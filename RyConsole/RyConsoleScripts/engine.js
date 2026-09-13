// engine.js — RyConsole 执行引擎（可编辑·热重载·改坏仅报错不崩 App）
// 由 main.m 在每次执行时加载（Documents/engine.js 优先，否则 bundle 版）。
// RYC_RUN: 执行用户代码；print 由原生实时流式刷新到输出页。
// 这就是「把执行 main/ObjC 分离出来、按需调用」的落地：UI 外壳锁死在 main.m，
// 执行逻辑在这里，改完下次执行即生效，无需重编译。
var geval = eval; // 间接 eval → 全局作用域，保留 function / var 声明语义（交互式跨次共享）
function RYC_RUN(code) {
  // 先按全局作用域执行（保留 var / function 跨次共享，交互式终端体验）。
  try { return geval(code); }
  catch (e) {
    // 顶层 return 等在全局作用域非法的语法 → 用 Function 构造器包裹重试：
    // 函数体内允许顶层 return / 提前退出（探针脚本常见），且不污染全局、不影响共享。
    if (e && (e instanceof SyntaxError || /return/i.test(String((e && e.message) || e)))) {
      try { return (new Function(code))(); }
      catch (e2) { e = e2; }
    }
    print("[engine] 运行异常: " + (e && e.stack ? e.stack : String(e)));
    return undefined;
  }
}
// 可在此追加执行期辅助（统一输出格式化、探针包装等），热重载生效。
