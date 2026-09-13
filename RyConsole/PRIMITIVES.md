# RyConsole 原生桥完整参考（PRIMITIVES）

> 由 `main.m` 的 `installPrimitives(ctx)` 注册，JS 侧**直接当全局函数调用**。
> 每次执行都是**全新 JSContext**（原语会重新注册），所以跨轮次状态必须落盘（见 §6 文件 IO）。
> 共 **51 个原生原语** + 6 个 JS 桥库函数。

## 通用约定

- 相对路径 → 基于 **App 的 Documents**；以 `/` 开头 → 绝对路径。
- 返回字符串的原语：失败时通常返回以 `[xxx error]` 开头的说明，**不会抛异常**。
- `print()` 是回传通道（Autorun 下收进 `output`）；`return` 的值进 `result`。
- 安全分级：🟢只读 / 🟡状态影响 / 🔴高危（需人工确认）

---

## 1. IOKit / 内核接口（核心）🟢

| 原语 | 签名 | 说明 |
|---|---|---|
| `iokitEnum` | `() → string` | 枚举 IORegistry 服务（JSON） |
| `iokitOpen` | `(cls: string, type: number) → number` | 打开 IOService，返回 conn；**>0 成功** |
| `iokitCall` | `(conn, sel, inputs: array) → string` | 标量入参调用，返回结果描述 |
| `iokitCallStruct` | `(conn, sel, scalarInputs, structB64, outSize) → string` | 带 inputStruct/OOL 输出（struct 以 base64） |
| `iokitMap` | `(conn, mapType) → string` | 映射内存 |
| `iokitClose` | `(conn) → number` | 关闭 |
| `bytesB64` | `(arr: number[]) → string` | 字节数组 → base64 |
| `b64Bytes` | `(b64: string) → array` | base64 → 字节数组 |

**典型用法**

```js
var conn = iokitOpen("IOSurfaceRoot", 0);
if (conn > 0) {
  print("selector 0 -> " + iokitCall(conn, 0, []));
  iokitClose(conn);
} else {
  print("打开失败 conn=" + conn);   // 0 常见于 NotPermitted / NotFound
}
```

## 2. IOSurface 🟡

| 原语 | 签名 | 说明 |
|---|---|---|
| `iosurfaceProbe` | `() → string` | 探测 IOSurface 可用性 |
| `iosurfaceCreate` | `(props: object) → number` | 创建，返回句柄 |
| `iosurfaceGetID` | `(handle) → number` | 取全局 ID |
| `iosurfaceSetValue` | `(handle, key, value) → string` | 设属性 |
| `iosurfaceGetValue` | `(handle, key) → string` | 读属性 |
| `iosurfaceLookup` | `(cid: number) → number` | 按 ID 反查（跨进程可见性探测） |
| `iosurfaceRelease` | `(handle) → string` | 释放 |

## 3. XPC / 系统服务 🟡

| 原语 | 签名 | 说明 |
|---|---|---|
| `xpcLookup` | `(svc) → "REACHABLE"／"NOT_REACHABLE"` | 端口可见性 |
| `xpcProbe` | `(svc) → string` | 连接 + 探测结果 |
| `xpcSend` | `(svc, selector, payloadJSON) → string` | 发送消息 |
| `nsxpcProbe` | `(svc) → string` | NSXPC 风格探测 |

## 4. 网络 🟡

| 原语 | 签名 | 说明 |
|---|---|---|
| **`httpRequest`** ★ | `(opts) → JSON string` | **同步 HTTP(S)**：`{url, method, headers, body, timeout}` → `{ok, status, body, len, error}` |
| `tcpConnect` | `(host, port) → "OPEN"／…` | 单端口探测（0.3s 超时） |
| `tcpScan` | `(host, start, end) → string` | 端口段扫描 |
| `tcpSend` | `(host, port, hexPayload) → string` | 原始 TCP 发送（payload 用 hex） |
| `canOpenURL` | `(scheme) → string` | URL scheme 可达性 |
| `openURL` | `(url) → string` | 打开 URL |
| `installIPA` | `(manifestUrl) → string` | 🔴 itms-services 安装 |

**`httpRequest` 用法（调用 AI 后端 / 局域网服务）**

```js
var r = JSON.parse(httpRequest({
  url: "http://127.0.0.1:11434/v1/chat/completions",   // 或 https://…
  method: "POST",
  headers: { "Authorization": "Bearer sk-xxx" },
  body: JSON.stringify({ model: "qwen2.5-coder:7b",
                         messages: [{role:"user", content:"hi"}] }),
  timeout: 60
}));
print("status=" + r.status);
if (r.ok) print(r.body);
```

> ATS：`https` 无限制；局域网 `http` 依赖 Info.plist 的 `NSAllowsLocalNetworking`
> ——**建议用 `.local` 主机名**，裸 IP 不保证。

## 5. 设备 / 身份 / 系统 🟢（`runCommand` 为 🔴）

| 原语 | 签名 | 说明 |
|---|---|---|
| `appInfo` | `() → JSON string` | 应用与设备信息 |
| `getPid` | `() → number` | 进程 PID |
| `getEntitlements` | `() → string` | 读主可执行文件 `__TEXT,__entitlements` 段 |
| `sysctlGet` | `(name) → string` | sysctl 查询 |
| `getPasteboard` / `setPasteboard` | `() / (s)` | 剪贴板 |
| `runCommand` | `(cmd) → string` | 🔴 popen 执行 shell（会真的执行，谨慎） |

## 6. 文件与目录（相对路径基于 Documents）🟡

| 原语 | 签名 | 说明 |
|---|---|---|
| `readFile` | `(path) → string` | 失败返回 `[readFile error] …` |
| `writeFile` | `(path, content) → "ok"` | **整文件覆盖** |
| **`fileAppend`** ★ | `(path, content) → "ok"` | **追加**（跨轮次 checkpoint 的唯一手段） |
| **`fileExists`** ★ | `(path) → bool` | 存在性 |
| **`fileSize`** ★ | `(path) → number` | 字节数；-1 表示取不到 |
| **`fileDelete`** ★ | `(path) → "ok"` | 删除 |
| `listDir` | `(path) → string` | 目录列表 |
| `mkdir` | `(name) → string` | 建目录 |

**跨轮次持久化模式**（每次执行 ctx 都是新的，变量不保留）：

```js
var CK = "autorun_checkpoint.json";
var state = fileExists(CK) ? JSON.parse(readFile(CK)) : { done: [], round: 0 };
state.round++;
// …干活…
writeFile(CK, JSON.stringify(state));      // 覆盖式写状态
fileAppend("autorun_log.txt", "round " + state.round + " ok\n");   // 追加式写日志
```

## 7. 时间与控制 ★新增

| 原语 | 签名 | 说明 |
|---|---|---|
| **`now`** ★ | `() → {wall, mono}` | `wall`=挂钟秒；`mono`=单调秒（测耗时不跳变） |
| **`sleep`** ★ | `(ms) → ms` | 阻塞休眠（上限 120s）。**限速/间隔专用** |
| `print` | `(...) → void` | 输出（回传通道） |
| `require` | `("bridge_x.js") → string` | 动态加载桥库（改 JS 不用重编 IPA） |
| `RYC_RUN` | `(code) → any` | engine.js 提供的执行入口（Autorun 内部用） |

**限速模式**

```js
for (var sel = 0; sel < 8; sel++) {
  var t0 = now().mono;
  var r = iokitCall(conn, sel, []);
  print("sel " + sel + " -> " + r + "  (" + ((now().mono - t0) * 1000).toFixed(1) + "ms)");
  sleep(300);        // 每次调用之间留间隔，降低 panic 与「被系统记录」的风险
}
```

## 8. Autorun 服务 🟡

| 原语 | 签名 | 说明 |
|---|---|---|
| `autorunStart` | `(port) → "OK:listening:8899"` | 启动监听 |
| `autorunStop` | `() → string` | 停止 |
| `autorunStatus` | `() → JSON` | `{running, port, lanIP, busy, jobs}` |
| `autorunLog` | `() → string` | 最近日志 |
| `openAutorunPanel` | `() → "OK"` | 打开图形面板 |

## 9. JS 桥库函数（`RyConsoleScripts/*.js`，随 bundle 加载）

| 文件 | 函数 |
|---|---|
| `bridge_iokit.js` | `jbIokitEnum()`、`jbProbeIOKit(...)`、`jbIokitVerdict(...)`、`jbV3Battery()`、`jbV3Report()`、`jbV3MethodCall(...)` |
| `bridge_info.js` | `dumpIdentity()`、`dumpEntitlements()` |
| `bridge_net.js` | `scanCommonPorts(host)`、`httpGet(host, port, path)`、`hexEncode(str)` |
| `bridge_ui.js` | `enumSchemes()` |
| `jbV3StructProbe.js` | `zeroStructB64(n)`、`krStr(code)`、`log(...)` |
| `engine.js` | `RYC_RUN(code)`（可热重载；改它不用重编） |

## 10. IOReturn 错误码字典（回喂给 AI 用，必需）🟢

```js
var IORETURN = {
  "0":            "kIOReturnSuccess",
  "-536870174":   "kIOReturnNotPermitted",     // 0xe00002e2 —— 权限门禁，换策略而不是重试
  "-536870163":   "kIOReturnUnsupported",      // 0xe00002bc
  "-536870206":   "kIOReturnBadArgument",      // 0xe00002c7
  "-536870203":   "kIOReturnNotOpen",          // 0xe00002c2
  "-536870195":   "kIOReturnNotFound",         // 0xe00002ca
  "-536870187":   "kIOReturnNotReady",         // 0xe00002d5
  "-536870201":   "kIOReturnNoResources",      // 0xe00002a7
  "-536870208":   "kIOReturnIPCError",         // 0xe00002c8
  "-536870211":   "kIOReturnTimeout",          // 0xe00002d2
  "-536870212":   "kIOReturnNotPrivileged",    // 0xe00002d3
  "-536870165":   "kIOReturnVMError",          // 0xe00002ba
  "-536870199":   "kIOReturnExclusiveAccess",  // 0xe00002c5
  "-536870207":   "kIOReturnAborted"           // 0xe00002c9
};
function kr(code) {
  var n = (typeof code === "string" && /^0x/i.test(code)) ? parseInt(code, 16) : Number(code);
  return IORETURN[String(n)] || ("unknown (" + code + ")");
}
```

**判读要点**
- `kIOReturnNotPermitted` → **不是你写错了**，是门禁。应当停止重试，改为记录结论 / 换服务 / 换类型。
- `kIOReturnUnsupported` → 该 selector 不存在，换 selector。
- `kIOReturnBadArgument` → 入参结构/标量不对，调整参数。
- `kIOReturnNotPrivileged` → 缺 entitlement。

## 11. 已知没有的能力（别浪费时间找）

| 缺什么 | 替代方案 |
|---|---|
| `setTimeout` / `setInterval` | 用阻塞 `sleep(ms)` |
| 跨执行保留变量 | 落盘（`writeFile`/`fileAppend` + `readFile`） |
| 进程列表 / 任务枚举 | `sysctlGet` + `iokitEnum` |
| Keychain 访问 | 未提供 |
| 后台常驻监听 | iOS 限制：App 必须前台 |
| Objective-C 运行时 / dlopen | 未提供（桥是白名单式的） |

## 12. 改动须知

- 新原语必须在 `main.m` 的 `installPrimitives(ctx)` 里注册 —— **属于原生代码，改完要重编 IPA**。
- 只想加"高层函数"（组合已有原语）→ 写进 `RyConsoleScripts/bridge_*.js`，**不用重编**。
- 返回 JSON 字符串比返回裸对象更稳（可打印、可落盘、可回传）。
