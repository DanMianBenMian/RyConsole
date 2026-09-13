// bridge_info.js — 身份/权限桥库（动态层：改此文件无需重编译 IPA）
// 依赖原生原语：appInfo / getPid / getEntitlements（main.m 已注册为全局）

// 一次性打印进程身份 + 运行时 entitlements（沙盒自省）
function dumpIdentity() {
  return "=== identity ===\n" + appInfo() + "pid=" + getPid() + "\n--- entitlements ---\n" + getEntitlements();
}
function dumpEntitlements(){ return getEntitlements(); }
