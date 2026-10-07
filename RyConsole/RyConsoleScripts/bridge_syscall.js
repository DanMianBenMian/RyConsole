// bridge_syscall.js — syscall(number, a, b, c, d) 原语糖 + AF_SYSCTL socket 通路
//
// 为什么加这一层（2026-10-07）：
//   原生侧 V2.4.21 已有 syscallN(number, args[], opts)：变参通道 + 号段校验 + csops(45) 死亡名单。
//   但它调用起来是「号 + 数组」，每次都要手写 args 数组、还要自己数尾部 null；
//   而 callPtr 那条固定元数路径（V2.4.23 修回 x0–x7）并不覆盖 syscall 的变参 ABI。
//   这里补的是**签名糖 + 逃生口 + 号/errno 速查**，让探针里可以直接写 syscall(202, mib, 2, 0, 0)。
//
// ★ 不碰原生：本文件走桥热更新（Documents 优先 → writeFile 即生效），不用重编 IPA。
//   若哪天原生 syscallN 被摘掉，syscall() 自动降级到 callVariadic + dlsymAddr 直调 syscall 符号。
//
// 提供：
//   syscall(number, a, b, c, d, opts?)    ← 用户点名的签名（尾部可省）
//   syscallRaw(number, args, opts?)      ← syscallN 直透（要精确控制槽位时用）
//   syscallName(n)                       ← syscall 号 → 常见名（未收录不编）
//   serrno(n) / errnoName(n)             ← errno → 名 + 人话
//   sysctlSock(ctl, name, bufSize?)      ← AF_SYSCTL socket 通路（绕过 SYS_sysctl 号上的沙盒检查点）
var BRIDGE_VERSION = "v1.0 (build 2026-10-07)";
var SCRIPT_VERSION = "bridge_syscall " + BRIDGE_VERSION;
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_syscall"] = BRIDGE_VERSION;

function rycJ(s) { try { return JSON.parse(s); } catch (e) { return null; } }
function rycNum(v) { var o = rycJ(v); return (o && o.ok === true && o.value) ? parseInt(o.value, 16) : NaN; }

// ★ memWrite 只吃 hex 串 / "b64:…" / {b64:"…"}，**不吃 number 数组**（传数组会报
//   "data 必须是 hex 串 / b64…"）。所以写内存一律先拼小端 hex。
function rycU32le(n) { return ("0000000" + (((n | 0) >>> 0).toString(16))).slice(-8); }
function rycU64le(n) { return rycU32le(n) + rycU32le(0); }        // 低 32 位 + 高 32 位（小端）
function rycAsciiHex(s) {
  var h = "";
  for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i) & 0xff; h += ("0" + c.toString(16)).slice(-2); }
  return h;
}
// 从缓冲里按小端读一个 u32（memRead 给的是 hex 串）
function rycReadU32(hexStr) {
  if (!hexStr || hexStr.length < 8) return 0;
  return parseInt(hexStr.slice(0, 8), 16) >>> 0;
}

// ---------------------------------------------------------------------------
//  主原语：syscall(number, a, b, c, d, opts?)
//   · a..d 可以任意省略（传 undefined/null 的尾部会被裁掉）
//   · 0 是合法实参，不会被裁（只有 undefined/null 才裁）
//   · 返回透传 syscallN 的 JSON 串：{"ok":true,"value":"0x…","ret":-1,"errno":N,"syscallNo":M}
//   · 号越界 / csops(45) 死亡名单由原生层先拦（27B2 越界号 = 内核 SIGSYS 杀进程，JS 拦不住）
// ---------------------------------------------------------------------------
function syscall(number, a, b, c, d, opts) {
  var args = [], tail = [a, b, c, d];
  for (var i = 0; i < tail.length; i++) {
    var v = tail[i];
    if (v === undefined || v === null) continue;     // 尾部省略
    args.push(v);
  }
  return syscallRaw(number, args, opts);
}

// syscallN 缺失时的降级：直调 syscall 符号，走真变参通道（等价于 callVariadic）
function syscallRaw(number, args, opts) {
  args = args || [];
  var num = (typeof number === "string") ? parseInt(number, 10) : number;
  if (typeof num !== "number" || Math.floor(num) !== num) {
    return JSON.stringify({ ok: false, error: "[syscall error] number must be an integer syscall number, got " + String(number),
                            signature: "syscall(number, a, b, c, d, opts?)" });
  }
  if (typeof syscallN === "function") return syscallN(number, args, opts || null);

  // ---- 降级路径：callVariadic（原生 callVariadic 缺时用 callPtr + 固定元数兜）----
  var ds = (typeof dlsymAddr === "function") ? dlsymAddr(0, "syscall") : null;
  if (!ds || !ds.addr) {
    return JSON.stringify({ ok: false, error: "[syscall error] 原生 syscallN 缺失，且 dlsymAddr(0,'syscall') 也找不到 → 两个通道都不可用" });
  }
  if (num < 0 || num >= 512) {
    return JSON.stringify({ ok: false, error: "[syscall error] number " + num + " 越界（号段校验在缺失 syscallN 时不再生效，请自查 kern.nsysent）", nsysent: 512 });
  }
  if (num === 45) {
    return JSON.stringify({ ok: false, error: "[syscall error] syscall 45 (csops) 在死亡名单（2.4.20 实测调用即杀进程）",
                            hint: "确要试验：在 opts 里给 {allowDead:true} 并自行承担风险" });
  }
  var all = [num].concat(args);
  var r = (typeof callVariadic === "function") ? callVariadic(ds.addr, all, opts || null)
        : callPtr(ds.addr, all, opts || null);
  return r;
}

// ---------------------------------------------------------------------------
//  号 → 名。只收「高置信」的几条；没把握的宁可返回未收录，也不瞎编（别拿错号去杀进程）。
//  权威表在设备头上：readFile("/usr/include/sys/syscall_sw.h")
// ---------------------------------------------------------------------------
var SYS_NAMES = {
  1:  "exit", 3: "read", 4: "write", 5: "open", 6: "close", 7: "wait4",
  9:  "link", 10: "unlink", 11: "chdir", 14: "getpid", 16: "umask", 17: "getuid",
  18: "getgid", 63: "dup2", 72: "fcntl", 79: "lseek", 82: "select",
  94: "sendmsg", 95: "recvmsg", 97: "socket", 101: "shutdown", 104: "bind",
  105: "connect", 117: "getsockopt", 118: "setsockopt", 122: "recvfrom", 133: "sendto",
  197: "mmap", 198: "munmap", 202: "sysctl", 224: "exit_group", 232: "rtprio"
};
function syscallName(n) {
  n = parseInt(n, 10);
  var nm = SYS_NAMES[n];
  if (!nm) {
    return "未收录(" + n + ")——别猜号！权威表: readFile('/usr/include/sys/syscall_sw.h')；"
         + "范围可先用 sysctlGet('kern.nsysent') 看，超界号 27B2 上会 SIGSYS 杀进程（JS 拦不住）";
  }
  return n + " = " + nm;
}

// ---------------------------------------------------------------------------
//  errno → 名 + 人话。核心 30 条（BSD/xnu 通用）；未收录老老实实说未收录。
//  完整表：readFile('/usr/include/sys/errno.h')
// ---------------------------------------------------------------------------
var ERRNO_NAMES = {
  1: "EPERM 权限不足（沙盒/AMFI 拒绝）", 2: "ENOENT 无此文件/名字", 3: "ESRCH 无此进程",
  4: "EINTR 被信号打断", 5: "EIO 底层 IO 错", 6: "ENXIO", 7: "E2BIG 参数太长",
  8: "ENOEXEC", 9: "EBADF 坏的文件描述符", 10: "ECHILD 无子进程",
  11: "EAGAIN/EWOULDBLOCK 再来一次（非阻塞）", 12: "ENOMEM 内核/用户内存不足",
  13: "EACCES 权限拒绝", 14: "EFAULT 坏地址（指针没映射）", 16: "EBUSY 忙",
  17: "EEXIST 已存在", 18: "EXDEV 跨设备", 19: "ENODEV 无此设备", 20: "ENOTDIR 非目录",
  21: "EISDIR 是目录", 22: "EINVAL 参数非法（号/形状不对最常见）", 23: "ENFILE 文件表满",
  24: "EMFILE fd 超限", 25: "ENOTTY", 26: "ETXTBSY", 27: "EFBIG 超文件大小",
  28: "ENOSPC 满", 29: "ESPIPE 非法 Seek", 30: "EROFS 只读", 31: "EMLINK 链接数超限",
  32: "EPIPE 管道断", 33: "EDOM", 34: "ERANGE 结果太大", 35: "EDEADLK 死锁",
  36: "ENAMETOOLONG 名字太长", 37: "ENOLCK", 38: "ENOSYS 该 syscall 不存在/未实现",
  39: "ENOTEMPTY 非空", 40: "ELOOP 符号链接环", 45: "EINPROGRESS 连接进行中",
  47: "EALREADY 已在进行", 48: "ENOTSOCK 不是 socket", 49: "EDESTADDRREQ 需要目的地址",
  50: "EMSGSIZE 报文太长", 51: "EPROTOTYPE 协议类型错", 52: "ENOPROTOOPT 协议选项错",
  53: "EPROTONOSUPPORT 协议不支持", 54: "ESOCKTNOSUPPORT", 57: "EOPNOTSUPP 不支持该操作",
  59: "EPFNOSUPPORT", 60: "EAFNOSUPPORT 地址族不支持", 61: "EADDRINUSE 地址已占用",
  62: "EADDRNOTAVAIL 地址不可用", 63: "ENETDOWN 网络Down", 64: "ENETUNREACH 不可达",
  65: "ECONNRESET 连接被对端重置", 66: "ECONNABORTED 连接终止", 67: "ECONNREFUSED 拒绝",
  68: "EHOSTDOWN", 69: "EHOSTUNREACH 主机不可达", 70: "ENOTCONN 未连接", 71: "ETIMEDOUT 超时",
  73: "EHOSTDOWN", 91: "EBADMSG", 92: "ECANCELED 已取消", 93: "ENOMSG", 96: "ETIME"
};
function serrno(n) {
  n = parseInt(n, 10);
  return ERRNO_NAMES[n] || ("未收录 errno " + n + "（原始数字在 syscall 的 .errno 字段里）");
}
function errnoName(n) { return serrno(n); }

// ---------------------------------------------------------------------------
//  AF_SYSCTL socket 通路（用户点名的备选方案）
//   普通 sysctl 走 SYS_sysctl(202) 号，沙盒在**那个号**上有检查点；
//   AF_SYSCTL=2 域里 socket(AF_SYSCTL, SOCK_DGRAM, 0) 再用 getsockopt(fd, 0, mib[0], buf, &len)
//   让 sysctl 逻辑改从 getsockopt(117) 号进来 —— 有时能绕开 SYS_sysctl 上的 hook。
//   xnu 的行为：sopt_name 当作 mib[0]，输出缓冲区**头 4 字节**被当作 mib[1] 读取。
//
//   用法：sysctlSock(ctl, name, bufSize?)  ← 例 sysctlSock(1 /*CTL_KERN*/, 1 /*KERN_VERSION*/, 512)
//
//  2026-10-07 iPadOS 27B2 真机实测（iPad10 / RyConsole 沙盒）：
//    · socket(AF_SYSCTL=2, SOCK_DGRAM, 0) **建得成功**（拿到合法 fd）—— 没堵 socket 创建；
//    · 但 getsockopt(117) 一律回 EINVAL(22)，与 ctl/name 取值无关 → AF_SYSCTL 通路在本固件上**走不通**。
//    · 对照：sysctl(202) 直接调也大面积 EPERM(1) —— seatbelt 对 SYS_sysctl 号按 **mib 白名单** 过滤，
//      白名单外一律 EPERM（白名单内的 kern.osversion 能读，kern.version / hw.memsize 被拒）。
//    ⇒ 结论：别指望 syscall(202) 当通用 sysctl，读系统值用现成的 sysctlGet()；
//      syscall 原语本身仍然可用（open(5) 实测真进内核、errno 正确回传）。
// ---------------------------------------------------------------------------
function sysctlSock(ctl, name, bufSize) {
  ctl  = parseInt(ctl, 10);
  name = parseInt(name, 10);
  if (isNaN(ctl) || isNaN(name)) return JSON.stringify({ ok: false, error: "[sysctlSock error] ctl 与 name 必须是整数（mib 两个元素）", signature: "sysctlSock(ctl, name, bufSize?)" });
  var sz = (!bufSize || isNaN(parseInt(bufSize, 10))) ? 512 : Math.min(parseInt(bufSize, 10), 65536);
  if (sz <= 0) sz = 512;

  function fin(ok, extra) {
    var o = extra || {};
    o.ok = !!ok;
    return JSON.stringify(o);
  }

  // ① socket(AF_SYSCTL=2, SOCK_DGRAM=2, protocol=0)
  //    ★ 这里用 syscall(97,2,2,0,0) 五参形态；getsockopt 要 6 个实参，超了 → 走 syscallRaw 直透 syscallN。
  var soRaw = syscall(97, 2, 2, 0, 0);
  var soo = rycJ(soRaw);
  var so = rycNum(soRaw);
  if (!soo || soo.ok !== true || isNaN(so) || so < 0 || so > 4096) {
    return fin(false, { error: "[sysctlSock error] socket(AF_SYSCTL,SOCK_DGRAM,0) 失败 —— AF_SYSCTL 这条路上现代 iOS 多半已封",
                        errno: soo && soo.errno ? soo.errno : null,
                        why: soo && soo.errno ? serrno(soo.errno) : "（无 errno 返回）", syscallNo: 97 });
  }
  // ② 两块临时内存：buf（放 mib[1] 头 4 字节 + 收数据）、lenp（in/out 的长度变量）
  var cb = rycNum(callPtr(dlsymAddr(0, "calloc").addr, [1, sz]));
  var mb = rycNum(callPtr(dlsymAddr(0, "malloc").addr, [8]));
  if (isNaN(cb) || isNaN(mb)) return fin(false, { error: "[sysctlSock error] calloc/malloc 分配失败", fd: so });
  // ③ len = sz（size_t 8 字节小端）
  memWrite(mb, rycU64le(sz));
  // ④ buf 头 4 字节 = mib[1]（u32 小端）
  memWrite(cb, rycU32le(name));
  // ⑤ getsockopt(fd, 0, mib[0]=ctl, buf, lenp) —— 6 实参 → 走 syscallRaw 直透 syscallN
  var go = rycJ(syscallRaw(117, [so, 0, ctl, cb, mb], null));
  var ret = (go && go.ok === true) ? (go.ret === -1 ? -1 : parseInt(go.value, 16)) : NaN;
  var outLen = 0;
  try { outLen = rycReadU32(memRead(mb, 8)); } catch (e) {}
  if (outLen > sz) outLen = sz;
  var payload = "";
  try { payload = memRead(cb, outLen > 0 ? outLen : 0); } catch (e) {}
  print("[sysctlSock] ctl=" + ctl + " name=" + name + " fd=" + so + " ret=" + (isNaN(ret) ? "?" : ret) +
        " outLen=" + outLen + (ret === -1 ? "  errno=" + (go && go.errno ? serrno(go.errno) : "?") : ""));
  // ⑥ 关 fd
  try { syscall(6, so, 0, 0, 0); } catch (e) {}
  return fin(ret !== -1, { ctl: ctl, name: name, fd: so, ret: ret, len: outLen, hex: payload,
                           errno: (go && go.errno) || 0, after: "" });
}

// ---- 守卫时序兜底 -----------------------------------------------------------
// bridge_guard 若在**本文件之前**加载，它遍历 GUARDS 时还看不到 syscall（skip），此后也不会回头补装。
// 这里主动再跑一次 installGuards：已装过的原语有 __ryGuarded 标记会跳过，只补缺的。
(function () {
  if (typeof installGuards !== "function" || typeof syscall !== "function" || syscall.__ryGuarded) return;
  try { installGuards.call(this); } catch (e) { print("[bridge_syscall] 守卫补装失败: " + e); }
})();

print("[bridge_syscall] 已加载: syscall(number,a,b,c,d) / syscallRaw / syscallName / serrno / errnoName / sysctlSock (" + SCRIPT_VERSION + ")");
print("  用例: syscall(202, 0x1807d528 /*mib*/, 2, 0, 0)  —— 号表查 syscallName(202)");
print("       sysctlSock(1 /*CTL_KERN*/, 1 /*KERN_VERSION*/)  —— AF_SYSCTL 通路（未真机验证，先看 socket 返回）");
