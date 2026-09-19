// bridge_iokit.js — DM-ROOT V3 IOKit 可达性桥 (v4.2, 2026-09-18 起含 Bug6 自解释错误)
// 原生 iokitOpen(cls,type) 返回数字:
//   >0           = 连接句柄 (沙盒成功打开! V3 命中)
//   -2           = 服务类不存在 (名错/未注册)
//   -3           = 类名为空 (参数错, v4.2 新增)
//   -536870174   = 0xe00002e2 kIOReturnNotPermitted (沙盒门禁挡死)
//   -9999        = 原生抛异常
//   其它负值     = 其它 kr 错误码
// 安装: RyConsole → 资源管理器 → 🔌 安装桥… → 名字取 "iokit" (自动存成 bridge_iokit.js, 覆盖内置版)
var BRIDGE_VERSION = "v4.2 (build 2026-09-18)"; // 包体版本：每次改桥都递增，方便真机核对跑的是哪版
// 自报版本：加载后可在设备上一次性查"每个桥跑的是哪版" —— return JSON.stringify(RYC_BRIDGES)
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_iokit"] = BRIDGE_VERSION;

var V3_KR_NOTPERMITTED = -536870174; // 0xe00002e2 (有符号 32 位真值)
var V3_KR_BADARGUMENT  = -536870206; // 0xe00002c2
var V3_KR_BADMSGID     = -536870202; // 0xe00002c6
var V3_KR_UNSUPPORTED  = -536870201; // 0xe00002c7
var V3_KR_NOTFOUND     = -2;
var V3_KR_EMPTYCLASS   = -3;
var V3_KR_EXC          = -9999;

// ---------------------------------------------------------------------------
// Bug6: IOReturn 自解释解码
//   表值取自 IOKit/IOKitReturn.h（本机已实测核对过 3 个:
//   0xe00002c2 BadArgument / 0xe00002c6 BadMessageID / 0xe00002e2 NotPermitted）
//   HINT 是重点 —— 不只报名字，还要能据此改对参数/换路线
// ---------------------------------------------------------------------------
var IOKIT_KR = {
  "e00002bc": "kIOReturnError",
  "e00002bd": "kIOReturnNoMemory",
  "e00002be": "kIOReturnNoResources",
  "e00002bf": "kIOReturnIPCError",
  "e00002c0": "kIOReturnNoDevice",
  "e00002c1": "kIOReturnNotPrivileged",
  "e00002c2": "kIOReturnBadArgument",
  "e00002c3": "kIOReturnLockedRead",
  "e00002c4": "kIOReturnLockedWrite",
  "e00002c5": "kIOReturnExclusiveAccess",
  "e00002c6": "kIOReturnBadMessageID",
  "e00002c7": "kIOReturnUnsupported",
  "e00002c8": "kIOReturnVMError",
  "e00002c9": "kIOReturnInternalError",
  "e00002ca": "kIOReturnIOError",
  "e00002cc": "kIOReturnCannotLock",
  "e00002cd": "kIOReturnNotOpen",
  "e00002ce": "kIOReturnNotReadable",
  "e00002cf": "kIOReturnNotWritable",
  "e00002d0": "kIOReturnNotAligned",
  "e00002d1": "kIOReturnBadMedia",
  "e00002d2": "kIOReturnStillOpen",
  "e00002d5": "kIOReturnBusy",
  "e00002d6": "kIOReturnTimeout",
  "e00002d7": "kIOReturnOffline",
  "e00002d8": "kIOReturnNotReady",
  "e00002d9": "kIOReturnNotAttached",
  "e00002da": "kIOReturnNoChannels",
  "e00002db": "kIOReturnNoSpace",
  "e00002e2": "kIOReturnNotPermitted",
  "e00002e6": "kIOReturnUnsupportedMode",
  "e00002eb": "kIOReturnAborted",
  "e00002f0": "kIOReturnNotFound"
};

var IOKIT_KR_HINT = {
  "e00002c1": "iOS 沙盒/entitlement 不足，非私有 API 能解",
  "e00002c2": "参数形状被拒：驱动的 check* 字段不认这个 (selector, 标量个数, struct 大小) 组合 → 换输入形状，或先用空输入试",
  "e00002c5": "设备被独占（已有别的连接持有）",
  "e00002c6": "selector 无效（该方法不存在）→ 换 selector",
  "e00002c7": "该 UserClient 根本不提供这条路径（disabled/stub）→ 别重试，换类或换路线",
  "e00002cd": "连接已关闭：conn 已 iokitClose，或服务被回收 → 重新 iokitOpen",
  "e00002d9": "未附着态（close 交界过渡码）：close 释放与引用清算交界的正常返回，竞态 harness 高频 open/close 下常见，通常不是漏洞证据",
  "e00002db": "输出缓冲太小 → 传更大的 outSize（iokitCallStruct 已会自动按内核回报值重试一次）",
  "e00002e2": "沙盒/entitlement 门禁挡死（kIOReturnNotPermitted）",
  "e00002f0": "句柄/程序不存在（可能已释放）"
};

function krHex(kr) { return "0x" + (kr >>> 0).toString(16); }
function krName(kr) {
  if (kr === 0) return "kIOReturnSuccess";
  return IOKIT_KR[(kr >>> 0).toString(16)] || ("未收录码 " + (kr >>> 0).toString(16));
}
// iokitOpen 专用哨兵（不是 kr，别当错误码去解 hex）
var IOKIT_OPEN_SENTINEL = {
  "-2":    "NOT_FOUND —— 服务类不存在（类名错/未注册）",
  "-3":    "EMPTY_CLASS —— 类名为空（参数错，不是类不存在）",
  "-9999": "EXC —— 原生抛异常（看 native 日志）"
};

// 一行式：名字 + hex + 该怎么办（探针输出直接用这个，别自己拼）
function krWhy(kr) {
  var sent = IOKIT_OPEN_SENTINEL[String(kr)];
  if (sent) return "iokitOpen 哨兵 " + kr + " = " + sent;
  var h = IOKIT_KR_HINT[(kr >>> 0).toString(16)];
  return krName(kr) + " (" + krHex(kr) + ")" + (h ? " — " + h : "");
}

// ---------------------------------------------------------------------------
// 打开探针
// ---------------------------------------------------------------------------
function jbIokitVerdict(r) {
  if (typeof r === "undefined" || r === null) return "ERR(null)";
  if (typeof r !== "number") return "UNKNOWN(" + r + ")";
  if (r > 0) return "★ OPEN_OK (conn=" + r + ", 沙盒可达! V3 命中)";
  if (r === V3_KR_NOTFOUND) return "NOT_FOUND (类不存在/名错)";
  if (r === V3_KR_EMPTYCLASS) return "EMPTY_CLASS (类名为空 —— 参数错, 不是类不存在)";
  if (r === V3_KR_EXC) return "EXC 原生抛异常";
  return "DENIED " + krWhy(r);
}

// className 必须是非空字符串；type 是 UserClient 类型(uint32，常见 0..5)
// 返回 { cls, type, result, verdict, closed } 或 { error:"[jbProbeIOKit error] …" }
function jbProbeIOKit(className, type) {
  if (typeof className !== "string" || className.length === 0)
    return { cls: String(className), type: type, verdict: "ERR",
             error: "[jbProbeIOKit error] className must be a non-empty string, e.g. 'IOSurfaceRoot'" };
  if (type === undefined || type === null) type = 0;
  if (typeof type !== "number" || type < 0 || type > 4294967295)
    return { cls: className, type: type, verdict: "ERR",
             error: "[jbProbeIOKit error] type must be uint32 (0..4294967295, 常见 0..5), got " + type };
  try {
    var r = iokitOpen(className, type);
    var closed = false;
    if (typeof r === "number" && r > 0) { try { iokitClose(r); closed = true; } catch (e) {} } // 探针后归还连接
    return { cls: className, type: type, result: r, verdict: jbIokitVerdict(r), closed: closed };
  } catch (e) {
    return { cls: className, type: type, error: String(e) };
  }
}

// V3 电池测试: 27 B2 kernelcache 静态审计点名的候选类
//   AGXAccelerator / AGXDevice  : H3 AGXUAT 主类
//   VCPDRMUserClient / AppleVCP : H15 VCPDRM (静态判为"内核敞开"候选)
//   IOSurfaceRootUserClient     : IOSurface 内核相邻面 (H3 入口)
//   IOGPUDevice / IOSession     : F5 session-slot 候选
//   AppleM2Scaler / AppleARMIO  : 其它高风险 UserClient
function jbV3Battery() {
  var targets = [
    ["AGXAccelerator", 0],
    ["AGXDevice", 0],
    ["VCPDRMUserClient", 0],
    ["AppleVCP", 0],
    ["IOSurfaceRootUserClient", 0],
    ["IOGPUDevice", 0],
    ["IOSession", 0],
    ["AppleM2Scaler", 0],
    ["AppleARMIO", 0]
  ];
  return targets.map(function (t) { return jbProbeIOKit(t[0], t[1]); });
}

// 打印版: 控制台直接 jbV3Report()
function jbV3Report() {
  if (typeof iokitOpen !== "function") {
    return "[bridge_iokit] iokitOpen 不可用 —— 请先重签含 iokitOpen 的 IPA。";
  }
  var rows = jbV3Battery();
  var hits = 0;
  var out = "[V3 IOKit 可达性电池测试]\n";
  rows.forEach(function (r) {
    var v = r.error ? ("ERR " + r.error) : r.verdict;
    if (v.indexOf("OPEN_OK") >= 0) hits++;
    out += "  " + r.cls + " (t=" + r.type + ") => " + v + "\n";
  });
  out += "合计: " + hits + "/" + rows.length + " 沙盒可达 (OPEN_OK = V3 命中)\n";
  out += (hits > 0)
    ? "➡ V3 路线可行: 普通沙盒 App 能打开上述 UserClient, 推进 H3/H15/F5。"
    : "➡ 当前候选全被沙盒门禁挡死, V3 需换思路 (或须先有 entitlement/内核R/W)。";
  return out;
}

// 附加: 枚举沙盒用户态能"看到"的全部 IOKit 类 (攻击面地图)
function jbIokitEnum() {
  if (typeof iokitEnum !== "function") return "[bridge_iokit] iokitEnum 不可用 (需重签含 iokitEnum 的 IPA)。";
  try { return iokitEnum(); } catch (e) { return "ERR " + e; }
}

// ---------------------------------------------------------------------------
// Bug6: iokitMap 自解释
//   背景：原生 iokitMap(conn, memType) 对所有形态都回 kIOReturnBadArgument 时，
//         只看那一个数字完全无法推断"要传什么"。这里补上扫描 + 结论。
//   注意：每扫中一个 memType 都会在本进程留下一次映射（原生未暴露 Unmap），
//         所以只当诊断用、别在循环里反复扫。
//   types 默认 [0..15]
// ---------------------------------------------------------------------------
function iokitMapTry(conn, types) {
  if (typeof conn !== "number" || conn <= 0)
    return { ok: false, error: "[iokitMapTry error] conn must be a handle from iokitOpen() (>0), got " + conn };
  if (types === undefined || types === null) {
    types = [];
    for (var i = 0; i <= 15; i++) types.push(i);
  }
  if (!(types instanceof Array) || types.length === 0)
    return { ok: false, error: "[iokitMapTry error] types must be a non-empty array of uint32, e.g. [0,1,2]" };
  // 先整体校验再动手：参数错时不留半截映射（映射没有 Unmap 原语，泄漏就是泄漏）
  for (var v = 0; v < types.length; v++) {
    if (typeof types[v] !== "number" || types[v] < 0 || types[v] > 4294967295)
      return { ok: false, error: "[iokitMapTry error] types[" + v + "] must be uint32 0..4294967295, got " + types[v]
               + "（未开始扫描，无副作用）" };
  }
  var hits = [], tried = 0, lastErr = null, sample = null;
  for (var j = 0; j < types.length; j++) {
    var t = types[j];
    var r;
    try { r = iokitMap(conn, t); }
    catch (e) { return { ok: false, error: "[iokitMapTry error] iokitMap 抛异常: " + e }; }
    tried++;
    if (r && r.ok && r.addr) hits.push({ memType: t, addr: r.addr, size: r.size });
    else if (r && r.error) { lastErr = r.error; if (!sample) sample = r; }
  }
  var verdict = hits.length
    ? ("★ 可用 memType: " + hits.map(function (h) { return h.memType; }).join(", ") + " —— 直接用 iokitMap(conn, memType) 取地址")
    : ("0.." + (tried - 1) + " 全无内存对象 → 该 UserClient 未实现 clientMemoryForType；换类或换路线"
       + "（IOSurface 不必 map，直接 IOSurfaceGetBaseAddress）");
  return { conn: conn, ok: true, tried: tried, hits: hits, verdict: verdict,
           lastError: lastErr, lastHint: sample ? sample.hint : null };
}

// ---------------------------------------------------------------------------
// V3 方法级可达性原语 (v4)
// 直接复用原生 iokitOpen / iokitCall / iokitClose，无需重编原生层。
// open -> externalMethod(IOConnectCallMethod, 标量输入) -> close 一步到位。
//   cls    : 类名 (非空字符串)
//   type   : UserClient 类型 (uint32, 默认 0)
//   sel    : externalMethod selector (uint32)
//   inputs : 标量数组 (最多 16 个 uint64 数字)；Phase1 用空/零输入，不传内核指针
// 返回: { cls, type, sel, kr, outputs, stage, verdict, hint, closed }
//   stage="open" 且 kr<=0 => 打开阶段失败 (类不在 OPEN_OK 集合)
//   stage="call"            => 方法已调用, kr 为 IOConnectCallMethod 返回值
// ---------------------------------------------------------------------------
function jbV3MethodCall(cls, type, sel, inputs) {
  if (typeof cls !== "string" || cls.length === 0)
    return { cls: String(cls), stage: "arg", verdict: "ERR",
             error: "[jbV3MethodCall error] cls must be a non-empty string, e.g. 'IOSurfaceRoot'" };
  if (type === undefined || type === null) type = 0;
  if (typeof type !== "number" || type < 0 || type > 4294967295)
    return { cls: cls, stage: "arg", verdict: "ERR",
             error: "[jbV3MethodCall error] type must be uint32 (默认 0), got " + type };
  if (typeof sel !== "number" || sel < 0 || sel > 4294967295)
    return { cls: cls, stage: "arg", verdict: "ERR",
             error: "[jbV3MethodCall error] sel must be uint32 (0..4294967295), got " + sel };
  inputs = inputs || [];
  if (!(inputs instanceof Array))
    return { cls: cls, stage: "arg", verdict: "ERR",
             error: "[jbV3MethodCall error] inputs must be an array of numbers (≤16), got " + (typeof inputs) };
  if (inputs.length > 16)
    return { cls: cls, stage: "arg", verdict: "ERR",
             error: "[jbV3MethodCall error] inputs.length must be ≤16 (标量输入上限), got " + inputs.length };

  try {
    var conn = iokitOpen(cls, type);
    if (typeof conn !== "number" || conn <= 0) {
      return { cls: cls, type: type, sel: sel, kr: (conn | 0), stage: "open",
               verdict: "OPEN_FAIL(" + (conn | 0) + "): " + jbIokitVerdict(conn),
               hint: "打开阶段就失败 → 该类不在 OPEN_OK 集合，方法级无从谈起",
               closed: false };
    }
    var res = (typeof iokitCall === "function") ? iokitCall(conn, sel, inputs) : null;
    var kr = (res && typeof res.ret === "number") ? res.ret : -1;
    var outs = (res && res.outputs) ? res.outputs : [];
    var closed = false;
    try { if (typeof iokitClose === "function") iokitClose(conn); closed = true; } catch (e) {}
    var verdict, hint = krHintCarrier(kr);
    if (kr === 0) { verdict = "★ SUCCESS (方法可调! V3 候选)"; hint = "selector " + sel + " 真实存在且接受该输入形状"; }
    else if (kr === V3_KR_NOTPERMITTED) verdict = "NOT_PERMITTED(方法可达但被 entitlement 挡)";
    else if (kr === V3_KR_BADMSGID) verdict = "BAD_MESSAGE_ID(selector 无效, 方法不存在)";
    else if (kr === V3_KR_BADARGUMENT) verdict = "BAD_ARG(方法存在但参数形状被拒 -> Phase2 喂参/iokitCallStruct)";
    else verdict = "OTHER " + krWhy(kr);
    var outStruct = (res && res.outStruct) ? res.outStruct : null;
    return { cls: cls, type: type, sel: sel, kr: kr, outputs: outs, outStruct: outStruct,
             stage: "call", verdict: verdict, hint: hint, closed: closed,
             note: (res && res.note) ? res.note : null };
  } catch (e) {
    return { cls: cls, type: type, sel: sel, error: String(e), stage: "call", closed: false };
  }
}

// jbV3MethodCall 用：给 kr 配套的"下一步"提示（BUG6：错误串要能指导改参数）
function krHintCarrier(kr) {
  if (kr === V3_KR_BADARGUMENT)
    return "驱动的 check* 字段不认这个 (selector, 标量个数, struct 大小) → 换标量个数，或用 iokitCallStruct 喂 struct";
  if (kr === V3_KR_NOTPERMITTED) return "沙盒门禁：需要 entitlement，纯用户态无解";
  if (kr === V3_KR_BADMSGID) return "换 selector：该 selector 未在 dispatch table 注册";
  return krHint(kr);
}

print("[bridge_iokit] 已加载: jbProbeIOKit / jbV3Battery / jbV3Report / jbIokitEnum / jbV3MethodCall"
      + " / iokitMapTry / krName / krWhy (" + BRIDGE_VERSION + ")");
