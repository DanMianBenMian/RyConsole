// engine.js — RyConsole 执行引擎（可编辑·热重载·改坏仅报错不崩 App）
// 由 main.m 在每次执行时加载（Documents/engine.js 优先，否则 bundle 版）。
// RYC_RUN: 执行用户代码；print 由原生实时流式刷新到输出页。
// 这就是「把执行 main/ObjC 分离出来、按需调用」的落地：UI 外壳锁死在 main.m，
// 执行逻辑在这里，改完下次执行即生效，无需重编译。
var geval = eval; // 间接 eval → 全局作用域，保留 function 声明语义
function RYC_RUN(code) {
  try { return geval(code); }
  catch (e) { print("[engine] 运行异常: " + (e && e.stack ? e.stack : String(e))); return undefined; }
}
// 可在此追加执行期辅助（统一输出格式化、探针包装等），热重载生效。
