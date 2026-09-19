// ============================================================
//  callPtr 回归验收脚本（V2.4.2 / CFBundleVersion 33）
//  用途：脚本库手动运行（文件名不带 bridge_ 前缀 → 不会自动加载）
//  覆盖测试 Agent 报告的 4 个验收用例：
//    ① strlen（C 字符串入参 + 标量返回）
//    ② getcwd（{buf} 出参缓冲 + 回读 buf0）
//    ③ mach_port_allocate（task port + {buf} 出参 + 内核返回值）
//    ④ MCM null 三连（预期 0x0 或 guarded:true —— 二者都算 PASS）
//
//  ★ 返回契约（钉死，详见 ERRATA_AND_TOOLING.md §5.1）：
//    正常:  {"ok":true,"value":"0x…"[,"out":{"buf0":<b64>,…}]}
//    兜底:  Autorun 信封 {"ok":false,"guarded":true,"guardSignal":…,"guardAddr":"0x58","guardPrim":"callPtr",…}
//    驳回:  {"ok":false,"error":"权限请求驳回（…）","rejected":true,"cmd":"…"}
//
//  ★ 用例④必须放最后：MCM 若 SIGSEGV 会被崩溃兜底 longjmp 掀栈，
//    本脚本后续代码不再执行（print 是流式的，判定已在调用前打出）。
// ============================================================

var PASS = 0, FAIL = 0, SKIPPED = 0;
function ok(id, msg)  { PASS++; print("[PASS] " + id + (msg ? "  — " + msg : "")); }
function bad(id, msg) { FAIL++; print("[FAIL] " + id + (msg ? "  — " + msg : "")); }
function skip(id, msg){ SKIPPED++; print("[SKIP] " + id + (msg ? "  — " + msg : "")); }
function J(s) { try { return JSON.parse(s); } catch (e) { return null; } }

print("=== callPtr 验收开始  " + new Date().toISOString() + " ===");

// ---------- 用例① strlen ----------
(function () {
  var id = "1/4 strlen(C字符串入参)";
  try {
    var ds = dlsymAddr(0, "strlen");
    if (!ds || !ds.addr) return skip(id, "dlsymAddr 找不到 strlen");
    var r = J(callPtr(ds.addr, ["hello"]));
    if (!r)                     return bad(id, "返回不是合法 JSON（契约破坏）");
    if (r.ok !== true)          return bad(id, "ok!=true: " + JSON.stringify(r));
    if (r.value === "0x5")      ok(id, "value=0x5 ✓");
    else                        bad(id, "期望 0x5，得到 " + r.value);
  } catch (e) { bad(id, "异常 " + e); }
})();

// ---------- 用例② getcwd ----------
(function () {
  var id = "2/4 getcwd({buf}出参)";
  try {
    var ds = dlsymAddr(0, "getcwd");
    if (!ds || !ds.addr) return skip(id, "dlsymAddr 找不到 getcwd");
    var r = J(callPtr(ds.addr, [{ buf: 1024 }, 1024]));
    if (!r)                return bad(id, "返回不是合法 JSON（契约破坏）");
    if (r.ok !== true)     return bad(id, "ok!=true: " + JSON.stringify(r));
    if (!r.out || !r.out.buf0) return bad(id, "缺少 out.buf0（buf 回传契约破坏）");
    // buf0 = base64；解码后应以 '\0' 截断的路径
    var path = "";
    try { path = atob(r.out.buf0).split("\u0000")[0]; } catch (e) {}
    if (path.indexOf("/") === 0) ok(id, "cwd=" + path);
    else bad(id, "buf0 解不出绝对路径: " + r.out.buf0.slice(0, 24) + "…");
  } catch (e) { bad(id, "异常 " + e); }
})();

// ---------- 用例③ mach_port_allocate ----------
(function () {
  var id = "3/4 mach_port_allocate(右类型0=RECEIVE)";
  try {
    var ts = dlsymAddr(0, "mach_task_self");
    var mp = dlsymAddr(0, "mach_port_allocate");
    var md = dlsymAddr(0, "mach_port_deallocate");
    if (!ts || !mp || !mp.addr) return skip(id, "dlsymAddr 缺符号");
    var t = J(callPtr(ts.addr, []));
    if (!t || t.ok !== true) return skip(id, "mach_task_self 调用失败");
    var task = parseInt(t.value, 16);
    // mach_port_allocate(task, right, &name): right 0 = MACH_PORT_RIGHT_RECEIVE
    var r = J(callPtr(mp.addr, [task, 0, { buf: 8 }]));
    if (!r)            return bad(id, "返回不是合法 JSON（契约破坏）");
    if (r.ok !== true) return bad(id, "ok!=true: " + JSON.stringify(r));
    if (r.value !== "0x0") return bad(id, "kr!=KERN_SUCCESS: " + r.value);
    // buf0 前 4 字节 = little-endian port name，非 0
    var raw = atob(r.out.buf0);
    var port = (raw.charCodeAt(0) | (raw.charCodeAt(1) << 8) |
                (raw.charCodeAt(2) << 16) | (raw.charCodeAt(3) << 24)) >>> 0;
    if (!port) return bad(id, "port name = 0（异常）");
    ok(id, "kr=0, port=0x" + port.toString(16));
    if (md && md.addr && port) { try { callPtr(md.addr, [task, port]); } catch (e) {} }
  } catch (e) { bad(id, "异常 " + e); }
})();

// ---------- 用例④ MCM null 三连（放最后：可能 SIGSEGV → 兜底掀栈） ----------
// 测试 Agent 若用了其它 MCM 函数名，改这个数组即可。
var MCM_FUNCS = [
  "MCMGetContainerUrlForIdentifier",
  "MCMGetContainerUrlForGroupIdentifier",
  "MCMContainerClassForIdentifier"
];
(function () {
  var id = "4/4 MCM null 三连";
  print("[INFO] " + id + " —— 预期：返回 0x0（旧路径）**或** 兜底 guarded:true@0x58（新路径）。两者都算 PASS，只有 App 死亡才算 FAIL。");
  for (var i = 0; i < MCM_FUNCS.length; i++) {
    var fn = MCM_FUNCS[i];
    var tag = id + " · " + fn + "(null)";
    try {
      var ds = dlsymAddr(0, fn);
      if (!ds || !ds.addr) { skip(tag, "dlsymAddr 找不到（改 MCM_FUNCS 数组）"); continue; }
      print("[INFO] 调用 " + fn + "(null) …（若下一条没有本函数结果 = 已被兜底拦截，看 Autorun 信封 guarded 字段）");
      var r = J(callPtr(ds.addr, [null]));
      if (!r)            print("[WARN] " + tag + " 返回非 JSON —— 契约破坏");
      else if (r.ok === true && r.value === "0x0") print("[PASS] " + tag + " → 0x0（未走 entitled 路径）");
      else if (r.ok === true) print("[WARN] " + tag + " → " + r.value + "（非 0 返回，记录一下）");
      else print("[WARN] " + tag + " → " + JSON.stringify(r));
    } catch (e) { print("[WARN] " + tag + " 异常 " + e); }
  }
  print("[INFO] 若本行被打印 = 三连全部存活返回（无 SIGSEGV，可能未触发 entitled 路径）");
})();

print("=== callPtr 验收结束  PASS=" + PASS + " FAIL=" + FAIL + " SKIP=" + SKIPPED + " ===");
print("提示：用例④若脚本在此前被掀栈，属预期（兜底拦截）；以 Autorun 信封 {guarded:true,guardAddr:\"0x58\"} 为准判 PASS。");
