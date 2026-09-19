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
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <spawn.h>
#import <sys/wait.h>
#import <errno.h>

// sandbox_check 是私有 C API（main.m 里已声明过，这里再声明一次即可直接链接）
extern int sandbox_check(pid_t pid, const char *operation, ...);

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
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC))) != 0)
        granted = NO;                        // 超时按驳回（与旧语义一致）
    atomic_store(&gScopeMode, granted ? 1 : 2);
    [self logCall:@"<脚本作用域>" risk:RYPermRiskNormal allowed:granted
             note:[NSString stringWithFormat:@"一次性确认：%@", [dc componentsJoinedByString:@"、"]]];
}

- (void)endScriptScope {
    atomic_store(&gScopeMode, 0);
}

// 一次性确认弹窗：主标题「请求权限」，副标题列出全部被禁但要调用的命令
- (void)askUserForCommands:(NSArray<NSString *> *)cmds completion:(void (^)(BOOL granted))cb {
    NSString *list = [cmds componentsJoinedByString:@"、"];
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
    UIViewController *host = [self topViewController];
    if (!host) { if (cb) cb(NO); return; }
    [host presentViewController:ac animated:YES completion:nil];
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
+ (NSArray<NSDictionary *> *)diagnosticSpecs {
    return @[
      // ---- Entitlement（读 App 自身嵌入的 __entitlements 段）----
      @{@"key": @"ent:get-task-allow",                       @"group": @"Entitlement", @"title": @"get-task-allow",                   @"desc": @"允许调试器附加（未签名/自签通常有）"},
      @{@"key": @"ent:task_for_pid-allow",                   @"group": @"Entitlement", @"title": @"task_for_pid-allow",               @"desc": @"拿其他进程 task port（实验版才有）"},
      @{@"key": @"ent:com.apple.system-task-ports",          @"group": @"Entitlement", @"title": @"com.apple.system-task-ports",      @"desc": @"系统进程 task port（私有，极易被 AMFI 拒）"},
      @{@"key": @"ent:com.apple.private.mobilehousearrest",  @"group": @"Entitlement", @"title": @"mobilehousearrest",                @"desc": @"House Arrest 跨容器（3105 分析判死，仅供实测）"},
      @{@"key": @"ent:com.apple.private.containermanager",   @"group": @"Entitlement", @"title": @"containermanager",                 @"desc": @"容器管理私有权限"},
      // ---- 能力实测 ----
      @{@"key": @"cap:sandbox_mach",      @"group": @"能力", @"title": @"sandbox_check(mach-lookup)",  @"desc": @"Mach 服务查询是否被沙盒允许"},
      @{@"key": @"cap:sandbox_file",      @"group": @"能力", @"title": @"sandbox_check(file-read*)",   @"desc": @"文件读取类操作（默认自身沙盒内可读）"},
      @{@"key": @"cap:iokit",             @"group": @"能力", @"title": @"IOKit 打开 IOSurfaceRoot",    @"desc": @"V3 的入口：能否拿到 UserClient"},
      @{@"key": @"cap:mach",              @"group": @"能力", @"title": @"machLookUp(com.apple.*)",     @"desc": @"能否看到系统 Mach 服务"},
      @{@"key": @"cap:dyld",              @"group": @"能力", @"title": @"dlopen 私有框架",              @"desc": @"能否加载 PrivateFrameworks"},
      @{@"key": @"cap:spawn",             @"group": @"能力", @"title": @"posixSpawn /bin/true",        @"desc": @"能否 fork/exec 子进程"},
      @{@"key": @"cap:keychain",          @"group": @"能力", @"title": @"钥匙串访问",                    @"desc": @"SecItemCopyMatching 是否可用"},
      @{@"key": @"cap:liveactivity",      @"group": @"能力", @"title": @"灵动岛 / 实时活动",             @"desc": @"后台权限提醒能不能走灵动岛"}
    ];
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

- (void)runDiagnostics:(void (^)(NSArray<NSDictionary *> *))done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *out = [NSMutableArray array];
        NSString *entStr = RYEmbeddedEntitlementsString();

        for (NSDictionary *spec in [RYPermLog diagnosticSpecs]) {
            NSMutableDictionary *r = [spec mutableCopy];
            NSString *key = spec[@"key"];
            BOOL ok = NO;
            NSString *detail = @"";

            if ([key hasPrefix:@"ent:"]) {
                NSString *entKey = [key substringFromIndex:4];
                if (!entStr) {
                    detail = @"无 __entitlements 段（未嵌入 entitlement / 未签名）";
                } else {
                    // 段内容是 plist XML：直接子串匹配键名足够用于"诊断是否声明"
                    NSString *needle = [NSString stringWithFormat:@"<string>%@</string>", entKey];
                    ok = ([entStr rangeOfString:needle].length > 0)
                         || ([entStr rangeOfString:entKey].length > 0);
                    detail = ok ? @"已声明（注意：声明 ≠ 生效，取决于重签/安装方式）" : @"未声明";
                }
            } else if ([key isEqualToString:@"cap:sandbox_mach"]) {
                errno = 0;
                int v = sandbox_check(getpid(), "mach-lookup", 0);
                ok = (v >= 0);
                detail = [NSString stringWithFormat:@"sandbox_check = %d（errno %d）", v, errno];
            } else if ([key isEqualToString:@"cap:sandbox_file"]) {
                errno = 0;
                int v = sandbox_check(getpid(), "file-read-data", 0);
                ok = (v >= 0);
                detail = [NSString stringWithFormat:@"sandbox_check = %d（errno %d）", v, errno];
            } else if ([key isEqualToString:@"cap:iokit"]) {
                // iOS 既没有 IOMasterPort 也没有 kIOMasterPortDefault → 与 main.m 一致，直接传 MACH_PORT_NULL
                CFMutableDictionaryRef m = IOServiceMatching("IOSurfaceRoot");
                io_service_t svc = m ? IOServiceGetMatchingService(MACH_PORT_NULL, m) : 0;   // iOS：与 main.m 一致，传 MACH_PORT_NULL
                {
                    kern_return_t kr = svc ? KERN_SUCCESS : KERN_FAILURE;
                    io_connect_t conn = 0;
                    kern_return_t okr = svc ? IOServiceOpen(svc, mach_task_self(), 0, &conn) : -1;
                    ok = (okr == KERN_SUCCESS && conn != 0);
                    detail = [NSString stringWithFormat:@"IOServiceOpen kr=0x%x conn=%u", okr, (unsigned)conn];
                    if (conn) IOServiceClose(conn);
                    if (svc) IOObjectRelease(svc);
                }
            } else if ([key isEqualToString:@"cap:mach"]) {
                // iOS 不暴露 <servers/bootstrap.h> → 运行时 dlsym 取符号，取不到就明确说不可用
                typedef kern_return_t (*BLookUpFn)(mach_port_t, const char *, mach_port_t *);
                BLookUpFn bl = (BLookUpFn)dlsym(RTLD_DEFAULT, "bootstrap_look_up");
                mach_port_t bp = MACH_PORT_NULL;
                task_get_bootstrap_port(mach_task_self(), &bp);
                if (!bl) {
                    detail = @"bootstrap_look_up 不可用（iOS 未导出该符号）";
                } else {
                    mach_port_t p = MACH_PORT_NULL;
                    kern_return_t kr = bl(bp, "com.apple.securityd", &p);
                    ok = (kr == KERN_SUCCESS);
                    detail = [NSString stringWithFormat:@"bootstrap_look_up(com.apple.securityd) kr=0x%x", kr];
                }
            } else if ([key isEqualToString:@"cap:dyld"]) {
                void *h = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
                ok = (h != NULL);
                detail = ok ? @"dlopen OK（FrontBoardServices）" : [NSString stringWithFormat:@"dlopen 失败: %s", dlerror()];
            } else if ([key isEqualToString:@"cap:spawn"]) {
                pid_t pid = -1;
                char *argv[] = {(char *)"/bin/true", NULL};
                int sp = posix_spawn(&pid, "/bin/true", NULL, NULL, argv, NULL);
                ok = (sp == 0);
                detail = (sp == 0) ? [NSString stringWithFormat:@"posix_spawn ok pid=%d", pid]
                                   : [NSString stringWithFormat:@"posix_spawn err=%d (%s)", sp, strerror(sp)];
                if (sp == 0) { int st = 0; waitpid(pid, &st, 0); }
            } else if ([key isEqualToString:@"cap:keychain"]) {
                void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
                typedef int (*SecCopyFn)(CFDictionaryRef, CFTypeRef *);
                SecCopyFn fn = sec ? (SecCopyFn)dlsym(sec, "SecItemCopyMatching") : NULL;
                if (!sec || !fn) { detail = @"Security 框架/符号不可用"; }
                else {
                    CFStringRef *kClass   = (CFStringRef *)dlsym(sec, "kSecClass");
                    CFStringRef *kClassGP = (CFStringRef *)dlsym(sec, "kSecClassGenericPassword");
                    CFStringRef *kLimit   = (CFStringRef *)dlsym(sec, "kSecMatchLimit");
                    CFStringRef *kLimitOne= (CFStringRef *)dlsym(sec, "kSecMatchLimitOne");
                    if (!kClass || !kClassGP || !kLimit || !kLimitOne) { detail = @"钥匙串常量取不到"; }
                    else {
                        NSDictionary *q = @{(__bridge id)*kClass   : (__bridge id)*kClassGP,
                                            (__bridge id)*kLimit   : (__bridge id)*kLimitOne};
                        CFTypeRef res = NULL;
                        int st = fn((__bridge CFDictionaryRef)q, &res);
                        ok = (st == 0 || st == -25300);   // 0=errSecSuccess, -25300=errSecItemNotFound（不引 Security 头）
                        detail = [NSString stringWithFormat:@"SecItemCopyMatching = %d（0=有条目 / -25300=无条目，两者都算钥匙串可达）", st];
                        if (res) CFRelease(res);
                    }
                }
            } else if ([key isEqualToString:@"cap:liveactivity"]) {
                ok = ryLiveActivityAvailable();
                detail = ok ? @"灵动岛可用（后台权限提醒会先弹岛）" : @"不可用（后台提醒只能等回前台弹窗）";
            }

            r[@"ok"] = @(ok);
            r[@"detail"] = detail;
            [out addObject:r];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(out); });
    });
}

@end
