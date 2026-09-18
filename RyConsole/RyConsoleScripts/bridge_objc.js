// bridge_objc.js — ObjC runtime 万用桥 + LSApplicationWorkspace 驱动
// 依赖 main.m 原生全局: objc_getClass / sel_registerName / objc_msgSend / objcDesc / objc_msgSendSafe
// 全部对象以 0x 十六进制句柄流动；objc_msgSend 返回 0x 句柄，objcDesc 回读内容。
//
// v1.1（2026-09-18，按《RyConsole Autorun 服务缺陷报告》Bug 5 修 —— lsAppList() 必崩）：
//   · 崩溃主因（推断已按此加固）：`allInstalledApplications` 返回的是 **autoreleased** 数组，
//     而 Autorun 的执行线程**没有 autorelease pool**；桥里把它当裸指针在循环里反复使用，
//     一旦对象被回收就是访问已释放内存 → SIGSEGV（表现为"一次调用即进程重启"）。
//     → 现在先 `retain` 住数组再遍历（短命进程，这点泄漏无所谓，只求不崩）。
//   · 另加 offset/limit 分页（默认 ≤120，硬上限 200），避免一次几百次 JSC↔原生跨界 + 内存尖峰。
//   · 全部改走 `objc_msgSendSafe`（结构化错误），任何一步失败都带进度信息返回，不再"崩了啥也没有"。
//   · lsAppList() 返回值仍保持 **字符串数组**（向后兼容老探针）；要总量/错误明细用 lsAppListInfo()。
var SCRIPT_VERSION = "bridge_objc v1.1 (build 2026-09-18)";
var BRIDGE_VERSION = "v1.1 (build 2026-09-18)";
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_objc"] = BRIDGE_VERSION;

var LS_APP_PAGE_DEFAULT = 120;
var LS_APP_PAGE_MAX = 200;

// 显式指针包装（传对象实参用；字符串自动包 NSString，无需包）
function objPtr(hex) { return { hex: hex }; }

// 小工具：把 objc_msgSendSafe 的 JSON 结果解出来
function objSafe(recv, selName, args) {
  try { return JSON.parse(objc_msgSendSafe(recv, selName, args || [])); }
  catch (e) { return { ok: false, error: "parse:" + e }; }
}

// LSApplicationWorkspace 单例句柄（i4Tools 同款私有类，无 entitlement 依赖）
function lsWorkspace() {
  var cls = objc_getClass("LSApplicationWorkspace");
  if (parseInt(cls, 16) === 0) { print("[lsWorkspace] LSApplicationWorkspace 类未找到"); return "0x0000000000000000"; }
  var r = objSafe(cls, "defaultWorkspace", []);
  return (r.ok && parseInt(r.value, 16) !== 0) ? r.value : "0x0000000000000000";
}

// 内部：拿住已装应用数组（已 retain，调用方负责遍历；用完可不管，进程会回收）
function lsAppsArray() {
  var ws = lsWorkspace();
  if (parseInt(ws, 16) === 0) return { err: "no-workspace" };
  var r1 = objSafe(ws, "allInstalledApplications", []);
  if (!r1.ok) return { err: "allInstalledApplications:" + r1.error };
  var apps = r1.value;
  if (parseInt(apps, 16) === 0) return { err: "nil-apps" };
  objSafe(apps, "retain", []);                       // ★ 关键：保住数组，别在遍历中途被释放
  var r2 = objSafe(apps, "count", []);
  var n = r2.ok ? parseInt(r2.value, 16) : 0;
  return { apps: apps, n: n };
}

function lsAppList(offset, limit) {                  // 兼容：仍返回 bundleID 字符串数组
  var info = lsAppListInfo(offset, limit);
  return info.ok ? info.apps : [];
}

// 带总量/错误明细的版本
function lsAppListInfo(offset, limit) {
  offset = (offset === undefined || offset === null) ? 0 : (parseInt(offset, 10) || 0);
  limit  = (limit  === undefined || limit  === null) ? LS_APP_PAGE_DEFAULT : (parseInt(limit, 10) || LS_APP_PAGE_DEFAULT);
  if (limit > LS_APP_PAGE_MAX) limit = LS_APP_PAGE_MAX;
  if (limit <= 0) limit = LS_APP_PAGE_DEFAULT;

  var a = lsAppsArray();
  if (a.err) { print("[lsAppList] 失败: " + a.err); return { ok: false, err: a.err, total: 0, apps: [] }; }

  var out = [], errs = [];
  var end = Math.min(a.n, offset + limit);
  for (var i = offset; i < end; i++) {
    var ra = objSafe(a.apps, "objectAtIndex:", [i]);
    if (!ra.ok) { errs.push(i + ":" + ra.error); continue; }
    var rb = objSafe(ra.value, "bundleIdentifier", []);
    if (!rb.ok) { errs.push(i + ":bid:" + rb.error); continue; }
    var bid = objcDesc(rb.value);
    if (bid && String(bid).indexOf("0x") !== 0 && bid !== "(nil)") out.push(String(bid));
  }
  print("[lsAppList] total=" + a.n + " offset=" + offset + " 返回 " + out.length +
        " 个" + (errs.length ? ("，失败 " + errs.length + " 个") : "") +
        ((a.n > end) ? "（还有 " + (a.n - end) + " 个，用 lsAppList(offset,limit) 翻页）" : ""));
  if (a.n > end) print("[lsAppList] 提示：默认一次 " + LS_APP_PAGE_DEFAULT + " 个（上限 " + LS_APP_PAGE_MAX + "），别一次拉全量");
  return { ok: true, total: a.n, offset: offset, limit: limit, apps: out, errors: errs };
}

// 只要数量（最省：不遍历对象）
function lsAppCount() {
  var a = lsAppsArray();
  return a.err ? -1 : a.n;
}

// 单个应用详情（bundle ID → description 对象：版本/路径/类型等）
function lsAppInfo(bundleId) {
  var ws = lsWorkspace();
  if (parseInt(ws, 16) === 0) return "(no workspace)";
  var r = objSafe(ws, "applicationForBundleIdentifier:", [bundleId]);
  if (!r.ok) return "[lsAppInfo error] " + r.error;
  return objcDesc(r.value);
}

// 通过 workspace 打开 URL（走 LSApplicationWorkspace openURL:，绕 LS 免沙盒 openURL 限制面）
function lsOpenURL(url) {
  var ws = lsWorkspace();
  if (parseInt(ws, 16) === 0) return false;
  var ru = objSafe(objc_getClass("NSURL"), "URLWithString:", [url]);
  if (!ru.ok) { print("[lsOpenURL] NSURL 构造失败: " + ru.error); return false; }
  var r = objSafe(ws, "openURL:", [objPtr(ru.value)]);
  if (!r.ok) { print("[lsOpenURL] openURL: 失败: " + r.error); return false; }
  var v = parseInt(r.value, 16);
  print("[lsOpenURL] " + url + " → " + (v & 1 ? "YES" : "NO") + " (" + r.value + ")");
  return !!(v & 1);
}

// 通过 workspace 拉起 App（bundle ID）
function lsOpenApp(bundleId) {
  var ws = lsWorkspace();
  if (parseInt(ws, 16) === 0) return false;
  var r = objSafe(ws, "openApplicationWithBundleID:", [bundleId]);
  if (!r.ok) { print("[lsOpenApp] 失败: " + r.error); return false; }
  var v = parseInt(r.value, 16);
  print("[lsOpenApp] " + bundleId + " → " + (v & 1 ? "YES" : "NO") + " (" + r.value + ")");
  return !!(v & 1);
}

// 通用: 对任意句柄取属性/调用无参方法并回读 description（探针速记用）
function objCall(hex, selName) {
  var r = objSafe(hex, selName, []);
  if (!r.ok) return "[objCall error] " + r.error;
  return objcDesc(r.value);
}

print("[bridge_objc] 已加载: objPtr/lsWorkspace/lsAppCount/lsAppList/lsAppListInfo/lsAppInfo/lsOpenURL/lsOpenApp/objCall + 原生 objc_getClass/sel_registerName/objc_msgSend/objcDesc/objc_msgSendSafe (" + SCRIPT_VERSION + ")");
