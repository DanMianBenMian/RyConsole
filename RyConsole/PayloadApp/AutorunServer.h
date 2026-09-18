//
//  AutorunServer.h
//  RyConsole —— Autorun 局域网执行服务
//
//  作用：在 iPad 上监听一个端口，接收电脑端发来的 JS 代码，执行后回传结果。
//  AI 不在设备上，AI 在电脑端（Ryan），iPad 只当"执行 + 回传"的手。
//
//  端点（全部是极简 HTTP，方便用 curl / python 调用）：
//    GET  /ping                    -> {"ok":true,...}
//    POST /eval    {"code":...}    -> 同步执行并返回结果
//    POST /submit  {"code":...}    -> 立即返回 {"id":"j1"}，异步执行
//    GET  /result?id=j1            -> {"status":"running"} / {"status":"done",...}
//
//  ⚠️ 仅监听局域网；iOS 侧必须在 Info.plist 声明 NSLocalNetworkUsageDescription，
//     且 App 需保持在前台（后台会被系统挂起）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 执行一段 JS 源码，返回其返回值（字符串形式）。由 main.m 用当前 JSContext 构造。
typedef NSString* (^RYEvalBlock)(NSString *jsSource);

// 日志回调（面板里显示用），可为 nil
typedef void (^RYLogBlock)(NSString *line);

// ★ 注册 JS 执行器（main.m 在拿到 JSContext 后调用一次即可）。
//   注册后，面板上的「启动」按钮也能直接工作，不必等 JS 先调 autorunStart。
void RYAutorunSetEval(RYEvalBlock eval);

// 启动监听；port <= 0 时用默认 8899。eval/logger 传 nil 表示沿用已注册的。
// 返回可读状态字符串（"OK:..." / "ERROR:..."）。
NSString *RYAutorunStart(int port, RYEvalBlock eval, RYLogBlock logger);

// 停止监听。返回状态字符串。
NSString *RYAutorunStop(void);

// 当前状态（JSON 字符串）
NSString *RYAutorunStatus(void);

// 最近的日志文本（给 JS 侧读取）
NSString *RYAutorunLogText(void);

// 打开 Autorun 面板（present UIViewController）。返回 "OK" 或错误说明。
NSString *RYAutorunOpenPanel(void);

// ==================== 供 UI 读取的最近状态 ====================

// 最近一次收到的代码（无则返回 ""）
NSString *RYAutorunLastCode(void);

// 最近一次执行的摘要（JSON）：{"status":"idle|running|done","ok":true,"ms":123,
//                              "output":"…","result":"…","error":null}
NSString *RYAutorunLastResultJSON(void);

// 最近一次请求的来源（"192.168.0.5 · 13:20:41"），无则 ""
NSString *RYAutorunPeer(void);

// 注册状态变化回调（在**主线程**触发）。支持注册多个（内部按列表保存）；
// 传 nil 表示清空全部回调。UI 用它刷新。
void RYAutorunObserve(void (^cb)(void));

// 清空日志与最近结果
void RYAutorunClear(void);

// ==================== 崩溃定位：最近调用的原生原语 ====================
//
// 背景：真机 SIGSEGV 时我们只能从崩溃栈拿到一个 block 序号
//       （__installPrimitives_block_invoke_N），反查源码极易错位（已踩过）。
// 做法：installPrimitives 末尾在 JS 侧给每个原语套一层"登记"包装，调用即记名；
//       崩溃日志里直接用 lastPrim 点名是哪个原语崩的。
//
//   RYNotePrimitive —— 由 JS 层包装调用（走 __ry_note 原语）
//   RYLastPrimitive —— 读当前记录（崩溃处理器 / /ping 状态里用）
//      ⚠️ 实现用的是**无锁 char 数组**：必须在信号处理器里也能安全读（只用 write/snprintf）。
void RYNotePrimitive(const char *name);
const char *RYLastPrimitive(void);
