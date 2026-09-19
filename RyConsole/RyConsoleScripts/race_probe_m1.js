// ============================================================
//  race_probe_m1.js — Stage2 里程碑 M1：并发版 close-then-use
//  （RACE_plan_v2 §四 M1：harness 合入后复跑 P88 同款，并发版）
//  文件名不带 bridge_ 前缀 → 不会自动加载；脚本库手动运行。
//  ------------------------------------------------------------
//  模式：threadSpawn 一个 body，worker 内按 __threadId 分角色：
//    · 线程 0（释放侧）：open → raceSharedSet 发布 handle → close，循环制造释放/使用交错
//    · 线程 1（使用侧）：轮询共享 handle，对它 iokitCall（打释放-使用窗口）
//  ★ 本脚本是【骨架】：iokitOpen/iokitCall 的具体参数请按 P88 原版探针调整
//    （SVC、sel、参数形状），模式本身（spawn→barrier→race→join）不用改。
//  判定纪律：无 crash / 无异常 ret 分布 → 诚实记录"该面竞态闭合"，转下一目标。
// ============================================================

var ITERS = 10000;          // 1e3 ~ 1e6 可调；先 1e4 冒烟，稳了再上 1e6
var SVC = "IOSurfaceRoot";  // 按实际 client 名调整

// 单一 body，worker 内按 __threadId 分角色（每个 worker 是独立 JSContext）
var body = [
  "var ITERS = " + ITERS + ", SVC = " + JSON.stringify(SVC) + ";",
  "raceBarrier(2);                                       // 与对方会合后再开跑",
  "if (__threadId === 0) {",
  "  // ---- 释放侧：open → 发布 → close ----",
  "  var opens = 0, closes = 0, lastErr = '';",
  "  for (var i = 0; i < ITERS; i++) {",
  "    if (threadStopFlag()) break;",
  "    var o = JSON.parse(iokitOpen(SVC));",
  "    if (o && o.conn) {",
  "      opens++;",
  "      raceSharedSet('h', o.conn);                      // 发布 handle 给使用侧",
  "      var c = JSON.parse(iokitClose(o.conn));",
  "      if (c && (c.ok === true || c.ok === 'ok')) closes++; else lastErr = JSON.stringify(c);",
  "    }",
  "    if (i % 500 === 0) threadProgress({ th: 0, i: i, opens: opens, closes: closes });",
  "  }",
  "  raceSharedSet('h', null);                            // 收尾：撤发布",
  "  'A done opens=' + opens + ' closes=' + closes + ' lastErr=' + lastErr;",
  "} else {",
  "  // ---- 使用侧：轮询共享 handle，对它 iokitCall ----",
  "  var uses = 0, dist = {}, lastH = null;",
  "  for (var i = 0; i < ITERS * 2; i++) {                // 频率翻倍，保证窗口覆盖",
  "    if (threadStopFlag()) break;",
  "    var h = raceSharedGet('h');",
  "    if (h !== null && h !== lastH) {                   // 只打新 handle（旧的多半已销毁）",
  "      lastH = h;",
  "      var r = JSON.parse(iokitCall(h, 0, [{ buf: 64 }]));  // ★ sel/参数按 P88 调整",
  "      var k = (r && r.ok === true) ? 'ok' : String(r && (r.error !== undefined ? r.error : r.kr)).slice(0, 40);",
  "      dist[k] = (dist[k] || 0) + 1; uses++;",
  "      if (i % 500 === 0) threadProgress({ th: 1, i: i, uses: uses });",
  "    }",
  "  }",
  "  'B done uses=' + uses + ' dist=' + JSON.stringify(dist);",
  "}"
].join("\n");

// ---- 主控：spawn → join → 汇总 ----
print("[M1] 并发 close-then-use 开始  ITERS=" + ITERS + " SVC=" + SVC);
var t0 = now().mono;
var sp = JSON.parse(threadSpawn(body, 2));
if (!sp.ok) { print("[M1] threadSpawn 失败: " + JSON.stringify(sp)); }
else {
  var jr = JSON.parse(threadJoin(600000));               // 最多等 10 分钟
  var ms = Math.round((now().mono - t0) * 1000);
  print("[M1] 完成 " + jr.done + "/" + jr.threads + " 用时 " + ms + "ms  stillRunning=" + JSON.stringify(jr.stillRunning));
  var guarded = 0;
  for (var i = 0; i < jr.results.length; i++) {
    var r = jr.results[i];
    if (r.guarded) guarded++;
    print("[M1] worker" + r.thread + (r.guarded ? " ★GUARDED★ " : " ") + "→ " + r.result);
  }
  print("[M1] 结论: " + (guarded === 0
    ? "无崩溃。看 dist 分布——全是可预期错误码（如 0x10000003 端口销毁）= 该面竞态闭合，转下一目标；出现异常 ret = 收获"
    : "有 worker 被兜底拦下（guardAddr 见其 result）—— 用户态 UAF 命中线索，降 iters 复现定位"));
  if (jr.stillRunning.length) print("[M1] ⚠ 仍有 worker 未跑完，可 threadStop() 后再 join");
}
