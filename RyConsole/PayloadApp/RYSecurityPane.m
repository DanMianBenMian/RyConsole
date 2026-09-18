//
//  RYSecurityPane.m
//  RyConsole —— 「权限与安全」面板（V2.4）
//
//  样式沿用外壳：深色卡片 + 系统色，小字号等宽文本。
//  三个分区用 UISegmentedControl 切换，各自一张表。
//

#import "RySecurityPane.h"
#import "RYPermLog.h"
#import <UIKit/UIKit.h>

#define SP_BG      [UIColor colorWithRed:0.043f green:0.043f blue:0.047f alpha:1.0f]
#define SP_PANEL   [UIColor colorWithRed:0.098f green:0.098f blue:0.106f alpha:1.0f]
#define SP_TEXT    [UIColor whiteColor]
#define SP_MUTED   [UIColor colorWithWhite:0.62f alpha:1.0f]
#define SP_ACCENT  [UIColor systemBlueColor]
#define SP_GREEN   [UIColor systemGreenColor]
#define SP_RED     [UIColor systemRedColor]
#define SP_AMBER   [UIColor systemOrangeColor]

@interface RYSecurityPaneVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UITableView *diagTable;
@property (nonatomic, strong) UITableView *cmdTable;
@property (nonatomic, strong) UITableView *logTable;
@property (nonatomic, strong) UILabel *statLabel;
@property (nonatomic, strong) UISegmentedControl *logFilter;
@property (nonatomic, strong) NSArray *diagResults;
@property (nonatomic, strong) NSArray *cmdHigh;
@property (nonatomic, strong) NSArray *cmdNormal;
@property (nonatomic, assign) BOOL diagRunning;
@property (nonatomic, strong) UIActivityIndicatorView *spin;
@end

@implementation RYSecurityPaneVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = SP_BG;
    self.title = @"权限与安全";

    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"权限诊断", @"安全", @"日志"]];
    self.seg.selectedSegmentIndex = 0;
    self.seg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.seg addTarget:self action:@selector(onSeg:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.seg];

    self.hostView = [[UIView alloc] init];
    self.hostView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.hostView];

    [NSLayoutConstraint activateConstraints:@[
        [self.seg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.seg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.seg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.hostView.topAnchor constraintEqualToAnchor:self.seg.bottomAnchor constant:12],
        [self.hostView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.hostView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.hostView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12]
    ]];

    [self buildDiagView];
    [self buildCmdView];
    [self buildLogView];
    [self onSeg:self.seg];
}

#pragma mark - ① 权限诊断
- (void)buildDiagView {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.tag = 100;
    [self.hostView addSubview:v];
    [self pin:v];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:@"重新诊断" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [btn addTarget:self action:@selector(runDiag) forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:btn];
    self.spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spin.translatesAutoresizingMaskIntoConstraints = NO;
    self.spin.hidesWhenStopped = YES;
    [v addSubview:self.spin];

    self.diagTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.diagTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.diagTable.backgroundColor = SP_BG;
    self.diagTable.dataSource = self;
    self.diagTable.delegate = self;
    [v addSubview:self.diagTable];

    [NSLayoutConstraint activateConstraints:@[
        [btn.topAnchor constraintEqualToAnchor:v.topAnchor constant:4],
        [btn.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:0],
        [self.spin.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
        [self.spin.trailingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:-10],
        [self.diagTable.topAnchor constraintEqualToAnchor:btn.bottomAnchor constant:8],
        [self.diagTable.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:0],
        [self.diagTable.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:0],
        [self.diagTable.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:0]
    ]];
}

- (void)runDiag {
    if (self.diagRunning) return;
    self.diagRunning = YES;
    [self.spin startAnimating];
    [[RYPermLog shared] runDiagnostics:^(NSArray<NSDictionary *> *results) {
        self.diagResults = results;
        self.diagRunning = NO;
        [self.spin stopAnimating];
        [self.diagTable reloadData];
    }];
}

#pragma mark - ② 安全（命令开关）
- (void)buildCmdView {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.tag = 101;
    [self.hostView addSubview:v];
    [self pin:v];

    UILabel *tip = [[UILabel alloc] init];
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    tip.text = @"默认全部启用。关掉的命令被调用时会向你确认（后台先用灵动岛提醒），拒绝 = 回给 AI「权限请求驳回」。";
    tip.textColor = SP_MUTED;
    tip.font = [UIFont systemFontOfSize:11];
    tip.numberOfLines = 3;
    [v addSubview:tip];

    self.cmdTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.cmdTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.cmdTable.backgroundColor = SP_BG;
    self.cmdTable.dataSource = self;
    self.cmdTable.delegate = self;
    [v addSubview:self.cmdTable];

    [NSLayoutConstraint activateConstraints:@[
        [tip.topAnchor constraintEqualToAnchor:v.topAnchor constant:0],
        [tip.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:0],
        [tip.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:0],
        [self.cmdTable.topAnchor constraintEqualToAnchor:tip.bottomAnchor constant:8],
        [self.cmdTable.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:0],
        [self.cmdTable.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:0],
        [self.cmdTable.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:0]
    ]];
}

#pragma mark - ③ 日志
- (void)buildLogView {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.tag = 102;
    [self.hostView addSubview:v];
    [self pin:v];

    self.statLabel = [[UILabel alloc] init];
    self.statLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statLabel.textColor = SP_TEXT;
    [v addSubview:self.statLabel];

    self.logFilter = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"一般", @"高危"]];
    self.logFilter.translatesAutoresizingMaskIntoConstraints = NO;
    self.logFilter.selectedSegmentIndex = 0;
    [self.logFilter addTarget:self action:@selector(onFilter:) forControlEvents:UIControlEventValueChanged];
    [v addSubview:self.logFilter];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:13];
    [clear addTarget:self action:@selector(onClearLog) forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:clear];

    self.logTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.logTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.logTable.backgroundColor = SP_BG;
    self.logTable.dataSource = self;
    self.logTable.delegate = self;
    [v addSubview:self.logTable];

    [NSLayoutConstraint activateConstraints:@[
        [self.statLabel.topAnchor constraintEqualToAnchor:v.topAnchor constant:2],
        [self.statLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:0],
        [self.logFilter.topAnchor constraintEqualToAnchor:self.statLabel.bottomAnchor constant:8],
        [self.logFilter.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:0],
        [self.logFilter.widthAnchor constraintEqualToConstant:220],
        [clear.centerYAnchor constraintEqualToAnchor:self.logFilter.centerYAnchor],
        [clear.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:0],
        [self.logTable.topAnchor constraintEqualToAnchor:self.logFilter.bottomAnchor constant:8],
        [self.logTable.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:0],
        [self.logTable.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:0],
        [self.logTable.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:0]
    ]];
}

- (void)pin:(UIView *)v {
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:self.hostView.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:self.hostView.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:self.hostView.trailingAnchor],
        [v.bottomAnchor constraintEqualToAnchor:self.hostView.bottomAnchor]
    ]];
}

#pragma mark - 切换 / 刷新
- (void)onSeg:(UISegmentedControl *)s {
    for (UIView *v in self.hostView.subviews) v.hidden = (v.tag != (100 + s.selectedSegmentIndex));
    if (s.selectedSegmentIndex == 0 && !self.diagResults.count) [self runDiag];
    if (s.selectedSegmentIndex == 1) [self reloadCommands];
    if (s.selectedSegmentIndex == 2) [self reloadLogs];
}

- (void)onFilter:(UISegmentedControl *)s { [self reloadLogs]; }

- (void)onClearLog {
    [[RYPermLog shared] clearLog];
    [self reloadLogs];
}

- (void)reloadCommands {
    self.cmdHigh = [RYPermLog highRiskCommands];
    NSMutableArray *normal = [NSMutableArray array];
    for (NSString *c in [RYPermLog managedCommands]) {
        if (![self.cmdHigh containsObject:c]) [normal addObject:c];
    }
    self.cmdNormal = normal;
    [self.cmdTable reloadData];
}

- (void)reloadLogs {
    NSInteger h = [[RYPermLog shared] countHigh];
    NSInteger n = [[RYPermLog shared] countNormal];
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"高危命令 %ld 次调用", (long)h]
                                                               attributes:@{NSForegroundColorAttributeName: SP_RED}]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:@"　·　" attributes:@{NSForegroundColorAttributeName: SP_MUTED}]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"一般命令 %ld 次调用", (long)n]
                                                               attributes:@{NSForegroundColorAttributeName: SP_GREEN}]];
    self.statLabel.attributedText = as;
    [self.logTable reloadData];
}

- (NSArray *)currentLogEntries {
    RYPermLogFilter f = (RYPermLogFilter)self.logFilter.selectedSegmentIndex;
    return [[RYPermLog shared] entries:f];
}

#pragma mark - Table
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    if (tv == self.cmdTable) return 2;
    return 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)sec {
    if (tv == self.cmdTable) return (sec == 0) ? @"高危命令（关掉后调用需确认）" : @"一般命令";
    if (tv == self.diagTable) return @"逐项实测（正常=可用，否则=禁用并给原因）";
    return nil;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    if (tv == self.diagTable) return self.diagResults.count ?: 1;
    if (tv == self.cmdTable) return (sec == 0) ? self.cmdHigh.count : self.cmdNormal.count;
    return [self currentLogEntries].count ?: 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (tv == self.diagTable) {
        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"diag"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"diag"];
        c.backgroundColor = SP_PANEL;
        if (!self.diagResults.count) {
            c.textLabel.text = self.diagRunning ? @"正在诊断…" : @"（点上方「重新诊断」开始）";
            c.textLabel.font = [UIFont systemFontOfSize:13];
            c.textLabel.textColor = SP_MUTED;
            c.detailTextLabel.text = nil;
            c.accessoryView = nil;
            return c;
        }
        NSDictionary *r = self.diagResults[ip.row];
        BOOL ok = [r[@"ok"] boolValue];
        c.textLabel.text = [NSString stringWithFormat:@"%@  %@", ok ? @"✅" : @"⛔", r[@"title"]];
        c.textLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
        c.textLabel.textColor = ok ? SP_TEXT : SP_RED;
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", r[@"desc"] ?: @"", r[@"detail"] ?: @""];
        c.detailTextLabel.numberOfLines = 3;
        c.detailTextLabel.font = [UIFont systemFontOfSize:10.5];
        c.detailTextLabel.textColor = SP_MUTED;
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 20)];
        badge.text = ok ? @"可用" : @"禁用";
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        badge.textColor = ok ? SP_GREEN : SP_RED;
        badge.textAlignment = NSTextAlignmentRight;
        c.accessoryView = badge;
        return c;
    }

    if (tv == self.cmdTable) {
        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"cmd"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cmd"];
        c.backgroundColor = SP_PANEL;
        NSArray *list = (ip.section == 0) ? self.cmdHigh : self.cmdNormal;
        NSString *name = (ip.row < (NSInteger)list.count) ? list[ip.row] : @"";
        c.textLabel.text = name;
        c.textLabel.font = [UIFont fontWithName:@"Menlo" size:12.5] ?: [UIFont systemFontOfSize:12.5];
        c.textLabel.textColor = (ip.section == 0) ? SP_AMBER : SP_TEXT;
        NSString *warn = [RYPermLog warnTextOfCommand:name];
        c.detailTextLabel.text = warn ? [NSString stringWithFormat:@"⚠ %@", warn] : nil;
        c.detailTextLabel.numberOfLines = 2;
        c.detailTextLabel.font = [UIFont systemFontOfSize:10];
        c.detailTextLabel.textColor = SP_AMBER;

        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [[RYPermLog shared] isEnabled:name];
        sw.tag = (ip.section << 16) | ip.row;
        [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"log"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"log"];
    c.backgroundColor = SP_PANEL;
    NSArray *es = [self currentLogEntries];
    if (!es.count) {
        c.textLabel.text = @"（暂无调用记录）";
        c.textLabel.font = [UIFont systemFontOfSize:12];
        c.textLabel.textColor = SP_MUTED;
        c.detailTextLabel.text = nil;
        return c;
    }
    NSDictionary *e = es[ip.row];
    BOOL high = ([e[@"risk"] integerValue] == RYPermRiskHigh);
    BOOL allowed = [e[@"allowed"] boolValue];
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:[e[@"ts"] doubleValue]];
    NSDateFormatter *fm = [[NSDateFormatter alloc] init];
    fm.dateFormat = @"HH:mm:ss";
    NSString *note = [e[@"note"] length] ? [NSString stringWithFormat:@"  · %@", e[@"note"]] : @"";
    c.textLabel.text = [NSString stringWithFormat:@"%@  %@%@", [fm stringFromDate:d], e[@"cmd"], note];
    c.textLabel.font = [UIFont fontWithName:@"Menlo" size:11.5] ?: [UIFont systemFontOfSize:11.5];
    c.textLabel.textColor = high ? SP_RED : SP_GREEN;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", high ? @"高危" : @"一般", allowed ? @"已放行" : @"已驳回"];
    c.detailTextLabel.font = [UIFont systemFontOfSize:10];
    c.detailTextLabel.textColor = SP_MUTED;
    return c;
}

- (void)onSwitch:(UISwitch *)sw {
    NSInteger sec = (sw.tag >> 16);
    NSInteger row = (sw.tag & 0xFFFF);
    NSArray *list = (sec == 0) ? self.cmdHigh : self.cmdNormal;
    if (row >= (NSInteger)list.count) return;
    [[RYPermLog shared] setEnabled:sw.on forCommand:list[row]];
}

@end

UIViewController *RYMakeSecurityPane(void) { return [[RYSecurityPaneVC alloc] init]; }
void RYSecurityPaneRefresh(UIViewController *vc) {
    if ([vc isKindOfClass:[RYSecurityPaneVC class]]) {
        RYSecurityPaneVC *p = (RYSecurityPaneVC *)vc;
        [p reloadCommands];
        [p reloadLogs];
    }
}
