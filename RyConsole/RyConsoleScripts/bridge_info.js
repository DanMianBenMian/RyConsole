// bridge_info.js — 身份/权限桥库（动态层：改此文件无需重编译 IPA）
// 依赖原生原语：appInfo / getPid / getEntitlements（main.m 已注册为全局）
// 版本规范（用户 2026-08-12 硬性要求）：每个桥顶部必须有版本号，末尾必须打印加载行。
var BRIDGE_VERSION = "v1.1 (build 2026-09-18)";
// 自报版本：加载后可在设备上一次性查"每个桥跑的是哪版" —— return JSON.stringify(RYC_BRIDGES)
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_info"] = BRIDGE_VERSION;
var SCRIPT_VERSION = "bridge_info " + BRIDGE_VERSION;

// 一次性打印进程身份 + 运行时 entitlements（沙盒自省）
function dumpIdentity() {
  return "=== identity ===\n" + appInfo() + "pid=" + getPid() + "\n--- entitlements ---\n" + getEntitlements();
}
function dumpEntitlements(){ return getEntitlements(); }

print("[bridge_info] 已加载: dumpIdentity / dumpEntitlements (" + BRIDGE_VERSION + ")");
