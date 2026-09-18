// engine.js — RyConsole 执行引擎（可编辑·热重载·改坏仅报错不崩 App）
// 由 main.m 在每次执行时加载（Documents/engine.js 优先，否则 bundle 版）。
// RYC_RUN: 执行用户代码；print 由原生实时流式刷新到输出页。
// 这就是「把执行 main/ObjC 分离出来、按需调用」的落地：UI 外壳锁死在 main.m，
// 执行逻辑在这里，改完下次执行即生效，无需重编译。
//
// v2（2026-09-18，按 AUTORUN 缺陷报告 Bug 3 修）：
//   以前异常只 print 一行 "[engine] 运行异常: <stack 首两帧>" —— 没有 name/message、
//   堆栈还被截断、error 字段为 null，调用方完全无法判断失败原因。
//   现在：① 打印 name + message + 堆栈前 8 行；② **再抛出去**，让原生侧把 error 字段也填上；
//         ③ 语法错误时会说明"已尝试 Function() 包裹重试"。
var geval = eval; // 间接 eval → 全局作用域，保留 function / var 声明语义（交互式跨次共享）

function RYC_ERRTEXT(e, stage) {
  var nm = (e && e.name) || "Error";
  var msg = (e && e.message) || String(e);
  var stk = (e && e.stack) ? String(e.stack) : "";
  var out = "[" + stage + "] " + nm + ": " + msg;
  if (stk) {
    var lines = stk.split("\n");
    for (var i = 0; i < lines.length && i < 8; i++) out += "\n    " + lines[i];
  }
  return out;
}

function RYC_RUN(code) {
  code = (code === undefined || code === null) ? "" : String(code);
  // 先按全局作用域执行（保留 var / function 跨次共享，交互式终端体验）。
  try { return geval(code); }
  catch (e) {
    var first = e;
    // 顶层 return 等在全局作用域非法的语法 → 用 Function 构造器包裹重试：
    // 函数体内允许顶层 return / 提前退出（探针脚本常见），且不污染全局、不影响共享。
    if (e && (e instanceof SyntaxError || /return/i.test(String((e && e.message) || e)))) {
      try { return (new Function(code))(); }
      catch (e2) {
        print(RYC_ERRTEXT(e2, "engine/Function") +
              "\n    （注：全局 eval 先报了 " + ((first && first.name) || "?") +
              "，已用 new Function(code) 包裹重试，仍失败）");
        throw e2;
      }
    }
    print(RYC_ERRTEXT(e, "engine"));
    print("    code 长度=" + code.length + " 首行=" + code.split("\n")[0].slice(0, 80));
    throw e;   // ★ 关键：抛出去，原生侧才会把 error 字段填上（否则调用方只看到 output）
  }
}
// 可在此追加执行期辅助（统一输出格式化、探针包装等），热重载生效。
