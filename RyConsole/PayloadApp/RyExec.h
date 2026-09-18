//
//  RyExec.h
//  RyConsole —— 通用 JS 执行器接口
//
//  Terminal 与 Autorun 共用同一条执行路径：装原语 → 载桥 → 载 engine.js → 执行。
//  实现位于 main.m（RYExecStream）。
//
//  线程：在**调用线程**上建 JSContext 并同步执行；
//        onLine / onDone 也在调用线程触发 —— UI 侧请自行 dispatch 回主线程。
//

#import <Foundation/Foundation.h>

// 流式执行一段 JS
//   onLine : print 输出 与 JS 错误，逐行回调（可为 nil）
//   onDone : 结束时回调 返回值 / 错误 / 耗时(ms)（可为 nil）
void RYExecStream(NSString *code,
                  void (^onLine)(NSString *line),
                  void (^onDone)(NSString *result, NSString *error, double ms));

// ============================================================
//  崩溃兜底（V2.2.6）—— 把"会崩的探针"变成"返回：触发崩溃，已兜底"
// ============================================================
//  RYExecStream 每次执行都会在**调用线程**布一个 sigsetjmp 检查点：
//    · 该线程随后出现 SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP → 信号处理器 siglongjmp 回检查点，
//      本次执行以 onDone(nil, "[崩溃兜底] …", ms) 收尾，**进程存活**；
//    · 常态下不改变任何原有行为（跑完撤检查点；兜不住的情形仍写崩溃日志 + 退出）。
//  ✅ 覆盖：用户态信号类崩溃（野指针 / 空函数指针 / objc_msgSend 打空 / 越界读 / 爆栈）
//  ❌ 不覆盖：内核 panic、看门狗卡死、非布点线程上的崩溃、外部 kill
//  ⚠ 拦下后那次执行是**被掀栈**结束的，锁/内存/JSC 状态可能不干净 → degraded 置 1，建议重启 App 复位

int  RYGuardHits(void);                    // 累计拦下次数
int  RYGuardLastSignal(void);              // 最近一次拦下的信号号
unsigned long long RYGuardLastAddr(void);  // 最近一次故障地址
int  RYGuardSeq(void);                     // 递增序号（执行前后比对即知"本次是否被拦"）
int  RYGuardEnabled(void);                 // 兜底开关（默认 1 = 开）
int  RYGuardDegraded(void);                // 拦过之后置 1 = "状态可能不干净"
const char *RYGuardLastPrim(void);         // 最近一次崩在哪个原语
void RYGuardSetEnabled(int on);            // 0 = 关掉（恢复真崩，便于 pid 差分定位）
NSString *RYGuardStatusJSON(void);         // 状态 JSON（/ping、crashGuardStatus 共用）
