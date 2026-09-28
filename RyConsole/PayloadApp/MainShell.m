//
//  MainShell.m
//  RyConsole —— 新外壳实现（深色科技风；左侧栏三板块）
//
//  终端   ：输入 JS → 流式执行（与 Autorun 共用 RYExecStream 这条执行路径）
//  Autorun：显示端口监听状态 / 来源 / 收到的代码 / 输出结果 / 回传状态
//  设置   ：端口、超时、清空日志、免责声明、经典界面入口
//

#import "MainShell.h"
#import "RySecurityPane.h"
#import "AutorunServer.h"
#import "RYPermLog.h"        // V2.4.17：复制地址弹窗要用分类端点 RYNetworkEndpointsJSON
#import "RyExec.h"
#import "RyShellBridge.h"
#import <stdlib.h>
#import <math.h>

// build61：远程连接查询函数原型（main.m 导出，供本文件调用；与 RYAutorunRunning 同机制）
NSString *RYRemoteLastCode(void);
BOOL RYRemoteIsActive(void);

// 取当前可 present 的顶层 VC（文件级，供各个 Pane 共用）
static UIViewController *RYTopVCForPresent(void) {
    UIWindow *key = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) { if (w.isKeyWindow) { key = w; break; } }
        if (key) break;
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - 配色（GitHub dark 风格）

#define RY_BG      [UIColor colorWithRed:0.051f green:0.067f blue:0.090f alpha:1.0f]  // #0d1117
#define RY_PANEL   [UIColor colorWithRed:0.086f green:0.106f blue:0.133f alpha:1.0f]  // #161b22
#define RY_PANEL2  [UIColor colorWithRed:0.055f green:0.071f blue:0.094f alpha:1.0f]  // #0e1318
#define RY_BORDER  [UIColor colorWithRed:0.188f green:0.212f blue:0.239f alpha:1.0f]  // #30363d
#define RY_TEXT    [UIColor colorWithRed:0.788f green:0.820f blue:0.851f alpha:1.0f]  // #c9d1d9
#define RY_MUTED   [UIColor colorWithRed:0.545f green:0.580f blue:0.620f alpha:1.0f]  // #8b949e
#define RY_ACCENT  [UIColor colorWithRed:0.184f green:0.506f blue:0.969f alpha:1.0f]  // #2f81f7
#define RY_GREEN   [UIColor colorWithRed:0.247f green:0.725f blue:0.314f alpha:1.0f]  // #3fb950
#define RY_RED     [UIColor colorWithRed:0.973f green:0.318f blue:0.286f alpha:1.0f]  // #f85149
#define RY_AMBER   [UIColor colorWithRed:0.824f green:0.600f blue:0.133f alpha:1.0f]  // #d29922

static const CGFloat kSidebarW = 168.0f;
static const CGFloat kSidebarCompactW = 58.0f;   // iPhone/紧凑宽度（<500pt）：纯图标侧栏
static const CGFloat kPad      = 12.0f;

#pragma mark - 小工具

static UIFont *ryMono(CGFloat s) {
    UIFont *f = [UIFont fontWithName:@"Menlo" size:s];
    if (f) return f;
    return [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightRegular];
}

static UIFont *ryUI(CGFloat s, UIFontWeight w) {
    return [UIFont systemFontOfSize:s weight:w];
}

static UILabel *ryLabel(NSString *text, CGFloat size, UIColor *color, BOOL mono) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = mono ? ryMono(size) : ryUI(size, UIFontWeightRegular);
    l.textColor = color;
    l.numberOfLines = 1;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

static UIView *ryPanel(UIView *parent) {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = RY_PANEL;
    v.layer.borderColor = RY_BORDER.CGColor;
    v.layer.borderWidth = 0.5f;
    v.layer.cornerRadius = 8.0f;
    v.clipsToBounds = YES;
    if (parent) [parent addSubview:v];
    return v;
}

static UIButton *ryButton(NSString *title, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.titleLabel.font = ryUI(13.0f, UIFontWeightMedium);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:RY_TEXT forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.06f];
    b.layer.cornerRadius = 6.0f;
    b.layer.borderColor = RY_BORDER.CGColor;
    b.layer.borderWidth = 0.5f;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UITextView *ryTextView(BOOL editable) {
    UITextView *tv = [[UITextView alloc] init];
    tv.backgroundColor = RY_PANEL2;
    tv.textColor = RY_TEXT;
    tv.font = ryMono(11.5f);
    tv.editable = editable;
    tv.selectable = YES;
    tv.textContainerInset = UIEdgeInsetsMake(8.0f, 8.0f, 8.0f, 8.0f);
    tv.layer.cornerRadius = 6.0f;
    tv.layer.borderColor = RY_BORDER.CGColor;
    tv.layer.borderWidth = 0.5f;
    tv.keyboardAppearance = UIKeyboardAppearanceDark;
    tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tv.spellCheckingType = UITextSpellCheckingTypeNo;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return tv;
}

static void ryScrollToBottom(UITextView *tv) {
    if (tv.text.length == 0) return;
    NSRange r = NSMakeRange(tv.text.length - 1, 1);
    [tv scrollRangeToVisible:r];
}

#pragma mark - 终端

@interface RYTerminalPane : UIView
@property (nonatomic, strong) UITextView *codeView;
@property (nonatomic, strong) UITextView *outView;
@property (nonatomic, strong) UILabel *stateLabel;
// 先声明再调用：ObjC 未先声明时 clang 会把参数当 id，
// ARC 下传 NSInteger/BOOL 等标量会直接 error（本文件已因此失败过一次）
- (void)append:(NSString *)line;
@end

@implementation RYTerminalPane

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = RY_BG;

        UILabel *h = ryLabel(@"终端", 15.0f, RY_TEXT, NO);
        h.font = ryUI(15.0f, UIFontWeightMedium);
        h.tag = 9001;
        [self addSubview:h];

        self.stateLabel = ryLabel(@"就绪", 11.0f, RY_MUTED, NO);
        self.stateLabel.tag = 9002;
        self.stateLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:self.stateLabel];

        UIView *codePanel = ryPanel(self);
        codePanel.tag = 9010;

        UILabel *cl = ryLabel(@"// 输入 JS（print 输出在下方）", 11.0f, RY_MUTED, YES);
        cl.tag = 9011;
        [codePanel addSubview:cl];

        self.codeView = ryTextView(YES);
        self.codeView.text = @"print(\"hello\");\nreturn JSON.stringify(autorunStatus());";
        self.codeView.tag = 9012;
        [codePanel addSubview:self.codeView];

        UIButton *runBtn = ryButton(@"执行", self, @selector(onRun));
        runBtn.tag = 9013;
        runBtn.backgroundColor = [UIColor colorWithRed:0.11f green:0.31f blue:0.60f alpha:1.0f];
        [codePanel addSubview:runBtn];

        UIButton *clrBtn = ryButton(@"清空", self, @selector(onClear));
        clrBtn.tag = 9014;
        [codePanel addSubview:clrBtn];

        UIView *outPanel = ryPanel(self);
        outPanel.tag = 9020;

        UILabel *ol = ryLabel(@"输出", 11.0f, RY_MUTED, YES);
        ol.tag = 9021;
        [outPanel addSubview:ol];

        self.outView = ryTextView(NO);
        self.outView.tag = 9022;
        [outPanel addSubview:self.outView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    [[self viewWithTag:9001] setFrame:CGRectMake(kPad, 10.0f, 120.0f, 20.0f)];
    [[self viewWithTag:9002] setFrame:CGRectMake(w - kPad - 180.0f, 12.0f, 180.0f, 16.0f)];

    CGFloat codeH = floorf(h * 0.36f);
    UIView *codePanel = [self viewWithTag:9010];
    codePanel.frame = CGRectMake(kPad, 36.0f, w - kPad * 2, codeH);

    [[codePanel viewWithTag:9011] setFrame:CGRectMake(10.0f, 6.0f, codePanel.bounds.size.width - 150.0f, 14.0f)];
    CGFloat btnW = 54.0f;
    [[codePanel viewWithTag:9013] setFrame:CGRectMake(codePanel.bounds.size.width - btnW * 2 - 18.0f, 5.0f, btnW, 24.0f)];
    [[codePanel viewWithTag:9014] setFrame:CGRectMake(codePanel.bounds.size.width - btnW - 10.0f, 5.0f, btnW, 24.0f)];
    [[codePanel viewWithTag:9012] setFrame:CGRectMake(8.0f, 24.0f, codePanel.bounds.size.width - 16.0f, codePanel.bounds.size.height - 32.0f)];

    CGFloat outY = 36.0f + codeH + 10.0f;
    UIView *outPanel = [self viewWithTag:9020];
    outPanel.frame = CGRectMake(kPad, outY, w - kPad * 2, h - outY - kPad);
    [[outPanel viewWithTag:9021] setFrame:CGRectMake(10.0f, 4.0f, 200.0f, 14.0f)];
    [[outPanel viewWithTag:9022] setFrame:CGRectMake(8.0f, 20.0f, outPanel.bounds.size.width - 16.0f, outPanel.bounds.size.height - 28.0f)];
}

- (void)append:(NSString *)line {
    NSString *cur = self.outView.text ? self.outView.text : @"";
    self.outView.text = [cur stringByAppendingFormat:@"%@\n", line ? line : @""];
    ryScrollToBottom(self.outView);
}

- (void)onClear {
    self.outView.text = @"";
    self.stateLabel.text = @"就绪";
    self.stateLabel.textColor = RY_MUTED;
}

- (void)onRun {
    NSString *code = self.codeView.text ?: @"";
    if (code.length == 0) return;
    [self.codeView resignFirstResponder];
    self.outView.text = @"";
    self.stateLabel.text = @"执行中…";
    self.stateLabel.textColor = RY_AMBER;

    __weak RYTerminalPane *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RYExecStream(code, ^(NSString *line) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf append:line]; });
        }, ^(NSString *result, NSString *error, double ms) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (result) [weakSelf append:[@"=> " stringByAppendingString:result]];
                if (error) [weakSelf append:[@"[错误] " stringByAppendingString:error]];
                [weakSelf append:[NSString stringWithFormat:@"--- 完成 %.0f ms ---", ms]];
                weakSelf.stateLabel.text = error ? @"有错误" : [NSString stringWithFormat:@"完成 %.0fms", ms];
                weakSelf.stateLabel.textColor = error ? RY_RED : RY_GREEN;
            });
        });
    });
}

@end

#pragma mark - Autorun

// ---- V2.4.24 远程连接分页（核心在 main.m rmt* 静态区，跨文件导出三个 C 函数）----
extern NSString *RYRemoteStart(NSString *url, NSString *token);
extern NSString *RYRemoteStop(void);
extern NSString *RYRemoteStatus(void);

@interface RYRemotePane : UIView
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextField *tokField;
@property (nonatomic, strong) UIButton *connBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *modeDot;       // build61：远程保活图标（☁️），区别于监听 ●
@property (nonatomic, strong) UITextView *codeView;   // build61：收到的代码（上半区）
@property (nonatomic, strong) UITextView *logView;    // 连接日志（下半区）
@property (nonatomic, strong) NSTimer *timer;
- (void)appendLog:(NSString *)line;
- (void)pollStatus;
- (void)doStartRemote;                                // build61：互斥确认后的真正启动
@end

@implementation RYRemotePane

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = RY_BG;

        UILabel *l1 = ryLabel(@"服务端地址", 11.0f, RY_MUTED, NO);
        l1.tag = 9200;
        [self addSubview:l1];

        self.urlField = [[UITextField alloc] init];
        self.urlField.tag = 9201;
        self.urlField.borderStyle = UITextBorderStyleRoundedRect;
        self.urlField.font = ryMono(11.0f);
        self.urlField.placeholder = @"https://xxxx.trycloudflare.com 或 http://192.168.x.x:8765";
        self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.urlField.keyboardType = UIKeyboardTypeURL;
        self.urlField.backgroundColor = RY_PANEL2;
        self.urlField.textColor = RY_TEXT;
        [self addSubview:self.urlField];

        UILabel *l2 = ryLabel(@"访问口令 token", 11.0f, RY_MUTED, NO);
        l2.tag = 9202;
        [self addSubview:l2];

        self.tokField = [[UITextField alloc] init];
        self.tokField.tag = 9203;
        self.tokField.borderStyle = UITextBorderStyleRoundedRect;
        self.tokField.font = ryMono(11.0f);
        self.tokField.placeholder = @"server config.json 里的 token";
        self.tokField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.tokField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.tokField.secureTextEntry = YES;
        self.tokField.backgroundColor = RY_PANEL2;
        self.tokField.textColor = RY_TEXT;
        [self addSubview:self.tokField];

        NSString *sa = [[NSUserDefaults standardUserDefaults] stringForKey:@"ryc_remote_addr"];
        NSString *st = [[NSUserDefaults standardUserDefaults] stringForKey:@"ryc_remote_token"];
        if (sa.length) self.urlField.text = sa;
        if (st.length) self.tokField.text = st;

        self.connBtn = ryButton(@"连接", self, @selector(onToggle));
        self.connBtn.tag = 9204;
        [self addSubview:self.connBtn];

        self.statusLabel = ryLabel(@"状态：未连接", 11.0f, RY_MUTED, YES);
        self.statusLabel.tag = 9205;
        [self addSubview:self.statusLabel];

        // build61：远程保活图标（☁️），与监听页 ● 区分
        self.modeDot = ryLabel(@"☁️", 13.0f, RY_MUTED, NO);
        self.modeDot.tag = 9206;
        [self addSubview:self.modeDot];

        // build61：收到的代码（上半区）
        UIView *codePanel = ryPanel(self);
        codePanel.tag = 9220;
        UILabel *cl = ryLabel(@"收到的代码", 11.0f, RY_MUTED, NO);
        cl.tag = 9221;
        [codePanel addSubview:cl];
        self.codeView = ryTextView(NO);
        self.codeView.tag = 9222;
        self.codeView.text = @"（等待 PC 端下发代码…）";
        [codePanel addSubview:self.codeView];

        UIView *logPanel = ryPanel(self);
        logPanel.tag = 9210;
        UILabel *ll = ryLabel(@"连接日志 / 执行输出", 11.0f, RY_MUTED, NO);
        ll.tag = 9211;
        [logPanel addSubview:ll];
        self.logView = ryTextView(NO);
        self.logView.tag = 9212;
        self.logView.text = @"iPad 主动出站连接电脑端 RyConsoleServer。\n地址每次重启服务可能变化（quick tunnel）。\n";
        [logPanel addSubview:self.logView];

        __weak RYRemotePane *weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            [weakSelf pollStatus];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    [[self viewWithTag:9200] setFrame:CGRectMake(10.0f, 6.0f, 140.0f, 14.0f)];
    [[self viewWithTag:9201] setFrame:CGRectMake(kPad, 22.0f, w - kPad * 2, 30.0f)];
    [[self viewWithTag:9202] setFrame:CGRectMake(10.0f, 58.0f, 140.0f, 14.0f)];
    [[self viewWithTag:9203] setFrame:CGRectMake(kPad, 74.0f, w - kPad * 2, 30.0f)];
    [[self viewWithTag:9204] setFrame:CGRectMake(kPad, 110.0f, 96.0f, 30.0f)];
    [[self viewWithTag:9206] setFrame:CGRectMake(kPad + 104.0f, 116.0f, 18.0f, 18.0f)];  // ☁️ 保活图标
    [[self viewWithTag:9205] setFrame:CGRectMake(kPad + 126.0f, 117.0f, w - kPad * 2 - 126.0f, 16.0f)];

    // build61：下方拆成上下两块 —— 上=收到的代码，下=连接日志
    CGFloat ly = 148.0f;
    CGFloat codeH = floorf((h - ly - kPad) * 0.40f);
    if (codeH < 80.0f) codeH = 80.0f;
    UIView *codePanel = [self viewWithTag:9220];
    codePanel.frame = CGRectMake(kPad, ly, w - kPad * 2, codeH);
    [[codePanel viewWithTag:9221] setFrame:CGRectMake(10.0f, 5.0f, 120.0f, 14.0f)];
    [[codePanel viewWithTag:9222] setFrame:CGRectMake(8.0f, 22.0f, codePanel.bounds.size.width - 16.0f, codePanel.bounds.size.height - 30.0f)];

    CGFloat ly2 = ly + codeH + 8.0f;
    UIView *logPanel = [self viewWithTag:9210];
    logPanel.frame = CGRectMake(kPad, ly2, w - kPad * 2, h - ly2 - kPad);
    [[logPanel viewWithTag:9211] setFrame:CGRectMake(10.0f, 5.0f, 120.0f, 14.0f)];
    [[logPanel viewWithTag:9212] setFrame:CGRectMake(8.0f, 22.0f, logPanel.bounds.size.width - 16.0f, logPanel.bounds.size.height - 30.0f)];
}

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_logView.text = [self->_logView.text stringByAppendingString:[line stringByAppendingString:@"\n"]];
        NSRange r = NSMakeRange(self->_logView.text.length, 0);
        [self->_logView scrollRangeToVisible:r];
    });
}

- (void)pollStatus {
    NSString *s = RYRemoteStatus();
    static NSString *last = nil;
    if (![s isEqualToString:last ?: @""]) {
        last = [s copy];
        [self appendLog:[NSString stringWithFormat:@"[status] %@", s]];
    }
    id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSString *state = [o isKindOfClass:[NSDictionary class]] ? (NSString *)((NSDictionary *)o[@"state"] ?: @"?") : @"?";
    NSString *lastErr = [o isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)o[@"lastError"] ?: @"") : @"";

    // V2.4.24 build57：按钮状态与真实状态强同步（自动断开后不再残留「断开」）
    NSString *want = [state isEqualToString:@"idle"] ? @"连接" : @"断开";
    if (![self.connBtn.currentTitle isEqualToString:want]) {
        [self.connBtn setTitle:want forState:UIControlStateNormal];
        [self appendLog:[NSString stringWithFormat:@"[local] 已自动断开（%@）", lastErr.length ? lastErr : state]];
    }

    if ([state isEqualToString:@"idle"]) {
        if (lastErr.length) {
            self.statusLabel.text = [NSString stringWithFormat:@"断开：%@", lastErr];
            self.statusLabel.textColor = RY_RED;
        } else {
            self.statusLabel.text = @"状态：未连接";
            self.statusLabel.textColor = RY_MUTED;
        }
        self.modeDot.textColor = RY_MUTED;
    } else if ([state isEqualToString:@"connected"]) {
        self.statusLabel.text = @"状态：已连接 ✓";
        self.statusLabel.textColor = RY_GREEN;
        self.modeDot.textColor = RY_GREEN;   // 远程保活图标亮绿
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"状态：%@…", state];
        self.statusLabel.textColor = RY_AMBER;
        self.modeDot.textColor = RY_AMBER;
    }

    // build61：收到的代码（PC 推来的 push_js）同步到上半区
    NSString *rc = RYRemoteLastCode();
    self.codeView.text = rc.length > 0 ? rc : @"（等待 PC 端下发代码…）";
}

- (void)onToggle {
    [self.urlField resignFirstResponder];
    [self.tokField resignFirstResponder];
    NSString *s = RYRemoteStatus();
    if (![s containsString:@"\"state\":\"idle\""]) {
        RYRemoteStop();
        [self.connBtn setTitle:@"连接" forState:UIControlStateNormal];
        [self appendLog:@"[local] 已断开"];
        return;
    }
    // build61：互斥 —— 监听与远程只能开一个；开远程前若监听在跑，提示并踢掉监听
    if (RYAutorunRunning()) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"监听与远程只能开一个"
            message:@"开启远程连接会停止当前「监听」，确定吗？" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"确定，断开监听" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *ac) {
                RYAutorunStop();
                [self doStartRemote];
            }]];
        [RYTopVCForPresent() presentViewController:a animated:YES completion:nil];
        return;
    }
    [self doStartRemote];
}

- (void)doStartRemote {
    NSString *addr = [self.urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *tok = [self.tokField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (addr.length == 0) { [self alert:@"请输入服务端地址"]; return; }
    if (tok.length == 0)  { [self alert:@"请输入访问口令 token"]; return; }
    [[NSUserDefaults standardUserDefaults] setObject:addr forKey:@"ryc_remote_addr"];
    [[NSUserDefaults standardUserDefaults] setObject:tok forKey:@"ryc_remote_token"];
    [self.connBtn setTitle:@"断开" forState:UIControlStateNormal];
    NSString *res = RYRemoteStart(addr, tok);
    [self appendLog:[NSString stringWithFormat:@"[local] %@", res]];
    [self appendLog:@"[local] 若 10 秒后状态仍非 connected，检查地址与 token（服务端日志会显示设备上线）"];
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [RYTopVCForPresent() presentViewController:a animated:YES completion:nil];
}

@end

@interface RYAutorunPane : UIView
@property (nonatomic, strong) UILabel *dot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *ipLabel;
@property (nonatomic, strong) UILabel *peerLabel;
@property (nonatomic, strong) UILabel *pill;
@property (nonatomic, strong) UITextView *codeView;
@property (nonatomic, strong) UITextView *outView;
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, strong) UISegmentedControl *seg;      // V2.4.24：监听 | 远程 分页
@property (nonatomic, strong) RYRemotePane *remotePane;
- (void)refresh;
- (void)copyPicked:(NSDictionary *)item;   // V2.4.17：弹窗选中后落到剪贴板
@end

@implementation RYAutorunPane

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = RY_BG;

        // ---- 状态条 ----
        UIView *strip = ryPanel(self);
        strip.tag = 9100;

        self.dot = ryLabel(@"●", 13.0f, RY_MUTED, NO);
        self.dot.tag = 9101;
        [strip addSubview:self.dot];

        self.statusLabel = ryLabel(@"未启动", 13.0f, RY_TEXT, NO);
        self.statusLabel.font = ryUI(13.0f, UIFontWeightMedium);
        self.statusLabel.tag = 9102;
        [strip addSubview:self.statusLabel];

        self.ipLabel = ryLabel(@"", 11.0f, RY_MUTED, YES);
        self.ipLabel.tag = 9103;
        [strip addSubview:self.ipLabel];

        self.pill = ryLabel(@"待命", 11.0f, RY_MUTED, NO);
        self.pill.tag = 9104;
        self.pill.textAlignment = NSTextAlignmentCenter;
        self.pill.layer.cornerRadius = 9.0f;
        self.pill.layer.borderWidth = 0.5f;
        self.pill.clipsToBounds = YES;
        [strip addSubview:self.pill];

        self.peerLabel = ryLabel(@"来源：—", 10.5f, RY_MUTED, YES);
        self.peerLabel.tag = 9105;
        [strip addSubview:self.peerLabel];

        // ---- 工具条 ----
        self.toggleBtn = ryButton(@"启动监听", self, @selector(onToggle));
        self.toggleBtn.tag = 9110;
        [self addSubview:self.toggleBtn];

        UIButton *clr = ryButton(@"清空", self, @selector(onClear));
        clr.tag = 9111;
        [self addSubview:clr];

        // V2.4.17：文案改「复制地址」（复制的是 http://… 且现在可选哪一条）
        UIButton *copy = ryButton(@"复制地址", self, @selector(onCopyIP));
        copy.tag = 9112;
        [self addSubview:copy];

        // ---- 代码面板 ----
        UIView *codePanel = ryPanel(self);
        codePanel.tag = 9120;
        UILabel *cl = ryLabel(@"收到的代码", 11.0f, RY_MUTED, NO);
        cl.tag = 9121;
        [codePanel addSubview:cl];
        UILabel *cpath = ryLabel(@"(电脑端 POST /submit 发来的原文)", 10.5f, RY_MUTED, YES);
        cpath.tag = 9122;
        cpath.textAlignment = NSTextAlignmentRight;
        [codePanel addSubview:cpath];
        self.codeView = ryTextView(NO);
        self.codeView.tag = 9123;
        self.codeView.text = @"（等待电脑端下发代码…）";
        [codePanel addSubview:self.codeView];

        // ---- 输出面板 ----
        UIView *outPanel = ryPanel(self);
        outPanel.tag = 9130;
        UILabel *ol = ryLabel(@"输出 / 结果", 11.0f, RY_MUTED, NO);
        ol.tag = 9131;
        [outPanel addSubview:ol];
        UILabel *ostat = ryLabel(@"", 10.5f, RY_MUTED, YES);
        ostat.tag = 9132;
        ostat.textAlignment = NSTextAlignmentRight;
        [outPanel addSubview:ostat];
        self.outView = ryTextView(NO);
        self.outView.tag = 9133;
        [outPanel addSubview:self.outView];

        // ---- V2.4.24：分页（监听 | 远程）—— 不加侧栏新栏目，Autorun 内部切页 ----
        self.seg = [[UISegmentedControl alloc] initWithItems:@[@"监听", @"远程"]];
        self.seg.translatesAutoresizingMaskIntoConstraints = NO;
        self.seg.selectedSegmentIndex = 0;
        [self.seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
        self.seg.selectedSegmentTintColor = RY_ACCENT;
        self.seg.backgroundColor = RY_PANEL;
        [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: RY_TEXT} forState:UIControlStateNormal];
        [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];
        [self addSubview:self.seg];

        self.remotePane = [[RYRemotePane alloc] init];
        self.remotePane.hidden = YES;
        [self addSubview:self.remotePane];

        __weak RYAutorunPane *weakSelf = self;
        RYAutorunObserve(^{ [weakSelf refresh]; });
        [self refresh];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    BOOL compact = (w < 500.0f);   // iPhone 竖屏 / 紧凑宽度

    // V2.4.24：顶部 seg 占一行，监听页整体下移；远程页覆盖 seg 以下区域
    self.seg.frame = CGRectMake(kPad, 10.0f, w - kPad * 2, 32.0f);
    CGFloat top = 10.0f + 32.0f + 8.0f;
    self.remotePane.frame = CGRectMake(kPad, top, w - kPad * 2, h - top - kPad);

    UIView *strip = [self viewWithTag:9100];
    strip.frame = CGRectMake(kPad, top, w - kPad * 2, 56.0f);
    CGFloat sw = strip.bounds.size.width;
    [self.dot setFrame:CGRectMake(12.0f, 8.0f, 14.0f, 18.0f)];
    [self.pill setFrame:CGRectMake(sw - 12.0f - 78.0f, 8.0f, 78.0f, 19.0f)];
    if (compact) {
        // 紧凑：状态 + 地址分两行；隐藏来源行；右侧信息标签放不下就藏
        [self.statusLabel setFrame:CGRectMake(28.0f, 9.0f, sw - 28.0f - 90.0f, 18.0f)];
        [self.ipLabel setFrame:CGRectMake(12.0f, 31.0f, sw - 24.0f, 15.0f)];
        [self.peerLabel setHidden:YES];
    } else {
        [self.statusLabel setFrame:CGRectMake(28.0f, 9.0f, 150.0f, 18.0f)];
        [self.ipLabel setFrame:CGRectMake(192.0f, 10.0f, sw - 192.0f - 96.0f, 16.0f)];
        [self.peerLabel setHidden:NO];
        [self.peerLabel setFrame:CGRectMake(12.0f, 31.0f, sw - 24.0f, 15.0f)];
    }

    CGFloat ty = top + 56.0f + 8.0f;
    [self.toggleBtn setFrame:CGRectMake(kPad, ty, 96.0f, 30.0f)];
    [[self viewWithTag:9111] setFrame:CGRectMake(kPad + 104.0f, ty, 60.0f, 30.0f)];
    [[self viewWithTag:9112] setFrame:CGRectMake(kPad + 172.0f, ty, 76.0f, 30.0f)];

    CGFloat cy = ty + 30.0f + 10.0f;
    CGFloat codeH = floorf((h - cy - kPad) * 0.42f);
    if (codeH < 90.0f) codeH = 90.0f;
    UIView *codePanel = [self viewWithTag:9120];
    codePanel.frame = CGRectMake(kPad, cy, w - kPad * 2, codeH);
    [[codePanel viewWithTag:9121] setFrame:CGRectMake(10.0f, 5.0f, 120.0f, 14.0f)];
    UIView *cpPath = [codePanel viewWithTag:9122];
    if (compact) {
        [cpPath setHidden:YES];
    } else {
        [cpPath setHidden:NO];
        [cpPath setFrame:CGRectMake(codePanel.bounds.size.width - 250.0f, 5.0f, 240.0f, 14.0f)];
    }
    [[codePanel viewWithTag:9123] setFrame:CGRectMake(8.0f, 22.0f, codePanel.bounds.size.width - 16.0f, codePanel.bounds.size.height - 30.0f)];

    CGFloat oy = cy + codeH + 10.0f;
    UIView *outPanel = [self viewWithTag:9130];
    outPanel.frame = CGRectMake(kPad, oy, w - kPad * 2, h - oy - kPad);
    [[outPanel viewWithTag:9131] setFrame:CGRectMake(10.0f, 5.0f, 140.0f, 14.0f)];
    UIView *outPath = [outPanel viewWithTag:9132];
    if (compact) {
        [outPath setHidden:YES];
    } else {
        [outPath setHidden:NO];
        [outPath setFrame:CGRectMake(outPanel.bounds.size.width - 250.0f, 5.0f, 240.0f, 14.0f)];
    }
    [[outPanel viewWithTag:9133] setFrame:CGRectMake(8.0f, 22.0f, outPanel.bounds.size.width - 16.0f, outPanel.bounds.size.height - 30.0f)];
}

- (void)segChanged {
    BOOL remote = (self.seg.selectedSegmentIndex == 1);
    self.remotePane.hidden = !remote;
    for (NSInteger t = 9100; t <= 9133; t++) {     // 监听页全部子视图（含面板内子项）
        UIView *v = [self viewWithTag:t];
        if (v) v.hidden = remote;
    }
}

- (void)refresh {
    NSString *st = RYAutorunStatus();
    NSDictionary *sd = nil;
    id o = [NSJSONSerialization JSONObjectWithData:[st dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0 error:NULL];
    if ([o isKindOfClass:[NSDictionary class]]) sd = (NSDictionary *)o;

    BOOL running = [sd[@"running"] boolValue];
    NSNumber *port = sd[@"port"];
    NSString *ip = sd[@"lanIP"] ?: @"?";

    self.dot.textColor = running ? RY_GREEN : RY_MUTED;
    self.statusLabel.text = running
        ? [NSString stringWithFormat:@"监听中 :%d", [port intValue]]
        : @"未启动";
    self.statusLabel.textColor = running ? RY_GREEN : RY_MUTED;
    // 只在**真正监听中**才显示可用地址；否则给明确提示。
    // （曾经无条件显示 http://ip:8899，导致用户复制到一个"还没生效"的地址去连 → 端口拒绝）
    if (running) {
        self.ipLabel.text = [NSString stringWithFormat:@"http://%@:%d", ip, [port intValue]];
        self.ipLabel.textColor = RY_ACCENT;
    } else {
        self.ipLabel.text = @"未监听 · 点「启动监听」后地址才可用";
        self.ipLabel.textColor = RY_AMBER;
    }
    [self.toggleBtn setTitle:(running ? @"停止监听" : @"启动监听") forState:UIControlStateNormal];

    NSString *peer = RYAutorunPeer();
    self.peerLabel.text = peer.length > 0 ? [@"来源：" stringByAppendingString:peer] : @"来源：—";

    // ---- 回传状态 pill ----
    NSDictionary *rd = nil;
    id o2 = [NSJSONSerialization JSONObjectWithData:[RYAutorunLastResultJSON() dataUsingEncoding:NSUTF8StringEncoding]
                                            options:0 error:NULL];
    if ([o2 isKindOfClass:[NSDictionary class]]) rd = (NSDictionary *)o2;
    NSString *phase = rd[@"status"] ?: @"idle";
    BOOL ok = [rd[@"ok"] boolValue];
    if ([phase isEqualToString:@"running"]) {
        self.pill.text = @"执行中";
        self.pill.textColor = RY_AMBER;
        self.pill.layer.borderColor = RY_AMBER.CGColor;
    } else if ([phase isEqualToString:@"done"]) {
        self.pill.text = ok ? @"已回传" : @"回传失败";
        self.pill.textColor = ok ? RY_GREEN : RY_RED;
        self.pill.layer.borderColor = (ok ? RY_GREEN : RY_RED).CGColor;
    } else {
        self.pill.text = @"待命";
        self.pill.textColor = RY_MUTED;
        self.pill.layer.borderColor = RY_BORDER.CGColor;
    }

    // ---- 代码 ----
    NSString *code = RYAutorunLastCode();
    self.codeView.text = code.length > 0 ? code : @"（等待电脑端下发代码…）";

    // ---- 输出 ----
    NSMutableString *s = [NSMutableString string];
    if (rd[@"ms"]) [s appendFormat:@"耗时 %@ ms\n", rd[@"ms"]];
    if (rd[@"output"] && ![rd[@"output"] isKindOfClass:[NSNull class]]) {
        [s appendFormat:@"--- print ---\n%@\n", rd[@"output"]];
    }
    if (rd[@"result"] && ![rd[@"result"] isKindOfClass:[NSNull class]]) {
        [s appendFormat:@"--- return ---\n%@\n", rd[@"result"]];
    }
    if (rd[@"error"] && ![rd[@"error"] isKindOfClass:[NSNull class]]) {
        [s appendFormat:@"--- error ---\n%@\n", rd[@"error"]];
    }
    NSString *log = RYAutorunLogText();
    if (log.length > 0) [s appendFormat:@"\n[事件日志]\n%@\n", log];
    self.outView.text = s.length > 0 ? s : @"（暂无）";
    [(UILabel *)[self viewWithTag:9132] setText:phase];

    // ---- 工具条 ----
    [(UIButton *)[self viewWithTag:9111] setEnabled:YES];
    [(UIButton *)[self viewWithTag:9112] setEnabled:running];
}

- (void)onToggle {
    NSInteger port = [[NSUserDefaults standardUserDefaults] integerForKey:@"ryc_port"];
    if (port <= 0) port = 8899;
    NSDictionary *sd = nil;
    id o = [NSJSONSerialization JSONObjectWithData:[RYAutorunStatus() dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0 error:NULL];
    if ([o isKindOfClass:[NSDictionary class]]) sd = (NSDictionary *)o;
    if ([sd[@"running"] boolValue]) {
        RYAutorunStop();
    } else {
        // build61：互斥 —— 启动监听会断开远程；若远程已连，提示并踢掉远程
        if (RYRemoteIsActive()) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"监听与远程只能开一个"
                message:@"启动监听会断开当前「远程连接」，确定吗？" preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:@"确定，断开远程" style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *ac) {
                    RYRemoteStop();
                    RYAutorunStart((int)port, nil, nil);
                    [self refresh];
                }]];
            [RYTopVCForPresent() presentViewController:a animated:YES completion:nil];
            return;
        }
        RYAutorunStart((int)port, nil, nil);
    }
    [self refresh];
}

- (void)onClear {
    RYAutorunClear();
    [self refresh];
}

// V2.4.17：弹窗让你选要复制哪条地址（Wi-Fi / 个人热点 / 蜂窝各一条，电脑在哪个网就选哪条）。
//   旧版只复制主地址一个，电脑若连的是热点就会复制到对不上的那条。
- (void)onCopyIP {
    NSDictionary *sd = nil;
    id o = [NSJSONSerialization JSONObjectWithData:[RYAutorunStatus() dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0 error:NULL];
    if ([o isKindOfClass:[NSDictionary class]]) sd = (NSDictionary *)o;
    if (![sd[@"running"] boolValue]) {
        // 没在监听就不给地址：否则用户会拿一个连不上的 URL 到处试
        self.ipLabel.text = @"还没启动监听，地址不可用";
        self.ipLabel.textColor = RY_AMBER;
        return;
    }
    NSInteger port = [sd[@"port"] integerValue];
    if (port <= 0) port = 8899;

    // 分类端点（wifi / hotspot / cellular，没有的那一类不出现）
    id ne = [NSJSONSerialization JSONObjectWithData:[RYNetworkEndpointsJSON() dataUsingEncoding:NSUTF8StringEncoding]
                                           options:0 error:NULL];
    NSDictionary *net = [ne isKindOfClass:[NSDictionary class]] ? (NSDictionary *)ne : @{};
    NSArray *order = @[@"wifi", @"hotspot", @"cellular"];
    NSMutableArray *items = [NSMutableArray array];   // @{@"label":…, @"url":…}
    for (NSString *k in order) {
        NSDictionary *e = net[k];
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *label = [k isEqualToString:@"wifi"]    ? @"Wi-Fi"
                        : [k isEqualToString:@"hotspot"] ? @"个人热点"
                        : @"蜂窝移动数据";
        [items addObject:@{@"label": label,
                           @"url": [NSString stringWithFormat:@"http://%@:%d", e[@"ip"], (int)port]}];
    }
    // 兜底：分类端点拿不到时仍给主地址
    if (!items.count) {
        [items addObject:@{@"label": @"主地址",
                           @"url": [NSString stringWithFormat:@"http://%@:%d", sd[@"lanIP"] ?: @"?", (int)port]}];
    }
    // 只有一条 → 不用弹，直接复制（少点一步）
    if (items.count == 1) { [self copyPicked:items[0]]; return; }

    UIViewController *top = RYTopVCForPresent();
    if (!top) { [self copyPicked:items[0]]; return; }   // 取不到 VC 就退回复制主地址

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"复制哪个地址？"
                                                               message:@"电脑在哪个网，就选哪一条"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *it in items) {
        UIAlertAction *a = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@  %@", it[@"label"], it[@"url"]]
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *_) { [self copyPicked:it]; }];
        [ac addAction:a];
    }
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [ac addAction:cancel];

    // iPad 必须给 popover 锚点，否则直接崩
    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        UIView *anchor = [self viewWithTag:9112];       // 「复制地址」按钮
        pop.sourceView = anchor ?: self;
        pop.sourceRect = anchor ? anchor.bounds : self.bounds;
        pop.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)copyPicked:(NSDictionary *)item {
    NSString *url = item[@"url"] ?: @"";
    [UIPasteboard generalPasteboard].string = url;
    self.ipLabel.text = [NSString stringWithFormat:@"已复制 %@：%@", item[@"label"] ?: @"地址", url];
    self.ipLabel.textColor = RY_GREEN;
}

@end

#pragma mark - 设置

@interface RYSettingsPane : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *portField;
@property (nonatomic, strong) UITextField *timeoutField;
- (UIViewController *)ry_topVC;
@end

@implementation RYSettingsPane

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = RY_BG;

        UILabel *h = ryLabel(@"设置", 15.0f, RY_TEXT, NO);
        h.font = ryUI(15.0f, UIFontWeightMedium);
        h.frame = CGRectMake(kPad, 10.0f, 120.0f, 20.0f);
        [self addSubview:h];

        UIView *p1 = ryPanel(self);
        p1.tag = 9200;
        UILabel *l1 = ryLabel(@"Autorun 端口", 12.0f, RY_TEXT, NO);
        l1.tag = 9201;
        [p1 addSubview:l1];
        self.portField = [[UITextField alloc] init];
        self.portField.keyboardType = UIKeyboardTypeNumberPad;
        self.portField.font = ryMono(13.0f);
        self.portField.textColor = RY_TEXT;
        self.portField.backgroundColor = RY_PANEL2;
        self.portField.layer.borderColor = RY_BORDER.CGColor;
        self.portField.layer.borderWidth = 0.5f;
        self.portField.layer.cornerRadius = 6.0f;
        self.portField.textAlignment = NSTextAlignmentCenter;
        NSInteger savedPort = [[NSUserDefaults standardUserDefaults] integerForKey:@"ryc_port"];
        self.portField.text = [NSString stringWithFormat:@"%d", savedPort > 0 ? (int)savedPort : 8899];
        self.portField.tag = 9202;
        [p1 addSubview:self.portField];

        UILabel *l11 = ryLabel(@"默认执行超时 (ms)", 12.0f, RY_TEXT, NO);
        l11.tag = 9203;
        [p1 addSubview:l11];
        self.timeoutField = [[UITextField alloc] init];
        self.timeoutField.keyboardType = UIKeyboardTypeNumberPad;
        self.timeoutField.font = ryMono(13.0f);
        self.timeoutField.textColor = RY_TEXT;
        self.timeoutField.backgroundColor = RY_PANEL2;
        self.timeoutField.layer.borderColor = RY_BORDER.CGColor;
        self.timeoutField.layer.borderWidth = 0.5f;
        self.timeoutField.layer.cornerRadius = 6.0f;
        self.timeoutField.textAlignment = NSTextAlignmentCenter;
        NSInteger savedTo = [[NSUserDefaults standardUserDefaults] integerForKey:@"ryc_timeout_ms"];
        self.timeoutField.text = [NSString stringWithFormat:@"%d", savedTo > 0 ? (int)savedTo : 15000];
        self.timeoutField.tag = 9204;
        [p1 addSubview:self.timeoutField];

        UILabel *hint = ryLabel(@"改完点「保存」；端口改动需重启监听生效", 10.5f, RY_MUTED, NO);
        hint.tag = 9205;
        [p1 addSubview:hint];

        UIButton *save = ryButton(@"保存", self, @selector(onSave));
        save.tag = 9210;
        [self addSubview:save];

        UIButton *clear = ryButton(@"清空 Autorun 日志", self, @selector(onClearLog));
        clear.tag = 9211;
        clear.tag = 9211;
        [self addSubview:clear];

        UIButton *disc = ryButton(@"免责声明 / 使用条款", self, @selector(onDisclaimer));
        disc.tag = 9212;
        [self addSubview:disc];

        UIButton *legacy = ryButton(@"经典界面（旧版控制台）", self, @selector(onLegacy));
        legacy.tag = 9213;
        [self addSubview:legacy];

        UILabel *about = ryLabel(@"RyConsole · 个人安全研究工具\n本应用含 AI 生成内容（Ryan / Hy3）\n仅供自有设备研究使用，详见免责声明", 11.0f, RY_MUTED, NO);
        about.numberOfLines = 3;
        about.tag = 9214;
        [self addSubview:about];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    UIView *p1 = [self viewWithTag:9200];
    p1.frame = CGRectMake(kPad, 36.0f, w - kPad * 2, 130.0f);
    CGFloat pw = p1.bounds.size.width;
    [[p1 viewWithTag:9201] setFrame:CGRectMake(12.0f, 14.0f, pw - 130.0f, 18.0f)];
    [self.portField setFrame:CGRectMake(pw - 110.0f, 10.0f, 98.0f, 28.0f)];
    [[p1 viewWithTag:9203] setFrame:CGRectMake(12.0f, 58.0f, pw - 130.0f, 18.0f)];
    [self.timeoutField setFrame:CGRectMake(pw - 110.0f, 54.0f, 98.0f, 28.0f)];
    [[p1 viewWithTag:9205] setFrame:CGRectMake(12.0f, 96.0f, pw - 24.0f, 16.0f)];

    CGFloat y = 36.0f + 130.0f + 12.0f;
    [[self viewWithTag:9210] setFrame:CGRectMake(kPad, y, 88.0f, 32.0f)];
    y += 44.0f;
    [[self viewWithTag:9211] setFrame:CGRectMake(kPad, y, 170.0f, 32.0f)];
    y += 44.0f;
    [[self viewWithTag:9212] setFrame:CGRectMake(kPad, y, 190.0f, 32.0f)];
    y += 44.0f;
    [[self viewWithTag:9213] setFrame:CGRectMake(kPad, y, 240.0f, 32.0f)];
    y += 44.0f;
    [[self viewWithTag:9214] setFrame:CGRectMake(kPad, y, w - kPad * 2, 54.0f)];
}

- (void)onSave {
    NSInteger p = [self.portField.text integerValue];
    NSInteger t = [self.timeoutField.text integerValue];
    if (p > 0 && p < 65536) [[NSUserDefaults standardUserDefaults] setInteger:p forKey:@"ryc_port"];
    if (t > 0) [[NSUserDefaults standardUserDefaults] setInteger:t forKey:@"ryc_timeout_ms"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.portField resignFirstResponder];
    [self.timeoutField resignFirstResponder];
}

- (void)onClearLog {
    RYAutorunClear();
}

- (void)onDisclaimer {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = RY_BG;
    UITextView *tv = ryTextView(NO);
    tv.frame = vc.view.bounds;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.text = @"RyConsole 免责声明与使用条款（摘要）\n\n"
              @"1. 定位：个人安全研究工具，仅限在【你本人拥有或已获授权】的设备上使用。\n\n"
              @"2. 禁止：对他人设备使用；绕过他人激活锁 / 锁屏密码；窃取、监听、破坏他人数据；"
              @"武器化 0day。发现漏洞请负责任披露给厂商。\n\n"
              @"3. 风险：对内核/驱动发起非预期调用可能导致【崩溃、重启、数据丢失】；"
              @"部分接口并非只读；AI 生成的探针代码未经人工逐行审阅。"
              @"强烈建议只用专用测试设备，并先做好备份。\n\n"
              @"4. 数据与隐私：本地日志可能含设备信息；启用联网 AI 时会发送探针代码、"
              @"返回码与错误信息到你配置的服务；不会主动上传照片、通讯录、消息、凭据。\n\n"
              @"5. AI 参与：本应用含 AI 生成内容（Ryan / Hy3 模型），如实标注。\n\n"
              @"6. 无担保：按「现状」提供，作者不承担设备损坏、数据丢失或法律后果。\n\n"
              @"7. 商标：iOS / iPadOS / Apple 为 Apple Inc. 商标；本项目与其无关联。\n\n"
              @"完整条款见项目内 DISCLAIMER.md。继续使用即视为已阅读并接受。";
    [vc.view addSubview:tv];
    vc.title = @"免责声明";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    UIViewController *top = [self ry_topVC];
    if (top) [top presentViewController:nav animated:YES completion:nil];
}

- (UIViewController *)ry_topVC {
    UIWindow *key = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) { if (w.isKeyWindow) { key = w; break; } }
        if (key) break;
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)onLegacy {
    UIViewController *legacy = RYMakeLegacyConsoleVC();
    if (legacy == nil) return;
    UIViewController *top = [self ry_topVC];
    if (top) [top presentViewController:legacy animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

#pragma mark - 外壳

@interface RYShellVC ()
@property (nonatomic, strong) UIView *sidebar;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) NSMutableArray *navButtons;
@property (nonatomic, strong) RYTerminalPane *terminalPane;
@property (nonatomic, strong) RYAutorunPane *autorunPane;
@property (nonatomic, strong) RYSettingsPane *settingsPane;
@property (nonatomic, assign) NSInteger current;
@property (nonatomic, strong) UILabel *sideStatus;
@property (nonatomic, assign) BOOL compact;              // iPhone/紧凑宽度模式
@property (nonatomic, strong) NSArray *navTitles;        // 侧栏按钮文字（compact 切换时恢复用）
// 全部先声明（select: 之前正是因为这个缺失导致 ARC 报错）
- (void)onNav:(UIButton *)sender;
- (void)select:(NSInteger)idx;
- (void)layoutIndicator;
- (void)refreshSideStatus;
- (void)firstLaunchDisclaimer;
- (void)configureNavForBottom:(BOOL)bottom;
@end

@implementation RYShellVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RY_BG;
    self.navButtons = [NSMutableArray array];

    // ---- 侧栏 ----
    self.sidebar = [[UIView alloc] init];
    self.sidebar.backgroundColor = RY_PANEL;
    self.sidebar.layer.borderColor = RY_BORDER.CGColor;
    self.sidebar.layer.borderWidth = 0.5f;
    [self.view addSubview:self.sidebar];

    // ---- 底部栏（手机 / iPad 竖屏用；横屏 iPad 用左侧栏）----
    self.bottomBar = [[UIView alloc] init];
    self.bottomBar.backgroundColor = RY_PANEL;
    self.bottomBar.layer.borderColor = RY_BORDER.CGColor;
    self.bottomBar.layer.borderWidth = 0.5f;
    self.bottomBar.hidden = YES;
    [self.view addSubview:self.bottomBar];

    UILabel *title = ryLabel(@"RyConsole", 15.0f, RY_TEXT, NO);
    title.font = ryUI(15.0f, UIFontWeightMedium);
    title.tag = 8090;
    title.frame = CGRectMake(16.0f, 22.0f, kSidebarW - 32.0f, 18.0f);
    [self.sidebar addSubview:title];

    // ★ 版本号改从 Bundle 读（单一事实源 = project.yml 的 CFBundleShortVersionString）。
    //   旧版这里硬编码 @"v1.1"，导致升到 V2.2.x 左上角仍显示 v1.1（用户 2026-09-19 实测报的）。
    NSString *appVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    UILabel *sub = ryLabel([NSString stringWithFormat:@"v%@ · 研究控制台", appVer], 10.5f, RY_MUTED, YES);
    sub.tag = 8091;
    sub.frame = CGRectMake(16.0f, 42.0f, kSidebarW - 32.0f, 14.0f);
    [self.sidebar addSubview:sub];

    NSArray *items = @[@[@"terminal", @"终端"],
                       @[@"antenna.radiowaves.left.and.right", @"Autorun"],
                       @[@"gearshape", @"设置"],
                       @[@"folder", @"资源管理器"],
                       @[@"lock.shield", @"权限与安全"]];
    self.navTitles = @[@"终端", @"Autorun", @"设置", @"资源管理器", @"权限与安全"];
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        CGFloat y = 76.0f + i * 48.0f;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0.0f, y, kSidebarW, 44.0f);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleLabel.font = ryUI(13.5f, UIFontWeightMedium);
        b.tag = 8000 + i;
        UIImage *img = [UIImage systemImageNamed:items[i][0]];
        if (img) [b setImage:img forState:UIControlStateNormal];
        [b setTitle:[@"  " stringByAppendingString:items[i][1]] forState:UIControlStateNormal];
        [b setTitleColor:RY_MUTED forState:UIControlStateNormal];
        b.tintColor = RY_MUTED;
        b.contentEdgeInsets = UIEdgeInsetsMake(0.0f, 16.0f, 0.0f, 0.0f);   // 左边距（老 SDK 兼容写法）
        [b addTarget:self action:@selector(onNav:) forControlEvents:UIControlEventTouchUpInside];
        [self.sidebar addSubview:b];
        [self.navButtons addObject:b];
    }

    // 选中指示条
    UIView *bar = [[UIView alloc] init];
    bar.tag = 8100;
    bar.backgroundColor = RY_ACCENT;
    bar.layer.cornerRadius = 1.0f;
    [self.sidebar addSubview:bar];

    self.sideStatus = ryLabel(@"● 未启动", 10.5f, RY_MUTED, YES);
    self.sideStatus.numberOfLines = 2;
    self.sideStatus.tag = 8101;
    [self.sidebar addSubview:self.sideStatus];

    // ---- 内容区 ----
    self.content = [[UIView alloc] init];
    self.content.backgroundColor = RY_BG;
    self.content.clipsToBounds = YES;
    [self.view addSubview:self.content];

    self.terminalPane = [[RYTerminalPane alloc] init];
    self.autorunPane = [[RYAutorunPane alloc] init];
    self.settingsPane = [[RYSettingsPane alloc] init];
    for (UIView *p in @[self.terminalPane, self.autorunPane, self.settingsPane]) {
        p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        p.hidden = YES;
        [self.content addSubview:p];
    }

    __weak RYShellVC *weakSelf = self;
    RYAutorunObserve(^{ [weakSelf refreshSideStatus]; });

    [self select:0];

    // 键盘避让
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboard:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardHide:)
                                                 name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    UIEdgeInsets sa = self.view.safeAreaInsets;
    BOOL isPhone = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone);
    BOOL isPad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    // 手机 / iPad 竖屏 → 底部栏；iPad 横屏 → 左侧栏
    BOOL bottomTab = isPhone || (isPad && w < h);
    if (bottomTab != self.bottomMode) {
        self.bottomMode = bottomTab;
        [self configureNavForBottom:bottomTab];
    }
    if (bottomTab) {
        self.sidebar.hidden = YES;
        self.bottomBar.hidden = NO;
        CGFloat barH = 52.0f;
        CGFloat top = fmaxf(sa.top, 20.0f);
        CGFloat bot = sa.bottom;
        self.bottomBar.frame = CGRectMake(0.0f, h - barH - bot, w, barH + bot);
        CGFloat bw = w / (CGFloat)self.navButtons.count;
        for (NSInteger i = 0; i < (NSInteger)self.navButtons.count; i++)
            ((UIButton *)self.navButtons[i]).frame = CGRectMake(i * bw, 0.0f, bw, barH);
        self.content.frame = CGRectMake(0.0f, top, w, h - top - barH - bot);
    } else {
        self.sidebar.hidden = NO;
        self.bottomBar.hidden = YES;
        self.compact = (w < 500.0f);
        CGFloat sw = self.compact ? kSidebarCompactW : kSidebarW;
        self.sidebar.frame = CGRectMake(0.0f, 0.0f, sw, h);
        [self.sideStatus setFrame:CGRectMake(16.0f, h - 56.0f, kSidebarW - 32.0f, 40.0f)];
        if (self.compact) {
            CGFloat top = fmaxf(sa.top, 20.0f);
            CGFloat bot = fmaxf(sa.bottom, 8.0f);
            self.content.frame = CGRectMake(sw, top, w - sw, h - top - bot);
        } else {
            self.content.frame = CGRectMake(sw, 0.0f, w - sw, h);
        }
    }
    for (UIView *p in @[self.terminalPane, self.autorunPane, self.settingsPane]) {
        p.frame = self.content.bounds;
    }
    self.resourcePane.view.frame = self.content.bounds;   // 第 4 面板（懒加载，可能为 nil）
    [self layoutIndicator];
}

// 侧栏 ↔ 底部栏切换：手机/iPad竖屏底部栏，iPad横屏左侧栏
- (void)configureNavForBottom:(BOOL)bottom {
    self.bottomMode = bottom;
    UIView *host = bottom ? self.bottomBar : self.sidebar;
    [[self.sidebar viewWithTag:8090] setHidden:bottom];
    [[self.sidebar viewWithTag:8091] setHidden:bottom];
    [self.sideStatus setHidden:bottom];
    NSInteger n = (NSInteger)self.navButtons.count;
    for (NSInteger i = 0; i < n; i++) {
        UIButton *b = self.navButtons[i];
        if (b.superview != host) [host addSubview:b];
        if (bottom) {
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            b.contentEdgeInsets = UIEdgeInsetsZero;
            b.titleLabel.font = ryUI(11.0f, UIFontWeightMedium);
            [b setTitle:self.navTitles[i] forState:UIControlStateNormal];
        } else {
            b.frame = CGRectMake(0.0f, 76.0f + i * 48.0f, kSidebarW, 44.0f);
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            b.contentEdgeInsets = UIEdgeInsetsMake(0.0f, 16.0f, 0.0f, 0.0f);
            b.titleLabel.font = ryUI(13.5f, UIFontWeightMedium);
            [b setTitle:[@"  " stringByAppendingString:self.navTitles[i]] forState:UIControlStateNormal];
        }
    }
}

- (void)layoutIndicator {
    UIView *bar = [self.sidebar viewWithTag:8100];
    bar.hidden = self.bottomMode;
    if (self.bottomMode) return;
    CGFloat y = 76.0f + self.current * 48.0f;
    bar.frame = CGRectMake(0.0f, y + 6.0f, 3.0f, 32.0f);
}

- (void)onNav:(UIButton *)sender {
    [self select:sender.tag - 8000];
}

- (void)select:(NSInteger)idx {
    if (idx < 0 || idx > 4) idx = 0;
    self.current = idx;
    for (NSInteger i = 0; i < (NSInteger)self.navButtons.count; i++) {
        UIButton *b = self.navButtons[i];
        BOOL sel = (i == idx);
        [b setTitleColor:(sel ? RY_ACCENT : RY_MUTED) forState:UIControlStateNormal];
        b.tintColor = sel ? RY_ACCENT : RY_MUTED;
        b.backgroundColor = sel ? [UIColor colorWithWhite:1.0f alpha:0.05f] : [UIColor clearColor];
    }

    // 第 4 个面板：资源管理器。**内嵌整页**（不是弹窗），首次进入才创建，省启动开销。
    if (idx == 3) {
        if (!self.resourcePane) {
            self.resourcePane = RYMakeResourceManagerPane();
            [self addChildViewController:self.resourcePane];
            self.resourcePane.view.frame = self.content.bounds;
            self.resourcePane.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.content addSubview:self.resourcePane.view];
            [self.resourcePane didMoveToParentViewController:self];
        }
        RYResourceManagerRefresh(self.resourcePane);   // 每次进来重扫 Documents（可能刚丢过脚本进来）
    }

    // 第 5 个面板：权限与安全（诊断 / 安全开关 / 日志），同样内嵌整页、首次进入才创建
    if (idx == 4) {
        if (!self.securityPane) {
            self.securityPane = RYMakeSecurityPane();
            [self addChildViewController:self.securityPane];
            self.securityPane.view.frame = self.content.bounds;
            self.securityPane.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.content addSubview:self.securityPane.view];
            [self.securityPane didMoveToParentViewController:self];
        }
        RYSecurityPaneRefresh(self.securityPane);
    }

    self.terminalPane.hidden = (idx != 0);
    self.autorunPane.hidden = (idx != 1);
    self.settingsPane.hidden = (idx != 2);
    self.resourcePane.view.hidden = (idx != 3);
    self.securityPane.view.hidden = (idx != 4);
    [self layoutIndicator];
    if (idx == 1) [self.autorunPane refresh];
}

- (void)refreshSideStatus {
    NSDictionary *sd = nil;
    id o = [NSJSONSerialization JSONObjectWithData:[RYAutorunStatus() dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0 error:NULL];
    if ([o isKindOfClass:[NSDictionary class]]) sd = (NSDictionary *)o;
    BOOL running = [sd[@"running"] boolValue];
    self.sideStatus.text = running
        ? [NSString stringWithFormat:@"● 监听中 :%d", [sd[@"port"] intValue]]
        : @"● 未启动";
    self.sideStatus.textColor = running ? RY_GREEN : RY_MUTED;
}

- (void)onKeyboard:(NSNotification *)n {
    NSDictionary *info = n.userInfo;
    CGRect end = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inSelf = [self.view convertRect:end fromView:nil];
    CGFloat overlap = self.view.bounds.size.height - inSelf.origin.y;
    if (overlap < 0.0f) overlap = 0.0f;
    if (self.bottomMode) {
        CGFloat barH = 52.0f;
        CGFloat top = fmaxf(self.view.safeAreaInsets.top, 20.0f);
        self.content.frame = CGRectMake(0.0f, top, self.view.bounds.size.width,
                                        self.view.bounds.size.height - overlap - top - barH - self.view.safeAreaInsets.bottom);
    } else {
        CGFloat sw = self.compact ? kSidebarCompactW : kSidebarW;
        CGFloat top = self.compact ? fmaxf(self.view.safeAreaInsets.top, 20.0f) : 0.0f;
        self.content.frame = CGRectMake(sw, top,
                                        self.view.bounds.size.width - sw,
                                        self.view.bounds.size.height - overlap - top);
    }
}

- (void)onKeyboardHide:(NSNotification *)n {
    if (self.bottomMode) {
        CGFloat barH = 52.0f;
        CGFloat top = fmaxf(self.view.safeAreaInsets.top, 20.0f);
        self.content.frame = CGRectMake(0.0f, top, self.view.bounds.size.width,
                                        self.view.bounds.size.height - top - barH - self.view.safeAreaInsets.bottom);
    } else {
        CGFloat sw = self.compact ? kSidebarCompactW : kSidebarW;
        CGFloat top = self.compact ? fmaxf(self.view.safeAreaInsets.top, 20.0f) : 0.0f;
        CGFloat bot = self.compact ? fmaxf(self.view.safeAreaInsets.bottom, 8.0f) : 0.0f;
        self.content.frame = CGRectMake(sw, top,
                                        self.view.bounds.size.width - sw,
                                        self.view.bounds.size.height - top - bot);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self firstLaunchDisclaimer];
}

- (void)firstLaunchDisclaimer {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger ver = [d integerForKey:@"ryc_disclaimer_version"];
    if ([d boolForKey:@"ryc_disclaimer_accepted_v1"] && ver >= 1) return;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"使用前请确认"
                         message:@"RyConsole 是个人安全研究工具，仅限在【你本人拥有或已获授权】的设备上使用。\n\n"
                                 @"它会调用设备底层接口，可能导致【崩溃、重启或数据丢失】；"
                                 @"其中的 AI 生成代码【未经人工逐行审阅】。\n\n"
                                 @"请确认：\n① 设备归你所有或已获授权\n② 重要数据已备份\n"
                                 @"③ 不用于绕过他人设备的安全机制\n\n"
                                 @"发现漏洞请负责任地披露给厂商，不要武器化。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"不同意，退出" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) { exit(0); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"我已知悉并同意" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [d setBool:YES forKey:@"ryc_disclaimer_accepted_v1"];
        [d setInteger:1 forKey:@"ryc_disclaimer_version"];
        [d synchronize];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end
