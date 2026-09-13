// bridge_objc.js — ObjC runtime 万用桥 + LSApplicationWorkspace 驱动（V2.1，2026-09-13）
// 依赖 main.m 原生全局: objc_getClass / sel_registerName / objc_msgSend / objcDesc
// 全部对象以 0x 十六进制句柄流动；objc_msgSend 返回 0x 句柄，objcDesc 回读内容。
var SCRIPT_VERSION = "bridge_objc v1.0 (build 2026-09-13)";

// 显式指针包装（传对象实参用；字符串自动包 NSString，无需包）
function objPtr(hex) { return { hex: hex }; }

// LSApplicationWorkspace 单例句柄（i4Tools 同款私有类，无 entitlement 依赖）
function lsWorkspace() {
  var cls = objc_getClass("LSApplicationWorkspace");
  if (parseInt(cls, 16) === 0) { print("[lsWorkspace] LSApplicationWorkspace 类未找到"); return "0x0000000000000000"; }
  return objc_msgSend(cls, sel_registerName("defaultWorkspace"), []);
}

// 全部已安装应用的 bundle ID 列表（公开能力，不触发任何授权弹窗）
function lsAppList() {
  var ws = lsWorkspace();
  var apps = objc_msgSend(ws, "allInstalledApplications", []);
  var n = parseInt(objc_msgSend(apps, "count", []), 16);
  print("[lsAppList] 已装应用 " + n + " 个");
  var out = [];
  for (var i = 0; i < n && i < 3000; i++) {
    var app = objc_msgSend(apps, "objectAtIndex:", [i]);
    out.push(objcDesc(objc_msgSend(app, "bundleIdentifier", [])));
  }
  return out;
}

// 单个应用详情（bundle ID → description 对象：版本/路径/类型等）
function lsAppInfo(bundleId) {
  var ws = lsWorkspace();
  var app = objc_msgSend(ws, "applicationForBundleIdentifier:", [bundleId]);
  return objcDesc(app);
}

// 通过 workspace 打开 URL（走 LSApplicationWorkspace openURL:，绕 LS 免沙盒 openURL 限制面）
function lsOpenURL(url) {
  var ws = lsWorkspace();
  var nsurl = objc_msgSend(objc_getClass("NSURL"), "URLWithString:", [url]);
  var r = objc_msgSend(ws, "openURL:", [objPtr(nsurl)]);
  var v = parseInt(r, 16);
  print("[lsOpenURL] " + url + " → " + (v & 1 ? "YES" : "NO") + " (" + r + ")");
  return v & 1;
}

// 通过 workspace 拉起 App（bundle ID）
function lsOpenApp(bundleId) {
  var ws = lsWorkspace();
  var r = objc_msgSend(ws, "openApplicationWithBundleID:", [bundleId]);
  var v = parseInt(r, 16);
  print("[lsOpenApp] " + bundleId + " → " + (v & 1 ? "YES" : "NO") + " (" + r + ")");
  return v & 1;
}

// 通用: 对任意句柄取属性/调用无参方法并回读 description（探针速记用）
function objCall(hex, selName) {
  return objcDesc(objc_msgSend(hex, selName, []));
}

print("[bridge_objc] 已加载: objPtr/lsWorkspace/lsAppList/lsAppInfo/lsOpenURL/lsOpenApp/objCall + 原生 objc_getClass/sel_registerName/objc_msgSend/objcDesc (v1.0)");
