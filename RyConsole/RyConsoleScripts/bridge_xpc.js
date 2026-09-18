// bridge_xpc.js — XPC 结构化桥 + 研究原语包（v1.1, 2026-09-18 起含 Bug6 自解释错误）
// 依赖 main.m 原生全局: xpcConn/xpcSendMsg/xpcClose/machLookUp/dlopenFW/dlsymAddr/
//                       sandboxCheck/keychainProbe/procListPids/posixSpawn
// 原生侧错误码/原始返回值原样回传；本桥做便捷封装 + 参数校验 + 语义命名。
var BRIDGE_VERSION = "v1.1 (build 2026-09-18)";
var SCRIPT_VERSION = "bridge_xpc " + BRIDGE_VERSION;

// 常见 XPC 错误事件 → 语义名（对端崩溃/拒绝/超时时 reply 会是 "<error>" 类字符串）
var XPC_ERR = {
  "connection-invalid": "服务名错或服务未注册",
  "peer-terminated":    "对端处理时崩溃/退出（后续消息可能仍在）",
  "timed-out":          "对端收到但未按时回",
  "code-attachment-invalid": "附件非法"
};

// ---- Bug6: 常见 kern_return_t（bootstrap / mach）→ 人话 ----
// 0..5 是 Mach 标准码；11xx 是 bootstrap 专用码（bootstrap.h）
var MACH_KR = {
  "0":    "OK（沙盒可见/可连）",
  "1":    "KERN_INVALID_ADDRESS",
  "2":    "KERN_PROTECTION_FAILURE 权限被拒",
  "3":    "KERN_NO_SPACE",
  "4":    "KERN_INVALID_ARGUMENT（服务名非法/为空）",
  "5":    "KERN_FAILURE（沙盒挡了这条 mach-lookup）",
  "1100": "BOOTSTRAP_NOT_PRIVILEGED",
  "1102": "BOOTSTRAP_UNKNOWN_SERVICE（服务未注册，或沙盒看不见它）",
  "1103": "BOOTSTRAP_SERVICE_ACTIVE",
  "1105": "BOOTSTRAP_NO_MEMORY"
};
function machKrWhy(kr) {
  var t = MACH_KR[String(kr >>> 0)];
  return "kr=" + kr + (t ? " " + t : "");
}

// 一次性结构化调用: 连接 → 发送 → 等回传 → 关闭（探针最常用姿势）
// msg 为任意可 JSON 化嵌套对象；timeoutSec 默认 2.5，<=0 表示只发不收
function xpcCall(svc, msg, timeoutSec) {
  if (typeof svc !== "string" || svc.length === 0)
    return { stage: "arg", error: "[xpcCall error] svc must be a non-empty service name string, e.g. 'com.apple.securityd'" };
  if (timeoutSec !== undefined && (typeof timeoutSec !== "number" || timeoutSec < 0))
    return { stage: "arg", error: "[xpcCall error] timeoutSec must be a number >= 0 (0 = 只发不收，默认 2.5)" };
  print("[xpcCall] → " + svc + " timeout=" + (timeoutSec === undefined ? 2.5 : timeoutSec));
  var c = xpcConn(svc);
  if (c.err) return { stage: "conn", err: c.err, hint: "连接阶段就失败，多为服务名错或沙盒挡了 mach-lookup（可先 machScan([svc]) 验证）" };
  var h = c.h;
  try {
    var r = xpcSendMsg(h, msg, timeoutSec === undefined ? 2.5 : timeoutSec);
    if (r && r.err) r.stage = "send/recv";
    return r;
  } finally {
    xpcClose(h);
  }
}

// bootstrap 可达性矩阵: 批量查服务名，回传 {name: {kr, port, reason?}}
// 成功路径保持旧形状（name → 结果对象）；调用失败时给 "[machScan error] …" 而不是抛异常
function machScan(svcNames) {
  if (!(svcNames instanceof Array) || svcNames.length === 0)
    return { error: "[machScan error] svcNames must be a non-empty array of service-name strings, e.g. ['com.apple.securityd']" };
  var out = {}, skipped = [];
  for (var i = 0; i < svcNames.length; i++) {
    var n = svcNames[i];
    if (typeof n !== "string" || n.length === 0) { skipped.push(i); continue; }
    var r = machLookUp(n) || {};
    if (typeof r.kr === "number" && r.kr !== 0) r.reason = machKrWhy(r.kr);
    out[n] = r;
    if (r.kr === 0) print("[machScan] " + n + " → port " + r.port);
    else print("[machScan] " + n + " → " + machKrWhy(r.kr));
  }
  if (skipped.length) {
    print("[machScan] 跳过非法项（不是非空字符串）：索引 " + skipped.join(", "));
    // 不能静默：把跳过项放进返回结果（Bug1 的教训 —— 静默失败最难查）
    out["<invalid entries>"] = "[machScan error] svcNames 里第 " + skipped.join(",") + " 项不是非空字符串，已跳过";
  }
  return out;
}

// 符号解析快捷: dlopen 私有框架 + dlsym 一次搞定
// fwPath 必须是 .framework 里的**可执行文件**，如 /System/Library/PrivateFrameworks/Foo.framework/Foo
// （传 .framework 目录会 dlopen 失败）
function symResolve(fwPath, symNames) {
  if (typeof fwPath !== "string" || fwPath.length === 0)
    return { stage: "arg", error: "[symResolve error] fwPath must be a non-empty string, e.g. '/System/Library/PrivateFrameworks/Foo.framework/Foo'" };
  if (fwPath.charAt(0) !== "/")
    return { stage: "arg", error: "[symResolve error] fwPath 必须是**以 / 开头的绝对路径**（指向 .framework 里的可执行文件，不是 .framework 目录）: " + fwPath };
  if (!(symNames instanceof Array) || symNames.length === 0)
    return { stage: "arg", error: "[symResolve error] symNames must be a non-empty array of symbol-name strings, e.g. ['_foo']" };
  var dl = dlopenFW(fwPath, 0);
  if (dl.err) return { stage: "dlopen", fw: fwPath, err: dl.err,
                       hint: "dlopen 失败：路径必须是 .framework/<二进制名>（非目录）、且沙盒允许读取该框架" };
  var out = { fw: fwPath, h: dl.h, syms: {} };
  var miss = [];
  for (var i = 0; i < symNames.length; i++) {
    var nm = symNames[i];
    if (typeof nm !== "string" || nm.length === 0) { miss.push("<索引 " + i + " 不是非空字符串>"); continue; }
    var a = dlsymAddr(dl.h, nm);
    out.syms[nm] = a;
    if (!a) { miss.push(nm); out.syms[nm] = "0x0 [not found: dlsym 返回 NULL —— 符号名错，或该框架不导出它（私有 C++ 符号多带 _ZN… 前缀）]"; }
  }
  if (miss.length) out.notFound = miss;
  return out;
}

// 钥匙串批量探针: 对多个 service 查 genp 类，回传 status 矩阵（-25300=不存在 0=存在可读）
function keychainScan(services) {
  if (!(services instanceof Array) || services.length === 0)
    return { error: "[keychainScan error] services must be a non-empty array of keychain service-name strings" };
  var out = {};
  for (var i = 0; i < services.length; i++) {
    var s = services[i];
    if (typeof s !== "string" || s.length === 0) { out["<索引 " + i + ">"] = "[keychainScan error] 不是非空字符串"; continue; }
    var r = keychainProbe("genp", s, null);
    out[s] = r.status;
    if (r.status === 0) print("[keychainScan] " + s + " EXISTS(可读)");
    else if (r.status !== -25300) print("[keychainScan] " + s + " status=" + r.status);
  }
  return out;
}

// 沙盒操作矩阵: 常用 operation 一把梭，回传原始 ret（语义自行比对）
// operation 名如 file-read-data / file-write-data / mach-lookup / process-exec / network-outbound
function sandboxScan(ops) {
  ops = ops || ["file-read-data", "file-write-data", "mach-lookup", "process-exec", "network-outbound"];
  if (!(ops instanceof Array) || ops.length === 0)
    return { error: "[sandboxScan error] ops must be a non-empty array of sandbox operation strings" };
  var out = {};
  for (var i = 0; i < ops.length; i++) {
    if (typeof ops[i] !== "string" || ops[i].length === 0) { out["<索引 " + i + ">"] = "[sandboxScan error] 不是非空字符串"; continue; }
    out[ops[i]] = sandboxCheck(ops[i]);
  }
  return out;
}

print("[bridge_xpc] 已加载: xpcCall/machScan/symResolve/keychainScan/sandboxScan"
      + " + 原生 xpcConn/xpcSendMsg/xpcClose/machLookUp/dlopenFW/dlsymAddr/sandboxCheck"
      + "/keychainProbe/procListPids/posixSpawn / machKrWhy (" + BRIDGE_VERSION + ")");
