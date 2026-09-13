// bridge_xpc.js — XPC 结构化桥 + 研究原语包（V2 扩展，2026-09-13）
// 依赖 main.m 原生全局: xpcConn/xpcSendMsg/xpcClose/machLookUp/dlopenFW/dlsymAddr/
//                       sandboxCheck/keychainProbe/procListPids/posixSpawn
// 原生侧错误码/原始返回值原样回传；本桥只做便捷封装与语义命名，不做解读。
var SCRIPT_VERSION = "bridge_xpc v1.0 (build 2026-09-13)";

// 常见 XPC 错误事件 → 语义名（对端崩溃/拒绝/超时时 reply 会是 "<error>" 类字符串）
var XPC_ERR = {
  "connection-invalid": "服务名错或服务未注册",
  "peer-terminated":    "对端处理时崩溃/退出（后续消息可能仍在）",
  "timed-out":          "对端收到但未按时回",
  "code-attachment-invalid": "附件非法"
};

// 一次性结构化调用: 连接 → 发送 → 等回传 → 关闭（探针最常用姿势）
// msg 为任意可 JSON 化嵌套对象；timeoutSec 默认 2.5，<=0 表示只发不收
function xpcCall(svc, msg, timeoutSec) {
  print("[xpcCall] → " + svc + " timeout=" + (timeoutSec === undefined ? 2.5 : timeoutSec));
  var c = xpcConn(svc);
  if (c.err) return { stage: "conn", err: c.err };
  var h = c.h;
  try {
    var r = xpcSendMsg(h, msg, timeoutSec === undefined ? 2.5 : timeoutSec);
    if (r && r.err) r.stage = "send/recv";
    return r;
  } finally {
    xpcClose(h);
  }
}

// bootstrap 可达性矩阵: 批量查服务名，回传 {name: {kr, port}}
function machScan(svcNames) {
  var out = {};
  for (var i = 0; i < svcNames.length; i++) {
    var n = svcNames[i];
    out[n] = machLookUp(n);
    if (out[n].kr === 0) print("[machScan] " + n + " → port " + out[n].port);
  }
  return out;
}

// 符号解析快捷: dlopen 私有框架 + dlsym 一次搞定（每次新 handle，用完自动不关——句柄留给后续调用）
// fwPath 形如 /System/Library/PrivateFrameworks/Foo.framework/Foo
function symResolve(fwPath, symNames) {
  var dl = dlopenFW(fwPath, 0);
  if (dl.err) return { stage: "dlopen", fw: fwPath, err: dl.err };
  var out = { fw: fwPath, h: dl.h, syms: {} };
  for (var i = 0; i < symNames.length; i++) {
    out.syms[symNames[i]] = dlsymAddr(dl.h, symNames[i]);
  }
  return out;
}

// 钥匙串批量探针: 对多个 service 查 genp 类，回传 status 矩阵（-25300=不存在 0=存在可读）
function keychainScan(services) {
  var out = {};
  for (var i = 0; i < services.length; i++) {
    var s = services[i];
    var r = keychainProbe("genp", s, null);
    out[s] = r.status;
    if (r.status === 0) print("[keychainScan] " + s + " EXISTS(可读)");
  }
  return out;
}

// 沙盒操作矩阵: 常用 operation 一把梭，回传原始 ret（语义自行比对）
function sandboxScan(ops) {
  ops = ops || ["file-read-data", "file-write-data", "mach-lookup", "process-exec", "network-outbound"];
  var out = {};
  for (var i = 0; i < ops.length; i++) out[ops[i]] = sandboxCheck(ops[i]);
  return out;
}

print("[bridge_xpc] 已加载: xpcCall/machScan/symResolve/keychainScan/sandboxScan + 原生 xpcConn/xpcSendMsg/xpcClose/machLookUp/dlopenFW/dlsymAddr/sandboxCheck/keychainProbe/procListPids/posixSpawn (v1.0)");
