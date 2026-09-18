// probe_env.js v1 — RyConsole 环境自测探针
// 验证点：engine.js 顶层 return 修复（旧引擎顶层 return 报 SyntaxError 吞掉整段）
// 用法：python ryc_autorun.py run --host <ip> --code-file probe_env.js

print('[probe_env] 启动执行...');

var env = {
  hasPrint: (typeof print === 'function'),
  hasObjC:  (typeof ObjC !== 'undefined'),
  hasUI:    (typeof UI !== 'undefined'),
  hasIOKit: (typeof IOKit !== 'undefined'),
  hasNet:   (typeof Net !== 'undefined'),
  hasBridgeInfo: (typeof BridgeInfo !== 'undefined'),
  time: new Date().toISOString()
};

print('[probe_env] 已收集 ' + Object.keys(env).length + ' 项环境标记');

// 关键：顶层 return —— 旧引擎此处会 SyntaxError 导致整段不跑；新引擎 new Function 包裹后合法
return JSON.stringify(env, null, 2);
