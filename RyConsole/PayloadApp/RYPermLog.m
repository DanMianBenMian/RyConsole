//
//  RYPermLog.m
//  RyConsole —— 权限与安全（V2.4）
//
//  高危命令表是**人工划定**的（依据：会不会碰内核/进程/内存/钥匙串/文件系统写入）。
//  判定原则：能"改变设备或越出本沙盒"的算高危；只读自省类的算一般。
//

#import "RYPermLog.h"
#import "LiveActivityBridge.h"          // 灵动岛提醒（后台确认用）
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/mach_init.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <stdatomic.h>                   // V2.4.6 脚本级作用域（gScopeMode 原子读写）
#import <UserNotifications/UserNotifications.h>   // V2.4.8 无灵动岛后台通道（本地推送）
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <spawn.h>
#import <sys/wait.h>
#import <errno.h>

// sandbox_check 是私有 C API（main.m 里已声明过，这里再声明一次即可直接链接）
extern int sandbox_check(pid_t pid, const char *operation, ...);

// iOS SDK 的 mach.h 不保证导出 task_for_pid 声明（新 clang 隐式声明 = 硬错误）→ 显式声明
extern kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *task);

// ---- 高危命令 + 提示文案 ----
static NSDictionary *RYHighRiskMap(void) {
    static NSDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            // 进程 / 命令执行
            @"posixSpawn":        @"会真的 fork/exec 一个进程（任意可执行文件路径）",
            @"runCommand":        @"会走 popen 执行 shell 命令，等于把命令行交给 AI",
            // 内核 / 驱动面
            @"iokitOpen":         @"打开内核驱动(UserClient)，是 V3 内核面的入口",
            @"iokitCall":         @"向内核驱动发方法调用，畸形输入可能触发驱动异常甚至 panic",
            @"iokitCallStruct":   @"带结构体的驱动调用，风险高于标量调用",
            @"iokitMap":          @"映射驱动内存到本进程",
            // 任意代码执行
            @"callPtr":           @"调用任意函数指针（FFI），等于把 PC 交给任意地址",
            @"objc_msgSend":      @"向任意对象/地址发消息，垃圾接收者会崩",
            @"objc_msgSendSafe":  @"同上（带结构化错误，但一样能调到任意方法）",
            @"memRead":           @"读取进程内任意可读内存（dump）",
            // 数据 / 凭据
            @"keychainProbe":     @"探测钥匙串条目（可能触及凭据面）",
            // 写入 / 外发
            @"writeFile":         @"写文件到 App 沙盒（可覆盖脚本/桥，等于改自己的行为）",
            @"fileAppend":        @"追加写文件",
            @"fileDelete":        @"删除文件",
            @"tcpSend":           @"对外发原始 TCP 数据（可能把设备信息带出去）",
            @"xpcSendMsg":        @"向系统服务发 XPC 消息（可能触发服务端行为）"
        };
    });
    return m;
}

// ---- 一般（受管但仍记录到日志）----
static NSArray *RYManagedNormal(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"iokitEnum", @"iokitClose", @"iosurfaceProbe", @"iosurfaceCreate", @"iosurfaceLookup",
              @"iosurfaceSetValue", @"iosurfaceGetValue", @"iosurfaceGetID", @"iosurfaceRelease",
              @"objPtr", @"objCall", @"objc_getClass", @"sel_registerName", @"objcDesc",
              @"dlopenFW", @"dlsymAddr", @"symResolve", @"machLookUp", @"sandboxCheck",
              @"procListPids", @"readFile", @"writeFile", @"fileExists", @"fileSize",
              @"listDir", @"mkdir", @"tcpConnect", @"tcpScan", @"httpGet",
              @"lsWorkspace", @"lsAppList", @"lsAppListInfo", @"lsAppCount", @"lsAppInfo",
              @"lsOpenURL", @"lsOpenApp", @"openURL", @"canOpenURL",
              @"xpcConn", @"xpcClose", @"xpcProbe", @"xpcLookup",
              @"appInfo", @"getPid", @"getEntitlements", @"dumpEntitlements",
              @"sysctlGet", @"sleep", @"hexEncode", @"bytesB64", @"b64Bytes",
              @"crashGuardStatus", @"crashGuardSet", @"primHelp", @"primErrors", @"primMissing"];
    });
    return a;
}

@implementation RYPermLog {
    NSMutableArray *_entries;
    NSInteger _cntHigh;
    NSInteger _cntNormal;
    NSMutableDictionary *_enabledOverride;   // 命令 → @(BOOL)
}

+ (instancetype)shared {
    static RYPermLog *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RYPermLog alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _entries = [NSMutableArray array];
        _cntHigh = 0; _cntNormal = 0;
        _enabledOverride = [NSMutableDictionary dictionary];
        NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ryc_cmd_enabled"];
        if ([saved isKindOfClass:[NSDictionary class]]) [_enabledOverride addEntriesFromDictionary:saved];
    }
    return self;
}

#pragma mark - 命令表
+ (NSArray<NSString *> *)managedCommands {
    NSMutableArray *a = [NSMutableArray arrayWithArray:[RYHighRiskMap() allKeys]];
    [a addObjectsFromArray:RYManagedNormal()];
    return [a sortedArrayUsingSelector:@selector(compare:)];
}
+ (NSArray<NSString *> *)highRiskCommands {
    return [[RYHighRiskMap() allKeys] sortedArrayUsingSelector:@selector(compare:)];
}
+ (RYPermRisk)riskOfCommand:(NSString *)cmd {
    return RYHighRiskMap()[cmd] ? RYPermRiskHigh : RYPermRiskNormal;
}
+ (NSString *)riskLabel:(RYPermRisk)risk {
    return (risk == RYPermRiskHigh) ? @"高危" : @"一般";
}
+ (NSString *)warnTextOfCommand:(NSString *)cmd {
    return RYHighRiskMap()[cmd];
}

#pragma mark - 开关（默认全启用）
- (BOOL)isEnabled:(NSString *)cmd {
    NSNumber *v = _enabledOverride[cmd];
    return v ? [v boolValue] : YES;
}
- (void)setEnabled:(BOOL)on forCommand:(NSString *)cmd {
    _enabledOverride[cmd] = @(on);
    [[NSUserDefaults standardUserDefaults] setObject:_enabledOverride forKey:@"ryc_cmd_enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
- (void)resetAllEnabled:(BOOL)on {
    for (NSString *c in [RYPermLog managedCommands]) _enabledOverride[c] = @(on);
    [[NSUserDefaults standardUserDefaults] setObject:_enabledOverride forKey:@"ryc_cmd_enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 拦截
// ---- V2.4.6 脚本级权限作用域 ----
//   0 = 无作用域（逐次问）；1 = 本脚本全放行；2 = 本脚本全驳回。
//   进程级全局（race worker 线程共享主脚本的作用域）；用 C11 原子变量，gateCommand
//   会在任意线程（autorun 连接线程 / race worker）读它。
static atomic_int gScopeMode = 0;

+ (NSArray<NSString *> *)disabledCommandsInCode:(NSString *)code {
    if (![code isKindOfClass:[NSString class]] || !code.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *c in [RYPermLog managedCommands]) {
        if (![[RYPermLog shared] isEnabled:c] && [code rangeOfString:c].location != NSNotFound) [out addObject:c];
    }
    return out;
}

- (void)beginScriptScope:(NSString *)code {
    NSArray *dc = [RYPermLog disabledCommandsInCode:code];
    if (dc.count == 0) {                    // 没引用任何被禁命令 → 直接放行作用域，不弹窗
        atomic_store(&gScopeMode, 1);
        return;
    }
    // 一次性确认：列出全部被禁但要调用的命令
    __block BOOL granted = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self askUserForCommands:dc completion:^(BOOL ok) {
            granted = ok; dispatch_semaphore_signal(sem);
        }];
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC))) != 0) {
        granted = NO;                        // 超时按驳回（与旧语义一致）
        ryLiveActivityAlert("", NULL);       // 清掉灵动岛/锁屏上的权限提醒
    }
    atomic_store(&gScopeMode, granted ? 1 : 2);
    [self logCall:@"<脚本作用域>" risk:RYPermRiskNormal allowed:granted
             note:[NSString stringWithFormat:@"一次性确认：%@", [dc componentsJoinedByString:@"、"]]];
}

- (void)endScriptScope {
    atomic_store(&gScopeMode, 0);
}

// V2.4.8 无灵动岛/无 Live Activities 的后台通道：本地推送（所有设备都有）。
// 首次调用会向系统申请通知授权（拒绝则退化为"回 App 才能看到确认框"）。
// 点通知开 App → DidBecomeActive → askUserForCommands 的确认框弹出（60s 窗口内有效）。
- (void)postPermNotification:(NSString *)list {
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                     completionHandler:^(BOOL ok, NSError *err) {
                         if (!ok) return;   // 用户拒了通知授权 → 只能回 App 看
                         UNMutableNotificationContent *ct = [UNMutableNotificationContent new];
                         ct.title = @"RyConsole 请求权限";
                         ct.body  = [NSString stringWithFormat:@"要调用 %@ 命令，点开确认（60 秒内有效）", list];
                         ct.sound = [UNNotificationSound defaultSound];
                         UNNotificationRequest *req = [UNNotificationRequest
                             requestWithIdentifier:@"ryc_perm" content:ct trigger:nil];
                         [c addNotificationRequest:req withCompletionHandler:nil];
                     }];
}

// 一次性确认弹窗：主标题「请求权限」，副标题列出全部被禁但要调用的命令。
// ★ 后台/锁屏（V2.4.7）：先灵动岛+锁屏横幅把提醒顶出来（LiveActivity 的 alert 字段
//   会渲染在锁屏上），等 App 回前台再弹确认框 —— 用户在 60s 窗口内点开 App 都能确认。
//   前台直接弹。
- (void)askUserForCommands:(NSArray<NSString *> *)cmds completion:(void (^)(BOOL granted))cb {
    NSString *list = [cmds componentsJoinedByString:@"、"];
    BOOL background = ([UIApplication sharedApplication].applicationState != UIApplicationStateActive);
    BOOL liveOK = ryLiveActivityAvailable();

    if (background && liveOK)
        ryLiveActivityAlert("⚠️ 请求权限", [[NSString stringWithFormat:@"要调用 %@ 命令，点开确认", list] UTF8String]);
    else if (background)
        [self postPermNotification:list];   // V2.4.8 无灵动岛：本地推送补位

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"请求权限"
        message:[NSString stringWithFormat:@"要调用 %@ 命令\n\n允许：本脚本执行期间全部放行（含并发线程）\n不同意：本脚本内这些命令直接驳回",
                 list]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"允许" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        ryLiveActivityAlert("", NULL);
        if (cb) cb(YES);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"不同意" style:UIAlertActionStyleCancel handler:^(UIAlertAction *_) {
        ryLiveActivityAlert("", NULL);
        if (cb) cb(NO);
    }]];

    void (^presentNow)(void) = ^{
        UIViewController *host = [self topViewController];
        if (host) {
            [host presentViewController:ac animated:YES completion:nil];
        } else {
            ryLiveActivityAlert("", NULL);
            if (cb) cb(NO);           // 实在找不到宿主 → 按驳回（不吊死脚本）
        }
    };

    if (!background) {
        dispatch_async(dispatch_get_main_queue(), presentNow);
        return;
    }

    // 后台：等 DidBecomeActive 再弹。60s 信号量超时后 beginScriptScope 已走驳回并清
    // 灵动岛提醒；届时再弹出的框点了也无副作用（cb 只会被有效消费一次）。
    __block id obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            [[NSNotificationCenter defaultCenter] removeObserver:obs];
            dispatch_async(dispatch_get_main_queue(), presentNow);
        }];
    // 防观察者泄漏：120s 后无论如何摘掉
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] removeObserver:obs];
    });
}

- (NSDictionary *)gateCommand:(NSString *)cmd {
    RYPermRisk risk = [RYPermLog riskOfCommand:cmd];
    BOOL managed = (RYHighRiskMap()[cmd] != nil) || [RYManagedNormal() containsObject:cmd];

    if (!managed) {
        [self logCall:cmd risk:risk allowed:YES note:@""];
        return @{@"ok": @YES};
    }

    // V2.4.6 脚本作用域：1=全放行 / 2=全驳回（不再逐次问）
    int mode = atomic_load(&gScopeMode);
    if (mode == 1) {
        [self logCall:cmd risk:risk allowed:YES note:@"脚本级放行"];
        return @{@"ok": @YES};
    }
    if (mode == 2) {
        [self logCall:cmd risk:risk allowed:NO note:@"脚本已驳回，直接拦截"];
        return @{@"ok": @NO,
                 @"error": [NSString stringWithFormat:@"[权限] 权限请求驳回：%@（本脚本权限已被用户驳回，直接拦截）", cmd]};
    }

    if ([self isEnabled:cmd]) {
        [self logCall:cmd risk:risk allowed:YES note:@""];
        return @{@"ok": @YES};
    }

    // 被禁用 → 问用户（UI 在主线程，当前线程同步等）
    __block BOOL granted = NO;
    __block BOOL timeout = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self askUserForCommand:cmd completion:^(BOOL ok, BOOL to) {
            granted = ok; timeout = to;
            dispatch_semaphore_signal(sem);
        }];
    });
    // 等 60s（Autorun 的 job TTL 是 300s，留足富余）；超时按**驳回**处理（安全侧失败）
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC))) != 0) {
        granted = NO; timeout = YES;
    }

    if (granted) {
        [self logCall:cmd risk:risk allowed:YES note:@"用户临时同意"];
        return @{@"ok": @YES};
    }
    NSString *msg = timeout
        ? [NSString stringWithFormat:@"[权限] 权限请求驳回：%@（等待确认超时 60s，按不同意处理）", cmd]
        : [NSString stringWithFormat:@"[权限] 权限请求驳回：%@（用户在设备上点了「不同意」）", cmd];
    [self logCall:cmd risk:risk allowed:NO note:(timeout ? @"超时驳回" : @"用户驳回")];
    return @{@"ok": @NO, @"error": msg};
}

// 主线程执行：后台+有灵动岛 → 灵动岛提醒（点进来在 App 内确认）；否则直接弹窗
- (void)askUserForCommand:(NSString *)cmd completion:(void (^)(BOOL granted, BOOL timeout))cb {
    BOOL background = ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground);
    BOOL liveOK = ryLiveActivityAvailable();

    if (background && liveOK) {
        // 灵动岛是"提醒面"：先弹岛，用户点进来后 App 内再弹确认框。
        ryLiveActivityAlert("⚠️ 请求权限", [[NSString stringWithFormat:@"要调用 %@ 命令，点开确认", cmd] UTF8String]);
    }

    NSString *title = @"请求权限";
    NSString *message = [NSString stringWithFormat:@"要调用 %@ 命令\n\n风险等级：%@%@", cmd,
                         [RYPermLog riskLabel:[RYPermLog riskOfCommand:cmd]],
                         ([RYPermLog warnTextOfCommand:cmd]
                          ? [NSString stringWithFormat:@"\n%@", [RYPermLog warnTextOfCommand:cmd]] : @"")];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"允许" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        ryLiveActivityAlert("", NULL);   // 清掉岛上的提醒
        if (cb) cb(YES, NO);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"不同意" style:UIAlertActionStyleCancel handler:^(UIAlertAction *_) {
        ryLiveActivityAlert("", NULL);
        if (cb) cb(NO, NO);
    }]];

    UIViewController *host = [self topViewController];
    if (!host) { if (cb) cb(NO, YES); return; }
    [host presentViewController:ac animated:YES completion:nil];
}

- (UIViewController *)topViewController {
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *ww in ((UIWindowScene *)s).windows) if (ww.isKeyWindow) { w = ww; break; }
            }
        }
    }
    if (!w) w = [UIApplication sharedApplication].keyWindow;
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

#pragma mark - 日志
- (void)logCall:(NSString *)cmd risk:(RYPermRisk)risk allowed:(BOOL)allowed note:(NSString *)note {
    NSDictionary *e = @{@"ts": @([[NSDate date] timeIntervalSince1970]),
                        @"cmd": cmd ?: @"?",
                        @"risk": @(risk),
                        @"allowed": @(allowed),
                        @"note": note ?: @""};
    @synchronized (self) {
        [_entries addObject:e];
        if (_entries.count > 500) [_entries removeObjectsInRange:NSMakeRange(0, _entries.count - 500)];
        if (risk == RYPermRiskHigh) _cntHigh++; else _cntNormal++;
    }
}
- (NSArray<NSDictionary *> *)entries:(RYPermLogFilter)filter {
    @synchronized (self) {
        NSArray *rev = [[_entries reverseObjectEnumerator] allObjects];
        if (filter == RYPermLogFilterAll) return rev;
        NSInteger want = (filter == RYPermLogFilterHigh) ? RYPermRiskHigh : RYPermRiskNormal;
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *e in rev) if ([e[@"risk"] integerValue] == want) [out addObject:e];
        return out;
    }
}
- (NSInteger)countHigh   { @synchronized (self) { return _cntHigh; } }
- (NSInteger)countNormal { @synchronized (self) { return _cntNormal; } }
- (void)clearLog {
    @synchronized (self) { [_entries removeAllObjects]; _cntHigh = 0; _cntNormal = 0; }
}

#pragma mark - 权限诊断
+ (NSDictionary<NSString *, NSString *> *)entitlementDescriptions {
    return @{
        @"get-task-allow":                 @"允许调试器附加（未签名/自签通常有）",
        @"task_for_pid-allow":             @"拿其他进程 task port（实验版才有）",
        @"com.apple.system-task-ports":     @"系统进程 task port（私有，极易被 AMFI 拒）",
        @"com.apple.private.mobilehousearrest": @"House Arrest 跨容器（3105 分析判死，仅供实测）",
        @"com.apple.private.containermanager":  @"容器管理私有权限",
        @"com.apple.security.exception.mach-lookup.global-name": @"沙盒例外：允许向指定系统 Mach 服务发起 look_up",
        @"com.apple.security.exception.files.absolute-path.read-only": @"沙盒例外：允许读指定绝对路径",
        @"application-identifier":          @"App 唯一标识（沙盒容器归属）",
        @"keychain-access-groups":          @"钥匙串访问组（跨 App 共享钥匙串）",
        @"com.apple.security.application-groups": @"App Group（共享容器 / 扩展通信）",
        @"com.apple.developer.default-data-protection": @"文件数据保护等级",
        @"com.apple.security.cs.allow-jit":       @"允许 JIT（运行时代码生成）",
        @"com.apple.security.cs.allow-unsigned-executable-memory": @"允许执行未签名内存页",
        @"com.apple.security.cs.disable-library-validation": @"关闭库签名校验（可加载未签名 dylib）",
        @"com.apple.security.cs.debugger":        @"允许自身被调试",
        @"platform-application":            @"平台 App（系统级，不受普通沙盒约束）",
        @"com.apple.private.security.no-sandbox": @"关闭沙盒（完全不受限）",
        @"com.apple.security.iokit-user-client-class": @"允许打开指定 IOKit UserClient",
        @"com.apple.mobileinstallation.allowedSPI": @"允许调用受限 MobileInstallation SPI",
    };
}

+ (NSArray<NSDictionary *> *)capabilitySpecs {
    return @[
        @{@"kind": @"sandbox_mach",  @"title": @"sandbox_check(mach-lookup)", @"desc": @"Mach 服务查询是否被沙盒允许"},
        @{@"kind": @"sandbox_file",  @"title": @"sandbox_check(file-read*)",  @"desc": @"文件读取类操作（默认自身沙盒内可读）"},
        @{@"kind": @"iokit",         @"title": @"IOKit 打开 IOSurfaceRoot",   @"desc": @"V3 的入口：能否拿到 UserClient"},
        @{@"kind": @"mach",          @"title": @"machLookUp(com.apple.*)",    @"desc": @"能否看到系统 Mach 服务"},
        @{@"kind": @"dyld",          @"title": @"dlopen 私有框架",             @"desc": @"能否加载 PrivateFrameworks"},
        @{@"kind": @"spawn",         @"title": @"posixSpawn /bin/true",       @"desc": @"能否 fork/exec 子进程"},
        @{@"kind": @"keychain",      @"title": @"钥匙串访问",                   @"desc": @"SecItemCopyMatching 是否可用"},
        @{@"kind": @"liveactivity",  @"title": @"灵动岛 / 实时活动",            @"desc": @"后台权限提醒能不能走灵动岛"}
    ];
}

+ (NSArray<NSDictionary *> *)diagnosticSpecs {
    return [self capabilitySpecs];
}
// 读主程序嵌入的 entitlements（XML plist 文本）。
// iOS 无 SecCode 公共 API；codesign 把 entitlements 放进 __LINKEDIT 的签名 blob 里
// （magic 0xfade7171），早期无签名导出则完全没有。两种都覆盖。
static NSString *RYEmbeddedEntitlementsString(void) {
    // iOS 没有 MH_EXECUTE_SYM → 遍历已加载 image，找 filetype == MH_EXECUTE 的主可执行
    const struct mach_header_64 *h = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh && mh->filetype == MH_EXECUTE) { h = (const struct mach_header_64 *)mh; break; }
    }
    if (!h) return nil;
    // 1) 命名段（部分工具 / 无签名导出会有）
    unsigned long size = 0;
    char *ptr = getsectdatafromheader_64(h, "__TEXT", "__entitlements", &size);
    if (ptr && size > 0)
        return [[NSString alloc] initWithBytes:ptr length:size encoding:NSUTF8StringEncoding];
    // 2) codesign 真正的位置：__LINKEDIT 签名 blob（magic 0xfade7171，文件/内存字节序 = fa de 71 71，后跟 4 字节大端长度 + XML plist）
    unsigned long lsz = 0;
    char *ld = getsegmentdata((const struct mach_header *)h, "__LINKEDIT", &lsz);
    if (ld && lsz > 8) {
        const uint8_t *b = (const uint8_t *)ld;
        for (unsigned long off = 0; off + 8 <= lsz; off++) {
            if (b[off]==0xfa && b[off+1]==0xde && b[off+2]==0x71 && b[off+3]==0x71) {
                uint32_t blen = ((uint32_t)b[off+4]<<24)|((uint32_t)b[off+5]<<16)|((uint32_t)b[off+6]<<8)|b[off+7];
                if (blen > 8 && off + blen <= lsz)
                    return [[NSString alloc] initWithBytes:(b + off + 8) length:(blen - 8) encoding:NSUTF8StringEncoding];
            }
        }
    }
    return nil;
}

// V2.4.11：内嵌/签名 blob 的 entitlements 解析成字典。
// 全能签等重签工具写的是**二进制 plist**（bplist00）——旧代码按 UTF-8 当文本返回再子串匹配，
// 二进制时乱码且全部判「未声明」。这里直接用 NSPropertyList/CFPropertyList 解析（二进制 + XML 通吃）。
static NSDictionary *RYEmbeddedEntitlementsDict(void) {
    const struct mach_header_64 *h = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh && mh->filetype == MH_EXECUTE) { h = (const struct mach_header_64 *)mh; break; }
    }
    if (!h) return nil;
    const void *data = NULL; unsigned long size = 0;
    char *ptr = getsectdatafromheader_64(h, "__TEXT", "__entitlements", &size);
    if (ptr && size > 0) { data = ptr; }
    if (!data || size == 0) {
        unsigned long lsz = 0;
        char *ld = getsegmentdata((const struct mach_header *)h, "__LINKEDIT", &lsz);
        if (ld && lsz > 8) {
            const uint8_t *b = (const uint8_t *)ld;
            for (unsigned long off = 0; off + 8 <= lsz; off++) {
                if (b[off]==0xfa && b[off+1]==0xde && b[off+2]==0x71 && b[off+3]==0x71) {
                    uint32_t blen = ((uint32_t)b[off+4]<<24)|((uint32_t)b[off+5]<<16)|((uint32_t)b[off+6]<<8)|b[off+7];
                    if (blen > 8 && off + blen <= lsz) { data = b + off + 8; size = blen - 8; break; }
                }
            }
        }
    }
    if (!data || size == 0) return nil;
    // blob 头（0xfade7171 + 4 字节长度）在 RYEmbeddedEntitlementsString 的扫描里已剥过；
    // 这里自己扫的 blob 同样剥 8 字节头；命名段则直接是 plist。
    const uint8_t *p = (const uint8_t *)data;
    uint32_t magic = (size >= 4) ? ((uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]) : 0;
    const uint8_t *pl = p; unsigned long plLen = size;
    if (magic == 0xfade7171 && size >= 8) { pl = p + 8; plLen = size - 8; }
    if (plLen == 0) return nil;
    NSData *pd = [NSData dataWithBytes:pl length:plLen];
    id obj = nil;
    // 容量受控（entitlements 不该超过 256KB）
    if (plLen > 256 * 1024) return nil;
    obj = [NSPropertyListSerialization propertyListWithData:pd options:NSPropertyListImmutable format:NULL error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    return obj;
}

// SecTask 符号是否可用（不可用时面板回退到旧的内嵌段判定语义）
static BOOL RYSecTaskEntValueAvailable(void) {
    return dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf") &&
           dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
}

// V2.4.10：SecTask 实测（签名层 = 内核视角）。内核 SecTask 校验读的是**签名 blob** 里的
// entitlements；全能签等重签工具注入的是签名层，与内嵌段（__TEXT,__entitlements / blob 内嵌 XML）
// 可以分叉 → 面板主判定改为 SecTask 取值，内嵌段检查降级为辅助标注。
// iOS SDK 无 SecTask 公开头 → dlsym 取符号，取不到明确退回（保持旧行为）。
static NSString *RYSecTaskEntValue(NSString *entKey) {
    typedef CFTypeRef (*RYSecTaskCreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*RYSecTaskCopyValueFn)(CFTypeRef, CFStringRef, CFErrorRef *);
    static RYSecTaskCreateFromSelfFn cfs = NULL;
    static RYSecTaskCopyValueFn cpv = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cfs = (RYSecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        cpv = (RYSecTaskCopyValueFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    });
    if (!cfs || !cpv) return nil;
    CFTypeRef task = cfs(kCFAllocatorDefault);
    if (!task) return nil;
    CFErrorRef err = NULL;
    CFTypeRef v = cpv(task, (__bridge CFStringRef)entKey, &err);
    CFRelease(task);
    if (!v) { if (err) CFRelease(err); return nil; }
    NSString *s;
    if (CFGetTypeID(v) == CFBooleanGetTypeID())
        s = [NSString stringWithFormat:@"%@(bool)", CFBooleanGetValue((CFBooleanRef)v) ? @"true" : @"false"];
    else if (CFGetTypeID(v) == CFStringGetTypeID())
        s = [NSString stringWithFormat:@"\"%@\"(string)", (__bridge NSString *)v];
    else
        s = [NSString stringWithFormat:@"%@", (__bridge id)v];
    CFRelease(v);
    return s;
}

// ent 键的功能探针（辅助证据；主判定 = SecTask 签名层）。
// facepanel_fix.md 实测基线：system-task-ports 在签名层生效时 mach_port_allocate /
// task_for_pid(self) 全通过；task_for_pid-allow 用 task_for_pid(1)；house_arrest /
// containermanager 用服务 lookup kr。
static NSString *RYEntProbeFor(NSString *entKey, BOOL *probeOK) {
    *probeOK = NO;
    if ([entKey isEqualToString:@"task_for_pid-allow"]) {
        mach_port_t t = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), 1, &t);
        if (t) mach_port_deallocate(mach_task_self(), t);
        *probeOK = (kr == KERN_SUCCESS);
        return [NSString stringWithFormat:@"task_for_pid(1) kr=0x%x", kr];
    }
    if ([entKey isEqualToString:@"com.apple.system-task-ports"]) {
        mach_port_t rp = MACH_PORT_NULL;
        kern_return_t kr1 = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
        if (rp) mach_port_deallocate(mach_task_self(), rp);
        mach_port_t tp = MACH_PORT_NULL;
        kern_return_t kr2 = task_for_pid(mach_task_self(), getpid(), &tp);
        if (tp) mach_port_deallocate(mach_task_self(), tp);
        *probeOK = (kr1 == KERN_SUCCESS && kr2 == KERN_SUCCESS);
        return [NSString stringWithFormat:@"mach_port_allocate kr=0x%x / task_for_pid(self) kr=0x%x", kr1, kr2];
    }
    if ([entKey isEqualToString:@"com.apple.private.mobilehousearrest"] ||
        [entKey isEqualToString:@"com.apple.private.containermanager"]) {
        typedef kern_return_t (*BLookUpFn)(mach_port_t, const char *, mach_port_t *);
        BLookUpFn bl = (BLookUpFn)dlsym(RTLD_DEFAULT, "bootstrap_look_up");
        if (!bl) return @"bootstrap_look_up 不可用（iOS 未导出）";
        mach_port_t bp = MACH_PORT_NULL;
        task_get_bootstrap_port(mach_task_self(), &bp);
        const char *svc = [entKey containsString:@"housearrest"] ? "com.apple.mobile.house_arrest"
                                                                 : "com.apple.mobile.containermanager";
        mach_port_t p = MACH_PORT_NULL;
        kern_return_t kr = bl(bp, svc, &p);
        if (p) mach_port_deallocate(mach_task_self(), p);
        *probeOK = (kr == KERN_SUCCESS);
        return [NSString stringWithFormat:@"bootstrap_look_up(%s) kr=0x%x", svc, kr];
    }
    return nil;   // 该键无可靠功能探针
}

// 前向声明（定义见下方 RYProbeCapabilityKind，runDiagnostics 会先调用）
static void RYProbeCapabilityKind(NSString *kind, BOOL *outOk, NSString **outDetail);

- (void)runDiagnostics:(void (^)(NSArray<NSDictionary *> *))done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *out = [NSMutableArray array];
        NSDictionary *embDict = RYEmbeddedEntitlementsDict();
        NSDictionary *descTbl = [RYPermLog entitlementDescriptions];

        // ---- ① Entitlement：动态枚举本 App 实际携带的所有键 ----
        //   候选 = 内嵌/签名 blob 解析出的全部键 ∪ 已知键表（捕获「签名层有、内嵌段无」的键）。
        //   只显示真实存在的键（签名层有值 或 内嵌段有值）；不存在的键跳过 → 不写死清单。
        NSMutableSet *cands = [NSMutableSet set];
        for (NSString *k in embDict.allKeys) [cands addObject:k];
        for (NSString *k in descTbl.allKeys) [cands addObject:k];
        NSArray *entKeys = [[cands allObjects] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *entKey in entKeys) {
            NSString *sig = RYSecTaskEntValue(entKey);
            BOOL emb = (embDict && embDict[entKey] != nil);
            if (!sig && !emb) continue;
            BOOL ok = (sig != nil);
            id embVal = embDict[entKey];
            NSString *embDesc = [embVal isKindOfClass:[NSString class]] ? (NSString *)embVal
                                : (embVal ? [NSString stringWithFormat:@"%@", embVal] : nil);
            NSMutableString *detail = [NSMutableString string];
            if (sig) {
                [detail appendFormat:@"签名层生效：%@", sig];
                if (!emb) [detail appendString:@" ⚠ 内嵌段未含（重签注入，签名/内嵌两处分叉）"];
            } else {
                [detail appendString:@"签名层无值（内核不认 → 不生效）"];
                if (emb) [detail appendString:@" · 但内嵌段已声明"];
            }
            if (embDesc) [detail appendFormat:@"\n内嵌段值：%@", embDesc];
            BOOL probeOK = NO;
            NSString *probe = RYEntProbeFor(entKey, &probeOK);
            if (probe) [detail appendFormat:@"\nprobe: %@（%@）", probe, probeOK ? @"通过" : @"未通过"];
            NSString *desc = descTbl[entKey] ?: @"（未知键，动态枚举得到）";
            [out addObject:@{@"group": @"Entitlement（签名层实测）", @"title": entKey,
                             @"desc": desc, @"ok": @(ok), @"detail": [detail copy]}];
        }

        // ---- ② 能力：数据驱动 registry，按 kind 分派探针 ----
        for (NSDictionary *spec in [RYPermLog capabilitySpecs]) {
            BOOL ok = NO; NSString *detail = @"";
            RYProbeCapabilityKind(spec[@"kind"], &ok, &detail);
            [out addObject:@{@"group": @"能力", @"title": spec[@"title"],
                             @"desc": spec[@"desc"], @"ok": @(ok), @"detail": detail}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(out); });
    });
}

// 能力探针（按 kind 分派），供 runDiagnostics 调用
static void RYProbeCapabilityKind(NSString *kind, BOOL *outOk, NSString **outDetail) {
    BOOL ok = NO; NSString *detail = @"";
    if ([kind isEqualToString:@"sandbox_mach"]) {
        errno = 0; int v = sandbox_check(getpid(), "mach-lookup", 0);
        ok = (v >= 0); detail = [NSString stringWithFormat:@"sandbox_check = %d（errno %d）", v, errno];
    } else if ([kind isEqualToString:@"sandbox_file"]) {
        errno = 0; int v = sandbox_check(getpid(), "file-read-data", 0);
        ok = (v >= 0); detail = [NSString stringWithFormat:@"sandbox_check = %d（errno %d）", v, errno];
    } else if ([kind isEqualToString:@"iokit"]) {
        CFMutableDictionaryRef m = IOServiceMatching("IOSurfaceRoot");
        io_service_t svc = m ? IOServiceGetMatchingService(MACH_PORT_NULL, m) : 0;
        io_connect_t conn = 0;
        kern_return_t okr = svc ? IOServiceOpen(svc, mach_task_self(), 0, &conn) : -1;
        ok = (okr == KERN_SUCCESS && conn != 0);
        detail = [NSString stringWithFormat:@"IOServiceOpen kr=0x%x conn=%u", okr, (unsigned)conn];
        if (conn) IOServiceClose(conn); if (svc) IOObjectRelease(svc);
    } else if ([kind isEqualToString:@"mach"]) {
        typedef kern_return_t (*BLookUpFn)(mach_port_t, const char *, mach_port_t *);
        BLookUpFn bl = (BLookUpFn)dlsym(RTLD_DEFAULT, "bootstrap_look_up");
        mach_port_t bp = MACH_PORT_NULL; task_get_bootstrap_port(mach_task_self(), &bp);
        if (!bl) detail = @"bootstrap_look_up 不可用（iOS 未导出该符号）";
        else { mach_port_t p = MACH_PORT_NULL; kern_return_t kr = bl(bp, "com.apple.securityd", &p);
               ok = (kr == KERN_SUCCESS); detail = [NSString stringWithFormat:@"bootstrap_look_up(com.apple.securityd) kr=0x%x", kr]; }
    } else if ([kind isEqualToString:@"dyld"]) {
        void *h = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        ok = (h != NULL); detail = ok ? @"dlopen OK（FrontBoardServices）" : [NSString stringWithFormat:@"dlopen 失败: %s", dlerror()];
    } else if ([kind isEqualToString:@"spawn"]) {
        pid_t pid = -1; char *argv[] = {(char *)"/bin/true", NULL};
        int sp = posix_spawn(&pid, "/bin/true", NULL, NULL, argv, NULL);
        ok = (sp == 0);
        detail = (sp == 0) ? [NSString stringWithFormat:@"posix_spawn ok pid=%d", pid] : [NSString stringWithFormat:@"posix_spawn err=%d (%s)", sp, strerror(sp)];
        if (sp == 0) { int st = 0; waitpid(pid, &st, 0); }
    } else if ([kind isEqualToString:@"keychain"]) {
        void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
        typedef int (*SecCopyFn)(CFDictionaryRef, CFTypeRef *);
        SecCopyFn fn = sec ? (SecCopyFn)dlsym(sec, "SecItemCopyMatching") : NULL;
        if (!sec || !fn) detail = @"Security 框架/符号不可用";
        else {
            CFStringRef *kClass=(CFStringRef *)dlsym(sec,"kSecClass"), *kClassGP=(CFStringRef *)dlsym(sec,"kSecClassGenericPassword"),
                         *kLimit=(CFStringRef *)dlsym(sec,"kSecMatchLimit"), *kLimitOne=(CFStringRef *)dlsym(sec,"kSecMatchLimitOne");
            if (!kClass||!kClassGP||!kLimit||!kLimitOne) detail = @"钥匙串常量取不到";
            else { NSDictionary *q=@{(__bridge id)*kClass:(__bridge id)*kClassGP,(__bridge id)*kLimit:(__bridge id)*kLimitOne};
                   CFTypeRef res=NULL; int st=fn((__bridge CFDictionaryRef)q,&res);
                   ok=(st==0||st==-25300);
                   detail=[NSString stringWithFormat:@"SecItemCopyMatching = %d（0=有条目 / -25300=无条目，两者都算钥匙串可达）", st];
                   if(res) CFRelease(res); }
        }
    } else if ([kind isEqualToString:@"liveactivity"]) {
        ok = ryLiveActivityAvailable();
        detail = ok ? @"灵动岛可用（后台权限提醒会先弹岛）" : @"不可用（后台提醒只能等回前台弹窗）";
    }
    if (outOk) *outOk = ok; if (outDetail) *outDetail = detail;
}


@end
