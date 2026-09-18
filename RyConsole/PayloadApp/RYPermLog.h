//
//  RYPermLog.h
//  RyConsole —— 权限与安全（V2.4）
//
//  三件事：
//    ① 命令风险分级（高危 / 一般）+ 用户开关（默认全启用，持久化 NSUserDefaults）
//    ② 调用拦截：被禁用的命令被调用时，弹窗 / 灵动岛向用户确认；不同意 → 回给 AI「权限请求驳回」
//    ③ 调用日志：环形缓冲 + 高危/一般计数，供「权限与安全 → 日志」页查看与筛选
//
//  线程：gateCommand: 会在**调用线程**同步等待用户决定（主线程弹窗，信号量等待，超时按驳回）。
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RYPermRisk) {
    RYPermRiskNormal = 0,   // 一般
    RYPermRiskHigh   = 1    // 高危
};

// 日志筛选
typedef NS_ENUM(NSInteger, RYPermLogFilter) {
    RYPermLogFilterAll   = 0,
    RYPermLogFilterNormal = 1,
    RYPermLogFilterHigh  = 2
};

@interface RYPermLog : NSObject

+ (instancetype)shared;

#pragma mark - 命令表 / 风险分级
// 受管命令（有明确风险分级）；未列出的按"一般"处理，不弹权限确认
+ (NSArray<NSString *> *)managedCommands;
+ (NSArray<NSString *> *)highRiskCommands;
+ (RYPermRisk)riskOfCommand:(NSString *)cmd;
+ (NSString *)riskLabel:(RYPermRisk)risk;      // @"高危" / @"一般"
+ (NSString *)warnTextOfCommand:(NSString *)cmd;   // 高危命令的提示文案（没有则 nil）

#pragma mark - 开关
- (BOOL)isEnabled:(NSString *)cmd;
- (void)setEnabled:(BOOL)on forCommand:(NSString *)cmd;
- (void)resetAllEnabled:(BOOL)on;

#pragma mark - 拦截（供 main.m 的 __ry_gate 调用）
// 返回 {ok:YES} 放行；{ok:NO, error:"[权限] …"} 驳回（调用方直接把 error 当作返回值给 AI）
- (NSDictionary *)gateCommand:(NSString *)cmd;

#pragma mark - 日志
- (NSArray<NSDictionary *> *)entries:(RYPermLogFilter)filter;   // 新→旧，最多 500 条
- (NSInteger)countHigh;
- (NSInteger)countNormal;
- (void)clearLog;

#pragma mark - 权限诊断
// 每项：@{@"key":…, @"title":…, @"group":@"Entitlement"/@"能力", @"desc":…}
+ (NSArray<NSDictionary *> *)diagnosticSpecs;
// 逐项实测（后台线程跑，主线程回调）。结果项追加 ok / detail 字段
- (void)runDiagnostics:(void (^)(NSArray<NSDictionary *> *results))done;

@end
