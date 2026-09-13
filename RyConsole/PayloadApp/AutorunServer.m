//
//  AutorunServer.m
//  RyConsole —— Autorun 局域网执行服务（实现）
//
//  设计要点：
//   · 监听线程只做 I/O；JS 执行一律 dispatch 回主线程（JSContext 必须在主线程用）
//   · 用 select() 做 1 秒超时轮询，避免阻塞在 accept() 上导致无法停止
//   · 一次连接 = 一个请求（Connection: close），解析只支持所需的最小子集
//   · 任务队列串行执行，结果留在内存里供 /result 轮询（最多保留 RY_MAX_JOBS 条）
//
//  假定：工程开启 ARC（Xcode 默认）。若为 MRC，请把 strong 改成 retain。
//

#import "AutorunServer.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdint.h>

#define RY_DEFAULT_PORT   8899
#define RY_MAX_LOG        400
#define RY_MAX_JOBS       40
#define RY_DEFAULT_TIMEOUT 15000   // ms

#pragma mark - 小工具

static NSString *ryStamp(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    [f setDateFormat:@"HH:mm:ss"];
    return [f stringFromDate:[NSDate date]];
}

// 取本机局域网 IPv4（en0 优先）
static NSString *ryLANAddress(void) {
    NSString *found = nil;
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0 || addrs == NULL) return @"?";
    for (struct ifaddrs *p = addrs; p != NULL; p = p->ifa_next) {
        if (p->ifa_addr == NULL) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = [NSString stringWithUTF8String:p->ifa_name ? p->ifa_name : ""];
        if (![name isEqualToString:@"en0"] && ![name isEqualToString:@"en1"]) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf)) == NULL) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        if ([ip hasPrefix:@"127."]) continue;
        found = ip;
        break;
    }
    freeifaddrs(addrs);
    return found ? found : @"?";
}

static UIViewController *ryTopVC(void) {
    UIWindow *key = nil;
    NSSet *scenes = UIApplication.sharedApplication.connectedScenes;
    for (UIScene *s in scenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) return nil;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSData *ryHttpResponse(int status, NSString *jsonBody) {
    if (jsonBody == nil) jsonBody = @"{}";
    NSData *body = [jsonBody dataUsingEncoding:NSUTF8StringEncoding];
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
         "Content-Type: application/json; charset=utf-8\r\n"
         "Content-Length: %lu\r\n"
         "Connection: close\r\n"
         "Access-Control-Allow-Origin: *\r\n"
         "\r\n",
        status, (status == 200 ? @"OK" : @"Error"), (unsigned long)body.length];
    NSMutableData *out = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:body];
    return out;
}

static void rySendAll(int fd, NSData *data) {
    const uint8_t *p = (const uint8_t *)data.bytes;
    size_t left = (size_t)data.length;
    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n <= 0) break;
        p += n;
        left -= (size_t)n;
    }
}

#pragma mark - 服务本体

@interface RYAutorunServer : NSObject
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) int port;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) int jobSeq;
@property (nonatomic, copy)   RYEvalBlock evalBlock;
@property (nonatomic, copy)   RYLogBlock logger;
@property (nonatomic, strong) NSMutableArray *logs;
@property (nonatomic, strong) NSMutableDictionary *jobs;
@property (nonatomic, strong) NSLock *lock;
// 供 UI 显示
@property (nonatomic, copy)   NSString *lastCode;
@property (nonatomic, strong) NSMutableDictionary *lastResult;
@property (nonatomic, copy)   NSString *peer;
@property (nonatomic, strong) NSMutableArray *observers;   // 支持多个观察者（面板 + 侧栏）
- (void)notify;
@end

@implementation RYAutorunServer

+ (RYAutorunServer *)shared {
    static RYAutorunServer *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RYAutorunServer alloc] init]; });
    return s;
}

- (id)init {
    self = [super init];
    if (self) {
        _listenFd = -1;
        _port = 0;
        _running = NO;
        _busy = NO;
        _jobSeq = 0;
        _logs = [NSMutableArray array];
        _jobs = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _lastCode = @"";
        _lastResult = [NSMutableDictionary dictionaryWithObject:@"idle" forKey:@"status"];
        _peer = @"";
        _observers = [NSMutableArray array];
    }
    return self;
}

- (void)notify {
    [self.lock lock];
    NSArray *snapshot = [self.observers copy];
    [self.lock unlock];
    if (snapshot.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^cb)(void) in snapshot) {
            cb();
        }
    });
}

- (void)logLine:(NSString *)s {
    if (s == nil) return;
    NSString *line = [NSString stringWithFormat:@"[%@] %@", ryStamp(), s];
    [self.lock lock];
    [self.logs addObject:line];
    if (self.logs.count > RY_MAX_LOG) {
        [self.logs removeObjectsInRange:NSMakeRange(0, self.logs.count - RY_MAX_LOG)];
    }
    [self.lock unlock];
    RYLogBlock lg = self.logger;
    if (lg) {
        dispatch_async(dispatch_get_main_queue(), ^{ lg(line); });
    }
    [self notify];
}

- (NSString *)start:(int)port eval:(RYEvalBlock)eval logger:(RYLogBlock)logger {
    if (eval) self.evalBlock = eval;
    if (logger) self.logger = logger;
    if (self.running) {
        return [NSString stringWithFormat:@"OK:already-running:%d", self.port];
    }
    if (port <= 0) port = RY_DEFAULT_PORT;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return [NSString stringWithFormat:@"ERROR:socket:%s", strerror(errno)];

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSString *e = [NSString stringWithFormat:@"ERROR:bind:%s (port %d 可能被占用)", strerror(errno), port];
        close(fd);
        return e;
    }
    if (listen(fd, 8) != 0) {
        NSString *e = [NSString stringWithFormat:@"ERROR:listen:%s", strerror(errno)];
        close(fd);
        return e;
    }

    self.listenFd = fd;
    self.port = port;
    self.running = YES;

    [self logLine:[NSString stringWithFormat:@"Autorun 已启动 · 端口 %d · 本机 %@，电脑端连 http://%@:%d/ping",
                   port, ryLANAddress(), ryLANAddress(), port]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self acceptLoop];
    });

    return [NSString stringWithFormat:@"OK:listening:%d", port];
}

- (NSString *)stop {
    if (!self.running) return @"OK:not-running";
    self.running = NO;
    if (self.listenFd >= 0) {
        shutdown(self.listenFd, SHUT_RDWR);
        close(self.listenFd);
        self.listenFd = -1;
    }
    [self logLine:@"Autorun 已停止"];
    return @"OK:stopped";
}

- (void)acceptLoop {
    while (self.running) {
        int lfd = self.listenFd;
        if (lfd < 0) break;
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(lfd, &rfds);
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        int sel = select(lfd + 1, &rfds, NULL, NULL, &tv);
        if (!self.running) break;
        if (sel <= 0) continue;

        struct sockaddr_in cli;
        socklen_t clilen = sizeof(cli);
        int cfd = accept(lfd, (struct sockaddr *)&cli, &clilen);
        if (cfd < 0) continue;

        char ipbuf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &cli.sin_addr, ipbuf, sizeof(ipbuf));
        [self handleConnection:cfd fromIP:[NSString stringWithUTF8String:ipbuf]];
        close(cfd);
    }
}

// ---- HTTP 最小解析 ----

- (BOOL)bufferComplete:(NSData *)buf {
    NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    if (s == nil) return NO;
    NSRange r = [s rangeOfString:@"\r\n\r\n"];
    if (r.location == NSNotFound) return NO;
    NSUInteger bodyStart = r.location + r.length;
    NSUInteger cl = 0;
    NSArray *lines = [[s substringToIndex:r.location] componentsSeparatedByString:@"\r\n"];
    for (NSString *ln in lines) {
        NSString *low = [ln lowercaseString];
        if ([low hasPrefix:@"content-length:"]) {
            cl = (NSUInteger)[[[ln substringFromIndex:15] stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]] integerValue];
        }
    }
    NSUInteger have = s.length - bodyStart;   // 近似（ASCII 头 + UTF-8 体）
    return have >= cl;
}

- (void)handleConnection:(int)cfd fromIP:(NSString *)ip {
    struct timeval rtv;
    rtv.tv_sec = 5;
    rtv.tv_usec = 0;
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));

    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    while (1) {
        ssize_t n = recv(cfd, tmp, sizeof(tmp), 0);
        if (n > 0) {
            [buf appendBytes:tmp length:(NSUInteger)n];
            if ([self bufferComplete:buf]) break;
            if (buf.length > 4 * 1024 * 1024) break;   // 保险
            continue;
        }
        break;
    }

    NSString *raw = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    if (raw == nil || raw.length == 0) {
        rySendAll(cfd, ryHttpResponse(400, @"{\"ok\":false,\"error\":\"empty request\"}"));
        return;
    }

    NSRange hr = [raw rangeOfString:@"\r\n\r\n"];
    NSString *head = (hr.location == NSNotFound) ? raw : [raw substringToIndex:hr.location];
    NSString *body = (hr.location == NSNotFound) ? @"" : [raw substringFromIndex:(hr.location + hr.length)];

    NSArray *headLines = [head componentsSeparatedByString:@"\r\n"];
    NSString *reqLine = headLines.count > 0 ? headLines[0] : @"";
    NSArray *parts = [reqLine componentsSeparatedByString:@" "];
    NSString *method = parts.count > 0 ? parts[0] : @"";
    NSString *path = parts.count > 1 ? parts[1] : @"/";

    NSString *route = path;
    NSString *query = @"";
    NSRange qr = [path rangeOfString:@"?"];
    if (qr.location != NSNotFound) {
        route = [path substringToIndex:qr.location];
        query = [path substringFromIndex:(qr.location + 1)];
    }

    NSDictionary *inJSON = nil;
    if (body.length > 0) {
        NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
        id o = [NSJSONSerialization JSONObjectWithData:bd options:0 error:NULL];
        if ([o isKindOfClass:[NSDictionary class]]) inJSON = (NSDictionary *)o;
    }

    [self logLine:[NSString stringWithFormat:@"%@ %@  <- %@", method, route, ip]];
    self.peer = [NSString stringWithFormat:@"%@ · %@", ip, ryStamp()];

    // ---- 路由 ----
    if ([route isEqualToString:@"/ping"]) {
        rySendAll(cfd, ryHttpResponse(200, [self statusJSON]));
        return;
    }

    if ([route isEqualToString:@"/result"]) {
        NSString *jid = nil;
        for (NSString *kv in [query componentsSeparatedByString:@"&"]) {
            if ([kv hasPrefix:@"id="]) jid = [kv substringFromIndex:3];
        }
        if (jid == nil) {
            rySendAll(cfd, ryHttpResponse(400, @"{\"ok\":false,\"error\":\"missing id\"}"));
            return;
        }
        [self.lock lock];
        NSDictionary *job = self.jobs[jid];
        [self.lock unlock];
        if (job == nil) {
            rySendAll(cfd, ryHttpResponse(404, @"{\"ok\":false,\"error\":\"unknown job\"}"));
            return;
        }
        rySendAll(cfd, ryHttpResponse(200, [self jsonFrom:job]));
        return;
    }

    if ([route isEqualToString:@"/submit"] || [route isEqualToString:@"/eval"]) {
        NSString *code = inJSON[@"code"];
        if (code == nil) code = body;   // 容错：直接把 body 当代码
        if (code == nil || code.length == 0) {
            rySendAll(cfd, ryHttpResponse(400, @"{\"ok\":false,\"error\":\"missing code\"}"));
            return;
        }
        int timeoutMs = RY_DEFAULT_TIMEOUT;
        id t = inJSON[@"timeoutMs"];
        if ([t respondsToSelector:@selector(intValue)]) timeoutMs = [t intValue];

        // 记录"本轮在跑什么"——UI 要显示收到的代码与回传状态
        self.lastCode = code;
        [self.lastResult setObject:@"running" forKey:@"status"];
        [self.lastResult removeObjectForKey:@"ok"];
        [self.lastResult removeObjectForKey:@"output"];
        [self.lastResult removeObjectForKey:@"result"];
        [self.lastResult removeObjectForKey:@"error"];
        [self.lastResult removeObjectForKey:@"ms"];
        [self notify];

        if ([route isEqualToString:@"/eval"]) {
            NSDictionary *res = [self executeCode:code timeoutMs:timeoutMs];
            [self.lastResult setObject:@"done" forKey:@"status"];
            [self.lastResult addEntriesFromDictionary:res];
            rySendAll(cfd, ryHttpResponse(200, [self jsonFrom:res]));
            return;
        }

        // /submit —— 异步
        [self.lock lock];
        self.jobSeq = self.jobSeq + 1;
        NSString *jid = [NSString stringWithFormat:@"j%d", self.jobSeq];
        NSMutableDictionary *job = [NSMutableDictionary dictionary];
        job[@"id"] = jid;
        job[@"status"] = @"running";
        job[@"codeLen"] = @(code.length);
        self.jobs[jid] = job;
        if (self.jobs.count > RY_MAX_JOBS) {
            NSArray *keys = [self.jobs allKeys];
            for (NSUInteger i = 0; i + RY_MAX_JOBS < keys.count; i++) {
                [self.jobs removeObjectForKey:keys[i]];
            }
        }
        [self.lock unlock];

        NSString *accepted = [NSString stringWithFormat:
            @"{\"ok\":true,\"id\":\"%@\",\"status\":\"accepted\",\"pollIntervalMs\":3000,\"maxPolls\":12}", jid];
        rySendAll(cfd, ryHttpResponse(200, accepted));

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSDictionary *res = [self executeCode:code timeoutMs:timeoutMs];
            [self.lock lock];
            NSMutableDictionary *j = self.jobs[jid];
            if (j) {
                [j addEntriesFromDictionary:res];
                j[@"status"] = @"done";
            }
            [self.lock unlock];
            [self.lastResult setObject:@"done" forKey:@"status"];
            [self.lastResult addEntriesFromDictionary:res];
            [self notify];
            [self logLine:[NSString stringWithFormat:@"任务 %@ 完成（%@）", jid,
                           [res[@"ok"] boolValue] ? @"ok" : @"失败"]];
        });
        return;
    }

    rySendAll(cfd, ryHttpResponse(404, @"{\"ok\":false,\"error\":\"no such route\"}"));
}

// ---- 执行 ----

- (NSDictionary *)executeCode:(NSString *)code timeoutMs:(int)timeoutMs {
    RYEvalBlock eb = self.evalBlock;
    NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];
    (void)timeoutMs;   // 保留参数以兼容 JSON 协议；执行耗时由 main.m 侧控制

    if (eb == nil) {
        return @{@"ok": @NO, @"error": @"执行器未注册：请确认 main.m 已调用 RYAutorunSetEval",
                 @"output": @"", @"result": [NSNull null], @"ms": @0};
    }

    // 注意：main.m 的 JS 执行器内部会「新建独立 JSContext + 在当前线程执行」
    // （与 RunCode 同样的模式），所以这里直接调用即可，不需要绕主线程。
    NSString *raw = nil;
    NSString *thrown = nil;
    self.busy = YES;
    @try {
        raw = eb(code ? code : @"");
    } @catch (NSException *e) {
        thrown = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    self.busy = NO;

    int ms = (int)(([[NSDate date] timeIntervalSince1970] - t0) * 1000.0);

    if (thrown) {
        return @{@"ok": @NO, @"error": thrown, @"output": @"",
                 @"result": [NSNull null], @"ms": @(ms)};
    }

    NSDictionary *parsed = nil;
    if (raw.length > 0) {
        id o = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:NULL];
        if ([o isKindOfClass:[NSDictionary class]]) parsed = (NSDictionary *)o;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"ms"] = @(ms);
    if (parsed) {
        out[@"output"] = parsed[@"output"] ?: @"";
        out[@"result"] = parsed[@"result"] ?: [NSNull null];
        out[@"error"] = parsed[@"error"] ?: [NSNull null];
        out[@"printCaptured"] = parsed[@"overrideOk"] ?: @NO;
        out[@"ok"] = (parsed[@"error"] == nil || parsed[@"error"] == [NSNull null]) ? @YES : @NO;
    } else {
        out[@"output"] = @"";
        out[@"result"] = raw ? raw : [NSNull null];
        out[@"error"] = [NSNull null];
        out[@"ok"] = @YES;
    }
    return out;
}

// ---- 序列化 ----

- (NSString *)jsonFrom:(NSDictionary *)d {
    if (d == nil) return @"{}";
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:NULL];
    if (data == nil) return @"{}";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ? s : @"{}";
}

- (NSString *)statusJSON {
    NSDictionary *d = @{
        @"ok": @YES,
        @"name": @"RyConsole-Autorun",
        @"version": @"1.0",
        @"running": @(self.running),
        @"port": @(self.port),
        @"lanIP": ryLANAddress(),
        @"busy": @(self.busy),
        @"jobs": @(self.jobs.count)
    };
    return [self jsonFrom:d];
}

@end

#pragma mark - Autorun 面板

@interface RYAutorunVC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *portField;
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UILabel *hintLabel;
@end

@implementation RYAutorunVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Autorun";
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
    }

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onClose)];

    self.portField = [[UITextField alloc] initWithFrame:CGRectMake(16, 96, 110, 36)];
    self.portField.borderStyle = UITextBorderStyleRoundedRect;
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    self.portField.placeholder = @"端口";
    self.portField.text = [NSString stringWithFormat:@"%d", RY_DEFAULT_PORT];
    self.portField.delegate = self;
    self.portField.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.view addSubview:self.portField];

    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleBtn.frame = CGRectMake(140, 96, 120, 36);
    [self.toggleBtn addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.toggleBtn];

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 140, self.view.bounds.size.width - 32, 40)];
    self.hintLabel.numberOfLines = 2;
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.hintLabel];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(16, 188, self.view.bounds.size.width - 32, 200)];
    self.logView.editable = NO;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10];
    if (@available(iOS 13.0, *)) {
        self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    } else {
        self.logView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    }
    [self.view addSubview:self.logView];

    [self refreshUI];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    self.hintLabel.frame = CGRectMake(16, 140, w - 32, 40);
    self.logView.frame = CGRectMake(16, 188, w - 32, h - 188 - 24);
    if (self.logView.text.length > 0) {
        NSRange bottom = NSMakeRange(self.logView.text.length - 1, 1);
        [self.logView scrollRangeToVisible:bottom];
    }
}

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *cur = self.logView.text ? self.logView.text : @"";
        self.logView.text = [cur stringByAppendingFormat:@"%@\n", line];
        NSRange bottom = NSMakeRange(self.logView.text.length - 1, 1);
        [self.logView scrollRangeToVisible:bottom];
    });
}

- (void)refreshUI {
    RYAutorunServer *s = [RYAutorunServer shared];
    [self.toggleBtn setTitle:(s.running ? @"停止" : @"启动") forState:UIControlStateNormal];
    self.hintLabel.text = [NSString stringWithFormat:
        @"%@\n电脑端连：http://%@:%d/ping",
        s.running ? @"● 正在监听（App 需保持前台）" : @"○ 未启动",
        ryLANAddress(), s.running ? s.port : RY_DEFAULT_PORT];
}

- (void)onToggle {
    RYAutorunServer *s = [RYAutorunServer shared];
    if (s.running) {
        NSString *r = [s stop];
        [self appendLog:r];
    } else {
        int p = [self.portField.text intValue];
        __weak RYAutorunVC *weakSelf = self;
        NSString *r = [s start:(p > 0 ? p : RY_DEFAULT_PORT)
                          eval:nil
                        logger:^(NSString *line) { [weakSelf appendLog:line]; }];
        [self appendLog:r];
    }
    // 把历史日志补进来
    RYAutorunServer *ss = [RYAutorunServer shared];
    [ss.lock lock];
    NSArray *snapshot = [ss.logs copy];
    [ss.lock unlock];
    self.logView.text = snapshot.count > 0 ? [[snapshot componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";
    [self refreshUI];
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

#pragma mark - C 接口

NSString *RYAutorunStart(int port, RYEvalBlock eval, RYLogBlock logger) {
    return [[RYAutorunServer shared] start:port eval:eval logger:logger];
}

NSString *RYAutorunStop(void) {
    return [[RYAutorunServer shared] stop];
}

NSString *RYAutorunStatus(void) {
    return [[RYAutorunServer shared] statusJSON];
}

NSString *RYAutorunLogText(void) {
    RYAutorunServer *s = [RYAutorunServer shared];
    [s.lock lock];
    NSString *txt = [[s.logs copy] componentsJoinedByString:@"\n"];
    [s.lock unlock];
    return txt ? txt : @"";
}

NSString *RYAutorunLastCode(void) {
    return [RYAutorunServer shared].lastCode ?: @"";
}

NSString *RYAutorunLastResultJSON(void) {
    RYAutorunServer *s = [RYAutorunServer shared];
    [s.lock lock];
    NSDictionary *d = [s.lastResult copy];
    [s.lock unlock];
    return [s jsonFrom:(d ? d : @{})];
}

NSString *RYAutorunPeer(void) {
    return [RYAutorunServer shared].peer ?: @"";
}

void RYAutorunObserve(void (^cb)(void)) {
    RYAutorunServer *s = [RYAutorunServer shared];
    [s.lock lock];
    if (cb == nil) {
        [s.observers removeAllObjects];
    } else {
        [s.observers addObject:[cb copy]];
    }
    [s.lock unlock];
}

void RYAutorunClear(void) {
    RYAutorunServer *s = [RYAutorunServer shared];
    [s.lock lock];
    [s.logs removeAllObjects];
    [s.jobs removeAllObjects];
    [s.lock unlock];
    s.lastCode = @"";
    [s.lastResult removeAllObjects];
    [s.lastResult setObject:@"idle" forKey:@"status"];
    s.peer = @"";
    [s notify];
}

void RYAutorunSetEval(RYEvalBlock eval) {
    [RYAutorunServer shared].evalBlock = eval;
}

NSString *RYAutorunOpenPanel(void) {
    UIViewController *top = ryTopVC();
    if (top == nil) return @"ERROR:no key window";
    RYAutorunVC *vc = [[RYAutorunVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
    return @"OK";
}
