// bridge_net.js — 网络桥库（动态层：改此文件无需重编译 IPA）
// 依赖原生原语：tcpConnect / tcpScan / tcpSend（main.m 已注册为全局）
// 本文件每次执行代码时自动加载；控制台或探针可直接调用下面这些高层函数。
// 以后要加新网络能力，只改这里（或新建 bridge_*.js 丢进脚本库），不碰 IPA。
var BRIDGE_VERSION = "v1.1 (build 2026-09-18)";
// 自报版本：加载后可在设备上一次性查"每个桥跑的是哪版" —— return JSON.stringify(RYC_BRIDGES)
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_net"] = BRIDGE_VERSION;
var SCRIPT_VERSION = "bridge_net " + BRIDGE_VERSION;

// 扫描一组常用端口，返回开放端口数组
// host 必填且非空（传错类型会由 bridge_guard 拦住）
function scanCommonPorts(host) {
  if (typeof host !== "string" || !host.length)
    return { error: "[scanCommonPorts error] host must be a non-empty string, e.g. '192.168.0.1'" };
  var common = [21,22,23,53,80,110,139,143,443,445,587,631,993,995,
    1080,1433,1521,1723,2049,3128,3306,3389,5432,5900,6379,7000,
    8000,8080,8443,8888,9000,9090,9200,27017,50070];
  var open = [];
  for (var i=0;i<common.length;i++) {
    var r;
    try { r = tcpConnect(host, common[i]); } catch (e) { continue; }
    if (r === "OPEN") open.push(common[i]);
  }
  return open;
}

// 对 host:port 发 HTTP GET，返回文本响应
// port 合法范围 1..65535；path 省略时默认 "/"
function httpGet(host, port, path) {
  if (typeof host !== "string" || !host.length)
    return "[httpGet error] host must be a non-empty string";
  if (typeof port !== "number" || port < 1 || port > 65535)
    return "[httpGet error] port must be 1..65535, got " + port;
  if (path !== undefined && typeof path !== "string")
    return "[httpGet error] path must be a string (可省略, 默认 \"/\")";
  path = path || "/";
  var req = "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\n\r\n";
  return tcpSend(host, port, hexEncode(req));
}

// 简易 hex 编码（探针自带 toHex 时亦可用）
function hexEncode(str){
  if (typeof str !== "string") return "";
  var o=""; for(var i=0;i<str.length;i++){var h=str.charCodeAt(i).toString(16); o+=h.length<2?"0"+h:h;} return o;
}

print("[bridge_net] 已加载: scanCommonPorts / httpGet / hexEncode (" + BRIDGE_VERSION + ")");
