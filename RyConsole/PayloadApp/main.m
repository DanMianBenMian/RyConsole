#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <mach-o/getsect.h>
#import <mach-o/ldsyms.h>
#import <string.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <Security/Security.h>
#import <IOKit/IOKitLib.h>
#import <sys/sysctl.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <execinfo.h>
#import <signal.h>
#import "AutorunServer.h"
#import "KeepAlive.h"
#import "LiveActivityBridge.h"
#import "RyExec.h"
#import "MainShell.h"
#import "RyShellBridge.h"
// iOS SDK 不提供 IOSurface 的 umbrella 头(IOSurface.h 是 macOS 布局)，
// 这里自前向声明用到的 C API；符号仍由 IOSurface.framework 链接时提供(project.yml 已 -framework IOSurface)。
typedef struct __IOSurface *IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
extern size_t IOSurfaceGetHeight(IOSurfaceRef buffer);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
// 框架层 UAF 驱动所需 (A1 乙路线): 创建后可持久持有 + 操作属性 + 释放竞态
extern IOSurfaceID IOSurfaceGetID(IOSurfaceRef buffer);
extern void IOSurfaceSetValue(IOSurfaceRef buffer, CFStringRef key, CFTypeRef value);
extern CFTypeRef IOSurfaceCopyValue(IOSurfaceRef buffer, CFStringRef key);
extern IOSurfaceRef IOSurfaceLookup(IOSurfaceID csid);

// bootstrap_look_up 手动声明（app target 不公开 <servers/bootstrap.h>）
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
#define BOOTSTRAP_SUCCESS 0

// ============================================================
//  RyConsole — 侧载一次、免重签跑代码的控制台
//   · 输入页：代码框 + 「执行」按钮
//   · 输出页：执行结果/输出 + 左上「返回」
//   · 引擎：JavaScriptCore（iOS 内置，免费签可跑）
//   · 桥接原生能力：runCommand / 文件IO / XPC 探测与 fuzz
// ============================================================

static mach_port_t lookUp(const char *name) {
    mach_port_t bp = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);
    mach_port_t sp = MACH_PORT_NULL;
    if (bootstrap_look_up(bp, name, &sp) != BOOTSTRAP_SUCCESS) return MACH_PORT_NULL;
    return sp;
}

static BOOL bridgeIsEnabled(NSString *name);
static NSString *loadEngineSource(void);
static void installPrimitives(JSContext *ctx);
static NSString *RYAutorunRunCapture(NSString *code);   // Autorun: 独立 ctx 执行并捕获输出
static void RunCode(UIViewController *from, NSString *code);
static void (^gRunCompletion)(NSString *output);   // LocalSend Code 头设入：RunCode 执行结束后回传完整输出
static NSString *installIPANative(NSString *manifestUrl);
@interface OutputVC : UIViewController
@property (nonatomic, strong) UITextView *textView;
@end

// ===== 新增原生原语（一次性补齐；上层桥库可动态扩展，详见 bridge_*.js）=====
// 前向声明（这些函数在文件后方定义，供本区块调用）
static NSString *docsDir(void);
static NSArray<NSDictionary*> *allScripts(void);
static NSString *loadScriptByName(NSString *name);
static NSString *probeService(const char *name);

#pragma mark - TCP (BSD socket)
static NSData *dataFromHex(NSString *hex) {
    NSMutableData *d = [NSMutableData data];
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""]
                       stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    for (NSUInteger i=0; i+1<clean.length; i+=2) {
        unsigned int b=0;
        NSString *pair=[clean substringWithRange:NSMakeRange(i,2)];
        if ([[NSScanner scannerWithString:pair] scanHexInt:&b]) [d appendBytes:&b length:1];
    }
    return d;
}
// 返回 @"OPEN" / @"REFUSED" / @"TIMEOUT" / @"ERROR:..." ；sendHex 非空时额外发数据并收响应
static NSString *tcpProbe(NSString *host, int port, double timeoutSec, NSString *sendHex) {
    struct sockaddr_in addr; memset(&addr,0,sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, [host UTF8String], &addr.sin_addr) != 1) return @"ERROR:badhost";
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return @"ERROR:socket";
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int r = connect(fd, (struct sockaddr*)&addr, sizeof(addr));
    if (r != 0 && errno != EINPROGRESS) { close(fd); return @"REFUSED"; }
    if (r != 0) {
        fd_set wfds; struct timeval tv;
        tv.tv_sec=(int)timeoutSec; tv.tv_usec=(int)((timeoutSec-(int)timeoutSec)*1e6);
        FD_ZERO(&wfds); FD_SET(fd,&wfds);
        int sel = select(fd+1, NULL, &wfds, NULL, &tv);
        if (sel <= 0) { close(fd); return @"TIMEOUT"; }
        int err=0; socklen_t len=sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        if (err != 0) { close(fd); return @"REFUSED"; }
    }
    if (sendHex == nil) { close(fd); return @"OPEN"; }
    NSData *payload = dataFromHex(sendHex);
    if (payload.length) send(fd, [payload bytes], [payload length], 0);
    NSMutableData *resp=[NSMutableData data];
    char buf[4096];
    double remain = timeoutSec;
    while (remain > 0) {
        fd_set rfds; struct timeval rtv;
        rtv.tv_sec=(int)remain; rtv.tv_usec=(int)((remain-(int)remain)*1e6);
        FD_ZERO(&rfds); FD_SET(fd,&rfds);
        int sel = select(fd+1, &rfds, NULL, NULL, &rtv);
        if (sel <= 0) break;
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [resp appendBytes:buf length:n];
        remain -= 0.05;
    }
    close(fd);
    NSString *ascii = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
    if (ascii) return ascii;
    NSMutableString *hex=[NSMutableString stringWithString:@"HEX:"];
    const unsigned char *b=resp.bytes;
    for (NSUInteger i=0;i<resp.length;i++) [hex appendFormat:@"%02x", b[i]];
    return hex;
}
static NSString *tcpScanRange(NSString *host, int start, int end) {
    NSMutableArray *open=[NSMutableArray array];
    for (int p=start; p<=end; p++) {
        NSString *r = tcpProbe(host, p, 0.05, nil);
        if ([r isEqualToString:@"OPEN"]) [open addObject:@(p)];
    }
    return open.count==0 ? @"OPEN:none" : [@"OPEN:" stringByAppendingString:[open componentsJoinedByString:@","]];
}

#pragma mark - URL scheme
static NSString *canOpenURLStr(NSString *scheme) {
    NSURL *u = [NSURL URLWithString:scheme];
    if (!u) return @"NO";
    if ([[NSThread currentThread] isMainThread]) {
        return [[UIApplication sharedApplication] canOpenURL:u] ? @"YES" : @"NO";
    }
    __block BOOL res=NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        res = [[UIApplication sharedApplication] canOpenURL:u];
    });
    return res?@"YES":@"NO";
}
static NSString *openURLStr(NSString *url) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return @"ERROR:bad-url";
    void (^call)(void) = ^{
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    };
    if ([[NSThread currentThread] isMainThread]) call();
    else dispatch_sync(dispatch_get_main_queue(), call);
    return @"YES";
}
// 触发 OTA 无线安装（itms-services://）。manifest 必须 HTTPS（LocalSend 服务端已配受信任的自签 CA）。
static NSString *installIPANative(NSString *manifestUrl) {
    if (!manifestUrl || ![manifestUrl hasPrefix:@"http"]) return @"ERROR:bad-url";
    NSString *enc = [manifestUrl stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *scheme = [NSString stringWithFormat:@"itms-services://?action=download-manifest&url=%@", enc];
    return openURLStr(scheme);
}

#pragma mark - Pasteboard
static NSString *getPasteboardStr(void) { return [UIPasteboard generalPasteboard].string ?: @""; }
static NSString *setPasteboardStr(NSString *s) { [UIPasteboard generalPasteboard].string = s?:@""; return @"ok"; }

#pragma mark - Identity / entitlements
static NSString *appInfoStr(void) {
    UIDevice *d=[UIDevice currentDevice];
    NSBundle *b=[NSBundle mainBundle];
    NSMutableString *s=[NSMutableString string];
    [s appendFormat:@"system: %@ %@\n", d.systemName, d.systemVersion];
    [s appendFormat:@"device: %@ (%@)\n", d.model, d.userInterfaceIdiom==UIUserInterfaceIdiomPad?@"pad":@"phone"];
    [s appendFormat:@"name: %@\n", d.name];
    [s appendFormat:@"bundleID: %@\n", b.bundleIdentifier];
    [s appendFormat:@"appVersion: %@\n", [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
    [s appendFormat:@"exec: %@\n", [b executablePath]];
    [s appendFormat:@"docDir: %@\n", docsDir()];
    return s;
}
static int getPidInt(void) { return (int)getpid(); }

#pragma mark - Bug6: 自解释错误（格式与 memRead 一致: "[<桥名> error] 参数名 + 合法范围"）
// 目标：桥失败时，调用方（人或 AI）只看返回串就能改对参数，不必读源码猜签名。
// 动因：iokitMap 曾对所有形态只回 {"ret":-536870206}（kIOReturnBadArgument），
//       完全无法推断该传什么 —— 与 memRead 的自解释风格形成鲜明对比。
static NSString *ryPrimErr(NSString *prim, NSString *why) {
    return [NSString stringWithFormat:@"[%@ error] %@", prim, why ?: @"unknown"];
}

// errno → 名称 + 人话（sysctl / 文件类桥共用）
static NSString *ryErrnoName(int e) {
    switch (e) {
        case ENOENT: return @"ENOENT 无此名字";
        case EPERM:  return @"EPERM 权限不足（沙盒拒绝）";
        case EACCES: return @"EACCES 拒绝访问";
        case EINVAL: return @"EINVAL 名字或参数非法";
        case EIO:    return @"EIO 底层 IO 错误";
        case ENOMEM: return @"ENOMEM 内存不足";
        case ENOTDIR:return @"ENOTDIR 路径中有非目录";
        case EISDIR: return @"EISDIR 目标是目录";
        default:     return nil;
    }
}

// 句柄体检：把"连接已失效"与"参数形状不对"分开，避免两者都糊成 kIOReturnBadArgument
static NSString *ryConnProblem(long conn) {
    if (conn <= 0)
        return [NSString stringWithFormat:
                @"conn must be a handle from iokitOpen() (>0), got %ld；先 jbProbeIOKit('IOSurfaceRoot') 拿句柄", conn];
    mach_port_type_t pt = 0;
    if (mach_port_type(mach_task_self(), (mach_port_name_t)conn, &pt) != KERN_SUCCESS || pt == 0)
        return [NSString stringWithFormat:
                @"conn %ld 不是有效的 Mach send right（已 iokitClose，或服务被回收）", conn];
    return nil;
}

// ===== V3 决定性原语: 打开/调用/映射/关闭/枚举 IOKit UserClient =====
// iokitOpen: 返回 io_connect_t (>0 成功)；失败返回负值：
//   -2 = 服务类不存在(名错)   -3 = 类名为空(参数错)   -9999 = 原生抛异常
//   其它负值 = IOServiceOpen 的 kr（如 0xe00002e2 → -536870174 kIOReturnNotPermitted = 沙盒门禁）
//   沙盒无对应 entitlement 时 IOServiceOpen 返回 kIOReturnNotPermitted；若该 UserClient 的 newUserClient
//   不查 entitlement(如静态审计点名的 VCPDRM)，沙盒 App 将得到 >=0 的 conn —— 这正是 V3 要证实/证伪的。
static long iokitOpenNative(NSString *className, int type) {
    if (![className isKindOfClass:[NSString class]] || className.length == 0) return -3;
    @try {
        io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL,
                                                        IOServiceMatching([className UTF8String]));
        if (svc == IO_OBJECT_NULL) return -2;
        io_connect_t conn = IO_OBJECT_NULL;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), (uint32_t)type, &conn);
        IOObjectRelease(svc);
        if (kr == KERN_SUCCESS) return (long)conn;
        return (long)kr;
    } @catch (NSException *e) {
        return -9999;
    }
}

// IOConnectCallMethod 封装。inputs: NSArray<NSNumber> (最多16个uint64)；返回 {ret:kr, outputs:[...], ok, error?}
// Bug6：conn 先体检；inputs 里非数字项会被丢弃并在 note 里点名（旧版把它们当占位槽，形状静默变宽）
static NSDictionary *iokitCallNative(long conn, uint32_t selector, NSArray *inputs) {
    NSString *bad = ryConnProblem(conn);
    if (bad) {
        return @{@"ret":@((long)kIOReturnBadArgument), @"outputs":@[], @"ok":@NO,
                 @"error":ryPrimErr(@"iokitCall", bad),
                 @"hint":@"iokitCall(conn, selector, inputs): conn = iokitOpen() 句柄；selector = uint32；inputs = 数字数组(≤16)"};
    }
    if (inputs != nil && ![inputs isKindOfClass:[NSArray class]])
        return @{@"ret":@((long)kIOReturnBadArgument), @"outputs":@[], @"ok":@NO,
                 @"error":ryPrimErr(@"iokitCall", @"inputs must be an array of numbers (可省略/空数组)")};
    uint64_t in[16] = {0}; uint32_t inCnt = 0; NSUInteger dropped = 0, overflow = 0;
    if ([inputs isKindOfClass:[NSArray class]]) {
        for (NSUInteger i = 0; i < inputs.count; i++) {
            id v = inputs[i];
            if (![v isKindOfClass:[NSNumber class]]) { dropped++; continue; }
            if (inCnt >= 16) { overflow++; continue; }
            in[inCnt++] = [v unsignedLongLongValue];
        }
    }
    uint64_t out[16] = {0}; uint32_t outCnt = 16;
    kern_return_t kr = IOConnectCallMethod((io_connect_t)conn, selector, in, inCnt, NULL, 0, out, &outCnt, NULL, NULL);
    NSMutableArray *oa = [NSMutableArray arrayWithCapacity:outCnt];
    for (uint32_t i = 0; i < outCnt; i++) [oa addObject:@(out[i])];
    NSMutableDictionary *res = [@{@"ret":@((long)kr), @"outputs":oa, @"inCount":@(inCnt),
                                  @"ok":@(kr == KERN_SUCCESS)} mutableCopy];
    if (dropped || overflow)
        res[@"note"] = [NSString stringWithFormat:@"inputs 有 %lu 个非数字项被忽略%s（标量输入上限 16）",
                        (unsigned long)dropped, overflow ? "，并有超出 16 的项被丢弃" : ""];
    return res;
}

// IOConnectCallMethod 封装（struct 变体）：在标量输入基础上额外接受 inputStruct 字节块，
// 返回标量输出 + struct 输出（base64）。这是 V3 (b) 的关键 —— 旧版 iokitCallNative 把
// inputStruct/OOL 实参传 NULL，打不动需要 OSData/结构化输入的 IOExternalMethod 方法。
static NSDictionary *iokitCallStructNative(long conn, uint32_t selector, NSArray *scalarInputs, NSData *structInput, NSUInteger outStructSize) {
    NSString *bad = ryConnProblem(conn);
    if (bad) {
        return @{@"ret":@((long)kIOReturnBadArgument), @"outputs":@[], @"ok":@NO, @"outStructSize":@0,
                 @"error":ryPrimErr(@"iokitCallStruct", bad),
                 @"hint":@"iokitCallStruct(conn, selector, scalarInputs, structB64, outSize): outSize 合法范围 1..65536（0/超界会被按 4096 兜底）"};
    }
    NSMutableArray *notes = [NSMutableArray array];
    uint64_t in[16] = {0}; uint32_t inCnt = 0; NSUInteger dropped = 0;
    if (scalarInputs != nil && ![scalarInputs isKindOfClass:[NSArray class]])
        return @{@"ret":@((long)kIOReturnBadArgument), @"outputs":@[], @"ok":@NO, @"outStructSize":@0,
                 @"error":ryPrimErr(@"iokitCallStruct", @"scalarInputs must be an array of numbers (可省略)")};
    if ([scalarInputs isKindOfClass:[NSArray class]]) {
        for (NSUInteger i = 0; i < scalarInputs.count; i++) {
            id v = scalarInputs[i];
            if (![v isKindOfClass:[NSNumber class]]) { dropped++; continue; }
            if (inCnt >= 16) { dropped++; continue; }
            in[inCnt++] = [v unsignedLongLongValue];
        }
    }
    if (dropped) [notes addObject:[NSString stringWithFormat:@"scalarInputs 有 %lu 项被忽略（非数字 / 超过 16）", (unsigned long)dropped]];
    const void *inStruct = (structInput && structInput.length) ? structInput.bytes : NULL;
    size_t inStructSize = structInput ? structInput.length : 0;
    if (outStructSize == 0 || outStructSize > 65536) {
        [notes addObject:[NSString stringWithFormat:@"outSize 收到 %lu，超出合法范围 1..65536 → 已按 4096 兜底", (unsigned long)outStructSize]];
        outStructSize = 4096;
    }
    NSMutableData *outStruct = [NSMutableData dataWithLength:outStructSize];
    uint64_t out[16] = {0}; uint32_t outCnt = 16;
    size_t outStructUsed = outStructSize;
    kern_return_t kr = IOConnectCallMethod((io_connect_t)conn, selector,
        in, inCnt, inStruct, inStructSize,
        out, &outCnt, outStruct.mutableBytes, &outStructUsed);
    if (kr == kIOReturnNoSpace && outStructUsed > 0 && outStructUsed <= 65536) {
        // 内核要求更大的输出 struct 缓冲：按报告大小重试一次
        outStructSize = outStructUsed;
        outStruct = [NSMutableData dataWithLength:outStructSize];
        outStructUsed = outStructSize;
        kr = IOConnectCallMethod((io_connect_t)conn, selector,
            in, inCnt, inStruct, inStructSize,
            out, &outCnt, outStruct.mutableBytes, &outStructUsed);
    }
    NSMutableArray *oa = [NSMutableArray arrayWithCapacity:outCnt];
    for (uint32_t i = 0; i < outCnt; i++) [oa addObject:@(out[i])];
    NSMutableDictionary *res = [@{@"ret":@((long)kr), @"outputs":oa, @"ok":@(kr == KERN_SUCCESS)} mutableCopy];
    // 修复：仅 kr==kIOReturnSuccess 且确有输出字节时才回填 struct 输出，
    // 避免失败时把默认 4096 缓冲误报为"有输出"（测量噪声，会使 hasOutStruct 信号失真）
    if (kr == kIOReturnSuccess && outStructUsed > 0 && outStructUsed <= outStructSize) {
        NSData *real = [NSData dataWithBytes:outStruct.mutableBytes length:outStructUsed];
        res[@"outStruct"] = [real base64EncodedStringWithOptions:0];
        res[@"outStructSize"] = @((unsigned long long)outStructUsed);
    } else {
        res[@"outStructSize"] = @(0);
    }
    if (notes.count) res[@"note"] = [notes componentsJoinedByString:@"；"];
    return res;
}

// 字节数组 <-> base64 互转（供 JS 侧构造 struct 输入 / 解析 struct 输出，避免 JS 做二进制 base64）
static NSString *bytesToB64(NSArray *bytes) {
    if (![bytes isKindOfClass:[NSArray class]]) return @"";
    NSMutableData *d = [NSMutableData dataWithCapacity:bytes.count];
    for (id b in bytes) {
        if ([b isKindOfClass:[NSNumber class]]) {
            uint8_t v = (uint8_t)[b unsignedIntValue];
            [d appendBytes:&v length:1];
        }
    }
    return [d base64EncodedStringWithOptions:0];
}
static NSArray *b64ToBytes(NSString *b64) {
    if (![b64 isKindOfClass:[NSString class]] || b64.length == 0) return @[];
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!d) return @[];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:d.length];
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) [a addObject:@(p[i])];
    return a;
}

// IOConnectMapMemory64 封装。成功: {ret:0, ok, addr, size}
// 失败: {ret:kr, ok:NO, error:"[iokitMap error] …", hint:"…"} —— 不再只回一个裸 kr
static NSDictionary *iokitMapNative(long conn, uint32_t memType) {
    NSString *bad = ryConnProblem(conn);
    if (bad) {
        return @{@"ret":@((long)kIOReturnBadArgument), @"ok":@NO,
                 @"error":ryPrimErr(@"iokitMap", bad),
                 @"hint":@"iokitMap(conn, memType): conn = iokitOpen() 的句柄(>0)；memType = uint32(常见 0..15)"};
    }
    mach_vm_address_t addr = 0; mach_vm_size_t size = 0;
    kern_return_t kr = IOConnectMapMemory64((io_connect_t)conn, memType, mach_task_self(), &addr, &size, kIOMapAnywhere);
    if (kr != KERN_SUCCESS) {
        return @{@"ret":@((long)kr), @"ok":@NO, @"conn":@(conn), @"memType":@(memType),
                 @"error":[NSString stringWithFormat:
                           @"[iokitMap error] IOConnectMapMemory64 kr=0x%08x (memType=%u 被拒)",
                           (uint32_t)kr, memType],
                 @"hint":@"该 UserClient 多半没为这个 memType 实现 clientMemoryForType；先跑 iokitMapTry(conn) 扫 0..15，"
                         @"全 BadArgument 就换路径（IOSurface 不必 map，直接 IOSurfaceGetBaseAddress）"};
    }
    return @{@"ret":@((long)kr), @"ok":@YES, @"addr":@((unsigned long long)addr),
             @"size":@((unsigned long long)size), @"memType":@(memType)};
}

static long iokitCloseNative(long conn) {
    return (long)IOServiceClose((io_connect_t)conn);
}

// 枚举 IORegistry (IOService plane, 递归) 中所有 IOKit 类，去重后返回类名数组。
// 这是 V3 的"全攻击面地图" —— 揭示沙盒用户态能看到的全部 UserClient 类。
static NSArray *iokitEnumNative(void) {
    io_registry_entry_t root = IORegistryGetRootEntry(MACH_PORT_NULL);
    if (root == IO_OBJECT_NULL) return @[];
    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iter);
    if (kr != KERN_SUCCESS) { IOObjectRelease(root); return @[]; }
    NSMutableSet *classes = [NSMutableSet set];
    io_registry_entry_t ent;
    while ((ent = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        io_name_t cls = {0};
        if (IOObjectGetClass(ent, cls) == KERN_SUCCESS && cls[0]) {
            [classes addObject:[NSString stringWithUTF8String:cls]];
        }
        IOObjectRelease(ent);
    }
    IOObjectRelease(iter);
    IOObjectRelease(root);
    return [classes allObjects];
}

// 读 sysctl (by name)。字符串型返回 NSString，整数型返回 NSNumber。
// 失败返回 "[sysctlGet error] 名字/errno 说明"（Bug6：不再只回 "<sysctl err N>"）。
// 关键用途: kern.bootargs(看 AMFI/sandbox 例外痕迹) / kern.version(内核版本) / hw.*。
static id sysctlGetNative(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0)
        return ryPrimErr(@"sysctlGet", @"name must be a non-empty string, e.g. \"kern.version\" / \"kern.bootargs\" / \"hw.memsize\"");
    const char *cname = [name UTF8String];
    size_t len = 0;
    if (sysctlbyname(cname, NULL, &len, NULL, 0) != 0) {
        int e0 = errno;
        long long lval = 0; size_t llen = sizeof(lval);
        if (sysctlbyname(cname, &lval, &llen, NULL, 0) == 0) return @(lval);
        int ival = 0; size_t ilen = sizeof(ival);
        if (sysctlbyname(cname, &ival, &ilen, NULL, 0) == 0) return @(ival);
        NSString *why = ryErrnoName(e0);
        return ryPrimErr(@"sysctlGet", [NSString stringWithFormat:
                @"unknown name \"%@\" (errno %d%@); 名字必须真实存在，可用 sysctlGet(\"kern.version\") 先验证桥通不通",
                name, e0, why ? [@" " stringByAppendingString:why] : @""]);
    }
    if (len == 0)
        return ryPrimErr(@"sysctlGet", [NSString stringWithFormat:@"\"%@\" 存在但长度为 0（无可读值）", name]);
    NSMutableData *buf = [NSMutableData dataWithLength:len];
    if (sysctlbyname(cname, [buf mutableBytes], &len, NULL, 0) != 0) {
        int e1 = errno;
        NSString *why = ryErrnoName(e1);
        return ryPrimErr(@"sysctlGet", [NSString stringWithFormat:@"读 \"%@\" 失败 (errno %d%@)", name, e1,
                                        why ? [@" " stringByAppendingString:why] : @""]);
    }
    char *c = (char *)[buf mutableBytes];
    BOOL printable = YES;
    for (size_t i = 0; i + 1 < len; i++) {
        unsigned char ch = (unsigned char)c[i];
        if (ch == 0) break;
        if (ch < 0x20 && ch != '\t' && ch != '\n') { printable = NO; break; }
        if (ch >= 0x7f) { printable = NO; break; }
    }
    if (printable) {
        NSString *s = [[NSString alloc] initWithBytes:c length:strlen(c) encoding:NSUTF8StringEncoding];
        return s ?: [NSString stringWithFormat:@"<len=%zu non-utf8>", len];
    }
    return [NSString stringWithFormat:@"<binary len=%zu>", len];
}

static NSString *getEntitlementsStr(void) {
    // iOS 无 SecCode 公共 API（macOS 专有）；改为直接读主可执行文件 __TEXT,__entitlements 段
    // （CS_Entitlements blob：magic 0xfade7171 + length + 二进制 plist）。免费侧载包签名后此处有真实 entitlements；未签名包无段则优雅返回。
    unsigned long size = 0;
    const void *data = getsectiondata(&_mh_execute_header, "__TEXT", "__entitlements", &size);
    if (!data) data = getsectiondata(&_mh_execute_header, "__LINKEDIT", "__entitlements", &size);
    if (!data || size == 0)
        return @"[getEntitlements] no __entitlements section (unsigned build / none embedded)";
    const uint8_t *p = (const uint8_t*)data;
    uint32_t magic = (size>=4) ? ((uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]) : 0;
    const uint8_t *plist;
    unsigned long plistLen;
    if (magic == 0xfade7171 && size >= 8) {   // CSMAGIC_ENTITLEMENTS
        plist = p + 8; plistLen = size - 8;
    } else {
        plist = p; plistLen = size;
    }
    if (plistLen == 0) return @"[getEntitlements] empty";
    NSData *pd = [NSData dataWithBytes:plist length:plistLen];
    CFErrorRef e = NULL;
    CFPropertyListRef pl = CFPropertyListCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)pd, kCFPropertyListImmutable, NULL, &e);
    if (!pl) { if(e) CFRelease(e); return @"[getEntitlements] plist parse failed"; }
    CFDataRef xml = CFPropertyListCreateData(kCFAllocatorDefault, pl, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    CFRelease(pl);
    if (!xml) return @"[getEntitlements] xml serialize failed";
    NSString *s = [[NSString alloc] initWithData:(__bridge NSData*)xml encoding:NSUTF8StringEncoding];
    CFRelease(xml);
    return s ?: @"[getEntitlements] empty string";
}

#pragma mark - IOSurface (内核相邻面)
static NSString *iosurfaceProbeStr(void) {
    NSMutableString *s=[NSMutableString string];
    // 直接用 CFSTR 字面量作 key，避免依赖 IOSurface.framework 导出的 kIOSurface* 常量符号
    NSDictionary *props=@{
        (__bridge id)CFSTR("IOSurfaceWidth"):@(4),
        (__bridge id)CFSTR("IOSurfaceHeight"):@(4),
        (__bridge id)CFSTR("IOSurfaceBytesPerElement"):@(4),
        (__bridge id)CFSTR("IOSurfaceBytesPerRow"):@(16)
    };
    IOSurfaceRef surf=IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (surf) {
        [s appendFormat:@"CREATE_OK width=%d height=%d allocSize=%llu\n",
              (int)IOSurfaceGetWidth(surf), (int)IOSurfaceGetHeight(surf),
              (unsigned long long)IOSurfaceGetAllocSize(surf)];
        void *m=IOSurfaceGetBaseAddress(surf);
        if (m) { memset(m, 0xAB, 4*4*4); [s appendString:@"MAP_OK baseWritable=YES\n"]; }
        CFRelease(surf);
    } else {
        [s appendFormat:@"CREATE_FAILED %@\n",
              ryPrimErr(@"iosurfaceProbe", @"IOSurfaceCreate 返回 NULL；探针写死的 props 为 {Width:4,Height:4,BytesPerElement:4,BytesPerRow:16}，失败说明本进程拿不到 IOSurface（沙盒/框架不可用），不是参数问题")];
    }
    return s;
}

#pragma mark - IOSurface 框架层 UAF 驱动桥 (A1 / 乙路线)
// 持久注册表: 让 JS 创建的 surface 跨调用存活, 可对其做 set/get value + release 竞态。
static NSMutableDictionary<NSNumber*, id> *gSurfRegistry = nil;
static int gSurfNextHandle = 1;

// 返回：>0 持久句柄；失败返回 "[iosurfaceCreate error] …" 字符串（Bug6：原来只回 -1，看不出是哪种参数错）
static id iosurfaceCreateNative(NSDictionary *props) {
    if (props != nil && ![props isKindOfClass:[NSDictionary class]])
        return ryPrimErr(@"iosurfaceCreate", @"props must be an object (省略也行)，键示例 {IOSurfaceWidth:4, IOSurfaceHeight:4, IOSurfaceBytesPerElement:4}");
    if (!gSurfRegistry) gSurfRegistry = [NSMutableDictionary dictionary];
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)(props ?: @{}));
    if (!surf)
        return ryPrimErr(@"iosurfaceCreate", @"IOSurfaceCreate 返回 NULL —— props 缺必需键或值非法；"
                         @"最小可用集 {IOSurfaceWidth:4, IOSurfaceHeight:4, IOSurfaceBytesPerElement:4, IOSurfaceBytesPerRow:16}");
    NSNumber *h = @(gSurfNextHandle++);
    gSurfRegistry[h] = (__bridge_transfer id)surf; // ARC 接管所有权, 安全持有
    return h;
}
static id iosurfaceGetIDNative(NSNumber *handle) {
    if (!gSurfRegistry) return ryPrimErr(@"iosurfaceGetID", @"本进程还没创建过任何 surface（注册表为空），先 iosurfaceCreate(props)");
    IOSurfaceRef surf = (__bridge IOSurfaceRef)(gSurfRegistry[handle]);
    if (!surf) return ryPrimErr(@"iosurfaceGetID", [NSString stringWithFormat:
                        @"unknown handle %@；句柄由 iosurfaceCreate()/iosurfaceLookup() 返回（本进程内有效，重启即失效）", handle]);
    return @((unsigned int)IOSurfaceGetID(surf));
}
static NSString *iosurfaceSetValueNative(NSNumber *handle, NSString *key, NSString *value) {
    if (!gSurfRegistry) return ryPrimErr(@"iosurfaceSetValue", @"本进程还没创建过任何 surface，先 iosurfaceCreate(props)");
    IOSurfaceRef surf = (__bridge IOSurfaceRef)(gSurfRegistry[handle]);
    if (!surf) return ryPrimErr(@"iosurfaceSetValue", [NSString stringWithFormat:
                        @"unknown handle %@（句柄来自 iosurfaceCreate()/iosurfaceLookup()）", handle]);
    NSString *k = key.length ? key : @"k";
    // 支持 base64 -> CFData (构造大/畸形值), 否则 CFString
    NSData *d = [[NSData alloc] initWithBase64EncodedString:(value?:@"") options:0];
    CFTypeRef v;
    if (d && d.length > 0) v = (__bridge CFTypeRef)d; else v = (__bridge CFTypeRef)(value?:@"");
    IOSurfaceSetValue(surf, (__bridge CFStringRef)k, v);
    return @"[set] ok";
}
static NSString *iosurfaceGetValueNative(NSNumber *handle, NSString *key) {
    if (!gSurfRegistry) return ryPrimErr(@"iosurfaceGetValue", @"本进程还没创建过任何 surface，先 iosurfaceCreate(props)");
    IOSurfaceRef surf = (__bridge IOSurfaceRef)(gSurfRegistry[handle]);
    if (!surf) return ryPrimErr(@"iosurfaceGetValue", [NSString stringWithFormat:
                        @"unknown handle %@（句柄来自 iosurfaceCreate()/iosurfaceLookup()）", handle]);
    NSString *k = key.length ? key : @"k";
    CFTypeRef v = IOSurfaceCopyValue(surf, (__bridge CFStringRef)k);
    if (!v) return [NSString stringWithFormat:@"[get] key \"%@\" 不存在（不是错误；surface 上没有这个属性）", k];
    NSString *desc;
    if (CFGetTypeID(v) == CFDataGetTypeID()) {
        desc = [NSString stringWithFormat:@"<CFData len=%lu>", (unsigned long)CFDataGetLength((CFDataRef)v)];
    } else {
        desc = [(__bridge id)v description];
    }
    CFRelease(v);
    return desc ?: @"[get] ?";
}
static NSString *iosurfaceReleaseNative(NSNumber *handle) {
    if (!gSurfRegistry) return ryPrimErr(@"iosurfaceRelease", @"本进程还没创建过任何 surface，先 iosurfaceCreate(props)");
    if (!gSurfRegistry[handle]) return ryPrimErr(@"iosurfaceRelease", [NSString stringWithFormat:
                        @"unknown handle %@；可能已 release 过（重复 release 是唯一会让句柄消失的情形）", handle]);
    [gSurfRegistry removeObjectForKey:handle]; // ARC 释放 -> CFRelease surface
    return @"[release] ok";
}
static id iosurfaceLookupNative(NSNumber *cid) {
    IOSurfaceRef surf = IOSurfaceLookup((unsigned int)[cid unsignedIntValue]);
    if (!surf) return ryPrimErr(@"iosurfaceLookup", [NSString stringWithFormat:
                        @"IOSurfaceLookup(%u) 返回 NULL；cid 必须是**本机当前活着**的 surface id（IOSurfaceGetID 来的 uint32），跨进程/已释放的 id 查不到",
                        (unsigned int)[cid unsignedIntValue]]);
    if (!gSurfRegistry) gSurfRegistry = [NSMutableDictionary dictionary];
    NSNumber *h = @(gSurfNextHandle++);
    gSurfRegistry[h] = (__bridge_transfer id)surf;
    return h;
}

#pragma mark - FS
static NSString *mkdirStr(NSString *name) {
    if(name.length==0) return @"[mkdir] empty";
    NSString *dp=[docsDir() stringByAppendingPathComponent:name];
    NSError *e;
    if([[NSFileManager defaultManager] createDirectoryAtPath:dp withIntermediateDirectories:NO attributes:nil error:&e])
        return @"ok";
    return [NSString stringWithFormat:@"[mkdir error] %@", e.localizedDescription];
}

#pragma mark - 桥库开关（UI 控件 + 持久化）
static NSString *bridgeFlagPath(void) {
    NSArray *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES);
    return [docs.firstObject stringByAppendingPathComponent:@".ryc_bridges_disabled"];
}
static BOOL bridgesEnabled(void) {
    return ![[NSFileManager defaultManager] fileExistsAtPath:bridgeFlagPath()];
}
static void setBridgesEnabled(BOOL on) {
    NSString *p=bridgeFlagPath();
    if(on) [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    else [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - 桥库加载（动态层）
static void loadBridgeFiles(JSContext *ctx) {
    if(!bridgesEnabled()) return;   // 桥库总开关关闭时不加载
    for (NSDictionary *d in allScripts()) {
        NSString *n=d[@"name"];
        if ([n hasPrefix:@"bridge_"] && [n hasSuffix:@".js"]) {
            if (!bridgeIsEnabled(n)) continue;   // 单桥独立开关
            NSString *src=loadScriptByName(n);
            if(src && ![src hasPrefix:@"[loadBundledScript]"]) [ctx evaluateScript:src];
        }
    }
}

// ---- 模块1 逻辑：门控判定 ----
static NSString *probeService(const char *name) {
    if (lookUp(name) == MACH_PORT_NULL) return @"NOT_REACHABLE";
    __block NSMutableString *out = [NSMutableString stringWithString:@"REACHABLE_XPC:"];
    __block BOOL gotDispatched = NO, gotEvent = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    xpc_connection_t conn = xpc_connection_create(name, NULL);
    xpc_connection_set_event_handler(conn, ^(xpc_object_t ev) {
        @autoreleasepool {
            if (xpc_get_type(ev)==XPC_TYPE_ERROR) {
                if (!gotEvent){ const char *d=xpc_dictionary_get_string(ev,XPC_ERROR_KEY_DESCRIPTION);
                    [out appendFormat:@" CONN_INVALID(desc=%@)", d?[NSString stringWithUTF8String:d]:@"(no desc)"]; gotEvent=YES; }
            } else {
                gotDispatched=YES; gotEvent=YES; NSString *cls;
                if (xpc_get_type(ev)==XPC_TYPE_DICTIONARY){ __block NSMutableArray *ks=[NSMutableArray array];
                    xpc_dictionary_apply(ev,^bool(const char*k,xpc_object_t v){if(ks.count<10)[ks addObject:[NSString stringWithUTF8String:k]];return true;});
                    cls=[NSString stringWithFormat:@"REPLY_DICT{%@}",[ks componentsJoinedByString:@","]];
                } else cls=[NSString stringWithFormat:@"REPLY_%s", xpc_type_get_name(xpc_get_type(ev))];
                [out appendFormat:@" DISPATCHED(%@)", cls];
            }
            dispatch_semaphore_signal(sem);
        }
    });
    xpc_connection_resume(conn);
    xpc_object_t m0=xpc_dictionary_create(NULL,NULL,0); xpc_connection_send_message(conn,m0);
    xpc_object_t m1=xpc_dictionary_create(NULL,NULL,0); xpc_dictionary_set_string(m1,"command","ping"); xpc_connection_send_message(conn,m1);
    dispatch_time_t t=dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC));
    long r=dispatch_semaphore_wait(sem,t); xpc_connection_cancel(conn);
    if (r!=0 && !gotEvent) [out appendString:@" TIMEOUT_NO_REPLY"];
    if (gotDispatched) out=[NSMutableString stringWithFormat:@"[GREEN] %@",out];
    return [out copy];
}

// ---- 模块2 逻辑：发送一条消息并收集回包 ----
static NSString *xpcSendRaw(const char *svc, xpc_object_t msg, double timeoutSec) {
    if (lookUp(svc)==MACH_PORT_NULL) return @"NOT_REACHABLE";
    __block NSMutableArray *events=[NSMutableArray array];
    dispatch_semaphore_t sem=dispatch_semaphore_create(0);
    xpc_connection_t conn=xpc_connection_create(svc,NULL);
    xpc_connection_set_event_handler(conn,^(xpc_object_t ev){
        @autoreleasepool {
            if (xpc_get_type(ev)==XPC_TYPE_ERROR){ const char*d=xpc_dictionary_get_string(ev,XPC_ERROR_KEY_DESCRIPTION);
                [events addObject:[NSString stringWithFormat:@"ERR:%@", d?[NSString stringWithUTF8String:d]:@"(no desc)"]];
            } else { NSString *cls;
                if (xpc_get_type(ev)==XPC_TYPE_DICTIONARY){ __block NSMutableArray*ks=[NSMutableArray array];
                    xpc_dictionary_apply(ev,^bool(const char*k,xpc_object_t v){if(ks.count<12)[ks addObject:[NSString stringWithUTF8String:k]];return true;});
                    cls=[NSString stringWithFormat:@"REPLY_DICT{%@}",[ks componentsJoinedByString:@","]];
                } else cls=[NSString stringWithFormat:@"REPLY_%s", xpc_type_get_name(xpc_get_type(ev))];
                [events addObject:cls];
            }
            dispatch_semaphore_signal(sem);
        }
    });
    xpc_connection_resume(conn); xpc_connection_send_message(conn,msg);
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+timeoutSec;
    while (CFAbsoluteTimeGetCurrent()<deadline){
        dispatch_time_t t=dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC));
        if (dispatch_semaphore_wait(sem,t)==0){} else break;
    }
    xpc_connection_cancel(conn);
    if (events.count==0) return @"TIMEOUT_NO_REPLY";
    __block BOOL anyReply=NO; [events enumerateObjectsUsingBlock:^(NSString*e,NSUInteger i,BOOL*s){if([e hasPrefix:@"REPLY"])anyReply=YES;}];
    NSString *sum=[events componentsJoinedByString:@" | "];
    return anyReply?[NSString stringWithFormat:@"[GREEN] %@",sum]:sum;
}

// ---- JSON/OC -> xpc 对象（支持一层嵌套 dict / array / 字符串 / 数字 / 布尔）----
static xpc_object_t xpcFromObj(id obj) {
    if ([obj isKindOfClass:[NSString class]]) return xpc_string_create([obj UTF8String]);
    if ([obj isKindOfClass:[NSNumber class]]) {
        if (strcmp([obj objCType],"c")==0 || strcmp([obj objCType],"B")==0) return xpc_bool_create([obj boolValue]);
        return xpc_int64_create([obj longLongValue]);
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        xpc_object_t d=xpc_dictionary_create(NULL,NULL,0);
        for (NSString *k in obj) xpc_dictionary_set_value(d,[k UTF8String],xpcFromObj(obj[k]));
        return d;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        xpc_object_t a=xpc_array_create(NULL,0);
        for (id e in obj) xpc_array_append_value(a,xpcFromObj(e));
        return a;
    }
    return xpc_string_create("");
}

// ============================================================
//  V2 扩展原语（2026-09-13 重构）: XPC 结构化桥 / dyld 符号 / 沙盒 / 钥匙串 / 进程
//  设计原则: 错误码/原始返回值原样回传，JS 探针侧自行解读（诚实测量，不替用户下结论）
// ============================================================

// ---- XPC 持久连接注册表（handle -> xpc_connection_t）----
static NSMutableDictionary<NSNumber *, NSValue *> *g_xpcConns = nil;
static long g_xpcNextHandle = 1000;

// xpc_object_t -> ObjC（递归解析 reply；深度限 6、每层条目限 64 防 reply 轰炸）
// UINT64 转十六进制字符串回传，避免 JS Number 53 位精度丢失
static id xpcToObj(xpc_object_t o, int depth) {
    if (depth > 6) return @"[depth-limit]";
    xpc_type_t t = xpc_get_type(o);
    if (t == XPC_TYPE_DICTIONARY) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        __block int n = 0;
        xpc_dictionary_apply(o, ^bool(const char *k, xpc_object_t v) {
            if (n++ < 64) d[[NSString stringWithUTF8String:k]] = xpcToObj(v, depth + 1);
            return true;
        });
        return d;
    }
    if (t == XPC_TYPE_ARRAY) {
        NSMutableArray *a = [NSMutableArray array];
        __block int n = 0;
        xpc_array_apply(o, ^bool(size_t i, xpc_object_t v) {
            if (n++ < 64) [a addObject:xpcToObj(v, depth + 1)];
            return true;
        });
        return a;
    }
    if (t == XPC_TYPE_STRING) { const char *s = xpc_string_get_string_ptr(o); return s ? [NSString stringWithUTF8String:s] : @""; }
    if (t == XPC_TYPE_INT64) return @(xpc_int64_get_value(o));
    if (t == XPC_TYPE_UINT64) return [NSString stringWithFormat:@"0x%016llx", xpc_uint64_get_value(o)];
    if (t == XPC_TYPE_BOOL) return @(xpc_bool_get_value(o));
    if (t == XPC_TYPE_DOUBLE) return @(xpc_double_get_value(o));
    if (t == XPC_TYPE_DATE) return @(xpc_date_get_value(o)); // ns since epoch
    if (t == XPC_TYPE_DATA) {
        size_t l = xpc_data_get_length(o);
        const void *p = xpc_data_get_bytes_ptr(o);
        NSData *d = p ? [NSData dataWithBytes:p length:l] : [NSData data];
        return [d base64EncodedStringWithOptions:0];
    }
    return [NSString stringWithFormat:@"<%s>", xpc_type_get_name(t)]; // NULL/ERROR/FD 等只给类型名
}

static NSDictionary *xpcConnNative(NSString *svc) {
    if (!g_xpcConns) g_xpcConns = [NSMutableDictionary new];
    xpc_connection_t c = xpc_connection_create([svc UTF8String], NULL);
    if (!c) return @{@"err": @"create-failed"};
    // 事件 handler 必须设（空实现即可）：默认 handler 收到 error 事件会直接 crash 进程
    xpc_connection_set_event_handler(c, ^(xpc_object_t ev) {});
    xpc_connection_resume(c);
    long h = g_xpcNextHandle++;
    g_xpcConns[@(h)] = c; // xpc 对象即 ObjC 对象(NSObject<OS_xpc_object>*), ARC 直接持有
    return @{@"h": @(h)};
}

static xpc_connection_t xpcConnGet(long h) {
    id v = g_xpcConns[@(h)];
    return (xpc_connection_t)v; // 同一 ObjC 类型, 直接桥回
}

static NSString *xpcCloseNative(long h) {
    xpc_connection_t c = xpcConnGet(h);
    if (!c) return @"NOT_FOUND";
    xpc_connection_cancel(c);
    [g_xpcConns removeObjectForKey:@(h)];
    return @"ok";
}

// 结构化收发: h=连接句柄, msg=任意嵌套 JS 对象(转 xpc_dictionary), timeoutSec<=0 为发射不等待
// 回传解析后的 reply 对象；超时 {err:timeout}；对端回 ERROR 事件时回传 "<error-type>" 字符串
static id xpcSendMsgNative(long h, NSDictionary *msg, double timeoutSec) {
    xpc_connection_t c = xpcConnGet(h);
    if (!c) return @{@"err": @"bad-handle"};
    if (![msg isKindOfClass:[NSDictionary class]]) return @{@"err": @"msg-not-dict"};
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    for (NSString *k in msg) xpc_dictionary_set_value(m, [k UTF8String], xpcFromObj(msg[k]));
    if (timeoutSec <= 0) {
        xpc_connection_send_message(c, m);
        return @"SENT";
    }
    __block id reply = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(c, m, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(xpc_object_t r) {
        reply = xpcToObj(r, 0);
        dispatch_semaphore_signal(sem);
    });
    // ARC: 新 SDK 中 xpc 对象已桥接为 ObjC 对象, 禁止 xpc_release(等价 [release])，生命周期由 ARC 管理
    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, t) != 0) return @{@"err": @"timeout"};
    return reply;
}

// bootstrap_look_up 原始版: 回传 kr + port 名(uint32 句柄)，供探针比对服务可达性与句柄分配
static NSDictionary *machLookUpNative(NSString *svc) {
    mach_port_t bp = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);
    mach_port_t sp = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bp, [svc UTF8String], &sp);
    if (kr != BOOTSTRAP_SUCCESS) return @{@"kr": @((long)kr), @"port": @0};
    return @{@"kr": @(0), @"port": @((unsigned long long)sp)};
}

// dlopen 私有框架: path 如 /System/Library/PrivateFrameworks/Foo.framework/Foo
static NSDictionary *dlopenFWNative(NSString *path, int mode) {
    void *h = dlopen([path UTF8String], mode > 0 ? mode : RTLD_LAZY);
    if (!h) { const char *e = dlerror(); return @{@"err": e ? [NSString stringWithUTF8String:e] : @"dlopen-failed"}; }
    return @{@"h": @((unsigned long long)(uintptr_t)h)};
}

// dlsym 符号解析: handle=0 时用 RTLD_DEFAULT(全镜像搜索)；addr 以 hex 回传(基址+slide 已含)
static NSDictionary *dlsymAddrNative(uint64_t handle, NSString *name) {
    void *h = handle ? (void *)(uintptr_t)handle : RTLD_DEFAULT;
    void *p = dlsym(h, [name UTF8String]);
    if (!p) { const char *e = dlerror(); return @{@"err": e ? [NSString stringWithUTF8String:e] : @"not-found"}; }
    return @{@"addr": [NSString stringWithFormat:@"0x%016llx", (unsigned long long)(uintptr_t)p]};
}

// sandbox_check: 苹果语义模糊(不同文档/版本对返回值解释不一)，回传原始返回值+errno，不解读
extern int sandbox_check(pid_t pid, const char *operation, ...);
static NSDictionary *sandboxCheckNative(NSString *op) {
    errno = 0;
    int r = sandbox_check(getpid(), [op UTF8String]);
    return @{@"ret": @(r), @"errno": @(errno)};
}

// 钥匙串探针: SecItemCopyMatching 只查不取(不弹框不触发用户交互)，status 原样回传
// 0=存在且可访问, -25300=errSecItemNotFound, -34018=errSecMissingEntitlement, -25291=交互被禁
static NSDictionary *keychainProbeNative(NSString *cls, NSString *svc, NSString *acct) {
    NSDictionary *clsMap = @{@"genp": (__bridge NSString *)kSecClassGenericPassword,
                             @"inet": (__bridge NSString *)kSecClassInternetPassword,
                             @"cert": (__bridge NSString *)kSecClassCertificate,
                             @"keys": (__bridge NSString *)kSecClassKey,
                             @"idnt": (__bridge NSString *)kSecClassIdentity};
    id secClass = clsMap[cls ?: @"genp"];
    if (!secClass) return @{@"err": @"bad-class", @"known": @[@"genp", @"inet", @"cert", @"keys", @"idnt"]};
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    q[(__bridge id)kSecClass] = secClass;
    if (svc.length) q[(__bridge id)kSecAttrService] = svc;
    if (acct.length) q[(__bridge id)kSecAttrAccount] = acct;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    q[(__bridge id)kSecReturnData] = @NO;
    q[(__bridge id)kSecReturnAttributes] = @NO;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, NULL);
    return @{@"status": @((long)st), @"exists": @(st == errSecSuccess),
             @"stHex": [NSString stringWithFormat:@"0x%08x", st]};
}

// 进程枚举: proc_listallpids 沙盒内多半 EPERM，错误本身即测量结果
extern int proc_listallpids(void *buffer, int buffersize);
static id procListPidsNative(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return @{@"err": @"proc_listallpids-failed", @"n": @(n)};
    if (n > 2048) n = 2048;
    pid_t *buf = (pid_t *)calloc((size_t)n, sizeof(pid_t));
    if (!buf) return @{@"err": @"oom"};
    int real = proc_listallpids(buf, n * (int)sizeof(pid_t));
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:real > 0 ? (NSUInteger)real : 0];
    for (int i = 0; i < real; i++) [a addObject:@(buf[i])];
    free(buf);
    return @{@"n": @(real), @"pids": a};
}

// posix_spawn: 沙盒内多被拒(spawn 错误码原样回传)；成功则 waitpid 轮询到退出/超时
// 超时不 reap(留僵尸，进程表可见——本身就是信号)。timeoutMs 上限 30s
// ============================================================
//  V2.1 ObjC runtime 桥（2026-09-13）: objc_getClass / sel_registerName / objc_msgSend
//  设计: 一切对象以 0x 十六进制句柄在 JS 与原生间流动
//        (Class/SEL 永生无需句柄表; 普通对象由 ARC/autorelease 池持有)
//  args 规则: 字符串→自动包 NSString | 数字→uint64 位槽(BOOL/int/long 都按位传)
//             true/false→BOOL | {hex:"0x.."}→原始指针 | null/undefined→nil
//  限制: 只覆盖整型/指针寄存器返回(id/BOOL/long); float/struct 返回的方法不适用
//        (arm64 无 stret 顾虑, 但 x0 读出来的位当指针回传会错)
//  已知取舍: 经 msgSend 调 alloc/new/copy 族会泄漏 +1(ARC 视 msgSend 返回为 +0), 探针别滥创建
// ============================================================
static NSString *objcHexFromPtr(uintptr_t p) {
    return [NSString stringWithFormat:@"0x%016llx", (unsigned long long)p];
}
static uintptr_t objcHexToPtr(id v) {
    if ([v isKindOfClass:[NSString class]]) {
        unsigned long long r = 0;
        NSScanner *s = [NSScanner scannerWithString:v];
        [s scanHexLongLong:&r];
        return (uintptr_t)r;
    }
    if ([v isKindOfClass:[NSNumber class]]) return (uintptr_t)[v unsignedLongLongValue];
    return 0;
}

static NSString *objcGetClassNative(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return @"0x0000000000000000";
    return objcHexFromPtr((uintptr_t)objc_getClass([name UTF8String]));
}

static NSString *objcSelNative(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return @"0x0000000000000000";
    return objcHexFromPtr((uintptr_t)sel_registerName([name UTF8String]));
}

// 句柄 → description/原文: 回读 msgSend 结果的唯一手段(NSString 原文, 其他对象 description)
static NSString *objcDescNative(NSString *hex) {
    uintptr_t p = objcHexToPtr(hex);
    if (!p) return @"(nil)";
    // ★ 同源防护（2026-09-18）：objc_msgSend 如果把 **标量返回值**（count / length / BOOL…）
    //   一路传到 objcDesc，下面 `[o isKindOfClass:]` 就是在给非法地址发消息 → SIGSEGV。
    //   这里做最便宜的体检：8 字节对齐 + 高于用户空间起点（arm64 tagged pointer 仍会通过）。
    if ((p & 0x7) != 0 || p < 0x100000000ULL) {
        return [NSString stringWithFormat:
                @"[objcDesc] 0x%llx 不像对象指针（对齐/范围体检未过）——"
                @"该 selector 大概返回的是标量，别把它丢给 objcDesc",
                (unsigned long long)p];
    }
    @try {
        id o = (__bridge id)(void *)p;
        if (!o) return @"(nil)";
        if ([o isKindOfClass:[NSString class]]) return [NSString stringWithString:o];
        return [NSString stringWithFormat:@"%@", o];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"[objcDesc exception] %@", e.reason];
    }
}

static NSString *objcMsgSendNative(id recvArg, NSString *selName, NSArray *args) {
    uintptr_t rp = objcHexToPtr(recvArg);
    if (!rp) return @"0x0000000000000000"; // nil recv → nil
    id recv = (__bridge id)(void *)rp;
    if (![selName isKindOfClass:[NSString class]] || !selName.length)
        return @"[objc_msgSend error] bad selector";
    SEL sel = [selName hasPrefix:@"0x"] ? (SEL)objcHexToPtr(selName)
                                        : sel_registerName([selName UTF8String]);
    if (!sel) return @"[objc_msgSend error] null selector";

    id objs[8] = {nil};
    unsigned long long nums[8] = {0};
    void *slots[8] = {0};
    int n = 0;
    for (id v in (args ?: @[])) {
        if (n >= 8) break;
        if (v == nil || [v isKindOfClass:[NSNull class]]) { slots[n] = NULL; }
        else if ([v isKindOfClass:[NSNumber class]]) {
            if (strcmp([v objCType], "c") == 0 || strcmp([v objCType], "B") == 0)
                nums[n] = (unsigned long long)([v boolValue] ? 1 : 0);
            else
                nums[n] = [v unsignedLongLongValue];
            slots[n] = (void *)nums[n]; // 位槽: 调用方按声明宽度读低位, 恰好正确
        }
        else if ([v isKindOfClass:[NSDictionary class]] && v[@"hex"]) {
            slots[n] = (void *)objcHexToPtr(v[@"hex"]);
        }
        else if ([v isKindOfClass:[NSString class]]) { objs[n] = v; slots[n] = (__bridge void *)objs[n]; }
        else { slots[n] = NULL; }
        n++;
    }
    @try {
        // 显式 arity 分发: 每档独立签名 cast, 不多传垃圾实参
        //
        // ★★ 严重崩溃根因（2026-09-18，由安全研究 AI 源码级定位）：
        //   这里原来写的是 `id ret = nil;`。ARC 下 `id` 是 **__strong**，所以每一条
        //     ret = ((id(*)(id,SEL))objc_msgSend)(...)      // ret 被赋值为"裸指针"
        //   都会插入 objc_retain()。当被调 selector **返回标量**（count / length /
        //   intValue / BOOL …）时，ret 拿到的是一个小整数（如 0x1f），
        //   objc_retain(0x1f) 就去解引用 0x1f → **SIGSEGV**（信号级，@try 抓不到）。
        //   这正是"lsAppList() 一次调用即崩""栈顶崩在 block 内、没有下层帧"的成因。
        //   修法：__unsafe_unretained（不参与 ARC 所有权）—— 指针原样透传，不再 retain。
        __unsafe_unretained id ret = nil;
        switch (n) {
            case 0: ret = ((id(*)(id, SEL))objc_msgSend)(recv, sel); break;
            case 1: ret = ((id(*)(id, SEL, void *))objc_msgSend)(recv, sel, slots[0]); break;
            case 2: ret = ((id(*)(id, SEL, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1]); break;
            case 3: ret = ((id(*)(id, SEL, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2]); break;
            case 4: ret = ((id(*)(id, SEL, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3]); break;
            case 5: ret = ((id(*)(id, SEL, void *, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3], slots[4]); break;
            case 6: ret = ((id(*)(id, SEL, void *, void *, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3], slots[4], slots[5]); break;
            default: ret = ((id(*)(id, SEL, void *, void *, void *, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3], slots[4], slots[5], slots[6]); break;
        }
        return objcHexFromPtr((uintptr_t)ret);
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"[objc_msgSend exception] %@", e.reason];
    }
}

// ============================================================
//  V2.2 读映射内存桥（memRead）：从本任务地址空间读 len 字节，safe via vm_read
//   用途：objc_msgSend 返回指针(句柄)后，可跟 memRead 把那块内存 dump 出来
//         （对象 isa/ivars、C 结构体、映射区）。越界/未映射返回 kr 错误，不崩。
//   限制：len 上限 64KB；只对本进程地址空间有效（沙盒内即 App 自身映射）。
// ============================================================
static NSString *memReadNative(NSString *hex, NSNumber *lenN) {
    uintptr_t addr = objcHexToPtr(hex);
    if (!addr) return @"[memRead error] null address";
    mach_vm_size_t len = (mach_vm_size_t)[lenN unsignedLongLongValue];
    if (len == 0 || len > 65536) return @"[memRead error] len must be 1..65536";
    vm_offset_t data = 0; mach_msg_type_number_t count = 0;
    kern_return_t kr = vm_read(mach_task_self(), (mach_vm_address_t)addr, len, &data, &count);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"[memRead error] vm_read kr=%d", (int)kr];
    NSMutableString *out = [NSMutableString stringWithCapacity:count * 2];
    const unsigned char *p = (const unsigned char *)(uintptr_t)data;
    for (mach_msg_type_number_t i = 0; i < count; i++) [out appendFormat:@"%02x", p[i]];
    vm_deallocate(mach_task_self(), data, count);
    return out;
}

// ============================================================
//  V2.2 objc_msgSend 安全封装（objc_msgSendSafe）：与原 objc_msgSend 区别
//   ① nil recv/sel 返回结构化错误而非静默 0x0
//   ② 参数 >7 直接拒绝（arm64 msgSend 无 stret，多传即崩）
//   ③ 异常转 JSON {ok,value|error}，调用方可清晰区分成功/失败
//   返回整型/指针寄存器(id/BOOL/long)；float/struct 返回方法不适用（同原桥）。
// ============================================================
static NSString *objcMsgSendSafeNative(id recvArg, NSString *selName, NSArray *args) {
    uintptr_t rp = objcHexToPtr(recvArg);
    if (!rp) return @"{\"ok\":false,\"error\":\"null receiver\"}";
    id recv = (__bridge id)(void *)rp;
    if (![selName isKindOfClass:[NSString class]] || !selName.length)
        return @"{\"ok\":false,\"error\":\"bad selector\"}";
    SEL sel = [selName hasPrefix:@"0x"] ? (SEL)objcHexToPtr(selName) : sel_registerName([selName UTF8String]);
    if (!sel) return @"{\"ok\":false,\"error\":\"null selector\"}";

    id objs[8] = {nil};
    unsigned long long nums[8] = {0};
    void *slots[8] = {0};
    int n = 0;
    for (id v in (args ?: @[])) {
        if (n >= 8) return @"{\"ok\":false,\"error\":\"too many args (>7)\"}";
        if (v == nil || [v isKindOfClass:[NSNull class]]) { slots[n] = NULL; }
        else if ([v isKindOfClass:[NSNumber class]]) {
            if (strcmp([v objCType], "c") == 0 || strcmp([v objCType], "B") == 0)
                nums[n] = (unsigned long long)([v boolValue] ? 1 : 0);
            else nums[n] = [v unsignedLongLongValue];
            slots[n] = (void *)nums[n];
        }
        else if ([v isKindOfClass:[NSDictionary class]] && v[@"hex"]) { slots[n] = (void *)objcHexToPtr(v[@"hex"]); }
        else if ([v isKindOfClass:[NSString class]]) { objs[n] = v; slots[n] = (__bridge void *)objs[n]; }
        else { slots[n] = NULL; }
        n++;
    }
    @try {
        // ★ 同 objcMsgSendNative：必须是 __unsafe_unretained，
        //   否则标量返回值（count/length/BOOL…）会被 ARC objc_retain 成野指针 → SIGSEGV。
        __unsafe_unretained id ret = nil;
        switch (n) {
            case 0: ret = ((id(*)(id, SEL))objc_msgSend)(recv, sel); break;
            case 1: ret = ((id(*)(id, SEL, void *))objc_msgSend)(recv, sel, slots[0]); break;
            case 2: ret = ((id(*)(id, SEL, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1]); break;
            case 3: ret = ((id(*)(id, SEL, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2]); break;
            case 4: ret = ((id(*)(id, SEL, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3]); break;
            case 5: ret = ((id(*)(id, SEL, void *, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3], slots[4]); break;
            case 6: ret = ((id(*)(id, SEL, void *, void *, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3], slots[4], slots[5]); break;
            default: ret = ((id(*)(id, SEL, void *, void *, void *, void *, void *, void *, void *))objc_msgSend)(recv, sel, slots[0], slots[1], slots[2], slots[3], slots[4], slots[5], slots[6]); break;
        }
        return [NSString stringWithFormat:@"{\"ok\":true,\"value\":\"%@\"}", objcHexFromPtr((uintptr_t)ret)];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"{\"ok\":false,\"error\":\"%@\"}", e.reason];
    }
}

static NSDictionary *posixSpawnNative(NSString *path, NSArray *argvArr, double timeoutSec) {
    if (timeoutSec <= 0 || timeoutSec > 30) timeoutSec = 5;
    int cap = (int)(argvArr.count ?: 0) + 2;
    char **argv = (char **)calloc((size_t)cap, sizeof(char *));
    if (!argv) return @{@"err": @"oom"};
    argv[0] = strdup([path UTF8String]);
    int i = 1;
    for (id v in argvArr) { if ([v isKindOfClass:[NSString class]] && i < cap - 1) argv[i++] = strdup([v UTF8String]); }
    argv[i] = NULL;
    extern char **environ;
    pid_t pid = -1;
    int sp = posix_spawn(&pid, [path UTF8String], NULL, NULL, argv, environ);
    for (int j = 0; j < cap && argv[j]; j++) free(argv[j]);
    free(argv);
    if (sp != 0) return @{@"spawn": @((long)sp), @"errstr": [NSString stringWithUTF8String:strerror(sp)]};
    int status = 0; BOOL done = NO;
    double deadline = CFAbsoluteTimeGetCurrent() + timeoutSec;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid || r < 0) { done = YES; break; }
        usleep(50000);
    }
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:@(pid) forKey:@"pid"];
    if (!done) { res[@"timeout"] = @YES; return res; }
    if (WIFEXITED(status)) res[@"exit"] = @(WEXITSTATUS(status));
    if (WIFSIGNALED(status)) res[@"signal"] = @(WTERMSIG(status));
    return res;
}

// ---- 内嵌脚本库：把整套 JS 探针环境打进 IPA，离线可用 ----
static NSArray<NSString*> *bundledScripts(void) {
    NSString *res = [[NSBundle mainBundle] resourcePath];
    NSMutableArray *out = [NSMutableArray array];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:res];
    NSString *f;
    while ((f = [e nextObject])) {
        if ([[f pathExtension] isEqualToString:@"js"])
            [out addObject:[f lastPathComponent]];
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}
static NSString *loadBundledScript(NSString *name) {
    NSString *res = [[NSBundle mainBundle] resourcePath];
    NSString *full = [res stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:full]) {
        NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:res];
        NSString *f;
        while ((f = [e nextObject])) {
            if ([[f lastPathComponent] isEqualToString:name]) {
                full = [res stringByAppendingPathComponent:f];
                break;
            }
        }
    }
    NSError *err;
    NSString *src = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:&err];
    return src ?: [NSString stringWithFormat:@"[loadBundledScript] read error: %@", err.localizedDescription];
}

// ---- 用户脚本库：Documents 目录（可写、持久），用于运行时粘贴保存新脚本 ----
static NSString *docsDir(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return docs.firstObject ?: NSTemporaryDirectory();
}
// 返回 @[@{@"name":, @"source":@"bundle"|@"docs"}, ...]，bundle 优先、docs 可覆盖同名
static NSArray<NSDictionary*> *allScripts(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *dd = docsDir();
    NSArray *df = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dd error:nil];
    for (NSString *f in df) {
        if ([[f pathExtension] isEqualToString:@"js"]) {
            [out addObject:@{@"name":f, @"source":@"docs"}];
            [seen addObject:f];
        }
    }
    for (NSString *n in bundledScripts()) {
        if (![seen containsObject:n]) {
            [out addObject:@{@"name":n, @"source":@"bundle"}];
            [seen addObject:n];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        return [a[@"name"] compare:b[@"name"]];
    }];
    return out;
}
// docs 优先（用户覆盖），否则 bundle
static NSString *loadScriptByName(NSString *name) {
    NSString *dp = [docsDir() stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dp])
        return [NSString stringWithContentsOfFile:dp encoding:NSUTF8StringEncoding error:nil];
    return loadBundledScript(name);
}
static NSString *saveScriptToDocs(NSString *name, NSString *code) {
    if (name.length == 0) return @"[saveScript] empty name";
    if (![name hasSuffix:@".js"]) name = [name stringByAppendingString:@".js"];
    NSString *dp = [docsDir() stringByAppendingPathComponent:name];
    NSError *e;
    if ([code writeToFile:dp atomically:YES encoding:NSUTF8StringEncoding error:&e])
        return [NSString stringWithFormat:@"saved -> %@", name];
    return [NSString stringWithFormat:@"[saveScript error] %@", e.localizedDescription];
}
static NSString *deleteDocScript(NSString *name) {
    if (![name hasSuffix:@".js"]) name = [name stringByAppendingString:@".js"];
    NSString *dp = [docsDir() stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dp]) return @"[deleteScript] not found";
    NSError *e;
    if ([[NSFileManager defaultManager] removeItemAtPath:dp error:&e])
        return [NSString stringWithFormat:@"deleted -> %@", name];
    return [NSString stringWithFormat:@"[deleteScript error] %@", e.localizedDescription];
}


// ============================================================
//  全局：流式输出缓冲（受保护，UI 加载逻辑锁死在此文件，修补页不可编辑）
// ============================================================
static __weak UITextView *gOutTV = nil;
static NSMutableString *gOutBuf = nil;

// ---- 桥独立开关状态（持久化 Documents/.ryc_bridge_states.json）----
static NSString *bridgeStatesPath(void) {
    return [docsDir() stringByAppendingPathComponent:@".ryc_bridge_states.json"];
}
static NSMutableDictionary *bridgeStates(void) {
    NSString *p = bridgeStatesPath();
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (d) {
        id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([o isKindOfClass:[NSDictionary class]]) return [o mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}
static BOOL bridgeIsEnabled(NSString *name) {
    NSDictionary *s = bridgeStates();
    id v = s[name];
    if (v == nil) return YES;            // 默认开启
    return [v boolValue];
}
static void setBridgeEnabled(NSString *name, BOOL on) {
    NSMutableDictionary *s = bridgeStates();
    s[name] = @(on);
    NSData *d = [NSJSONSerialization dataWithJSONObject:s options:0 error:nil];
    [d writeToFile:bridgeStatesPath() atomically:YES];
}

// ---- engine.js（可编辑执行引擎，热重载；改坏仅报错不崩 App）----
static NSString *engineDocPath(void) { return [docsDir() stringByAppendingPathComponent:@"engine.js"]; }
static NSString *loadEngineSource(void) {
    NSString *dp = engineDocPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:dp])
        return [NSString stringWithContentsOfFile:dp encoding:NSUTF8StringEncoding error:nil];
    return loadBundledScript(@"engine.js");
}

// ---- 同步 HTTP 请求（NSURLSession + 信号量；支持 https / 自定义 header / JSON body）----
// 返回 JSON 字符串：{ok, status, body, len, error}
// 注意：跑在调用线程；ATS 限制见 Info.plist（https 无限制，局域网 http 需 NSAllowsLocalNetworking）
static NSString *httpRequestNative(NSDictionary *opts) {
    if (![opts isKindOfClass:[NSDictionary class]]) {
        return @"{\"ok\":false,\"error\":\"opts must be an object\"}";
    }
    NSString *urlStr = opts[@"url"];
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
        return @"{\"ok\":false,\"error\":\"missing url\"}";
    }
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil) {
        return @"{\"ok\":false,\"error\":\"bad url\"}";
    }

    NSString *method = [opts[@"method"] isKindOfClass:[NSString class]]
        ? [(NSString *)opts[@"method"] uppercaseString] : @"GET";
    NSDictionary *headers = [opts[@"headers"] isKindOfClass:[NSDictionary class]] ? opts[@"headers"] : nil;
    NSNumber *timeoutN = [opts[@"timeout"] isKindOfClass:[NSNumber class]] ? opts[@"timeout"] : nil;
    double timeout = timeoutN ? [timeoutN doubleValue] : 30.0;
    if (timeout <= 0) timeout = 30.0;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = timeout;
    for (NSString *k in headers) {
        id v = headers[k];
        if ([k isKindOfClass:[NSString class]] && v != nil) {
            [req setValue:[v description] forHTTPHeaderField:k];
        }
    }

    id body = opts[@"body"];
    if ([body isKindOfClass:[NSString class]]) {
        req.HTTPBody = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
        if (headers[@"Content-Type"] == nil && headers[@"content-type"] == nil) {
            [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        }
    } else if ([body isKindOfClass:[NSData class]]) {
        req.HTTPBody = (NSData *)body;
    }

    __block NSData *respData = nil;
    __block NSHTTPURLResponse *resp = nil;
    __block NSError *nerr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = timeout;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [sess dataTaskWithRequest:req
                                        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        respData = d;
        if ([r isKindOfClass:[NSHTTPURLResponse class]]) resp = (NSHTTPURLResponse *)r;
        nerr = e;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    long long waitNs = (long long)((timeout + 5.0) * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, waitNs)) != 0) {
        [task cancel];
        [sess invalidateAndCancel];
        return @"{\"ok\":false,\"status\":0,\"body\":\"\",\"len\":0,\"error\":\"timeout\"}";
    }
    [sess finishTasksAndInvalidate];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (nerr) {
        out[@"ok"] = @NO;
        out[@"error"] = [nerr localizedDescription] ?: @"request failed";
    } else {
        out[@"ok"] = @YES;
    }
    out[@"status"] = @(resp ? resp.statusCode : 0);
    NSString *text = respData ? [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] : nil;
    out[@"body"] = text ? text : @"";
    out[@"len"] = @(respData ? (long)respData.length : 0);

    NSData *jd = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
    NSString *s = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : nil;
    return s ? s : @"{\"ok\":false,\"error\":\"serialize failed\"}";
}

// ---- 安装原生原语（从 #4 原 runCode 提取，行为完全一致）----
static void installPrimitives(JSContext *ctx) {
ctx[@"runCommand"]=^NSString*(NSString *cmd){
                FILE *fp=popen([cmd UTF8String],"r");
                if(!fp) return @"[runCommand: popen failed]";
                NSMutableData *d=[NSMutableData data]; char buf[4096];
                while(fgets(buf,sizeof(buf),fp)) [d appendBytes:buf length:strlen(buf)];
                pclose(fp);
                NSString *s=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                return s?:@"";
            };

            // 文件 IO（沙盒内，相对路径基于 Documents）
            NSString *(^docPath)(NSString*)=^(NSString *p){
                NSArray *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES);
                NSString *base=docs.firstObject;
                if([p hasPrefix:@"/"]) return p;
                return [base stringByAppendingPathComponent:p];
            };
            ctx[@"readFile"]=^NSString*(NSString *path){
                NSError *e; NSString *c=[NSString stringWithContentsOfFile:docPath(path) encoding:NSUTF8StringEncoding error:&e];
                return c?:[NSString stringWithFormat:@"[readFile error] %@",e.localizedDescription];
            };
            ctx[@"writeFile"]=^NSString*(NSString *path, NSString *content){
                NSError *e; BOOL ok=[content writeToFile:docPath(path) atomically:YES encoding:NSUTF8StringEncoding error:&e];
                return ok?@"ok":[NSString stringWithFormat:@"[writeFile error] %@",e.localizedDescription];
            };
            ctx[@"listDir"]=^NSString*(NSString *path){
                NSError *e; NSArray *f=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:docPath(path) error:&e];
                return f?[f componentsJoinedByString:@"\n"]:[NSString stringWithFormat:@"[listDir error] %@",e.localizedDescription];
            };

            // XPC 桥接
            ctx[@"xpcLookup"]=^NSString*(NSString *svc){ return lookUp([svc UTF8String])!=MACH_PORT_NULL?@"REACHABLE":@"NOT_REACHABLE"; };
            ctx[@"xpcProbe"]=^NSString*(NSString *svc){ return probeService([svc UTF8String]); };
            ctx[@"xpcSend"]=^NSString*(NSString *svc, NSString *selector, NSString *payloadJSON){
                xpc_object_t msg=xpc_dictionary_create(NULL,NULL,0);
                xpc_dictionary_set_string(msg,"selector",[selector UTF8String]);
                if(payloadJSON && payloadJSON.length){
                    NSData *jd=[payloadJSON dataUsingEncoding:NSUTF8StringEncoding];
                    id json=[NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
                    if([json isKindOfClass:[NSDictionary class]])
                        for(NSString *k in json) xpc_dictionary_set_value(msg,[k UTF8String],xpcFromObj(json[k]));
                }
                return xpcSendRaw([svc UTF8String],msg,2.5);
            };

            // === 新增原生桥（一次性补齐，之后加桥只改 bridge_*.js，零重编译）===
            ctx[@"tcpConnect"]=^(NSString *h, NSNumber *p){ return tcpProbe(h,[p intValue],0.3,nil); };
            ctx[@"tcpScan"]=^(NSString *h, NSNumber *s, NSNumber *e){ return tcpScanRange(h,[s intValue],[e intValue]); };
            ctx[@"tcpSend"]=^(NSString *h, NSNumber *p, NSString *hex){ return tcpProbe(h,[p intValue],2.0,hex); };
            ctx[@"canOpenURL"]=^(NSString *scheme){ return canOpenURLStr(scheme); };
            ctx[@"openURL"]=^(NSString *url){ return openURLStr(url); };
            ctx[@"installIPA"]=^(NSString *url){ return installIPANative(url); };
            ctx[@"getPasteboard"]=^NSString*{ return getPasteboardStr(); };
            ctx[@"setPasteboard"]=^(NSString *s){ return setPasteboardStr(s); };
            ctx[@"appInfo"]=^NSString*{ return appInfoStr(); };
            ctx[@"getPid"]=^NSNumber*{ return @(getPidInt()); };
            ctx[@"getEntitlements"]=^NSString*{ return getEntitlementsStr(); };
            ctx[@"iosurfaceProbe"]=^NSString*{ return iosurfaceProbeStr(); };
            // A1 框架层 IOSurface 桥 (乙路线: 持久持有 surface + 属性 set/get + release 竞态)
            ctx[@"iosurfaceCreate"]=^(NSDictionary *props){ return iosurfaceCreateNative(props); };
            ctx[@"iosurfaceGetID"]=^(NSNumber *h){ return iosurfaceGetIDNative(h); };
            ctx[@"iosurfaceSetValue"]=^(NSNumber *h, NSString *k, NSString *v){ return iosurfaceSetValueNative(h,k,v); };
            ctx[@"iosurfaceGetValue"]=^(NSNumber *h, NSString *k){ return iosurfaceGetValueNative(h,k); };
            ctx[@"iosurfaceRelease"]=^(NSNumber *h){ return iosurfaceReleaseNative(h); };
            ctx[@"iosurfaceLookup"]=^(NSNumber *cid){ return iosurfaceLookupNative(cid); };
            ctx[@"mkdir"]=^(NSString *n){ return mkdirStr(n); };
            ctx[@"nsxpcProbe"]=^(NSString *svc){ return probeService([svc UTF8String]); };

            // V3 决定性原语集: 打开/调用/映射/关闭 IOKit UserClient + 枚举 IORegistry + 进程/sysctl
            ctx[@"iokitOpen"]=^(NSString *cls, NSNumber *t){ return @(iokitOpenNative(cls, [t intValue])); };
            ctx[@"iokitCall"]=^(NSNumber *conn, NSNumber *sel, NSArray *inp){ return iokitCallNative([conn longValue], [sel unsignedIntValue], inp); };
            // V3 (b): struct/OOL 输入探针原语 —— 标量 + inputStruct 字节均可发，输出 struct 以 base64 回传
            ctx[@"iokitCallStruct"]=^(NSNumber *conn, NSNumber *sel, NSArray *scalarInputs, NSString *structB64, NSNumber *outSize){
                NSData *sd = nil;
                if ([structB64 isKindOfClass:[NSString class]] && structB64.length) sd = [[NSData alloc] initWithBase64EncodedString:structB64 options:0];
                NSUInteger os = [outSize unsignedIntegerValue];
                return iokitCallStructNative([conn longValue], [sel unsignedIntValue], scalarInputs, sd, os);
            };
            ctx[@"bytesB64"]=^(NSArray *b){ return bytesToB64(b); };
            ctx[@"b64Bytes"]=^(NSString *b64){ return b64ToBytes(b64); };
            ctx[@"iokitMap"]=^(NSNumber *conn, NSNumber *mt){ return iokitMapNative([conn longValue], [mt unsignedIntValue]); };
            ctx[@"iokitClose"]=^(NSNumber *conn){ return @(iokitCloseNative([conn longValue])); };
            ctx[@"iokitEnum"]=^{ return iokitEnumNative(); };
            ctx[@"sysctlGet"]=^(NSString *n){ return sysctlGetNative(n); };

            // ---- V2 扩展桥（2026-09-13）: XPC 结构化 / dyld 符号 / 沙盒 / 钥匙串 / 进程 ----
            ctx[@"xpcConn"]=^(NSString *svc){ return xpcConnNative(svc); };
            ctx[@"xpcSendMsg"]=^(NSNumber *h, NSDictionary *msg, NSNumber *timeoutSec){ return xpcSendMsgNative([h longValue], msg, [timeoutSec doubleValue]); };
            ctx[@"xpcClose"]=^(NSNumber *h){ return xpcCloseNative([h longValue]); };
            ctx[@"machLookUp"]=^(NSString *svc){ return machLookUpNative(svc); };
            ctx[@"dlopenFW"]=^(NSString *p, NSNumber *mode){ return dlopenFWNative(p, [mode intValue]); };
            ctx[@"dlsymAddr"]=^(NSNumber *h, NSString *name){ return dlsymAddrNative([h unsignedLongLongValue], name); };
            ctx[@"sandboxCheck"]=^(NSString *op){ return sandboxCheckNative(op); };
            ctx[@"keychainProbe"]=^(NSString *cls, NSString *svc, NSString *acct){ return keychainProbeNative(cls, svc, acct); };
            ctx[@"procListPids"]=^{ return procListPidsNative(); };
            ctx[@"posixSpawn"]=^(NSString *path, NSArray *argvArr, NSNumber *timeoutMs){ return posixSpawnNative(path, argvArr, [timeoutMs doubleValue]/1000.0); };

            // ---- V2.1 ObjC runtime 桥（2026-09-13）: 万用钥匙, 私有类直接驱动 ----
            ctx[@"objc_getClass"]=^(NSString *n){ return objcGetClassNative(n); };
            ctx[@"sel_registerName"]=^(NSString *n){ return objcSelNative(n); };
            ctx[@"objc_msgSend"]=^(id recv, NSString *sel, NSArray *args){ return objcMsgSendNative(recv, sel, args); };
            ctx[@"objcDesc"]=^(id hex){ return objcDescNative(hex); };

            // ---- V2.2 安全封装 + 读映射内存：与原生桥同级的全局原语 ----
            //   objc_msgSendSafe：结构化错误返回，参数 >7 拒绝，调用方 JSON.parse 即可区分成败
            //   memRead：给定 objc_msgSend 返回的指针(句柄)，把那块映射内存 dump 成 hex
            ctx[@"objc_msgSendSafe"]=^(id recv, NSString *sel, NSArray *args){ return objcMsgSendSafeNative(recv, sel, args); };
            ctx[@"memRead"]=^(NSString *hex, NSNumber *len){ return memReadNative(hex, len); };

            // ---- V2.2 保活状态（只读）：保活由 Autorun 监听开关驱动，JS 只能查不能改 ----
            ctx[@"keepAliveStatus"]=^{ return [[RYKeepAlive shared] statusLine]; };
            ctx[@"keepAliveInfo"]=^{ return [[RYKeepAlive shared] statusJSON]; };

            // ---- V2.2 实时活动（灵动岛）状态（只读）：{"available":bool,"active":bool} ----
            ctx[@"liveActivityStatus"]=^{
                return [NSString stringWithFormat:@"{\"available\":%@,\"active\":%@}",
                        ryLiveActivityAvailable() ? @"true" : @"false",
                        ryLiveActivityActive() ? @"true" : @"false"];
            };

            // ---- AI / Autorun 辅助原语（探针迭代常用；每次执行都是全新 ctx，跨轮状态请落盘）----
            // 限速/间隔：JavaScriptCore 没有 setTimeout，用阻塞 sleep 代替（上限 120s 防呆）
            ctx[@"sleep"]=^(NSNumber *ms){
                int m=[ms intValue];
                if(m>0 && m<=120000) usleep((useconds_t)m*1000);
                return @(m);
            };
            // 时间戳：wall=挂钟秒；mono=单调秒（测耗时不跳变）
            ctx[@"now"]=^NSDictionary*{
                static mach_timebase_info_data_t tb;
                if(tb.denom==0) mach_timebase_info(&tb);
                double mono=(double)mach_absolute_time()*(double)tb.numer/(double)tb.denom/1000000000.0;
                return @{@"wall":@([[NSDate date] timeIntervalSince1970]),@"mono":@(mono)};
            };
            ctx[@"fileExists"]=^(NSString *p){ return @([[NSFileManager defaultManager] fileExistsAtPath:docPath(p)]); };
            ctx[@"fileSize"]=^(NSString *p){
                NSDictionary *a=[[NSFileManager defaultManager] attributesOfItemAtPath:docPath(p) error:NULL];
                return a?@([a[NSFileSize] longLongValue]):@(-1);
            };
            // 追加写：跨轮次 checkpoint / 日志累加的唯一手段（writeFile 会整文件覆盖）
            ctx[@"fileAppend"]=^(NSString *p, NSString *content){
                NSString *fp=docPath(p);
                NSFileManager *fm=[NSFileManager defaultManager];
                if(![fm fileExistsAtPath:fp]) [fm createFileAtPath:fp contents:[NSData data] attributes:nil];
                NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:fp];
                if(!fh) return @"[fileAppend error] cannot open";
                @try{
                    [fh seekToEndOfFile];
                    [fh writeData:[(content?:@"") dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                    return @"ok";
                }@catch(NSException *e){
                    return [NSString stringWithFormat:@"[fileAppend error] %@",e.reason];
                }
            };
            ctx[@"fileDelete"]=^(NSString *p){
                NSError *e; BOOL ok=[[NSFileManager defaultManager] removeItemAtPath:docPath(p) error:&e];
                return ok?@"ok":[NSString stringWithFormat:@"[fileDelete error] %@",e.localizedDescription];
            };
            // 同步 HTTP(S)：调用 AI 后端 / 局域网服务用（比 tcpSend+hex 好用得多）
            ctx[@"httpRequest"]=^NSString*(NSDictionary *opts){ return httpRequestNative(opts); };

            // ---- Autorun 局域网执行服务（AI 在电脑端，iPad 只负责执行 + 回传）----
            // 电脑端连：http://<本机IP>:端口/ping | /eval | /submit | /result?id=
            RYAutorunSetEval(^NSString*(NSString *js){ return RYAutorunRunCapture(js); });
            ctx[@"autorunStart"]=^(NSNumber *port){ return RYAutorunStart([port intValue], nil, nil); };
            ctx[@"autorunStop"]=^NSString*{ return RYAutorunStop(); };
            ctx[@"autorunStatus"]=^NSString*{ return RYAutorunStatus(); };
            ctx[@"autorunLog"]=^NSString*{ return RYAutorunLogText(); };
            ctx[@"openAutorunPanel"]=^NSString*{ return RYAutorunOpenPanel(); };

            // require 桥库（动态加载任意 .js，零重编译即可扩展桥）
            ctx[@"require"]=^NSString*(NSString *name){
                NSString *fn=[name hasSuffix:@".js"]?name:[name stringByAppendingString:@".js"];
                NSString *src=loadScriptByName(fn);
                if(!src) return [NSString stringWithFormat:@"[require] not found: %@",name];
                if([src hasPrefix:@"[loadBundledScript]"]) return src;
                JSValue *r=[ctx evaluateScript:src];
                if(ctx.exception) return [NSString stringWithFormat:@"[require exception] %@",[ctx.exception description]];
                return (r&&![r isUndefined])?[r description]:@"(loaded)";
            };

            // ---- 崩溃定位：登记"最后调用的原语"（见 RYNotePrimitive 注释）----
            ctx[@"__ry_note"]=^BOOL(NSString *n){ RYNotePrimitive([n UTF8String]); return YES; };

            // 给所有原生原语套一层"点名"包装。
            //   · 跳过 __ry_* 自身、跳过 print（print 调用太频繁，会把真正的凶手冲掉）
            //   · 只包函数，其它类型（对象/常量）原样不动
            //   · 用 (function(n,fn){...}) 闭包逐层绑定名字，不能用 for 里的 k（闭包共享变量坑）
            [ctx evaluateScript:
                @"(function(){var g=this;var keys=Object.keys(g);for(var i=0;i<keys.length;i++){"
                @"var k=keys[i];"
                @"if(k==='__ry_note'||k==='print'||k.indexOf('__ry_')===0)continue;"
                @"var f=g[k];"
                @"if(typeof f!=='function')continue;"
                @"g[k]=(function(n,fn){return function(){try{__ry_note(n);}catch(e){}return fn.apply(this,arguments);};})(k,f);"
                @"}})();"];
}

// ---- 执行用户代码（流式输出，立即跳转输出页；UI 锁死，异常不崩 App）----
static void RunCode(UIViewController *from, NSString *code) {
    if (!from.navigationController) return;
    OutputVC *ovc = [[OutputVC alloc] init];
    [from.navigationController pushViewController:ovc animated:YES];
    if (!gOutBuf) gOutBuf = [NSMutableString string];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            [gOutBuf setString:@""];
            JSContext *ctx = [[JSContext alloc] init];
            ctx.exceptionHandler = ^(JSContext *c, JSValue *e) {
                NSString *m = [e description];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gOutTV) gOutTV.text = [gOutTV.text stringByAppendingString:[@"[JS Error] " stringByAppendingString:m]];
                    else [gOutBuf appendFormat:@"[JS Error] %@\n", m];
                });
            };
            // 流式 print：实时 append 到输出页；输出页未建好时先缓冲
            ctx[@"print"] = ^(id arg) {
                NSMutableArray *parts = [NSMutableArray array];
                if ([arg isKindOfClass:[NSArray class]]) { for (id a in arg) [parts addObject:[a description]]; }
                else if (arg != nil && ![arg isEqual:[NSNull null]]) { [parts addObject:[arg description]]; }
                NSString *line = [NSString stringWithFormat:@"%@\n", [parts componentsJoinedByString:@" "]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gOutTV) {
                        gOutTV.text = [gOutTV.text stringByAppendingString:line];
                        NSRange r = NSMakeRange(gOutTV.text.length, 0);
                        [gOutTV scrollRangeToVisible:r];
                    } else { [gOutBuf appendString:line]; }
                });
            };
            [ctx evaluateScript:@"var console={log:function(){print.apply(null,arguments);},error:function(){print.apply(null,arguments);},info:function(){print.apply(null,arguments);},warn:function(){print.apply(null,arguments);}};"];
            installPrimitives(ctx);                 // 终端/文件/XPC/V3 原语
            loadBridgeFiles(ctx);                   // 桥（含单桥开关）
            NSString *eng = loadEngineSource();     // 可编辑执行引擎（热重载）
            if (eng && [eng length]) [ctx evaluateScript:eng];
            JSValue *runFn = ctx[@"RYC_RUN"];
            JSValue *res = nil;
            if (runFn && ![runFn isUndefined]) res = [runFn callWithArguments:@[code ?: @""]];
            else res = [ctx evaluateScript:code];
            if (ctx.exception) {
                // 已由 exceptionHandler 处理
            } else if (res && ![res isUndefined]) {
                NSString *out = [NSString stringWithFormat:@"\n=> %@\n", [res description]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gOutTV) gOutTV.text = [gOutTV.text stringByAppendingString:out]; else [gOutBuf appendString:out];
                });
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *done = @"\n=== 执行完成 ===\n";
                if (gOutTV) gOutTV.text = [gOutTV.text stringByAppendingString:done]; else [gOutBuf appendString:done];
                NSString *finalOut = gOutTV ? [gOutTV.text copy] : [gOutBuf copy];
                if (gRunCompletion) { void (^cb)(NSString *) = gRunCompletion; gRunCompletion = nil; cb(finalOut); }
            });
        }
    });
}

// ---- Autorun 专用：独立 ctx 执行用户代码并捕获输出，返回 JSON ----
// 与 RunCode 的区别：①print 不写 UI，而是收进数组回传；②异常/返回值都结构化
// 注意：本函数由 Autorun 的连接线程调用（与 RunCode 一样跑在后台线程），不碰主线程。
// 把 JS 异常整理成可读文本（Bug 3）：name + message + stack 前 20 行。
// 以前只丢一行 description，调用方看不出是 SyntaxError 还是 TypeError、也拿不到行号。
static NSString *rycExceptionText(JSValue *e, NSString *stage) {
    if (e == nil) return [NSString stringWithFormat:@"[%@] (nil exception)", stage ?: @"JS"];
    JSValue *nv = [e objectForKeyedSubscript:@"name"];
    JSValue *mv = [e objectForKeyedSubscript:@"message"];
    JSValue *sv = [e objectForKeyedSubscript:@"stack"];
    NSString *nm  = (nv && ![nv isUndefined] && ![nv isNull]) ? [nv toString] : nil;
    NSString *msg = (mv && ![mv isUndefined] && ![mv isNull]) ? [mv toString] : nil;
    NSString *stk = (sv && ![sv isUndefined] && ![sv isNull]) ? [sv toString] : nil;
    if (nm.length == 0)  nm  = @"Error";
    if (msg.length == 0) msg = [e description] ?: @"?";
    NSMutableString *out = [NSMutableString stringWithFormat:@"[%@ %@] %@", stage ?: @"JS", nm, msg];
    if (stk.length) {
        NSArray *lines = [stk componentsSeparatedByString:@"\n"];
        NSUInteger n = MIN(lines.count, (NSUInteger)20);
        for (NSUInteger i = 0; i < n; i++) [out appendFormat:@"\n    %@", lines[i]];
    }
    return out;
}

// ---- 通用流式执行器（Terminal / Autorun 共用同一条执行路径）----
void RYExecStream(NSString *code, void (^onLine)(NSString *line),
                  void (^onDone)(NSString *result, NSString *error, double ms)) {
    double t0 = [[NSDate date] timeIntervalSince1970];
    NSMutableArray *errs = [NSMutableArray array];

    JSContext *ctx = [[JSContext alloc] init];
    // Bug 3 修复：异常要带 name / message / stack 前 20 行，别只给一行 description
    ctx.exceptionHandler = ^(JSContext *c, JSValue *e) {
        NSString *m = rycExceptionText(e, @"JS");
        [errs addObject:m];
        if (onLine) onLine(m);
    };
    ctx[@"print"] = ^(id arg) {
        NSMutableArray *parts = [NSMutableArray array];
        if ([arg isKindOfClass:[NSArray class]]) { for (id a in arg) [parts addObject:[a description]]; }
        else if (arg != nil && ![arg isEqual:[NSNull null]]) { [parts addObject:[arg description]]; }
        if (onLine) onLine([parts componentsJoinedByString:@" "]);
    };
    [ctx evaluateScript:@"var console={log:function(){print.apply(null,arguments);},error:function(){print.apply(null,arguments);},info:function(){print.apply(null,arguments);},warn:function(){print.apply(null,arguments);}};"];
    installPrimitives(ctx);
    loadBridgeFiles(ctx);
    NSString *eng = loadEngineSource();
    if (eng && [eng length]) [ctx evaluateScript:eng];

    NSString *resStr = nil;
    NSString *err = nil;
    @try {
        JSValue *runFn = ctx[@"RYC_RUN"];
        JSValue *res = nil;
        if (runFn && ![runFn isUndefined]) res = [runFn callWithArguments:@[code ? code : @""]];
        else res = [ctx evaluateScript:(code ? code : @"")];
        if (res && ![res isUndefined] && ![res isNull]) resStr = [res description];
    } @catch (NSException *e) {
        err = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    if (ctx.exception && ctx.exception != nil) err = rycExceptionText(ctx.exception, @"JS");
    if (err == nil && errs.count > 0) err = [errs componentsJoinedByString:@"\n"];

    double ms = ([[NSDate date] timeIntervalSince1970] - t0) * 1000.0;
    if (onDone) onDone(resStr, err, ms);
}

// ---- Autorun 用：同步执行并汇总成 JSON（复用上面的流式执行器）----
static NSString *RYAutorunRunCapture(NSString *code) {
    NSMutableArray *cap = [NSMutableArray array];
    __block NSString *resStr = nil;
    __block NSString *err = nil;
    __block double ms = 0;
    RYExecStream(code,
                 ^(NSString *line) { if (line) [cap addObject:line]; },
                 ^(NSString *r, NSString *e, double m) { resStr = r; err = e; ms = m; });

    NSString *out = [cap componentsJoinedByString:@"\n"];
    NSDictionary *d = @{
        @"ok":     (err ? @NO : @YES),
        @"output": (out ? out : @""),
        @"result": (resStr ? resStr : [NSNull null]),
        @"error":  (err ? err : [NSNull null]),
        @"ms":     @((int)ms)
    };
    NSData *jd = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    NSString *s = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : nil;
    return s ? s : @"{\"ok\":false,\"error\":\"serialize failed\"}";
}

// ============================================================
//  UI — 受保护外壳（资源管理器 / 脚本 / 桥）
//  注意：本段为 UI 加载逻辑，锁死在此文件。可编辑的「底层」JS（engine.js + bridge_*.js）
//       一律运行时从 Documents 读取（无效则回落 bundle），碰不到这里的原生代码。
// ============================================================
@implementation OutputVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"输出";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(goBack)];
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    [self.view addSubview:_textView];
    if (gOutBuf && gOutBuf.length) _textView.text = [gOutBuf copy];
    gOutTV = _textView;
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; if (gOutTV == _textView) gOutTV = nil; }
- (void)goBack { [self.navigationController popViewControllerAnimated:YES]; }
@end

// ---- 编辑器（新增/编辑 脚本·桥）----
@class EditorVC;
@interface EditorVC : UIViewController
@property (nonatomic, weak) UIViewController *hostVC;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextView *codeView;
@property (nonatomic, assign) BOOL isBridge;
@property (nonatomic, assign) BOOL isEdit;
@property (nonatomic, strong) NSString *origName;
@end
@implementation EditorVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = _isBridge ? (_isEdit ? @"编辑桥" : @"安装桥") : (_isEdit ? @"编辑脚本" : @"添加脚本");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(onSave)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(onCancel)];
    _nameField = [[UITextField alloc] init]; _nameField.translatesAutoresizingMaskIntoConstraints = NO;
    _nameField.borderStyle = UITextBorderStyleRoundedRect; _nameField.font = [UIFont systemFontOfSize:14];
    _nameField.placeholder = _isBridge ? @"桥名，如 mytool（自动加 bridge_ 前缀）" : @"脚本名，如 my_probe.js";
    [self.view addSubview:_nameField];
    _codeView = [[UITextView alloc] init]; _codeView.translatesAutoresizingMaskIntoConstraints = NO;
    _codeView.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    _codeView.layer.borderColor = [UIColor secondaryLabelColor].CGColor; _codeView.layer.borderWidth = 1.0; _codeView.layer.cornerRadius = 8;
    [self.view addSubview:_codeView];
    if (_isEdit && _origName) { _nameField.text = _origName; _nameField.enabled = NO; _codeView.text = loadScriptByName(_origName) ?: @""; }
    else if (_isBridge) { _codeView.text = @"// 桥：定义高层函数，下次执行代码时自动可用\nfunction myBridgeHello() { return \"hello from my bridge\"; }\n"; }
    else { _codeView.text = @"// 粘贴 JS 探针，保存后进「资源管理器→脚本」即可运行\nprint(\"hello from my script\");\n"; }
    [NSLayoutConstraint activateConstraints:@[
        [_nameField.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_nameField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_nameField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_codeView.topAnchor constraintEqualToAnchor:_nameField.bottomAnchor constant:12],
        [_codeView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_codeView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_codeView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
}
- (void)onSave {
    NSString *raw = _nameField.text ?: @""; NSString *name = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) { [self alert:@"请先填名字"]; return; }
    if (_isBridge && ![name hasPrefix:@"bridge_"]) name = [@"bridge_" stringByAppendingString:name];
    NSString *r = saveScriptToDocs(name, _codeView.text ?: @"");
    if ([r hasPrefix:@"[saveScript"]) { [self alert:r]; return; }
    [self dismissViewControllerAnimated:YES completion:^{ if ([_hostVC respondsToSelector:@selector(refreshRM)]) [_hostVC performSelector:@selector(refreshRM)]; }];
}
- (void)onCancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)alert:(NSString*)msg { UIAlertController *a = [UIAlertController alertControllerWithTitle:@"提示" message:msg preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
@end

// ---- 资源管理器（2 分类：脚本 / 桥；修补模块已于 V2.2 移除）----
//  同一份实现支持两种呈现：
//   · embedded = YES → 外壳的第 4 个面板，**内嵌整页显示**（深色现代样式，无导航栏）
//   · embedded = NO  → 「设置 → 经典界面」里的旧入口，**模态弹出**（保留导航栏 + 关闭按钮）
//  配色对齐外壳（MainShell 的 RY_* 宏），那套是文件内宏，这里复制一份 RM_* 保持视觉一致。
#define RM_BG      [UIColor colorWithRed:0.051f green:0.067f blue:0.090f alpha:1.0f]  // #0d1117
#define RM_PANEL   [UIColor colorWithRed:0.086f green:0.106f blue:0.133f alpha:1.0f]  // #161b22
#define RM_BORDER  [UIColor colorWithRed:0.188f green:0.212f blue:0.239f alpha:1.0f]  // #30363d
#define RM_TEXT    [UIColor colorWithRed:0.788f green:0.820f blue:0.851f alpha:1.0f]  // #c9d1d9
#define RM_MUTED   [UIColor colorWithRed:0.545f green:0.580f blue:0.620f alpha:1.0f]  // #8b949e
#define RM_ACCENT  [UIColor colorWithRed:0.184f green:0.506f blue:0.969f alpha:1.0f]  // #2f81f7

@class ResourceManagerVC;
@interface ResourceManagerVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *addBtn;
@property (nonatomic, strong) NSArray *scripts;
@property (nonatomic, strong) NSArray *bridges;
@property (nonatomic, assign) BOOL lpAdded;
@property (nonatomic, assign) BOOL embedded;      // YES = 外壳内嵌面板
@end
@implementation ResourceManagerVC
- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL emb = self.embedded;
    self.view.backgroundColor = emb ? RM_BG : [UIColor systemBackgroundColor];
    self.title = @"资源管理器";
    if (!emb) {
        // 模态弹出（经典界面入口）才需要"关闭"；内嵌面板由外壳的导航项切换
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self action:@selector(close)];
    }
    CGFloat pad = emb ? 16.0f : 12.0f;

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"脚本", @"桥"]];
    _seg.translatesAutoresizingMaskIntoConstraints = NO; _seg.selectedSegmentIndex = 0;
    [_seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
    if (emb) {                                  // 深色现代样式，跟外壳同一套配色
        _seg.selectedSegmentTintColor = RM_ACCENT;
        _seg.backgroundColor = RM_PANEL;
        [_seg setTitleTextAttributes:@{NSForegroundColorAttributeName: RM_TEXT} forState:UIControlStateNormal];
        [_seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];
    }
    [self.view addSubview:_seg];

    // 「新建」按钮做成面板内的圆形/圆角按钮（不再依赖导航栏 rightBarButtonItem，
    // 因为内嵌模式下没有导航栏 —— 这正是上一版加不了东西的原因）
    _addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _addBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_addBtn setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    _addBtn.tintColor = emb ? RM_ACCENT : [UIColor systemBlueColor];
    _addBtn.backgroundColor = emb ? RM_PANEL : [UIColor secondarySystemBackgroundColor];
    _addBtn.layer.cornerRadius = 8.0f;
    _addBtn.layer.borderWidth = 0.5f;
    _addBtn.layer.borderColor = (emb ? RM_BORDER : [UIColor separatorColor]).CGColor;
    [_addBtn addTarget:self action:@selector(addCurrent) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_addBtn];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hintLabel.font = [UIFont systemFontOfSize:11.0f];
    _hintLabel.textColor = emb ? RM_MUTED : [UIColor secondaryLabelColor];
    _hintLabel.text = @"点脚本 = 立即运行 · 长按 = 运行/编辑/删除 · 桥右侧开关控制启用";
    [self.view addSubview:_hintLabel];

    // 内嵌模式用 insetGrouped：圆角卡片行，现代观感；模态模式保持原来的 plain
    _table = [[UITableView alloc] initWithFrame:CGRectZero
                                          style:(emb ? UITableViewStyleInsetGrouped : UITableViewStylePlain)];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.delegate = self; _table.dataSource = self;
    if (emb) {
        _table.backgroundColor = RM_BG;
        _table.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    }
    [self.view addSubview:_table];
    _lpAdded = NO;

    [NSLayoutConstraint activateConstraints:@[
        [_seg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [_seg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [_addBtn.leadingAnchor constraintEqualToAnchor:_seg.trailingAnchor constant:8],
        [_addBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [_addBtn.centerYAnchor constraintEqualToAnchor:_seg.centerYAnchor],
        [_addBtn.widthAnchor constraintEqualToConstant:40],
        [_addBtn.heightAnchor constraintEqualToConstant:32],
        [_hintLabel.topAnchor constraintEqualToAnchor:_seg.bottomAnchor constant:8],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad + 2],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-(pad + 2)],
        [_table.topAnchor constraintEqualToAnchor:_hintLabel.bottomAnchor constant:4],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:0],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:0],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:0],
    ]];
    [self refreshRM];
}
- (void)refreshRM {
    NSString *dd = docsDir();
    NSArray *df = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dd error:nil] ?: @[];
    NSMutableArray *sc = [NSMutableArray array];
    for (NSString *f in df) { if ([[f pathExtension] isEqualToString:@"js"] && ![f hasPrefix:@"bridge_"] && ![f isEqualToString:@"engine.js"]) [sc addObject:f]; }
    _scripts = sc;
    NSMutableArray *br = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    NSArray *docsB = [df filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'bridge_' AND SELF ENDSWITH '.js'"]];
    for (NSString *f in docsB) { [br addObject:f]; [seen addObject:f]; }
    for (NSString *f in bundledScripts()) { if ([f hasPrefix:@"bridge_"] && [f hasSuffix:@".js"] && ![seen containsObject:f]) { [br addObject:f]; [seen addObject:f]; } }
    _bridges = br;
    [_table reloadData];
}
- (void)segChanged { [self refreshRM]; }
- (void)addCurrent {
    if (_seg.selectedSegmentIndex == 0) { EditorVC *e = [[EditorVC alloc] init]; e.hostVC = self; e.isBridge = NO; e.isEdit = NO;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:e]; nav.modalPresentationStyle = UIModalPresentationFormSheet; [self presentViewController:nav animated:YES completion:nil]; }
    else if (_seg.selectedSegmentIndex == 1) { EditorVC *e = [[EditorVC alloc] init]; e.hostVC = self; e.isBridge = YES; e.isEdit = NO;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:e]; nav.modalPresentationStyle = UIModalPresentationFormSheet; [self presentViewController:nav animated:YES completion:nil]; }
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _seg.selectedSegmentIndex == 0 ? _scripts.count : _bridges.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    if (self.embedded) {                     // 深色卡片行（配色对齐外壳）
        c.backgroundColor = RM_PANEL;
        c.textLabel.textColor = RM_TEXT;
        c.detailTextLabel.textColor = RM_MUTED;
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.06f];
        c.selectedBackgroundView = sel;
    }
    if (_seg.selectedSegmentIndex == 0) { NSString *n = _scripts[ip.row]; c.textLabel.text = n; c.detailTextLabel.text = @"脚本（点击运行）"; c.accessoryType = UITableViewCellAccessoryNone; c.accessoryView = nil; }
    else { NSString *n = _bridges[ip.row]; c.textLabel.text = n; BOOL en = bridgeIsEnabled(n);
        BOOL isOverride = [[NSFileManager defaultManager] fileExistsAtPath:[docsDir() stringByAppendingPathComponent:n]] && [bundledScripts() containsObject:n];
        NSString *detail = en ? @"已开启" : @"已关闭";
        if (isOverride) detail = [detail stringByAppendingString:@" · 覆盖版(重置内置桥可还原)"];
        c.detailTextLabel.text = detail;
        UISwitch *sw = [[UISwitch alloc] init]; sw.on = en; sw.tag = ip.row;
        if (self.embedded) sw.onTintColor = RM_ACCENT;
        [sw addTarget:self action:@selector(toggleBridge:) forControlEvents:UIControlEventValueChanged]; c.accessoryView = sw; }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_seg.selectedSegmentIndex == 0) RunCode(self, loadScriptByName(_scripts[ip.row]));
}
- (void)toggleBridge:(UISwitch *)sw {
    if (_seg.selectedSegmentIndex != 1) return;
    NSString *n = _bridges[sw.tag]; setBridgeEnabled(n, sw.on);
    [_table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:sw.tag inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!_lpAdded) { UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)]; lp.minimumPressDuration = 0.5; [_table addGestureRecognizer:lp]; _lpAdded = YES; } }
- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:_table]; NSIndexPath *ip = [_table indexPathForRowAtPoint:p]; if (!ip) return;
    if (_seg.selectedSegmentIndex == 0) {
        NSString *n = _scripts[ip.row];
        BOOL isUser = [[NSFileManager defaultManager] fileExistsAtPath:[docsDir() stringByAppendingPathComponent:n]];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:n message:isUser ? @"用户脚本" : @"内置脚本（编辑=生成覆盖版；不可删内置）" preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"运行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { RunCode(self, loadScriptByName(n)); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"编辑" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { EditorVC *e = [[EditorVC alloc] init]; e.hostVC = self; e.isBridge = NO; e.isEdit = YES; e.origName = n; UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:e]; nav.modalPresentationStyle = UIModalPresentationFormSheet; [self presentViewController:nav animated:YES completion:nil]; }]];
        if (isUser) [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) { deleteDocScript(n); [self refreshRM]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) { a.popoverPresentationController.sourceView = _table; a.popoverPresentationController.sourceRect = CGRectMake(p.x, p.y, 1, 1); }
        [self presentViewController:a animated:YES completion:nil];
    } else if (_seg.selectedSegmentIndex == 1) {
        NSString *n = _bridges[ip.row];
        BOOL isUser = [[NSFileManager defaultManager] fileExistsAtPath:[docsDir() stringByAppendingPathComponent:n]];
        BOOL isBundled = [bundledScripts() containsObject:n];
        NSString *msg;
        if (isUser && isBundled) msg = @"内置桥覆盖版（重置内置桥可还原为 bundle 原版）";
        else if (isUser) msg = @"用户桥";
        else msg = @"内置桥（删除=禁用；恢复初始底层可还原）";
        UIAlertController *a = [UIAlertController alertControllerWithTitle:n message:msg preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"编辑" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { EditorVC *e = [[EditorVC alloc] init]; e.hostVC = self; e.isBridge = YES; e.isEdit = YES; e.origName = n; UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:e]; nav.modalPresentationStyle = UIModalPresentationFormSheet; [self presentViewController:nav animated:YES completion:nil]; }]];
        if (isUser) [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) { deleteDocScript(n); [self refreshRM]; }]];
        else [a addAction:[UIAlertAction actionWithTitle:@"禁用(删除)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) { setBridgeEnabled(n, NO); [self refreshRM]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) { a.popoverPresentationController.sourceView = _table; a.popoverPresentationController.sourceRect = CGRectMake(p.x, p.y, 1, 1); }
        [self presentViewController:a animated:YES completion:nil];
    }
}
// 修补模块已移除（V2.2）：引擎/桥逻辑统一走 require() 动态加载，改底层不再需要内置编辑器。
- (void)alert:(NSString*)msg { UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
@end

// 资源管理器工厂：外壳（MainShell）通过它拿本 VC，不必看到 main.m 内部的 @interface。
// RYMakeResourceManagerVC  = 模态弹出用（经典界面入口，带导航栏 + 关闭）
// RYMakeResourceManagerPane = 外壳内嵌面板用（现代深色样式，整页显示，不是弹窗）
UIViewController *RYMakeResourceManagerVC(void) {
    return [[ResourceManagerVC alloc] init];
}
UIViewController *RYMakeResourceManagerPane(void) {
    ResourceManagerVC *r = [[ResourceManagerVC alloc] init];
    r.embedded = YES;
    return r;
}
void RYResourceManagerRefresh(UIViewController *vc) {
    if ([vc isKindOfClass:[ResourceManagerVC class]]) [(ResourceManagerVC *)vc refreshRM];
}

// ---- LocalSend（局域网服务端投喂：Update / Code / UpdateIPA 三 head）----
@interface LocalSendDetailVC : UIViewController <NSURLSessionDelegate>
@property (nonatomic, strong) NSDictionary *payload;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UITextView *codeView;
@end
@interface LocalSendVC : UIViewController <NSURLSessionDelegate>
@property (nonatomic, strong) UITextField *addrField;
@property (nonatomic, strong) NSURLSession *lsSession;
@property (nonatomic, strong) NSMutableData *lsData;
@property (nonatomic, copy) void (^lsCompletion)(NSData *data, NSURLResponse *resp, NSError *err);
@end
@implementation LocalSendVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"LocalSend";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    UILabel *lab = [[UILabel alloc] init]; lab.translatesAutoresizingMaskIntoConstraints = NO; lab.text = @"请输入服务端"; lab.font = [UIFont systemFontOfSize:15];
    _addrField = [[UITextField alloc] init]; _addrField.translatesAutoresizingMaskIntoConstraints = NO;
    _addrField.borderStyle = UITextBorderStyleRoundedRect; _addrField.font = [UIFont systemFontOfSize:14];
    _addrField.placeholder = @"https://DESKTOP-4EILO2C.local:8443";
    _addrField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _addrField.autocorrectionType = UITextAutocorrectionTypeNo;
    _addrField.keyboardType = UIKeyboardTypeURL;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"ryc_localsend_addr"];
    if (saved.length) _addrField.text = saved;
    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem]; go.translatesAutoresizingMaskIntoConstraints = NO;
    [go setTitle:@"保存并查找" forState:UIControlStateNormal]; go.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [go setBackgroundColor:[UIColor systemBlueColor]]; [go setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    go.layer.cornerRadius = 10; [go addTarget:self action:@selector(onGo) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:lab]; [self.view addSubview:_addrField]; [self.view addSubview:go];
    [NSLayoutConstraint activateConstraints:@[
        [lab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [lab.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_addrField.topAnchor constraintEqualToAnchor:lab.bottomAnchor constant:10],
        [_addrField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_addrField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [go.topAnchor constraintEqualToAnchor:_addrField.bottomAnchor constant:16],
        [go.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [go.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [go.heightAnchor constraintEqualToConstant:46],
    ]];
}
- (void)close { [self.lsSession invalidateAndCancel]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)onGo {
    [self.view endEditing:YES];
    NSString *addr = [_addrField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (addr.length == 0) { [self alert:@"请输入服务端地址"]; return; }
    if (![addr hasPrefix:@"http://"] && ![addr hasPrefix:@"https://"]) addr = [@"https://" stringByAppendingString:addr];
    [[NSUserDefaults standardUserDefaults] setObject:addr forKey:@"ryc_localsend_addr"];
    [self fetchFrom:addr];
}
- (void)fetchFrom:(NSString *)input {
    // 地址可带路径：如 https://host:8443/bridge 拉桥清单；默认 /localsend。
    // 重构：直接取用户输入的 path，绝不二次拼接，避免「/bridge」变「/bridge/bridge」的双重路径 bug。
    NSString *trimmed = [input stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/ "]];
    NSURL *inURL = [NSURL URLWithString:trimmed];
    if (!inURL || !inURL.scheme || !inURL.host) { [self alert:@"地址无法解析"]; return; }
    NSString *path = (inURL.path.length > 1) ? inURL.path : @"/localsend";
    NSString *authority = [NSString stringWithFormat:@"%@://%@", inURL.scheme, inURL.host];
    if (inURL.port) authority = [authority stringByAppendingFormat:@":%@", [inURL.port stringValue]];
    NSURL *url = [NSURL URLWithString:[authority stringByAppendingString:path]];
    if (!url) { [self alert:@"地址无法解析"]; return; }
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:sp]; [sp startAnimating];
    if (!self.lsSession) {
        // 局域网研究工具：自建 session 并用 self 作 delegate，使其接受自签证书（仅用于可信 LAN 服务端）
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        self.lsSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    NSURLSessionDataTask *t = [self.lsSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.rightBarButtonItem = nil;
            if (err) { [self alert:[NSString stringWithFormat:@"连接失败：%@", err.localizedDescription]]; return; }
            NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
            if (h.statusCode != 200) { [self alert:[NSString stringWithFormat:@"服务端返回 %ld", (long)h.statusCode]]; return; }
            NSError *je; id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
            if (![obj isKindOfClass:[NSDictionary class]]) { [self alert:@"返回内容不是合法 JSON"]; return; }
            LocalSendDetailVC *d = [[LocalSendDetailVC alloc] init]; d.payload = obj;
            [self.navigationController pushViewController:d animated:YES];
        });
    }];
    [t resume];
}
// 局域网研究服务端使用自签证书：对 server-trust 挑战直接接受（仅用于可信 LAN，不校验证书链）
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSURLCredential *c = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, c);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
- (void)alert:(NSString *)msg { UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
@end

@implementation LocalSendDetailVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    NSString *head = _payload[@"head"] ?: @"LocalSend";
    self.title = _payload[@"title"] ?: head;
    NSString *changelog = _payload[@"changelog"] ?: @"(无更新说明)";
    NSString *code = _payload[@"code"] ?: @"";
    _logView = [[UITextView alloc] init]; _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO; _logView.font = [UIFont systemFontOfSize:13]; _logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _logView.text = [NSString stringWithFormat:@"【更新内容】\n%@\n", changelog];
    _codeView = [[UITextView alloc] init]; _codeView.translatesAutoresizingMaskIntoConstraints = NO;
    _codeView.editable = NO; _codeView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    _codeView.text = code;
    [self.view addSubview:_logView]; [self.view addSubview:_codeView];
    [NSLayoutConstraint activateConstraints:@[
        [_logView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_logView.heightAnchor constraintEqualToConstant:120],
        [_codeView.topAnchor constraintEqualToAnchor:_logView.bottomAnchor constant:8],
        [_codeView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_codeView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_codeView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
    if ([head isEqualToString:@"Update"]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"更新" style:UIBarButtonItemStyleDone target:self action:@selector(onUpdate)];
    } else if ([head isEqualToString:@"Code"]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"执行" style:UIBarButtonItemStyleDone target:self action:@selector(onCode)];
    } else if ([head isEqualToString:@"UpdateIPA"]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"安装" style:UIBarButtonItemStyleDone target:self action:@selector(onInstall)];
    } else if ([head isEqualToString:@"Bridge"]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"安装桥" style:UIBarButtonItemStyleDone target:self action:@selector(onInstallBridge)];
    }
}
- (void)onUpdate {
    NSString *file = _payload[@"file"] ?: @"engine.js";
    NSString *code = _payload[@"code"] ?: @"";
    NSString *path = [file isEqualToString:@"engine.js"] ? engineDocPath() : [docsDir() stringByAppendingPathComponent:file];
    NSError *e;
    if ([code writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e])
        [self alert:[NSString stringWithFormat:@"已更新 %@（下次执行生效）", file]];
    else [self alert:[NSString stringWithFormat:@"更新失败：%@", e.localizedDescription]];
}
- (void)onCode {
    NSString *code = _payload[@"code"] ?: @"";
    if (code.length == 0) { [self alert:@"服务端未提供代码"]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"执行代码" message:@"请输入输出返回地址（留空则不回传结果）" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.placeholder = @"https://192.168.0.110:8443/result";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"执行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        NSString *addr = [[a.textFields.firstObject text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (addr.length) {
            NSString *finalAddr = addr;
            if (![finalAddr hasPrefix:@"http://"] && ![finalAddr hasPrefix:@"https://"]) finalAddr = [@"https://" stringByAppendingString:finalAddr];
            __weak typeof(self) wself = self;
            gRunCompletion = ^(NSString *output){ [wself postResult:output to:finalAddr]; };
        } else {
            gRunCompletion = nil;
        }
        RunCode(self, code);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)onInstall {
    NSString *url = _payload[@"installUrl"] ?: @"";
    if (url.length == 0) { [self alert:@"服务端未提供安装地址"]; return; }
    NSString *r = installIPANative(url);
    [self alert:[NSString stringWithFormat:@"已请求安装：%@", r]];
}
- (void)onInstallBridge {
    NSString *file = _payload[@"file"] ?: @"bridge_new.js";
    if (![file hasPrefix:@"bridge_"]) file = [@"bridge_" stringByAppendingString:file];
    NSString *code = _payload[@"code"] ?: @"";
    if (code.length == 0) { [self alert:@"服务端未提供桥代码"]; return; }
    NSString *path = [docsDir() stringByAppendingPathComponent:file];
    NSError *e;
    if ([code writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e]) {
        setBridgeEnabled(file, YES);
        [self alert:[NSString stringWithFormat:@"已安装桥 %@（已启用，下次执行生效）", file]];
    } else {
        [self alert:[NSString stringWithFormat:@"安装失败：%@", e.localizedDescription]];
    }
}
- (void)postResult:(NSString *)output to:(NSString *)urlStr {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { [self alert:[NSString stringWithFormat:@"返回地址无法解析：%@", urlStr]]; return; }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"output": output ?: @"", @"title": _payload[@"title"] ?: @""};
    NSError *je;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&je];
    if (!data) data = [[NSString stringWithFormat:@"{\"output\":%@}", output ?: @""] dataUsingEncoding:NSUTF8StringEncoding];
    [req setHTTPBody:data];
    NSURLSessionDataTask *t = [s dataTaskWithRequest:req completionHandler:^(NSData *_, NSURLResponse *resp, NSError *err) {
        NSInteger status = ([resp isKindOfClass:[NSHTTPURLResponse class]]) ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || status < 200 || status >= 300) {
                NSString *why = err ? err.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)status];
                if (gOutTV) gOutTV.text = [gOutTV.text stringByAppendingString:[NSString stringWithFormat:@"\n[回传失败] %@\n", why]];
                [self alert:[NSString stringWithFormat:@"结果回传失败：%@", why]];
            } else {
                if (gOutTV) gOutTV.text = [gOutTV.text stringByAppendingString:[NSString stringWithFormat:@"\n[结果已回传至 %@]\n", urlStr]];
                [self alert:[NSString stringWithFormat:@"结果已回传至 %@", urlStr]];
            }
        });
    }];
    [t resume];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSURLCredential *c = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, c);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
- (void)alert:(NSString *)msg { UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
@end

// ---- 主控制台（代码框 + 执行 + 资源管理器 + LocalSend）----
@interface InputVC : UIViewController
@property (nonatomic, strong) UITextView *codeInput;
@property (nonatomic, strong) UIButton *execBtn;
@property (nonatomic, strong) UIButton *rmBtn;
@property (nonatomic, strong) UIButton *lsBtn;
@property (nonatomic, assign) BOOL engineChecked;
@end
@implementation InputVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor]; self.title = @"RyConsole";
    _codeInput = [[UITextView alloc] init]; _codeInput.translatesAutoresizingMaskIntoConstraints = NO;
    _codeInput.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    _codeInput.layer.borderColor = [UIColor secondaryLabelColor].CGColor; _codeInput.layer.borderWidth = 1.0; _codeInput.layer.cornerRadius = 8;
    _codeInput.text = @"// RyConsole — 侧载一次、免重签跑代码（执行即跳转输出页，实时刷新）\nprint(\"hello from RyConsole\");\nprint(\"uname: \" + runCommand(\"uname -a\"));\n\n// 列出所有脚本/桥：\nprint(JSON.stringify(listScripts()));\n";
    [self.view addSubview:_codeInput];
    _execBtn = [UIButton buttonWithType:UIButtonTypeSystem]; _execBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_execBtn setTitle:@"执行" forState:UIControlStateNormal]; _execBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [_execBtn setBackgroundColor:[UIColor systemBlueColor]]; [_execBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _execBtn.layer.cornerRadius = 10; [_execBtn addTarget:self action:@selector(onExec) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_execBtn];
    _rmBtn = [UIButton buttonWithType:UIButtonTypeSystem]; _rmBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_rmBtn setTitle:@"资源管理器" forState:UIControlStateNormal]; _rmBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [_rmBtn setBackgroundColor:[UIColor systemGrayColor]]; [_rmBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _rmBtn.layer.cornerRadius = 10; [_rmBtn addTarget:self action:@selector(openRM) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_rmBtn];
    _lsBtn = [UIButton buttonWithType:UIButtonTypeSystem]; _lsBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_lsBtn setTitle:@"LocalSend" forState:UIControlStateNormal]; _lsBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [_lsBtn setBackgroundColor:[UIColor systemIndigoColor]]; [_lsBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _lsBtn.layer.cornerRadius = 10; [_lsBtn addTarget:self action:@selector(openLocalSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_lsBtn];
    [NSLayoutConstraint activateConstraints:@[
        [_codeInput.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_codeInput.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_codeInput.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_codeInput.bottomAnchor constraintEqualToAnchor:_rmBtn.topAnchor constant:-12],
        [_rmBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_rmBtn.trailingAnchor constraintEqualToAnchor:_lsBtn.leadingAnchor constant:-6],
        [_rmBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [_rmBtn.heightAnchor constraintEqualToConstant:48],
        [_lsBtn.leadingAnchor constraintEqualToAnchor:_rmBtn.trailingAnchor constant:6],
        [_lsBtn.trailingAnchor constraintEqualToAnchor:_execBtn.leadingAnchor constant:-6],
        [_lsBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [_lsBtn.heightAnchor constraintEqualToConstant:48],
        [_execBtn.leadingAnchor constraintEqualToAnchor:_lsBtn.trailingAnchor constant:6],
        [_execBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_execBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [_execBtn.heightAnchor constraintEqualToConstant:48],
        [_rmBtn.widthAnchor constraintEqualToAnchor:_lsBtn.widthAnchor],
        [_lsBtn.widthAnchor constraintEqualToAnchor:_execBtn.widthAnchor],
    ]];
}
- (void)onExec { _execBtn.enabled = NO; [_execBtn setTitle:@"执行中…" forState:UIControlStateNormal]; RunCode(self, _codeInput.text); [self performSelector:@selector(reEnable) withObject:nil afterDelay:0.6]; }
- (void)reEnable { _execBtn.enabled = YES; [_execBtn setTitle:@"执行" forState:UIControlStateNormal]; }
- (void)openRM { ResourceManagerVC *r = [[ResourceManagerVC alloc] init]; UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:r]; nav.modalPresentationStyle = UIModalPresentationFormSheet; [self presentViewController:nav animated:YES completion:nil]; }
- (void)openLocalSend {
    LocalSendVC *l = [[LocalSendVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:l];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!_engineChecked) { _engineChecked = YES; [self validateEngineAtLaunch]; } }
- (void)alert:(NSString*)msg { UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
- (void)validateEngineAtLaunch {
    // 启动容错：仅当用户覆盖版 engine.js 存在时，做一次「轻量」语法预检（括号/花括号配平）。
    // 关键：不创建 JSContext、不做任何可能崩溃的外部调用；整段包在 @try/@catch，任何异常都静默放过，
    // 保证 App 一定能进入。括号不配平才提示可还原初始底层（粗粒度语法错）。
    @try {
        NSString *dp = engineDocPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:dp]) return;
        NSString *eng = [NSString stringWithContentsOfFile:dp encoding:NSUTF8StringEncoding error:nil];
        if (!eng || ![eng length]) return;
        int depth = 0; BOOL inStr = NO; unichar q = 0; BOOL inLine = NO; BOOL inBlock = NO;
        for (NSUInteger i = 0; i < eng.length; i++) {
            unichar c = [eng characterAtIndex:i];
            if (inLine) { if (c == '\n') inLine = NO; continue; }
            if (inBlock) { if (c == '*' && i+1 < eng.length && [eng characterAtIndex:i+1] == '/') { inBlock = NO; i++; } continue; }
            if (inStr) { if (c == '\\') { i++; continue; } if (c == q) inStr = NO; continue; }
            if (c == '/' && i+1 < eng.length) {
                unichar n = [eng characterAtIndex:i+1];
                if (n == '/') { inLine = YES; i++; continue; }
                if (n == '*') { inBlock = YES; i++; continue; }
            }
            if (c == '"' || c == '\'' || c == '`') { inStr = YES; q = c; continue; }
            if (c == '(' || c == '[' || c == '{') depth++;
            else if (c == ')' || c == ']' || c == '}') { depth--; if (depth < 0) break; }
        }
        if (depth != 0) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"engine.js（你修改过的底层）出错"
                message:@"括号/花括号未配平，可能存在语法错误。\n\n是否还原为 IPA 初始底层（bundle 原版）？"
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"还原初始底层" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
                @try { [[NSFileManager defaultManager] removeItemAtPath:engineDocPath() error:nil]; } @catch (NSException *e) {}
                [self alert:@"已还原 engine.js 为初始底层（下次执行生效）"];
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"仍加载（可能功能缺失）" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }
    } @catch (NSException *e) {
        return; // 任何异常都放过，保证 App 能进入
    }
}
@end

// ============================================================
//  崩溃日志（V2.2）：把崩溃现场落到 Documents/ryconsole_crash.log
//  目的：本机没有 Mac / 没有调试器，真机崩了只能靠这个文件定位。
//  覆盖：未捕获 ObjC 异常（含完整符号栈）+ SIGSEGV/SIGBUS/SIGABRT/… 信号（含回溯地址）
//  读取：文件 App → 我的 iPad 上 → RyConsole → ryconsole_crash.log
//       （也能在被弹出的 RyConsole 面板里用 readFile("ryconsole_crash.log") 拿）
// ============================================================
static int ryCrashFd = -1;

// 「最后调用的原语」：installPrimitives 在 JS 侧给每个原语套了登记包装（见 __ry_note），
// 每次调用都会写这个 **无锁 char 数组** —— 这样信号处理器里也能安全读（只用 snprintf/write）。
// 崩溃日志里直接点名是哪个原语崩的，省掉"从 block 序号反查源码"那套不可靠操作。
static char gLastPrim[128] = {0};

void RYNotePrimitive(const char *name) {
    if (name == NULL) return;
    strlcpy(gLastPrim, name, sizeof(gLastPrim));
}

const char *RYLastPrimitive(void) {
    return gLastPrim[0] ? gLastPrim : "(none)";
}

static void ryCrashWrite(const char *s, size_t n) {
    if (ryCrashFd >= 0 && s && n) { ssize_t _ = write(ryCrashFd, s, n); (void)_; }
}

static void ryCrashLog(NSString *s) {
    if (!s) return;
    const char *c = [s UTF8String];
    if (c) ryCrashWrite(c, strlen(c));
}

static void ryUncaughtExceptionHandler(NSException *e) {
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"\n==== RyConsole 未捕获异常 @ %@ ====\n", [NSDate date]];
    [m appendFormat:@"lastPrim: %s\n", RYLastPrimitive()];      // ★ 直接点名刚才在跑哪个原语
    [m appendFormat:@"name   : %@\nreason : %@\n", e.name, e.reason];
    [m appendString:@"userInfo:\n"];
    [m appendFormat:@"  %@\n", e.userInfo];
    [m appendString:@"callStackSymbols:\n"];
    for (NSString *l in e.callStackSymbols) [m appendFormat:@"  %@\n", l];
    [m appendString:@"==== end ====\n\n"];
    ryCrashLog(m);
}

// 信号处理里只允许 async-signal-safe 调用：纯 write / snprintf / backtrace_symbols_fd，**不碰 ObjC**
static void rySignalHandler(int sig) {
    char buf[288];
    // ★ lastPrim：崩溃时正在执行哪个 JS 原语（只读无锁 char 数组 + write，信号安全）
    int n = snprintf(buf, sizeof(buf), "\n==== RyConsole 收到信号 %d（%s） lastPrim=%s ====\n",
                     sig, strsignal(sig), RYLastPrimitive());
    if (n > 0) ryCrashWrite(buf, (size_t)n);
    void *bt[64];
    int frames = backtrace(bt, 64);
    if (ryCrashFd >= 0 && frames > 0) backtrace_symbols_fd(bt, frames, ryCrashFd);
    // 还原默认处理再重抛：保留系统侧的崩溃上报/看门狗行为
    signal(sig, SIG_DFL);
    raise(sig);
}

void RYInstallCrashLogger(void) {
    if (ryCrashFd >= 0) return;
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = paths.count ? paths.firstObject : NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:@"ryconsole_crash.log"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        }
        ryCrashFd = open([path fileSystemRepresentation], O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (ryCrashFd < 0) return;
        ryCrashLog([NSString stringWithFormat:@"\n######## RyConsole 启动 @ %@ ########\n", [NSDate date]]);
        NSSetUncaughtExceptionHandler(&ryUncaughtExceptionHandler);
        int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
        for (int i = 0; i < 6; i++) signal(sigs[i], rySignalHandler);
    } @catch (NSException *e) {
        NSLog(@"[RyCrash] 安装失败: %@", e.reason);
    }
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
// ---- 供新外壳（MainShell）调用：返回经典界面（旧 InputVC 的导航栈）----
UIViewController *RYMakeLegacyConsoleVC(void) {
    InputVC *ivc = [[InputVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:ivc];
    return nav;
}

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    RYInstallCrashLogger();          // 第一件事：装崩溃捕获（后面任何崩溃都留证据）

    // 清掉"上次进程被强杀"残留的灵动岛：强杀不会给我们任何回调，只能在下次启动补刀
    int32_t swept = ryLiveActivitySweep();
    if (swept > 0) NSLog(@"[LiveActivity] 启动时清掉 %d 个残留活动", (int)swept);

    // Autorun 执行器提前注册：这样面板直接点「启动」也能工作（不必先跑过一段 JS）
    RYAutorunSetEval(^NSString*(NSString *js){ return RYAutorunRunCapture(js); });
    _window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // 新外壳：左侧栏三板块（终端 / Autorun / 设置）；旧界面从「设置 → 经典界面」进入
    RYShellVC *shell = [[RYShellVC alloc] init];
    _window.rootViewController = shell;
    [_window makeKeyAndVisible];
    return YES;
}

// 正常终止（系统回收 / 用户主动退出 App）：保活 + 灵动岛一起收掉。
// 注意：从后台把 App **划掉**属于强杀（SIGKILL），这里不会触发 —— 那种情况靠
//       下次启动的 ryLiveActivitySweep() 兜底，另外活动的 staleDate 也会让它自动变陈旧。
- (void)applicationWillTerminate:(UIApplication *)application {
    @try {
        ryLiveActivityStop();
        [[RYKeepAlive shared] end];
        NSLog(@"[RyConsole] willTerminate：保活与实时活动已收尾");
    } @catch (NSException *e) {
        NSLog(@"[RyConsole] willTerminate 异常（已吞）: %@", e.reason);
    }
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
