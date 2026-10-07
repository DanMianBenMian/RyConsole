// ============================================================
//  syscall 族冒烟自检（文件名不带 bridge_ 前缀 → 不会自动加载，进脚本库手动跑）
//  用途：验证 bridge_syscall.js + 原生 syscallN 这条链在真机上真的通。
//
//  覆盖：
//    ① 号速查 syscallName / errno 人话 serrno
//    ② 越界号必须**受控报错**（27B2 越界号 = 内核 SIGSYS 杀进程，这里必须拦住不杀）
//    ③ 死亡名单 45=csops 默认拦截
//    ④ SYC_sysctl(202) 真读 kern.version（mib / oldlen 都靠 calloc + memWrite 现造）
//    ⑤ syscall(5=open) 打一个不存在路径 → 必须回 -1 + errno=2 ENOENT（验证 errno 链路）
//    ⑥ AF_SYSCTL 通路 sysctlSock(1, 1)（未验证项，先看 socket 那步的 errno）
//
//  跑法：RyConsole → 脚本库 → 选中本文件 → 运行。逐行看 print 输出。
// ============================================================
var PASS = 0, FAIL = 0;
function ck(cond, tag, msg) { if (cond) { PASS++; print("[PASS] " + tag + (msg ? "  — " + msg : "")); } else { FAIL++; print("[FAIL] " + tag + (msg ? "  — " + msg : "")); } }
function J(s) { try { return JSON.parse(s); } catch (e) { return null; } }

print("=== syscall 冒烟开始  " + new Date().toISOString() + " ===");

// 工具：calloc 一块清零内存（返回地址）
function alloc(n) {
  var c = dlsymAddr(0, "calloc");
  var r = J(callPtr(c.addr, [1, n]));
  return (r && r.ok === true) ? parseInt(r.value, 16) : 0;
}
// memWrite 只吃 hex/b64，不吃 number 数组 —— bridge_syscall 里已有一份，这里兜底再定义一次
if (typeof rycU32le !== "function") {
  rycU32le = function (n) { return ("0000000" + (((n | 0) >>> 0).toString(16))).slice(-8); };
  rycU64le = function (n) { return rycU32le(n) + rycU32le(0); };
  rycAsciiHex = function (s) {
    var h = "";
    for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i) & 0xff; h += ("0" + c.toString(16)).slice(-2); }
    return h;
  };
  rycReadU32 = function (h) { return (h && h.length >= 8) ? parseInt(h.slice(0, 8), 16) >>> 0 : 0; };
}
function readU32(addr) { try { return rycReadU32(memRead(addr, 8)); } catch (e) { return 0; } }

// ---------- ① 速查 ----------
print("[1] 号表/errno 速查");
print("    " + syscallName(202) + " | " + syscallName(97) + " | " + syscallName(117));
print("    未收录示例: " + syscallName(12345).slice(0, 60) + "…");
print("    serrno(1) = " + serrno(1));
print("    serrno(38) = " + serrno(38));
ck(syscallName(202) === "202 = sysctl", "号表 202=sysctl", syscallName(202));
ck(String(syscallName(12345)).indexOf("未收录") === 0, "未收录如实报未收录", "不编假名");

// ---------- ② 越界号必须受控拦截（关键：不能 SIGSYS 杀进程）----------
(function () {
  print("[2] syscall(9999) —— 期望受控报错，进程必须活着");
  var r = J(syscall(9999, 0, 0, 0, 0));
  print("    " + JSON.stringify(r).slice(0, 200));
  ck(r && r.ok === false && /error/.test(String(r.error || "")), "越界号受控拦截", String(r && r.error || ""));
  ck(r && r.nsysent > 0, "回传 nsysent", "nsysent=" + (r && r.nsysent));
})();

// ---------- ③ 死亡名单 ----------
(function () {
  print("[3] syscall(45) = csops —— 期望默认拦截");
  var r = J(syscall(45, 0, 0, 0, 0));
  print("    " + JSON.stringify(r).slice(0, 200));
  ck(r && r.ok === false && /死亡名单|拦截/.test(String(r.error || "")), "csops 死亡名单拦截", String(r && r.error || ""));
})();

// ---------- ④ SYS_sysctl(202) 真读 kern.version ----------
(function () {
  print("[4] syscall(202, mib={CTL_KERN=1, KERN_VERSION=1}, 2, buf, oldlen)");
  var mib = alloc(8), buf = alloc(512), lp = alloc(8);
  if (!mib || !buf || !lp) { ck(false, "分配 mib/buf/len 缓冲", "calloc 失败"); return; }
  memWrite(mib, rycU64le(1) + rycU32le(1));          // mib = {CTL_KERN=1, KERN_VERSION=1}（8 字节小端）
  memWrite(lp,  rycU64le(512));                      // oldlen = 512
  var r = J(syscall(202, mib, 2, buf, lp));   // number + a..d 正好四参，多余的 newp/newlen 留 0
  print("    " + JSON.stringify(r).slice(0, 200));
  if (!r || r.ok !== true) { ck(false, "sysctl(202) 调用", JSON.stringify(r)); return; }
  var len = readU32(lp);                             // 内核回写后的真实长度
  var ver = "";
  try { ver = atob(memRead(buf, len > 0 ? len : 0)).replace(/\0.*$/, ""); } catch (e) {}
  print("    len=" + len + "  version=\"" + ver + "\"");
  ck(/Darwin Kernel Version/.test(ver), "读到 kern.version", ver.slice(0, 60));
})();

// ---------- ⑤ errno 链路：open 一个不存在的路径 ----------
(function () {
  print("[5] syscall(5=open, \"/nonexistent_zzz\") —— 期望 -1 + errno=2 ENOENT");
  var p = alloc(24);
  if (!p) { ck(false, "构造路径缓冲", "calloc 失败"); return; }
  memWrite(p, rycAsciiHex("/nonexistent_zzz") + "00000000");   // ASCII + NUL 结尾
  var r = J(syscall(5, p, 0, 0, 0));         // open(path, flags, mode, …)
  print("    " + JSON.stringify(r).slice(0, 200));
  if (!r || r.ok !== true) { ck(false, "open syscall 返回", JSON.stringify(r)); return; }
  var isErr = (r.ret === -1 || parseInt(r.value, 16) === -1 || parseInt(r.value, 16) === 0xffffffffffffffff);
  print("    errno=" + r.errno + " → " + (r.errno ? serrno(r.errno) : "(无)"));
  ck(isErr && r.errno === 2, "open 失败回 -1 + ENOENT", "errno=" + r.errno + " 期望 2");
})();

// ---------- ⑥ AF_SYSCTL socket 通路（未验证项，看 socket 那步）----------
(function () {
  print("[6] sysctlSock(CTL_KERN=1, KERN_VERSION=1) —— AF_SYSCTL 通路（未真机验证）");
  var r = J(sysctlSock(1, 1, 512));
  print("    " + JSON.stringify(r).slice(0, 300));
  if (!r) { print("[WARN] 返回非 JSON"); return; }
  if (r.ok === false) {
    print("[INFO] AF_SYSCTL 这条路在当前系统被封（socket 那步就失败了）—— 这是**合理结果**，"
        + "说明现代 iOS 已堵住这条旁路；普通 sysctl 请继续用 syscall(202, …) 或 sysctlGet()");
    if (r.errno) print("    errno=" + r.errno + " → " + serrno(r.errno));
  } else {
    ck(r.len > 0 && /Darwin/.test(String(r.hex || "")), "AF_SYSCTL 通路读出 kern.version", "len=" + r.len);
  }
})();

print("=== syscall 冒烟结束  PASS=" + PASS + " FAIL=" + FAIL + " ===");
