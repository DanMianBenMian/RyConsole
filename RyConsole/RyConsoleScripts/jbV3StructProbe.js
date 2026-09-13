// jbV3StructProbe.js — V3 (b) struct/OOL 输入探针
// ============================================================
// 硬性要求（2026-08-13 用户规定）：所有脚本输出须带包体版本号前缀 [PKG_VER]。
//   桥同理：[bridge_xxx] 已加载：xxx（见各 bridge_*.js 末尾加载行）。
//   本脚本所有 print 统一走 log()，自动加 [RyConsole#8] 前缀，便于真机核对跑的是哪版。
//
// 目的：对 5 个 OPEN_OK 类（沙盒已确认能 IOServiceOpen 拿到连接的 UserClient）建立 struct 输入通道，
//       枚举已知/候选 externalMethod selector 在"携带 inputStruct 字节"下的 kr 签名，
//       为 V3 ②（方法级可达性 / 是否真解析结构化输入）提供真实设备数据。
//
// 注意（最坏角度，不夸大）：
//   - 本探针只采集 (selector -> kr, outStructSize) 信号，不宣布任何漏洞或"路线活"。
//   - 部分 selector 收到畸形/零 struct 可能触发 UserClient 解析分支异常，研究机可承受 kernel panic/重启
//     （iOSurfaceRoot/IOSurfaceCreate 等尤为敏感）。若设备中途黑屏重启，属预期副作用，重跑剩余项即可。
//   - 真·OSData（如 IOSurfaceCreateArgs 序列化字典）构造是专项探针工作，不在本脚本；本脚本先用最小零块
//     探测 handler 是否对 inputStruct 做解析（返回非 BadArgument/Unsupported 即"到达 handler 逻辑"）。
//
// 用法：RyConsole → 资源管理器 → 脚本 → 新建/粘贴 → 保存 → 点击运行
//      （脚本存本地 Documents，不读 IPA 内置；需已装含 iokitCallStruct 原语的 #8 IPA）
// ============================================================

// ===== 包体版本号（硬性要求：所有输出须带此前缀）=====
var PKG_VER = "RyConsole#9";
function log(s) { print("[" + PKG_VER + "] " + s); }

// kr 字典：常见 IOKit 返回码 -> 语义
var KR = {
  0: "kIOReturnSuccess",
  0xe00002c2: "kIOReturnBadArgument",
  0xe00002c7: "kIOReturnNotReadable",
  0xe00002cb: "kIOReturnNoDevice",
  0xe00002cc: "kIOReturnNotOpen",
  0xe00002d2: "kIOReturnUnsupported",
  0xe00002e2: "kIOReturnNotPrivileged",
  0xe00002fe: "kIOReturnNotPermitted",
  0xe00002c9: "kIOReturnNoMemory",
  0xe00002ca: "kIOReturnNoResources"
};
function krStr(kr) {
  var h = "0x" + (kr >>> 0).toString(16);
  return KR[kr >>> 0] ? (h + " (" + KR[kr >>> 0] + ")") : h;
}

// 最小零块 inputStruct：16 字节全 0，足以触发 handler 对 inputStruct 的解析分支
function zeroStructB64(n) {
  n = n || 16;
  var z = [];
  for (var i = 0; i < n; i++) z.push(0);
  return bytesB64(z);
}

// 目标清单：[类名, type, [selector...]]
var TARGETS = [
  { cls: "IOSurfaceRoot",            type: 0, sels: [0,1,2,3,4,5,6,7,8,9,10,11,12] },
  { cls: "AppleKeyStore",            type: 0, sels: [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26] },
  { cls: "AppleJPEGDriver",          type: 0, sels: [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15] },
  { cls: "AppleCLCD2",               type: 0, sels: [0,1,2,3,4,5,6,7,8,9,10] },
  { cls: "AppleM2ScalerCSCDriver",   type: 0, sels: [0,1,2,3,4,5,6,7,8,9,10] }
];

var ZERO = zeroStructB64(16);
var report = [];

log("脚本正在执行：V3 IOKit struct/OOL 输入探针 —— 枚举 5 个 OPEN_OK 类(IOSurfaceRoot/AppleKeyStore/AppleJPEGDriver/AppleCLCD2/AppleM2ScalerCSCDriver)的候选 selector 并发送最小 struct 块, 采集 kr/outStructSize 签名以判定 V3 ② 方法级可达性");
log("开始 V3 struct 输入探针 (5 OPEN_OK 类)");
log("说明：kr=BadArgument/Unsupported 视为门禁拒绝；其它(尤其 Success/NotPrivileged/异常)需逐条人工判定");

for (var t = 0; t < TARGETS.length; t++) {
  var T = TARGETS[t];
  log("--- [" + (t + 1) + "/" + TARGETS.length + "] " + T.cls + " (type=" + T.type + ") ---");
  var conn = iokitOpen(T.cls, T.type);
  if (conn < 0) {
    log("  OPEN FAIL ret=" + conn + " （非 OPEN_OK 或沙盒不可达，跳过）");
    report.push({ cls: T.cls, open: conn, rows: null });
    continue;
  }
  log("  OPEN OK conn=" + conn);
  var rows = [];
  for (var s = 0; s < T.sels.length; s++) {
    var sel = T.sels[s];
    var r = iokitCallStruct(conn, sel, [], ZERO, 4096);
    var kr = r.ret >>> 0;
    var sz = (r.outStructSize !== undefined && r.outStructSize !== null) ? (r.outStructSize >>> 0) : 0;
    var hasOut = !!(r.outStruct && r.outStruct.length);
    var line = "  sel=" + sel + " -> " + krStr(kr) + " outStructSize=" + sz + (hasOut ? " hasOutStruct=YES" : "");
    log(line);
    rows.push({ sel: sel, kr: kr, outSize: sz, hasOut: hasOut });
  }
  iokitClose(conn);
  report.push({ cls: T.cls, open: conn, rows: rows });
}

// 汇总：非 BadArgument/Unsupported 的 selector = 到达 handler 逻辑（值得深挖，但非漏洞证据）
log("=== 汇总：到达 handler 逻辑的 selector（需人工逐条判定，非漏洞证据）===");
var interesting = 0;
for (var i = 0; i < report.length; i++) {
  var R = report[i];
  if (!R.rows) continue;
  for (var j = 0; j < R.rows.length; j++) {
    var rw = R.rows[j];
    if (rw.kr !== 0xe00002c2 && rw.kr !== 0xe00002d2) {
      log("  [" + R.cls + "] sel=" + rw.sel + " kr=" + krStr(rw.kr) +
            " outSize=" + rw.outSize + (rw.hasOut ? " hasOutStruct" : ""));
      interesting++;
    }
  }
}
log("interesting count=" + interesting + " （kIOReturnSuccess / NotPrivileged / 其它异常 kr 都算，不自动宣布路线活）");
log("脚本执行结束：V3 IOKit struct/OOL 输入探针");
