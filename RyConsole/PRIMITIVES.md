# RyConsole 原生桥完整参考（PRIMITIVES）

> 由 `main.m` 的 `installPrimitives(ctx)` 注册，JS 侧**直接当全局函数调用**。
> 每次执行都是**全新 JSContext**（原语会重新注册），所以跨轮次状态必须落盘（见 §6 文件 IO）。
> 共 **69 个原生原语**（实测：`main.m` 里 `ctx[@"…"]=` 的唯一名字数）+ 8 个 JS 桥库文件。
>
> | 批次 | 新增 |
> |---|---|
> | V2 | 结构化 XPC（`xpcConn`/`xpcSendMsg`/`xpcClose`）、`machLookUp`、dyld（`dlopenFW`/`dlsymAddr`）、`sandboxCheck`、`keychainProbe`、`procListPids`、`posixSpawn` |
> | V2.1 | ObjC runtime：`objc_getClass` / `sel_registerName` / `objc_msgSend` / `objcDesc` |
> | V2.2 | `objc_msgSendSafe`（结构化错误 + 参数上限）、`memRead`（映射内存 dump）、`keepAliveStatus` / `keepAliveInfo`、`liveActivityStatus` |
> | V2.2.4 | **Bug6 自解释错误**：失败一律给「参数名 + 合法范围」；`iokitMapTry`、`krWhy/machKrWhy`、`primHelp/primErrors/primMissing`（详见「通用约定 → 错误约定」） |
> | **V2.3.0** | **`callPtr`（C 函数指针调用/FFI）**——补齐 dlopen/dlsym 之后最后一环；规格见 `RYCONSOLE_CALLPTR_SPEC.md`（§14 有完整说明） |

## 通用约定

- 相对路径 → 基于 **App 的 Documents**；以 `/` 开头 → 绝对路径。
- 返回字符串的原语：失败时通常返回以 `[xxx error]` 开头的说明，**不会抛异常**。
- `print()` 是回传通道（Autorun 下收进 `output`）；`return` 的值进 `result`。
- 安全分级：🟢只读 / 🟡状态影响 / 🔴高危（需人工确认）

### 错误约定（v2.2.4 起强制，Bug6）

**判据只有一句：字符串里出现 `] error]` 就是错误。** 调用方不用猜。

| 形态 | 样子 | 怎么读 |
|---|---|---|
| ① 自解释错误串 | `"[<桥名> error] <参数名> + <合法范围>"`<br>例：`memRead(h,0)` → `[memRead error] len must be 1..65536` | 直接照它改参数 |
| ② 结构化结果 | `{ret/kr, ok, outputs, error?, hint?, note?}` | `ok:false` 时看 `error`（是什么）+ `hint`（下一步怎么办） |
| ③ 裸数字/裸码 | `iokitOpen("Foo")` → `-2`；`iokitCall(...).ret` → `0xe00002c2` | **先过 `krWhy(kr)`（IOKit）或 `machKrWhy(kr)`（Mach/bootstrap）**，别把数字贴给人看 |
| ④ 单例哨兵 | `-1` / `-2` / `-3` / `0x0` | `-2`=类不存在、`-3`=类名为空（参数错）、`0x0`=类/符号不存在 |
| ⑤ 类型错（v2.2.5） | `iosurfaceCreate("x")` → `[iosurfaceCreate error] props must be an object/dictionary (可省略), got string("x") \| 签名: … \| 查参数: primHelp("iosurfaceCreate")` | 由 `bridge_guard.js` 在进入原生前拦住 |

> **为什么会有 ⑤**：原生桥 block 参数是强类型的（`NSDictionary*`/`NSString*`/`NSNumber*`），JS 传错类型时
> **JavaScriptCore 会在进入原生校验前就抛英文 `TypeError`**（如 `Cannot convert primitive to NSDictionary`），
> 中文错误根本没机会执行。`bridge_guard.js`（纯 JS，**可热更新**）给 33 个原语套了类型守卫，把这种错误转成 ①。
> 通用技巧：**桥脚本能覆盖原生全局**，所以"外壳逻辑"（参数/类型校验）尽量放 JS 层 —— 不用重编 IPA。

**排查顺序**：① 有 `] error]`/`ok:false` → 参数错；② conn 报"不是有效 send right" → 句柄失效；③ `kr=0xe00002e2` → 沙盒/entitlement 门禁（用户态无解）；④ `kr=0xe00002c2` → 驱动的 check* 拒了 (selector, 标量数, struct 大小) 组合，换形状；⑤ `kr=0xe00002c6` → selector 没注册。

**在设备上查文档**（不用翻这份文件）：
```js
primHelp()              // 全部原语速查（标 ✅自解释 / ⚠裸码）
primHelp("iokit")       // 过滤
primHelp("iokitMap")    // 单个完整说明：参数名/类型/合法范围/返回/错误
primErrors()            // 上面这套错误约定的机读版
primMissing()           // 还欠自解释的桥（诚实清单）
krWhy(-536870206)       // "kIOReturnBadArgument (0xe00002c2) — 参数形状被拒…"
```

---

## 1. IOKit / 内核接口（核心）🟢

| 原语 | 签名 | 说明 |
|---|---|---|
| `iokitEnum` | `() → string[]` | 枚举 IORegistry 服务类名（去重，攻击面地图） |
| `iokitOpen` | `(cls: string, type: number) → number` | 打开 IOService，返回 conn；**>0 成功**。`-2` 类不存在 / `-3` 类名为空 / `-536870174` NotPermitted / `-9999` 抛异常 |
| `iokitCall` | `(conn, sel, inputs: number[]) → {ret, outputs, inCount, ok, error?}` | 标量入参调用（≤16 个；非数字项被忽略并在 `note` 点名，不再静默占位） |
| `iokitCallStruct` | `(conn, sel, scalarInputs, structB64, outSize) → {ret, outputs, outStruct, outStructSize, ok}` | 带 inputStruct/OOL 输出（struct 以 base64）。`outSize` 合法 1..65536，超界会兜底 4096 并在 `note` 说明 |
| `iokitMap` | `(conn, mapType) → {ret, ok, addr?, size?, error?, hint?}` | 映射内存。失败**不再只回裸 kr**：给 `error`（是什么）+ `hint`（怎么办） |
| `iokitClose` | `(conn) → number` | 关闭 |
| `bytesB64` | `(arr: number[]) → string` | 字节数组 → base64 |
| `b64Bytes` | `(b64: string) → array` | base64 → 字节数组 |

**典型用法**

```js
var conn = iokitOpen("IOSurfaceRoot", 0);
if (conn > 0) {
  var r = iokitCall(conn, 0, []);
  if (!r.ok) print("失败 " + krWhy(r.ret) + " / " + (r.error || ""));   // 别贴裸数字
  var m = iokitMapTry(conn);                                            // memType 不确定就先扫
  print(m.verdict);
  iokitClose(conn);
} else {
  print("打开失败: " + krWhy(conn));   // -2 类名错 / -3 类名为空 / 0xe00002e2 沙盒门禁
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

## 3. XPC / 系统服务 / dyld / 沙盒 / 钥匙串 / 进程 🟡

| 原语 | 签名 | 说明 |
|---|---|---|
| `xpcLookup` | `(svc) → "REACHABLE"／"NOT_REACHABLE"` | 端口可见性 |
| `xpcProbe` | `(svc) → string` | 连接 + 探测结果 |
| `xpcSend` | `(svc, selector, payloadJSON) → string` | 发送消息（旧版，裸字典） |
| `nsxpcProbe` | `(svc) → string` | NSXPC 风格探测 |
| **`xpcConn`** ★ | `(svc) → "0x…"／错误串` | **结构化 XPC**：建连接句柄（V2） |
| **`xpcSendMsg`** ★ | `(conn, dict) → JSON` | 发结构化消息（`{type:"dictionary"|"string"|"uint64"|…}`），回 `{ok,reply}` |
| **`xpcClose`** ★ | `(conn) → "ok"` | 关连接 |
| **`machLookUp`** ★ | `(svc) → "0x…"` | `bootstrap_look_up` 拿 mach port（不发消息也能看可达性） |
| **`dlopenFW`** ★ | `(path, flag?) → JSON` | `dlopen` 私有框架（如 `/System/Library/PrivateFrameworks/…`） |
| **`dlsymAddr`** ★ | `(handle, sym) → "0x…"` | 取符号地址，配合 `objc_msgSend`/`memRead` 用 |
| **`sandboxCheck`** ★ | `() → JSON` | 读自身 sandbox 容器/权限概况（判定"能碰哪"） |
| **`keychainProbe`** ★ | `(class, service, account) → JSON` | Keychain 读探测（通常 `errSecMissingEntitlement`） |
| **`procListPids`** ★ | `() → JSON` | 进程 PID 列表（`sysctl KERN_PROC_ALL`） |
| **`posixSpawn`** ★ | `(path, argv[], timeoutMs) → JSON` | 起子进程 + 收 stdout（超时上限 30s） |

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

**后台保活（V2.2）**：`autorunStart` 成功后会**自动开启保活**，`autorunStop` 会立刻释放。
保活 = `AVAudioSession(playback, mixWithOthers)` 循环播放 ≈ -78 dBFS 的极低幅度音频
（人耳不可闻，但样本非零，系统才认"在播放"）+ `beginBackgroundTaskWithName` 每 8s 无限续期
+ 周期性重新激活音频会话（被通话/录音抢走后自愈）。

- 效果：**监听期间可以切后台、锁屏，App 不会被挂起**，电脑端仍能连；停止监听即完全断开保活。
- 前置：`Info.plist` 必须声明 `UIBackgroundModes = [audio, fetch]`（本仓库 project.yml 已写死）。
- 自签（免费/个人证书）同样生效——这是 Info.plist 声明，不依赖特殊 entitlement。
- 只读查询：`keepAliveStatus()` 一行字串；`keepAliveInfo()` JSON `{active, audioPlaying, audioRestarts, bgTaskRenewals, background, …}`。
- 限制：iOS 仍可能在某些场景（低电量模式、系统回收压力、录音占用）终止进程；
  音频保活是"极大延长"，不是"永久豁免"。真机长时间挂后台请以 `/ping` 心跳确认。

## 9. ObjC runtime 万用桥（V2.1 / V2.2）🔴

> 一次性投入：拿到 Class / SEL / 任意消息发送能力后，**所有已链接到进程的 ObjC 类**（含私有框架类）
> 立即可驱动 —— 应用枚举、URL 打开、系统服务这些公开能力不再需要额外 entitlement。

| 原语 | 签名 | 说明 |
|---|---|---|
| `objc_getClass` | `(name) → "0x…"` | 类句柄（永生，不会失效） |
| `sel_registerName` | `(name) → "0x…"` | SEL 句柄 |
| `objc_msgSend` | `(recv, sel, args[]) → "0x…"` | 原始调用，直接返回寄存器值 |
| `objc_msgSendSafe` | `(recv, sel, args[]) → JSON` | **推荐用这个**：`{ok,value}` / `{ok:false,error}`，参数 >7 直接拒绝 |
| `objcDesc` | `(hex) → string` | 回读句柄：NSString 给原文，其它对象给 `description` |
| `memRead` | `(hex, len) → hex string` | 读那根指针指向的映射内存（上限 64KB，越界返回 `vm_read kr=` 不崩） |

**args 规则**：字符串 → 自动转 `NSString`；数字 → 当 `uint64` 位槽传；`{hex:"0x…"}` → 原始指针；`null` → `nil`。

```js
var WS   = objc_getClass("LSApplicationWorkspace");
var inst = objc_msgSendSafe(WS, "defaultWorkspace", []);
var url  = objc_msgSendSafe(objc_getClass("NSURL"), "URLWithString:", ["https://example.com"]);
var r    = objc_msgSendSafe(JSON.parse(inst).value, "openURL:options:configuration:error:", [url, {}, {}]);
print(r);
```

**红线**
- 只对**整型/指针返回**可靠；返回 `float`/`struct` 的方法不要用（arm64 无 stret 约定）。
- `alloc` / `new` / `copy` 经 msgSend 会泄漏 +1 引用（无 release 通道，短命进程可忽略）。
- ≤7 个参数（含 self/_cmd 之外的显式参数）。
- **block 参数方法不可调**（explicit `void(^)(void)` 变参在 JSC 里没有承载形态）。

## 10. JS 桥库函数（`RyConsoleScripts/*.js`，随 bundle 加载）

| 文件 | 函数 |
|---|---|
| `bridge_iokit.js` | `jbIokitEnum()`、`jbProbeIOKit(...)`、`jbIokitVerdict(...)`、`jbV3Battery()`、`jbV3Report()`、`jbV3MethodCall(...)`、**`iokitMapTry(conn, types?)`**、**`krName/krHex/krWhy/krHint`** |
| `bridge_guard.js` ★v2.2.5 新增 | **`installGuards()`** —— 给 33 个原语套类型守卫（`iosurfaceCreate`/`iokitMap`/`iokitCall`/`memRead`/`sysctlGet`/文件与网络族…），传错类型不再抛 JSC 英文 `TypeError` |
| `bridge_help.js` ★v2.2.4 新增 | **`primHelp(过滤词?)`**（原语自解释手册）、**`primErrors()`**（错误约定）、**`primMissing()`**（还欠自解释的桥清单） |
| `bridge_info.js` | `dumpIdentity()`、`dumpEntitlements()` |
| `bridge_net.js` | `scanCommonPorts(host)`、`httpGet(host, port, path)`、`hexEncode(str)` |
| `bridge_ui.js` | `enumSchemes()` |
| `bridge_xpc.js` | `xpcCall/machScan/symResolve/keychainScan/sandboxScan` + **`machKrWhy(kr)`** |
| `bridge_objc.js` | `objPtr`、`lsWorkspace`、`lsAppList(offset,limit)`、`lsAppListInfo`、`lsAppCount`、`lsAppInfo`、`lsOpenURL`、`lsOpenApp`、`objCall` |
| `engine.js` | `RYC_RUN(code)`（可热重载；改它不用重编） |

## 11. IOReturn 错误码字典（回喂给 AI 用，必需）🟢

> **v2.2.4 勘误**：本节旧表**整张都是错的**（名字与 hex 全错位，如把 `-536870163` 标成 Unsupported、把 `0xe00002c7` 标成 BadArgument）。
> 下表按 `IOKit/IOKitReturn.h` 的 `iokit_common_err(0x2xx)` 重新生成，并用真机实测的 3 个码交叉验证过：
> `-536870206`=BadArgument、`-536870202`=BadMessageID、`-536870174`=NotPermitted。

```js
// 建议直接用桥里的：krWhy(kr) / krName(kr) / krHint(kr)（bridge_iokit.js），下面是同源数据
var IOKIT_KR_HEX = {
  "e00002bc": "kIOReturnError",            "e00002bd": "kIOReturnNoMemory",
  "e00002be": "kIOReturnNoResources",      "e00002bf": "kIOReturnIPCError",
  "e00002c0": "kIOReturnNoDevice",         "e00002c1": "kIOReturnNotPrivileged",
  "e00002c2": "kIOReturnBadArgument",      "e00002c3": "kIOReturnLockedRead",
  "e00002c4": "kIOReturnLockedWrite",      "e00002c5": "kIOReturnExclusiveAccess",
  "e00002c6": "kIOReturnBadMessageID",     "e00002c7": "kIOReturnUnsupported",
  "e00002c8": "kIOReturnVMError",          "e00002c9": "kIOReturnInternalError",
  "e00002ca": "kIOReturnIOError",          "e00002cc": "kIOReturnCannotLock",
  "e00002cd": "kIOReturnNotOpen",          "e00002ce": "kIOReturnNotReadable",
  "e00002cf": "kIOReturnNotWritable",      "e00002d0": "kIOReturnNotAligned",
  "e00002d1": "kIOReturnBadMedia",         "e00002d2": "kIOReturnStillOpen",
  "e00002d5": "kIOReturnBusy",             "e00002d6": "kIOReturnTimeout",
  "e00002d8": "kIOReturnNotReady",         "e00002da": "kIOReturnNoChannels",
  "e00002db": "kIOReturnNoSpace",          "e00002e2": "kIOReturnNotPermitted",
  "e00002e6": "kIOReturnUnsupportedMode",  "e00002eb": "kIOReturnAborted",
  "e00002f0": "kIOReturnNotFound"
};
function kr(code) {                       // 传有符号数或 0x… 都行
  var n = (typeof code === "string" && /^0x/i.test(code)) ? parseInt(code, 16) : Number(code);
  return IOKIT_KR_HEX[((n >>> 0).toString(16)).padStart(8, "0")] || ("unknown (" + code + " / 0x" + ((n >>> 0).toString(16)) + ")");
}
```

**有符号 ↔ hex 对照（只列常用的，完整见上表）**

| 有符号 | hex | 名字 | 判读 |
|---|---|---|---|
| -536870206 | 0xe00002c2 | kIOReturnBadArgument | 驱动的 check* 拒了参数形状 → 换标量个数/struct 大小 |
| -536870202 | 0xe00002c6 | kIOReturnBadMessageID | selector 没注册 → 换 selector |
| -536870201 | 0xe00002c7 | kIOReturnUnsupported | 该 UserClient 不提供这条路径 → 别重试，换类/换路线 |
| -536870207 | 0xe00002c1 | kIOReturnNotPrivileged | 缺 entitlement |
| -536870174 | 0xe00002e2 | kIOReturnNotPermitted | 沙盒/entitlement 门禁，**用户态无解** |
| -536870195 | 0xe00002cd | kIOReturnNotOpen | conn 已关闭 → 重新 iokitOpen |
| -536870203 | 0xe00002c5 | kIOReturnExclusiveAccess | 设备被别的连接独占 |
| -536870181 | 0xe00002db | kIOReturnNoSpace | 输出/映射缓冲太小 |

**判读要点**
- `kIOReturnNotPermitted` → **不是你写错了**，是门禁。停止重试，改记录结论 / 换服务 / 换类型。
- `kIOReturnUnsupported` → 这条路该 UserClient 根本没有，换路线（重试无用）。
- `kIOReturnBadArgument` → 参数形状不对：先试空输入，再按 selector 声明逐步加结构体（`iokitCallStruct`）。
- `kIOReturnBadMessageID` → selector 无效，不是参数问题。

## 12. 已知没有的能力（别浪费时间找）

| 缺什么 | 替代方案 / 现状 |
|---|---|
| `setTimeout` / `setInterval` | 用阻塞 `sleep(ms)` |
| 跨执行保留变量 | 落盘（`writeFile`/`fileAppend` + `readFile`） |
| Swift / block 参数方法 | `objc_msgSend` 只能带指针/整型参，block 无承载形态 |
| 返回值是 `float` / `struct` 的方法 | 同上，只能拿整型/指针寄存器 |
| 开放 Keychain 明文 | `keychainProbe` 只做**读探测**，沙盒外条目一律 `errSecMissingEntitlement` |
| 内核内存 / 页表 | 用户态 `vm_read` 只能读**自己任务**的映射（`memRead`） |
| 真正的 PPL / KTRR 绕过 | 不在用户态桥的能力范围内 |
| 后台永久常驻 | 已用音频+bgTask 保活把监听期拉到"很长"，但不是永久豁免 |

> 曾经的"App 必须前台"限制**已解决**：见 §8 后台保活。

## 13. 改动须知

- 新原语必须在 `main.m` 的 `installPrimitives(ctx)` 里注册 —— **属于原生代码，改完要重编 IPA**。
- 只想加"高层函数"（组合已有原语）→ 写进 `RyConsoleScripts/bridge_*.js`，**不用重编**。
- 返回 JSON 字符串比返回裸对象更稳（可打印、可落盘、可回传）。

### 桥的作业方式（装桥 / 改桥都不用重编，v2.2.5）

加载顺序：**Documents 同名文件优先于包内默认**。所以改桥 = 写进 Documents。
一条命令搞定（`tools/ryc_bridge.py`，纯标准库）：

```bash
python tools/ryc_bridge.py <iPadIP> list          # 看：谁在用 Documents 覆盖、谁用包内默认、两边字节数
python tools/ryc_bridge.py <iPadIP> versions      # 看：设备上**实际加载**的每个桥版本（各桥自报 RYC_BRIDGES）
python tools/ryc_bridge.py <iPadIP> push bridge_x.js     # 装/改单个桥（写完回读校验字节数）
python tools/ryc_bridge.py <iPadIP> pushall             # 把本地 RyConsoleScripts/*.js 全推上去
python tools/ryc_bridge.py <iPadIP> get bridge_objc.js  # 把设备当前生效的源码拉回来（含包内默认）
python tools/ryc_bridge.py <iPadIP> rm bridge_x.js      # 删覆盖 → 回落包内默认
python tools/ryc_bridge.py <iPadIP> check               # 总览：连通/桥开关/覆盖数/版本/崩溃日志大小
```

**每个桥必须自报版本**（用户 2026-08-12 硬性要求，v2.2.5 起全量落实）：
```js
var BRIDGE_VERSION = "vX.Y (build YYYY-MM-DD)";
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }   // 各桥自持一段，顺序无关
RYC_BRIDGES["bridge_x"] = BRIDGE_VERSION;
print("[bridge_x] 已加载: … (" + BRIDGE_VERSION + ")");
```

## 14. 崩溃兜底（V2.2.6）★

探针把 App 打崩 → 现在**不再重启进程**，而是这次执行以「触发崩溃，已兜底」返回。

| 原语 | 签名 | 说明 |
|---|---|---|
| `crashGuardStatus` | `() → string` | JSON：`enabled / hits / lastSignal / lastAddr / lastPrim / degraded` + 能兜/不能兜清单 |
| `crashGuardSet` | `(0或1) → string` | **关掉 = 恢复真崩**。想在探针里用 pid 差分定位崩溃时，先 `crashGuardSet(0)` |

**机制**：每次执行前在**调用线程**布 `sigsetjmp` 检查点（Terminal / 资源管理器 / Autorun 三条路都套）；
本线程发生 SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP → 信号处理器写崩溃日志 → `siglongjmp` 回检查点 →
本次执行返回「已兜底」，进程存活。装了 `sigaltstack`，爆栈也能兜。

| | |
|---|---|
| ✅ 能兜 | 用户态信号类崩溃：野指针 / 空函数指针 / `objc_msgSend` 打空 / 越界读 / JSC 深递归爆栈 |
| ❌ 不能兜 | **内核 panic**（驱动/IOKit 内核侧触发 → 设备重启）、看门狗卡死（0x8badf00d）、**非布点线程上的崩溃**、外部 kill |

**★ 对调用方（AI）的影响 —— 必读**
1. **兜底开着时，被拦下的崩溃不改 pid** → **pid 差分法失效**。改看：`/eval` 返回的 `guarded:true` +
   `guardSignal/guardAddr/guardPrim`，或 `/ping` 的 `guardHits/guardLastPrim/guardDegraded`。
2. `guarded:true` 的语义是"**这条代码确实会把 App 打崩**"，只是被拦了 —— **别当成普通失败去重试**。
3. 被拦下的那次执行是**被掀栈**结束的，锁/内存/JSC 状态可能不干净（`guardDegraded:true`）——
   若后续行为诡异，**重启 App 复位**再继续。
4. 想要"真崩"（验证崩溃本身、测 pid 变化）：探针第一行 `crashGuardSet(0)`，跑完 `crashGuardSet(1)` 恢复。

## 15. callPtr —— C 函数指针调用（V2.3.0）★

规格：`RYCONSOLE_CALLPTR_SPEC.md`（研究侧 2026-09-19）。补齐 `dlopenFW` → `dlsymAddr` → **调用** 的最后一环。

| 原语 | 签名 | 说明 |
|---|---|---|
| `callPtr` | `(addrHex, args?, opts?) → {ok, value, out?, error?, hint?}` | 调用 `dlsymAddr`/`symResolve` 拿到的 C 函数地址 |

**实参打包**（≤8 个；与 objc_msgSend 位槽规则同源）：

| JS 传入 | 打包为 |
|---|---|
| `number` | `unsigned long long` 位槽 |
| `string` | **C 字符串** `const char *`（★ 与 objc_msgSend 不同，不是 NSString 对象） |
| `{hex:"0x…"}` | 原始指针 |
| `{buf:<n>}` / `{buf:true}` | 分配 n 字节可写缓冲（calloc 零填充），**调用后内容按 base64 回传 `out.bufN`** |
| `{str:"…"}` | 可写 C 字符串（char* 输出参数用） |
| `null` / 缺省 | `NULL` |

**返回**：统一取 x0（uintptr_t）转 hex 串。整型 `parseInt(v,16)`；指针可喂 `memRead`/`objcDesc`。
`opts.bufSize` 设 `{buf:true}` 未指大小时的默认（1024，上限 65536）。

**安全网**（构建侧在规格之上加的两道）：
1. 函数地址先 `vm_read` 体检 → 垃圾地址返回 `[callPtr error] 地址 0x… 不可读`，不靠崩溃兜底硬扛；
2. 调用坏函数真正崩了 → crashGuard 拦成 `guarded:true`（内核 panic 除外）。

**红线**：只支持**整型/指针**返回；float/struct 返回不适用（同 `objc_msgSend` 限制）。

```js
// 验收（研究侧 §五）
var a = dlsymAddr(0, 'strlen');
JSON.stringify(callPtr(a.addr, ['hello']));      // 期望 {"ok":true,"value":"0x5"}
var b = dlsymAddr(0, 'strcmp');
JSON.stringify([callPtr(b.addr,['abc','abc']), callPtr(b.addr,['abc','abd'])]);  // 0x0 / 非0
var c = dlsymAddr(0, 'getcwd');
JSON.stringify(callPtr(c.addr, [{ buf: 1024 }]));  // value=缓冲地址, out.buf0=base64(工作目录)
```

## 16. 环境与网络（V2.4.13 新增 / V2.4.14 改端点分类）★

> 本节 C 函数实现在 `main.m`，声明在 `RYPermLog.h`；面板「权限与安全 → 环境」页是它们的可视化。

| 原语 | 签名 | 说明 |
|---|---|---|
| `envState` | `() → JSON` | 环境快照：`{clean, uid, euid, gid, egid, pid, groups[], groupCount, ip, interfaces[], net, hasNetwork, serverRunning, sharedMapCount, batchUsed, batchActive, slotNonZero, reasons[]}`。`clean = 共享字典空 && 无竞态批次 && 原子槽全零`；脏时 `reasons` 逐条给原因。★ **V2.4.15 起「服务端运行中」不算污染**（它是工作台不是残留） |
| `envReset` | `([stopServer]) → JSON` | **原地复位**：清 `gSharedMap`、16 个 `gRaceSlots` 归零、`gRaceStop` 归零、回收全部 `gBatches`（销毁闸 mutex/cond、清零 done/guarded/taken、置空 results）。★ **V2.4.15 起默认不停服务端**（监听是工作台，重置只清残留，**电脑端连接不断**）；传 `true` 才调 `RYAutorunStop()`。返回 `{ok, recycledBatches, sharedMapCleared, slotsZeroed, serverStopped, serverKeptRunning, serverWasRunning, serverStop, note?}` |
| `envIP` | `() → [{if, family, ip, kind}]` | `getifaddrs` 枚举全部接口 IPv4/IPv6；`family` = `inet`/`inet6`，`kind` = `wifi`/`hotspot`/`cellular`/`vpn`/`other` |
| **`envNet`** | `() → JSON` | ★ **分类端点**：`{wifi?, hotspot?, cellular?, hasAny, all[]}`，各类形如 `{if, kind, ip}`。**没有的那一类不出现**（没连 Wi-Fi 就无 `wifi` 键，没开蜂窝就无 `cellular` 键）；`hasAny:false` = 网都没有 |
| `envServerStart` | `(port) → JSON` | 起服务并回 `{ok, port, ip, urls[]}`；`urls` **按类各一条** `{kind, if, ip, url}`。**`hasAny=false` 时直接返 `{ok:false, error:"无可用网络…"}` 且不启动监听** |
| `envServerStop` | `() → string` | 停服务 |
| `envServerStatus` | `() → JSON` | 同 `/ping`（`running`/`port`/`lanIP`/`endpoints`…） |

**主地址的选取优先级**（`RYReachableIP()`，原名 `RYHotspotIP()`；排除 `127.*`、`awdl*`、`lo*`）：
`en0` / `en1`（Wi-Fi）→ `bridge100`（个人热点）→ `pdp_ip0` / `ipsec0`（蜂窝）→ 其它非回环接口兜底。

> ⚠️ **V2.4.14 修正**：旧版把 `bridge100` 排最前 → **连着 Wi-Fi 时却报热点的 `172.20.10.1`**，
> 而电脑在同网段 Wi-Fi 上根本连不到它。现在 **Wi-Fi 优先**，热点只在没有 Wi-Fi 时才当主地址。
> 服务端 `bind("0.0.0.0")` 全接口可连，**各类地址其实同时可达** —— 主地址只是"最可能的那个"，
> 完整列表用 `envNet()`（`/ping` 的 `endpoints` 字段同源）。

> 热点场景：iPhone/iPad 个人热点的 `bridge100` 通常是 `172.20.10.1`，连上热点的电脑拿到 `172.20.10.2` 等。
> 蜂窝的 `pdp_ip0` 常被运营商 NAT，电脑要连上一般得**连到设备的热点**，那时用 `hotspot.ip`。

**配套（V2.4.12，此前未录入本节）**：

| 原语 | 签名 | 说明 |
|---|---|---|
| `memWrite` | `(addrHex, data) → JSON` | 向本任务地址空间写二进制（`vm_write` 就地覆盖）。`data` 支持 hex 串 / `"b64:…"` / `{b64:"…"}`；kr 干净报错（2=未映射，4=页只读）；64KB 上限，与 `memRead` 对称 |
| `threadBatches` | `() → JSON` | 逐槽 dump 竞态批次注册表（`used/joined/id/n/ready/done/taken` + `seq`），排查 `threadJoin` 收割不到时用 |

> ⚠️ **待补录**：竞态 harness 全套（`threadSpawn` / `threadJoin` / `raceBarrier` / `raceSharedSet|Get` /
> `raceSlotSet|Get|AtomicAdd|AtomicCas` / `raceRounds` / `threadProgress` / `threadStop|Flag`，
> V2.4.3～V2.4.5 引入）尚未在本文件展开，签名以 `ERRATA_AND_TOOLING.md` 版本表 + 设备上 `primHelp("<名>")` 为准。
