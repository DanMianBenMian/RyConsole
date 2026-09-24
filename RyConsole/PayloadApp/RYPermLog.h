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

#pragma mark - 脚本级权限作用域（V2.4.6）
// 脚本开始时一次性确认（用户需求：放行 = 当前脚本放行全部权限，拒绝 = 直接驳回）：
//   · 扫描 code 文本里出现过的**被禁用**受管命令，非空 → 弹一次窗列出「要调用 xx、xxx 命令」
//     —— 允许   → 本脚本作用域内全部放行（含 race worker 线程，进程级全局）
//     —— 不同意 → 本脚本作用域内被禁命令一律直接驳回，不再弹窗
//   · 扫描结果为空 → 不弹窗，直接进入放行作用域
//   · 脚本结束（RYExecStream/终端执行器出口，含崩溃兜底路径）必须调 endScriptScope 清作用域
+ (NSArray<NSString *> *)disabledCommandsInCode:(NSString *)code;
- (void)beginScriptScope:(NSString *)code;
- (void)endScriptScope;

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

#pragma mark - 环境（V2.4.13）
// 以下为 main.m 实现的 C 函数，环境页与原语共用
NSString *RYEnvironmentStateJSON(void);   // 身份(uid/gid/pid/组) + 干净与否 + 网络
NSString *RYResetEnvironment(void);       // 清共享字典/归零原子槽/回收批次/停服务端
NSString *RYInterfaceIPsJSON(void);       // 所有接口 IP（含个人热点 bridge100）
NSString *RYHotspotIP(void);              // 对连热点/局域网电脑可达的 IP

@end
