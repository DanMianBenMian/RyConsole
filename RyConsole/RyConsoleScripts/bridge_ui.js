// bridge_ui.js — URL scheme 桥库（动态层：改此文件无需重编译 IPA）
// 依赖原生原语：canOpenURL / openURL（main.m 已注册为全局）
var BRIDGE_VERSION = "v1.1 (build 2026-09-18)";
// 自报版本：加载后可在设备上一次性查"每个桥跑的是哪版" —— return JSON.stringify(RYC_BRIDGES)
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_ui"] = BRIDGE_VERSION;
var SCRIPT_VERSION = "bridge_ui " + BRIDGE_VERSION;

// 枚举哪些 scheme 系统里有 handler（URL scheme 派发面）
// schemes 可省略；给了就必须是非空字符串数组（元素错会点名索引）
function enumSchemes(schemes) {
  schemes = schemes || ["tel","sms","mailto","http","https","facetime","maps",
    "itms-services","prefs","weixin","alipay","mqq","dingtalk","lark","fb","instagram","twitter"];
  if (!(schemes instanceof Array) || !schemes.length)
    return { error: "[enumSchemes error] schemes must be a non-empty array of scheme strings (可省略)" };
  var out = [], bad = [];
  for (var i=0;i<schemes.length;i++) {
    if (typeof schemes[i] !== "string" || !schemes[i].length) { bad.push(i); continue; }
    var r;
    try { r = canOpenURL(schemes[i] + "://"); } catch (e) { continue; }
    if (r === "YES") out.push(schemes[i]);
  }
  if (bad.length) out.push("[enumSchemes error] schemes 里第 " + bad.join(",") + " 项不是非空字符串，已跳过");
  return out;
}

print("[bridge_ui] 已加载: enumSchemes (" + BRIDGE_VERSION + ")");
