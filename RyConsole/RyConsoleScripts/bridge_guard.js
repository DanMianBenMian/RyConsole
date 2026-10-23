// bridge_guard.js — 原生原语的「类型参数守卫」（v1.0, 2026-09-18）
//
// 为什么需要它：
//   原生桥的 block 参数是**强类型**的（NSDictionary* / NSString* / NSNumber* …）。一旦 JS 侧传错类型，
//   JavaScriptCore 会在**进入原生校验之前**就抛英文 TypeError，例如：
//       iosurfaceCreate("x")  →  TypeError: Cannot convert primitive to NSDictionary
//   这种错误：① 是英文 ② 没有参数名/合法范围 ③ 我们的 [iosurfaceCreate error] 根本没机会跑。
//
// 做法：加载时把相关原语包一层**类型校验**（纯 JS，热更新即可生效，不用重编 IPA）。
//   校验不通过 → 返回 "[<桥名> error] 参数名 must be …，got …  |  签名: …"（memRead 风格）
//   校验通过   → 原样透传给原生（原生侧还有第二层校验，双保险）
//
// 顺序：本文件在 installPrimitives 之后加载（桥都在之后），所以包装到的是已带 __ry_note 的函数，
//       崩溃点名的行为不受影响。
var BRIDGE_VERSION = "v1.1 (build 2026-09-19)";
// 自报版本：加载后可在设备上一次性查"每个桥跑的是哪版" —— return JSON.stringify(RYC_BRIDGES)
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_guard"] = BRIDGE_VERSION;
var SCRIPT_VERSION = "bridge_guard " + BRIDGE_VERSION;

// 期望类型 → 人话
function _gWant(kind) {
  switch (kind) {
    case "num":    return "a number";
    case "u32":    return "a uint32 (0..4294967295)";
    case "int":    return "an integer";
    case "str":    return "a string";
    case "strNe":  return "a non-empty string";
    case "obj":    return "an object/dictionary (可省略)";
    case "arr":    return "an array (可省略)";
    case "arrNum": return "an array of numbers (可省略)";
    case "strOpt": return "a string (可省略)";
    case "numOpt": return "a number (可省略)";
    default:       return "?(未定义)";
  }
}

// 实际值 → 人话（用于 "got …"）
function _gGot(v) {
  if (v === undefined) return "undefined";
  if (v === null) return "null";
  if (v instanceof Array) return "array(" + v.length + ")";
  var t = typeof v;
  if (t === "string") return "string(\"" + (v.length > 20 ? v.slice(0, 20) + "…" : v) + "\")";
  if (t === "number") return "number(" + v + ")";
  if (t === "boolean") return "boolean(" + v + ")";
  return t;
}

// 单参数校验：返回 null=通过，否则返回期望描述
function _gCheck(kind, v) {
  switch (kind) {
    case "num":    return (typeof v === "number") ? null : _gWant(kind);
    case "u32":    return (typeof v === "number" && v >= 0 && v <= 4294967295) ? null : _gWant(kind);
    case "int":    return (typeof v === "number" && Math.floor(v) === v) ? null : _gWant(kind);
    case "str":    return (typeof v === "string") ? null : _gWant(kind);
    case "strNe":  return (typeof v === "string" && v.length > 0) ? null : _gWant(kind);
    case "obj":    return (typeof v === "object" && v !== null && !(v instanceof Array)) ? null : _gWant(kind);
    case "arr":    return (v instanceof Array) ? null : _gWant(kind);
    case "arrNum":
      if (!(v instanceof Array)) return _gWant(kind);
      for (var i = 0; i < v.length; i++) {
        if (typeof v[i] !== "number") return "an array of numbers（第 " + i + " 项是 " + _gGot(v[i]) + "）";
      }
      return null;
    case "strOpt": return (typeof v === "string") ? null : _gWant(kind);
    case "numOpt": return (typeof v === "number") ? null : _gWant(kind);
    default:       return null;
  }
}

// 需要守卫的原语。opt:true = 该位置可省略（undefined/null 直接放过）。
// 只守卫「传错类型会变成 JSC 英文 TypeError」或「参数名极易搞错」的位置。
var GUARDS = [
  { p: "iosurfaceCreate", sig: "iosurfaceCreate(props?)",
    args: [{ n: "props", k: "obj", opt: true }] },
  { p: "iosurfaceLookup", sig: "iosurfaceLookup(cid)",
    args: [{ n: "cid", k: "u32" }] },
  { p: "iosurfaceGetID", sig: "iosurfaceGetID(handle)",
    args: [{ n: "handle", k: "num" }] },
  { p: "iosurfaceRelease", sig: "iosurfaceRelease(handle)",
    args: [{ n: "handle", k: "num" }] },
  { p: "iosurfaceSetValue", sig: "iosurfaceSetValue(handle, key, value)",
    args: [{ n: "handle", k: "num" }, { n: "key", k: "str", opt: true }, { n: "value", k: "str", opt: true }] },
  { p: "iosurfaceGetValue", sig: "iosurfaceGetValue(handle, key)",
    args: [{ n: "handle", k: "num" }, { n: "key", k: "str", opt: true }] },
  // V2.4.27 WS1：后备内存观测通道
  { p: "iosurfaceBaseAddress", sig: "iosurfaceBaseAddress(handle)",
    args: [{ n: "handle", k: "num" }] },
  { p: "iosurfaceLock", sig: "iosurfaceLock(handle, opts?)",
    args: [{ n: "handle", k: "num" }, { n: "opts", k: "numOpt", opt: true }] },
  { p: "iosurfaceUnlock", sig: "iosurfaceUnlock(handle)",
    args: [{ n: "handle", k: "num" }] },
  { p: "iosurfaceRead", sig: "iosurfaceRead(handle, off, len)",
    args: [{ n: "handle", k: "num" }, { n: "off", k: "u32" }, { n: "len", k: "u32" }] },
  { p: "iosurfaceWrite", sig: "iosurfaceWrite(handle, off, data)",
    args: [{ n: "handle", k: "num" }, { n: "off", k: "u32" }, { n: "data", opt: true }] },

  { p: "iokitOpen", sig: "iokitOpen(cls, type)",
    args: [{ n: "cls", k: "strNe" }, { n: "type", k: "u32", opt: true }] },
  { p: "iokitClose", sig: "iokitClose(conn)",
    args: [{ n: "conn", k: "num" }] },
  { p: "iokitMap", sig: "iokitMap(conn, memType)",
    args: [{ n: "conn", k: "num" }, { n: "memType", k: "u32" }] },
  { p: "iokitCall", sig: "iokitCall(conn, sel, inputs?)",
    args: [{ n: "conn", k: "num" }, { n: "sel", k: "u32" }, { n: "inputs", k: "arrNum", opt: true }] },
  { p: "iokitCallStruct", sig: "iokitCallStruct(conn, sel, scalarInputs?, structB64?, outSize?)",
    args: [{ n: "conn", k: "num" }, { n: "sel", k: "u32" }, { n: "scalarInputs", k: "arrNum", opt: true },
           { n: "structB64", k: "strOpt", opt: true }, { n: "outSize", k: "numOpt", opt: true }] },

  { p: "callPtr", sig: "callPtr(addrHex, args?, opts?)",
    args: [{ n: "addrHex", k: "strNe" }, { n: "args", k: "arr", opt: true }, { n: "opts", k: "obj", opt: true }] },
  // V2.4.27：syscall 是 JS 侧签名糖（bridge_syscall.js），尾部 a/b/c/d 可省 → 全部 opt
  { p: "syscall", sig: "syscall(number, a, b, c, d, opts?)",
    args: [{ n: "number", k: "num" }, { n: "a", k: "numOpt", opt: true },
           { n: "b", k: "numOpt", opt: true }, { n: "c", k: "numOpt", opt: true },
           { n: "d", k: "numOpt", opt: true }, { n: "opts", k: "obj", opt: true }] },
  { p: "sysctlSock", sig: "sysctlSock(ctl, name, bufSize?)",
    args: [{ n: "ctl", k: "num" }, { n: "name", k: "num" }, { n: "bufSize", k: "numOpt", opt: true }] },
  { p: "memRead", sig: "memRead(hexAddr, len)",
    args: [{ n: "hexAddr", k: "strNe" }, { n: "len", k: "num" }] },
  { p: "sysctlGet", sig: "sysctlGet(name)",
    args: [{ n: "name", k: "strNe" }] },

  { p: "xpcConn", sig: "xpcConn(svc)",
    args: [{ n: "svc", k: "strNe" }] },
  { p: "machLookUp", sig: "machLookUp(svc)",
    args: [{ n: "svc", k: "strNe" }] },
  { p: "dlsymAddr", sig: "dlsymAddr(handle, name)",
    args: [{ n: "handle", k: "num" }, { n: "name", k: "strNe" }] },
  { p: "dlopenFW", sig: "dlopenFW(path, mode?)",
    args: [{ n: "path", k: "strNe" }, { n: "mode", k: "numOpt", opt: true }] },
  { p: "sandboxCheck", sig: "sandboxCheck(operation)",
    args: [{ n: "operation", k: "strNe" }] },
  { p: "keychainProbe", sig: "keychainProbe(cls, service, account?)",
    args: [{ n: "cls", k: "strNe" }, { n: "service", k: "strNe" }, { n: "account", k: "strOpt", opt: true }] },
  { p: "sleep", sig: "sleep(ms)",
    args: [{ n: "ms", k: "num" }] },
  { p: "tcpConnect", sig: "tcpConnect(host, port)",
    args: [{ n: "host", k: "strNe" }, { n: "port", k: "num" }] },
  { p: "tcpSend", sig: "tcpSend(host, port, hex)",
    args: [{ n: "host", k: "strNe" }, { n: "port", k: "num" }, { n: "hex", k: "str" }] },
  { p: "tcpScan", sig: "tcpScan(host, startPort, endPort)",
    args: [{ n: "host", k: "strNe" }, { n: "startPort", k: "num" }, { n: "endPort", k: "num" }] },
  { p: "posixSpawn", sig: "posixSpawn(path, argv, timeoutMs)",
    args: [{ n: "path", k: "strNe" }, { n: "argv", k: "arr" }, { n: "timeoutMs", k: "num", opt: true }] },
  { p: "objc_getClass", sig: "objc_getClass(name)",
    args: [{ n: "name", k: "strNe" }] },
  { p: "sel_registerName", sig: "sel_registerName(name)",
    args: [{ n: "name", k: "strNe" }] },
  { p: "fileExists", sig: "fileExists(path)",
    args: [{ n: "path", k: "strNe" }] },
  { p: "readFile", sig: "readFile(path)",
    args: [{ n: "path", k: "strNe" }] },
  { p: "writeFile", sig: "writeFile(path, content)",
    args: [{ n: "path", k: "strNe" }, { n: "content", k: "strOpt", opt: true }] },
  { p: "fileAppend", sig: "fileAppend(path, content)",
    args: [{ n: "path", k: "strNe" }, { n: "content", k: "strOpt", opt: true }] },
  { p: "mkdir", sig: "mkdir(name)",
    args: [{ n: "name", k: "strNe" }] }
];

function installGuards() {
  var g = this;
  var ok = [], skipped = [];
  for (var i = 0; i < GUARDS.length; i++) {
    var spec = GUARDS[i];
    var orig = g[spec.p];
    if (typeof orig !== "function") { skipped.push(spec.p); continue; }
    if (orig.__ryGuarded) { ok.push(spec.p + "(已装)"); continue; }
    g[spec.p] = (function (name, sig, args, fn) {
      var w = function () {
        var a = arguments;
        for (var j = 0; j < args.length; j++) {
          var s = args[j], v = a[j];
          if ((v === undefined || v === null) && (s.opt || s.def !== undefined)) continue;
          if (v === undefined && !s.opt) {
            return "[" + name + " error] " + s.n + " is required, got undefined  |  签名: " + sig
                 + "  |  查参数: primHelp(\"" + name + "\")";
          }
          var bad = _gCheck(s.k, v);
          if (bad) {
            return "[" + name + " error] " + s.n + " must be " + bad + ", got " + _gGot(v)
                 + "  |  签名: " + sig + "  |  查参数: primHelp(\"" + name + "\")";
          }
        }
        return fn.apply(this, a);
      };
      w.__ryGuarded = true;
      w.__ryOriginal = fn;
      return w;
    })(spec.p, spec.sig, spec.args, orig);
    ok.push(spec.p);
  }
  return { guarded: ok, skipped: skipped };
}

// 在全局装上（IIFE 里 this = 全局对象，和 main.m 那层"点名"包装同一套路）
(function () {
  var r = installGuards.call(this);
  var msg = "[bridge_guard] 已装载参数守卫 " + r.guarded.length + " 个原语（类型错不再抛英文 TypeError）";
  if (r.skipped.length) msg += "；跳过不存在的: " + r.skipped.join(",");
  print(msg + " (" + BRIDGE_VERSION + ")");
})();
