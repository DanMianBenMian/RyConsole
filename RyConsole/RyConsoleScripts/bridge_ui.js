// bridge_ui.js — URL scheme 桥库（动态层：改此文件无需重编译 IPA）
// 依赖原生原语：canOpenURL / openURL（main.m 已注册为全局）

// 枚举哪些 scheme 系统里有 handler（URL scheme 派发面）
function enumSchemes(schemes) {
  schemes = schemes || ["tel","sms","mailto","http","https","facetime","maps",
    "itms-services","prefs","weixin","alipay","mqq","dingtalk","lark","fb","instagram","twitter"];
  var out = [];
  for (var i=0;i<schemes.length;i++) if (canOpenURL(schemes[i] + "://") === "YES") out.push(schemes[i]);
  return out;
}
