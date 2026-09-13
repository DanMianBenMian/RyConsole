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
