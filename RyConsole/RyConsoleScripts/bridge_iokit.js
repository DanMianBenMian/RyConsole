// bridge_iokit.js — DM-ROOT V3 IOKit 可达性桥 (修正版, 匹配 #4 原生 iokitOpen 数字契约)
// 原生 iokitOpen(cls,type) 返回数字:
//   >0           = 连接句柄 (沙盒成功打开! V3 命中)
//   -2           = 服务类不存在 (名错/未注册)
//   -536870194   = 0xe00002e2 kIOReturnNotPermitted (沙盒门禁挡死)
//   -9999        = 原生抛异常
//   其它负值     = 其它 kr 错误码
// 安装: RyConsole → 脚本库 → 🔌 安装桥… → 名字取 "iokit" (自动存成 bridge_iokit.js, 覆盖内置的 bug 版)

var V3_KR_NOTPERMITTED = -536870174; // 0xe00002e2 (有符号 32 位真值；原 -536870194 差 0x14 系计算错)
var V3_KR_NOTFOUND = -2;
var V3_KR_EXC = -9999;
var BRIDGE_VERSION = "v4.1 (build 2026-08-12)"; // 包体版本：每次改桥都递增，方便真机核对跑的是哪版

function jbIokitVerdict(r) {
  if (typeof r === "undefined" || r === null) return "ERR(null)";
  if (typeof r !== "number") return "UNKNOWN(" + r + ")";
  if (r > 0) return "★ OPEN_OK (conn=" + r + ", 沙盒可达! V3 命中)";
  if (r === V3_KR_NOTFOUND) return "NOT_FOUND (类不存在/名错)";
  if (r === V3_KR_NOTPERMITTED) return "DENIED kIOReturnNotPermitted(0xe00002e2) 沙盒门禁挡死";
  if (r === V3_KR_EXC) return "EXC 原生抛异常";
  return "DENIED kr=" + r + " (0x" + (r >>> 0).toString(16) + ")";
}

function jbProbeIOKit(className, type) {
  type = type || 0;
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
    return "[bridge_iokit] iokitOpen 不可用 —— 请先重签含 iokitOpen 的 IPA (#3/#4)。";
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
  if (typeof iokitEnum !== "function") return "[bridge_iokit] iokitEnum 不可用 (需 #4 IPA)。";
  try { return iokitEnum(); } catch (e) { return "ERR " + e; }
}

// ---- V3 方法级可达性原语 (v4 新增) ----
// 直接复用原生 iokitOpen / iokitCall / iokitClose，无需重编原生层。
// open -> externalMethod(IOConnectCallMethod, 标量输入) -> close 一步到位。
//   cls    : 类名 (字符串)
//   type   : UserClient 类型 (默认 0)
//   sel    : externalMethod selector (uint32)
//   inputs : 标量数组 (最多 16 个 uint64)；Phase1 用空/零输入，不传内核指针。
// 返回: { cls, type, sel, kr, outputs, stage, verdict, closed }
//   stage="open" 且 kr<=0 => 打开阶段失败 (类不在 OPEN_OK 集合)
//   stage="call"            => 方法已调用, kr 为 IOConnectCallMethod 返回值
function jbV3MethodCall(cls, type, sel, inputs) {
  type = type || 0;
  inputs = inputs || [];
  try {
    var conn = iokitOpen(cls, type);
    if (typeof conn !== "number" || conn <= 0) {
      return { cls: cls, type: type, sel: sel, kr: (conn | 0), stage: "open",
               verdict: "OPEN_FAIL(" + (conn | 0) + ")", closed: false };
    }
    var res = (typeof iokitCall === "function") ? iokitCall(conn, sel, inputs) : null;
    var kr = (res && typeof res.ret === "number") ? res.ret : -1;
    var outs = (res && res.outputs) ? res.outputs : [];
    var closed = false;
    try { if (typeof iokitClose === "function") iokitClose(conn); closed = true; } catch (e) {}
    var verdict;
    if (kr === 0) verdict = "★ SUCCESS (方法可调! V3 候选)";
    else if (kr === V3_KR_NOTPERMITTED) verdict = "NOT_PERMITTED(沙盒门禁, 方法可达但被 entitlement 挡)";
    else if (kr === -536870202) verdict = "BAD_MESSAGE_ID(selector 无效, 方法不存在)";
    else if (kr === -536870206) verdict = "BAD_ARG(方法存在/跑了, 参数拒 -> Phase2 喂参)";
    else verdict = "OTHER kr=" + kr + " (0x" + (kr >>> 0).toString(16) + ")";
    return { cls: cls, type: type, sel: sel, kr: kr, outputs: outs, stage: "call",
             verdict: verdict, closed: closed };
  } catch (e) {
    return { cls: cls, type: type, sel: sel, error: String(e), stage: "call", closed: false };
  }
}

print("[bridge_iokit] 已加载: jbProbeIOKit / jbV3Battery / jbV3Report / jbIokitEnum / jbV3MethodCall (" + BRIDGE_VERSION + ")");
