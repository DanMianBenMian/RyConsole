// bridge_net.js — 网络桥库（动态层：改此文件无需重编译 IPA）
// 依赖原生原语：tcpConnect / tcpScan / tcpSend（main.m 已注册为全局）
// 本文件每次执行代码时自动加载；控制台或探针可直接调用下面这些高层函数。
// 以后要加新网络能力，只改这里（或新建 bridge_*.js 丢进脚本库），不碰 IPA。

// 扫描一组常用端口，返回开放端口数组
function scanCommonPorts(host) {
  var common = [21,22,23,53,80,110,139,143,443,445,587,631,993,995,
    1080,1433,1521,1723,2049,3128,3306,3389,5432,5900,6379,7000,
    8000,8080,8443,8888,9000,9090,9200,27017,50070];
  var open = [];
  for (var i=0;i<common.length;i++) if (tcpConnect(host, common[i]) === "OPEN") open.push(common[i]);
  return open;
}

// 对 host:port 发 HTTP GET，返回文本响应
function httpGet(host, port, path) {
  path = path || "/";
  var req = "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\n\r\n";
  return tcpSend(host, port, hexEncode(req));
}

// 简易 hex 编码（探针自带 toHex 时亦可用）
function hexEncode(str){
  var o=""; for(var i=0;i<str.length;i++){var h=str.charCodeAt(i).toString(16); o+=h.length<2?"0"+h:h;} return o;
}
