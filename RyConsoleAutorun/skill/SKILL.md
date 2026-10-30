---
name: ryconsole-autorun
description: >-
  通过局域网把 JS 代码送到 iPad 上的 RyConsole 执行，并取回结果（AI 在电脑端，iPad 只负责「执行 + 回传」）。
  当需要在真机 iPad 上跑 iOS 探针 / IOKit 调用 / 沙盒能力测试 / 执行任意 JS 并拿到输出与返回值时使用。
  典型触发：「在 iPad 上跑这段 JS」「用 RyConsole 执行」「真机验证这个探针」「把结果传回来看」。
  内置轮询契约：提交后每 3 秒查一次结果、最多 12 次；并含全部实踩坑点（连不上的四要素、
  面板必须先启动、V2.2 起监听期自带后台保活（可切后台/锁屏）、print 捕获语义、轮询未完成的判定与处置）。
  ★ 关键坑（v1.0 实测）：提交必须用 JSON body（form 分支不做 percent-decode，会静默失败）、
  job 只活 ~36s（超时变 404 而非报错）、`lsAppList()` 一次调用即崩进程、服务单线程（并发必坏）。
  ★ 若官方 exe 只报 `unknown job`，改用直连客户端 `ryc.py` 看服务端原始响应。
agent_created: true
---

# RyConsole Autorun —— 用 iPad 当"执行手"

## 核心心智模型

```
AI（电脑端 / Ryan）  ── 写 JS ──▶  RyConsole（iPad，Autorun 服务）  ── 执行 ──▶  回传 JSON
        ▲                                                                          │
        └────────────────────────── 结果（output / result / error） ◀───────────────┘
```

**AI 不在设备上，也不需要在设备上**。iPad 只是一个「能碰底层接口的执行环境」，
所有判断、迭代、下一步决策都在电脑端（也就是你）这边做。
这绕开了端上算力的一切限制：不需要在 iPad 上跑模型。

## 前置条件（缺一不可，先检查再动手）

| 条件 | 怎么确认 |
|---|---|
| iPad 上 Autorun 已启动 | 应用内打开面板点「启动」，或在控制台执行 `autorunStart(8899)`；面板顶部会显示本机 IP |
| iPad 与电脑同一局域网 | 电脑 `ping <iPadIP>` 能通 |
| RyConsole 处于**保活态** | V2.2 起点「启动监听」后自动保活（静音音频 + 后台任务续期）→ **可切后台 / 锁屏**；面板提示应为「● 正在监听 · 后台保活已开」，灵动岛/锁屏显示「监听中」。若面板显示未启动就是没开 |
| 端口一致 | 默认 `8899`（面板里可改） |

**先跑 `ping` 确认，再谈执行。** ping 不通时不要盲目重试，按下面报错表处理。

## 工具位置（路径不写死 —— 见下方「调用第一步」）

```
tools\ryc_autorun.py        # ★ Agent 用这个（CLI，无第三方依赖；已可打包为单 exe ryc_autorun.exe）
tools\ryc_gui.py            # 电脑端图形界面（人看结果用；也可给 Agent 当控制接口）
tools\RunAutorunPanel.bat   # 双击启动 GUI（纯 ASCII，内含 %USERPROFILE% 运行时解析）
tools\logs\autorun_gui.jsonl# GUI 每轮交互追加落盘（Agent 直接读文件也能取结果）
```

> ⚠️ **软件位置不写死**：本 skill 不假设 `ryc_autorun.exe/.py` 的绝对路径（项目随工作区目录如带时间戳的 `2026-07-22-11-14-51` 移动 / 被清理后写死会断）。

**调用第一步（必做）**：AI 加载本 skill 后，**先向用户询问 `ryc_autorun` 可执行文件的实际位置**
（`ryc_autorun.exe` 或 `ryc_autorun.py` 的绝对路径 / 所在目录）。
- 若本对话中用户已给过路径或 IP，直接采用，不必重复问。
- 拿到后记作 `<RYC_EXE>`；建议先跑 `<RYC_EXE> --help` 验证文件存在且可执行。
- 解释器：纯标准库，任意 Python 3.8+ 均可；若用 `.exe` 则无需 Python 环境。

## 命令速查（`<RYC_EXE>` = 上方询问用户得到的可执行文件位置）

```bash
# 0) 连通性（永远先做这一步）
<RYC_EXE> ping --host <iPadIP> --port 8899

# 1) ★ 标准动作：提交 + 自动轮询（每 3s，最多 12 次）
<RYC_EXE> run --host <iPadIP> --code-file <探针.js 绝对路径> --json --quiet

# 2) 同步执行（代码很快时用；会占住连接）
<RYC_EXE> eval --host <iPadIP> --code 'return 1+1'

# 3) 手动两步（需要自己控制轮询节奏时）
<RYC_EXE> submit --host <iPadIP> --code-file <探针.js 绝对路径> --json
<RYC_EXE> result --host <iPadIP> --id j1 --json
```

> 探针 `.js` 文件用绝对路径（或相对 `<RYC_EXE>` 所在目录）；不要依赖当前工作目录。

**默认就用 `run`**：它已经内置了「提交 → 每 3 秒查一次 → 最多 12 次」的契约（≈36 秒上限，足够跑完并回传）。
不要自己写 sleep 循环去轮询 —— 用脚本里的 `run`，避免节奏不一致。

## 电脑端图形界面（给人看；也给 Agent 当第二入口）

```bash
# 双击启动
tools\RunAutorunPanel.bat
# 或命令行（可预填目标；路径同 <RYC_EXE> 所在目录，记作 <RYC_EXE_DIR>）
<RYC_EXE_DIR>\ryc_gui.py --host 192.168.0.110 --port 8899
python ryc_gui.py --no-control          # 不启动 AI 控制接口
python ryc_gui.py --selftest --port 18899   # 无界面自测（需 mock 服务）
```

界面（深色科技风，与 iPad 端同一套配色）：顶栏 `iPad IP / 端口 / 连接`＋状态灯；
中部「发送到 iPad 的代码」编辑区（载入 .js / 另存 .js / 清空 / 执行，`Ctrl+Enter` 也可执行）；
下部「执行结果 / 回传内容」（状态 pill：待命→执行中→已回传/未回传，含往返毫秒、print 段、返回值段、错误段）；
底部「事件日志」逐次打印轮询进度。

### 内置 AI 控制接口（默认开，仅绑 127.0.0.1:8877）

GUI 在跑时，Agent 可以**不经过 CLI**直接驱动它 —— 好处是用户能实时看到"AI 正在发什么代码、回传了什么"：

```bash
GET  http://127.0.0.1:8877/status          # 目标/连接/忙闲/最近结果摘要
GET  http://127.0.0.1:8877/ping
POST http://127.0.0.1:8877/exec  {"code":"...", "host":"...", "port":8899}
GET  http://127.0.0.1:8877/result?id=j7
GET  http://127.0.0.1:8877/last            # 最近一次完整结果
GET  http://127.0.0.1:8877/log?n=80        # 事件日志文本
GET  http://127.0.0.1:8877/history?n=20    # 历史（不含代码，防爆量）
POST http://127.0.0.1:8877/stop
```

`/exec` 是**阻塞式**的：内部走完「submit → 3s 轮询 ×12」才返回最终 JSON（结构与 CLI 的 `run --json` 一致）。
Agent 发来的代码会自动回显到 GUI 编辑区，用户看得见。

**两条路怎么选**：GUI 没开 → 用 CLI；GUI 开着且希望用户旁观 → 走控制接口。
无论哪条，结果都会追加进 `logs\autorun_gui.jsonl`（GUI 路径）。

## 输出怎么读

```json
{
  "id": "j7",
  "status": "done",        // running / done
  "ok": true,               // 代码是否无异常
  "output": "print 的全部输出（多行）",
  "result": "代码 return 的值（已转成字符串）",
  "error": null,            // 有异常时是异常文本（含堆栈）
  "ms": 1234                // 执行耗时
}
```

- `ok:false` 且 `error` 有内容 → **代码本身报错了**（不是通信问题），读 `error` 改代码。
- `error` 里出现 `[JS Error]` 前缀 → 该行是 JS 异常，可能与 `output` 交错，注意区分。
- `status:"running"` 跑满 12 次 → 说明代码还没跑完（或卡住）。**不要无脑重试**：先让用户看 iPad 屏幕，
  确认 App 是否被系统回收（保活态的灵动岛/锁屏应仍显示「监听中」）、是否弹了系统弹窗（如局域网权限），
  必要时把代码拆小分步跑，或让用户重新点「启动监听」。

## ★ 提交与轮询的硬约束（v1.0 实测，2026-09-18）

服务端真实 API：

```
POST /submit   Content-Type: application/json   body: {"code":"<js>"}     (form/裸 JS 也支持)
               -> {"ok":true,"id":"j<session>-N","status":"accepted",
                   "pollIntervalMs":3000,"maxPolls":12,"jobTtlSec":300,"srcKind":"json"}
GET  /result?id=jN   -> {status, result, output, id, ms, ok, error, codeLen, srcKind, ts}
                        （过期 -> {"error":"job_expired","hint":...}；无此 id -> "unknown_job"）
GET  /ping           -> {ok, port, lanIP, jobs, busy, version, running,
                         hits, pid, session, lastCodeLen, lastCodeHead, lastSrcKind, lastPrim, jobTtlSec}
```

| # | 约束 | 症状 | 处置 |
|---|---|---|---|
| 1 | JSON body（**V2.2.2 起 form 也支持**） | 老版 form 分支不做 percent-decode：`%22`/`%28` 被当字面量送进 `new Function()` → SyntaxError 且 `ok:true`（完全静默）。**V2.2.2 已修**（完整 percent-decode + `srcKind` 标记；body 不像 form 就当裸 JS） | 仍推荐 `json.dumps({"code": code})` + `Content-Type: application/json` |
| 2 | job 保留 **300s**（V2.2.2 起） | 老版只活 ~36s，过期返裸 404。现在过期返 `{"error":"job_expired","hint":...}`（HTTP 200），`unknown_job` 才是真没这个 id | 长任务仍建议拆多轮；查 `/ping` 的 `jobTtlSec` |
| 3 | 服务单线程（V2.2.2 起 busy 返 **429**） | 并发 `POST /eval` → 后到的原本会被断连（`RemoteDisconnected`）。现在返回 `429 + retryAfterMs` | **仍要串行**：一次一个探针；长活走 `/submit` |
| 4 | 异常带 name+message+stack（V2.2.2 起） | 老版只留一行被截断的 stack，`error` 还是 null | 现在 `error` 字段有完整异常；自己包 try/catch 依然更稳 |
| 5 | `jobs` 计数会跳变、重启后 id 带会话前缀（`j<session>-<n>`） | 旧 id 查不到 | 别缓存 id 跨请求复用；`/ping` 的 `session`/`pid` 变化即"服务重启过" |

### 直连客户端（官方 exe 掩盖错误时用）

官方 `ryc_autorun.exe` 在 job 过期时统一报 `unknown job`，看不到服务端原始响应。备一个直连客户端：

```bash
python ryc.py <iPadIP> 8899 <probe.js>     # stderr 打印 /ping /submit 原始响应，stdout 打印完整 job 结果
```

关键实现（10 行）：
```python
body = json.dumps({"code": code}).encode("utf-8")
req = urllib.request.Request(f"http://{h}:{p}/submit", data=body, method="POST")
req.add_header("Content-Type", "application/json")
jid = json.loads(urllib.request.urlopen(req, timeout=25).read())["id"]   # 然后轮询 /result?id=
```

### 崩溃桥黑名单（v1.0 实测 → **V2.2.3 已修**）

| 桥 | v1.0 | V2.2.3 起 | 说明 |
|---|---|---|---|
| **`lsAppList()`** | ❌ 必崩 | ✅ **可用**（分页） | 老版一次调用即进程重启（pid 差分实证）。**根因**见下。现改为 `lsAppList(offset, limit)`（默认 120 / 上限 200）+ `lsAppCount()` / `lsAppListInfo()`，返回 bundleID 字符串数组 |
| **`objc_msgSend` / `objc_msgSendSafe` 调标量-返回 selector** | ❌ 必崩 | ✅ 可用 | `count`/`length`/`intValue`/`isEqual:` 这类现在能直接调，返回值就是整数的十六进制串 |
| `objc_getClass` / `sel_registerName` / `objcDesc` | ✅ | ✅ | `objcDesc` 新增指针体检：把标量当对象传进来会返回提示串而不是崩 |
| `iokitOpen` / `iosurfaceProbe` / `lsWorkspace` / `memRead` / `objPtr` | ✅ | ✅ | 可放心用（`memRead` 只读本进程映射） |
| `openAutorunPanel()` | ❌ 必崩 | ✅ 可用 | 它从 **Autorun 连接线程（后台）** 读 keyWindow + present 视图 = 后台碰 UI → 段错误。已改为切主线程（返回 `OK:queued-on-main`） |
| `iokitMap` | ❓ | ✅ 用法明确 | **签名早已确定**：`iokitMap(conn, memType)`（就是 `IOConnectMapMemory64(conn, memType, mach_task_self(), …, kIOMapAnywhere)`）。一直回 `kIOReturnBadArgument` **不是签名问题**，而是多数 UserClient 没实现 `clientMemoryForType`。V2.2.4 起失败会给 `{ok:false, error, hint}`，并可用 **`iokitMapTry(conn)`** 扫 0..15 一次定论 |

> **崩溃根因（2026-09-18，安全研究 AI 源码级定位，已在 V2.2.3 修复）**：
> `main.m` 的 `objcMsgSendNative` / `objcMsgSendSafeNative` 用 `id ret = nil;` 接 `objc_msgSend` 返回值。
> ARC 下 `id` 是 `__strong`，**赋值即插入 `objc_retain()`**；当 selector 返回**标量**（如 `count` 返回 `0x1f`）时，
> `objc_retain(0x1f)` 去解引用非法地址 → **SIGSEGV**（信号级，`@try/@catch` 抓不到，所以表现为"一次调用即重启"）。
> 修法：**`__unsafe_unretained id ret`**（两处，各一行）。
>
> 定位手段（可复用）：① `readFile("ryconsole_crash.log")` 取栈（V2.2.1 起自动记录）；
> ② **pid 差分**：ping 拿 `pid` → 发探针 → 再 ping；pid 变了就是这条探针把进程打崩了（`/ping` 现带 `pid`/`session`）；
> ③ V2.2.2 起崩溃日志与 `/ping` 还带 **`lastPrim`**（崩溃时正在执行哪个原语），可直接点名。
>
> **★ V2.2.6 崩溃兜底改变了 ②**：探针触发的**用户态信号崩溃**（SIGSEGV/SIGBUS/…）不再重启进程 ——
> 本次执行以「触发崩溃，已兜底」返回，App 存活。所以：
> - **兜底开着时 pid 差分失效**（pid 不再变）→ 改看 `/eval` 返回的 **`guarded:true`** + `guardSignal/guardAddr/guardPrim`，
>   或 `/ping` 的 `guardHits / guardLastPrim / guardDegraded`；
> - **`guarded:true` = 这条代码确实会崩**（有价值的结论：找到了真实崩溃面），只是被拦了 —— **别当普通失败重试**；
> - 被拦下的那次执行状态可能不干净（`guardDegraded:true`），后续行为诡异就**重启 App 复位**；
> - 想真崩（验证崩溃本身 / 用 pid 差分）：探针里 `crashGuardSet(0)`，跑完 `crashGuardSet(1)`；
> - 边界：❌ 内核 panic（IOKit 内核侧 → 设备重启，用户态无解，且崩溃日志通常来不及写）❌ 看门狗卡死 ❌ 非布点线程。

## 报错处置表

### 错误自解释约定（V2.2.4 起，Bug6 修复）

**判据一句话：字符串里出现 `] error]` 就是错误**，不用猜。

| 形态 | 例子 | 怎么读 |
|---|---|---|
| 自解释串 | `memRead(h,0)` → `[memRead error] len must be 1..65536`<br>`sysctlGet("")` → `[sysctlGet error] name must be a non-empty string…` | 照它改参数 |
| 结构化 | `iokitMap(0,0)` → `{ok:false, error:"[iokitMap error] conn must be a handle…", hint:"…"}` | `error`=是什么，`hint`=下一步 |
| 裸码 | `iokitOpen("Foo")` → `-2`；`iokitCall(...).ret` → `0xe00002c2` | **先 `krWhy(kr)` / `machKrWhy(kr)`** 再判断 |
| **类型错** | `iosurfaceCreate("x")` → `[iosurfaceCreate error] props must be an object/dictionary (可省略), got string("x")  \|  签名: … \|  查参数: primHelp("iosurfaceCreate")` | 由 **`bridge_guard.js`** 在进入原生前拦住 |

**★ 为什么会有"类型错"这一档（V2.2.5 新增）**：原生桥的 block 参数是强类型的（`NSDictionary*`/`NSString*`/`NSNumber*`…）。
JS 侧传错类型时，**JavaScriptCore 会在进入原生校验之前就抛英文 `TypeError`**（例：`Cannot convert primitive to NSDictionary`），
我们的中文错误根本没机会跑。`bridge_guard.js` 在加载时给 33 个原语套一层类型守卫（纯 JS，**热更新即生效**），
把这种错误换成带「参数名 + 期望类型 + 实际类型 + 签名 + primHelp 指引」的自解释串。
> 通用技巧：**桥脚本可以覆盖原生全局**（`main.m` 里那层"点名"包装就是这么干的），
> 所以参数校验、类型守卫这类"外壳逻辑"放 JS 层 → 不用重编 IPA 就能修。

**在设备上直接查文档（不用翻这份文件、也不用到仓库里找 PRIMITIVES.md）**：
```js
primHelp()              // 全部原语速查（标 ✅自解释 / ⚠裸码）
primHelp("iokitMap")    // 单个：参数名+类型+合法范围+返回+常见错误
primErrors()            // 错误约定机读版
primMissing()           // 还欠自解释的桥（诚实清单）
krWhy(-536870206)       // "kIOReturnBadArgument (0xe00002c2) — 参数形状被拒…"
iokitMapTry(conn)       // 扫 memType 0..15，给"哪个可用/都不支持"的定论
```

> ⚠️ 旧版 §11 IOReturn 字典**整张是错的**（名字与 hex 错位）。下表已按 `IOKitReturn.h` 重新生成，
> 并用真机实测交叉验证过 3 个码：`-536870206`=BadArgument、`-536870202`=BadMessageID、`-536870174`=NotPermitted。
>
> **★ 同一张错表还藏在 V3 探针里（V2.2.5 已修，读旧结论要注意）**：`jbV3StructProbe.js` 的 `KR` 表同样错位，
> 且错得危险 —— `0xe00002e2` 旧标 **NotPrivileged**（实为 **NotPermitted = 沙盒门禁**）、
> `0xe00002c7` 旧标 NotReadable（实为 Unsupported）、`0xe00002d2` 旧标 Unsupported（实为 StillOpen）。
> 该探针现在 `krStr()` 改为**优先调用 `krWhy()`**（单一事实源）。**凡是用旧版探针输出得出的 kr 语义结论，都要用 `krWhy()` 复核一遍。**

| 现象 | 原因 | 处置 |
|---|---|---|
| `连不上 ... WinError 10060` / 超时 | 服务没启动 / 不同网段 / 保活被系统回收 | 让用户①开面板点启动 ②确认同一 Wi-Fi ③看灵动岛是否还在显示「监听中」，不在就重点启动 |
| `连不上 ... 10061 拒绝` | 端口不对或服务已停 | 核对端口；面板里看「● 正在监听」 |
| `HTTP 404 no such route` | 端点拼错 | 只用 `/ping` `/eval` `/submit` `/result` |
| `执行器未注册` | 原生侧 `RYAutorunSetEval` 没跑到 | 让用户先在控制台跑任意一段 JS（会触发注册），再启动 Autorun |
| 返回不是 JSON | 服务被别的程序占用端口 | 换端口（面板改 + `--port` 同步改） |
| `status:running` 满 12 次 | 代码卡住 / 主线程被占 / 弹窗未确认 | 看设备屏幕；把代码拆成小步；避免死循环 |
| App 突然退出（连接中断后重连不上） | 崩了 | ★ **先取崩溃现场**：`readFile("ryconsole_crash.log")`（V2.2.1 起自动记录，含符号栈）。用 `fileAppend` 前先 `fileSize` 确认非空 |
| 监听停了但灵动岛还挂着「监听中」 | App 被强杀（划掉）→ 系统无回调 | 重新打开 RyConsole 会自动清扫；无需重装 |

## 写探针代码的约定

1. **`print()` 就是回传通道**：所有中间信息用 `print(...)` 输出，会收在 `output` 里。
2. **`return` 是结果通道**：最后 `return` 的对象/字符串进 `result`。
3. **探针首行写不写注释都行**（可选）。写的好处：人若正好在看 iPad 的「收到的代码」面板，一眼知道这条在干嘛；
   批量跑多探针时（`// [7/19][JS] iokitMapTry 参数校验`）尤其有用。**单条快探针不必强加** —— 用户明确说过"不一定有人看"，
   别为了形式加一堆。真正硬性的只有：`output` 里能看懂、`return` 是结果。
4. 代码里可以直接调用**已注册的原生原语**（68 个，见下节「原生桥清单」）——
   不要凭猜测写 API，**先用清单核对**再写；清单里没有的接口就是没有。
5. **把结果做成 JSON 字符串再 return**，比返回裸对象更稳（可读、可解析）。
6. **单步优先**：一轮一件事。跑得越久越容易触发超时和 panic，也更难定位。
7. **返回值尽量小**：不要 return 巨大的结构，超长输出用 `print` 分段。

### 推荐模板

```js
// 探针模板：结果统一用 JSON 回传
var out = { goal: "探测 XXX", hits: [], errors: [] };
try {
  var conn = iokitOpen("IOSurfaceRoot", 0);
  out.conn = conn;
  if (conn > 0) {
    var r = iokitCall(conn, 0, []);
    out.selector0 = r;
    print("selector 0 -> " + r);
    iokitClose(conn);
  }
} catch (e) {
  out.errors.push(String(e));
}
return JSON.stringify(out);
```

## 原生桥清单（写在探针前先核对这张表）

**全部 68 个原语**都已注册为全局函数。每次执行都是**全新 JSContext**（跨轮次变量不保留 → 要状态就落盘）。
安全分级：🟢只读 / 🟡有副作用 / 🔴高危（人工确认）。

### IOKit 内核接口（核心）🟢
| 原语 | 签名 | 说明 |
|---|---|---|
| `iokitEnum` | `() → string[]` | 枚举 IORegistry 服务类名 |
| `iokitOpen` | `(cls, type) → number` | 打开 IOService；**>0 成功**。`-2` 类不存在 / `-3` 类名为空 / `-536870174` 门禁 |
| `iokitCall` | `(conn, sel, inputs[]) → {ret,outputs,ok,error?}` | 标量入参（≤16；非数字项会被忽略并在 `note` 点名） |
| `iokitCallStruct` | `(conn, sel, scalarInputs[], structB64, outSize) → {ret,outputs,outStruct,ok}` | 带 inputStruct / OOL 输出；`outSize` 合法 1..65536 |
| `iokitMap` | `(conn, memType) → {ret,ok,addr?,size?,error?,hint?}` | 内存映射。**失败自带原因+建议**（V2.2.4）；memType 不确定先 `iokitMapTry(conn)` |
| `iokitClose` | `(conn) → number` | 关闭 |
| `bytesB64` / `b64Bytes` | `(arr)/ (b64)` | 字节 ↔ base64 |

### IOSurface 🟡
`iosurfaceProbe()`、`iosurfaceCreate(props)`、`iosurfaceGetID(h)`、`iosurfaceSetValue(h,k,v)`、
`iosurfaceGetValue(h,k)`、`iosurfaceLookup(cid)`、`iosurfaceRelease(h)`

### XPC / 服务 🟡
`xpcLookup(svc)→"REACHABLE"/"NOT_REACHABLE"`、`xpcProbe(svc)`、`xpcSend(svc, selector, payloadJSON)`、`nsxpcProbe(svc)`

### XPC 结构化桥（V2 新增，2026-09-13）🟡
| 原语 | 签名 | 说明 |
|---|---|---|
| **`xpcConn`** | `(svc) → {h}` | 持久连接句柄（事件 handler 已设空块，对端崩溃不会 crash 本进程） |
| **`xpcSendMsg`** | `(h, msgDict, timeoutSec) → reply对象` | 结构化收发：任意嵌套 JS 对象 → xpc_dictionary；reply 递归解析回 JS 对象（uint64 转 0x 十六进制串防精度丢失；深度限 6、每层限 64）。`timeoutSec<=0` 只发不收 → "SENT"；超时 `{err:"timeout"}` |
| **`xpcClose`** | `(h) → "ok"` | 关闭并释放 |
| **`machLookUp`** | `(svc) → {kr, port}` | bootstrap_look_up 原始版：kr=0 成功，port 为 mach 句柄名 |
| `xpcCall`（bridge_xpc.js） | `(svc, msg, timeoutSec)` | 一次性封装：连接→发→收→关，探针最常用 |

### ObjC runtime 万用桥（V2.1 新增，2026-09-13）🔴最高能级
| 原语 | 签名 | 说明 |
|---|---|---|
| **`objc_getClass`** | `(name) → "0x…"` | 类指针句柄（Class 永生，句柄跨轮次稳定） |
| **`sel_registerName`** | `(name) → "0x…"` | SEL 句柄（永生） |
| **`objc_msgSend`** | `(recv, sel, args) → "0x…"` | 万能调用。recv=0x 句柄(0=nil)；sel=名字(自动注册)或 0x 句柄；args 规则：字符串→自动包 NSString、数字→uint64 位槽(BOOL/int/long 位传)、`{hex:"0x.."}`→原始指针、null→nil。返回 x0 的位（nil="0x0000000000000000"） |
| **`objcDesc`** | `(hex) → string` | 回读句柄内容：NSString 原文，其他对象 description |
| `objPtr/lsWorkspace/lsAppInfo/lsOpenURL/lsOpenApp/objCall`（bridge_objc.js） | | LSApplicationWorkspace 驱动套装：单点查询 / 拉起 App / 打开 URL，均无 entitlement 依赖 |
| ❌ **`lsAppList()`** | | **v1.0 实测：一次调用即崩进程**（pid 2078→2099→2102 差分实证）。批量枚举已装应用是雷区，改用 `lsAppInfo('<bundleID>')` 单点查询 |

⚠️ 红线：①只适用整型/指针返回（float/struct 返回方法不适用）②经 msgSend 调 alloc/new/copy 族泄漏 +1（ARC 视 msgSend 返回为 +0）③方法实参超过 7 个不支持 ④接收 completion handler(block) 参数的方法不可调。

### ObjC 安全封装 + 读映射内存（V2.2 新增，2026-09-18）🔴
| 原语 | 签名 | 说明 |
|---|---|---|
| **`objc_msgSendSafe`** | `(recv, sel, args[]) → JSON` | 返回 `{"ok":true,"value":"0x…"}` / `{"ok":false,"error":"…"}`。nil 接收者、坏 selector、参数 >7 都变成可读错误。⚠️ **但它并没有修掉崩溃根因**：源码 `main.m` 里它和裸版一样用 `id ret` 接收返回值 → **任何返回整数的 selector（`count`/`length`/`intValue`/`isEqual:`…）都会被 ARC 当对象指针 retain/release → SIGSEGV**（`@try/@catch` 抓不到信号）。**在修复前，调 objc 桥只挑"确定返回对象 id"的 selector**（如 `defaultWorkspace`、`objectAtIndex:`），避开一切返回标量的 |
| **`memRead`** | `(hex_addr, len) → hex string` | 读 **本进程地址空间**（实现是 `vm_read(mach_task_self(), …)`，main.m 注释明说"只对本进程地址空间有效"）。`len ∈ [1, 65536]`。签名由错误信息自解释：`memRead()`→`[memRead error] null address`；`memRead(h)`→`[memRead error] len must be 1..65536`；越界/未映射→`[memRead error] vm_read kr=N`。实测 `memRead(lsWorkspace(), 64)` 能读出真实 objc 对象头（isa 带 PAC 签名 `0x01000002_0604dd59`）→ **真实读非回显**。⚠️ **它不是内核读原语**：读内核地址只会返回 `kr=2`（KERN_INVALID_ADDRESS），不崩也读不到 |

```js
var WS   = objc_getClass("LSApplicationWorkspace");
var inst = JSON.parse(objc_msgSendSafe(WS, "defaultWorkspace", []));   // {ok:true, value:"0x…"}
if (inst.ok) {
  print("desc: " + objcDesc(inst.value));
  print("dump: " + memRead(inst.value, 64));   // 对象头部（isa / 前几个 ivar）
}
```

### dyld / 符号解析（V2 新增）🟡
| 原语 | 签名 | 说明 |
|---|---|---|
| **`dlopenFW`** | `(path, mode) → {h}` 或 `{err}` | dlopen 私有框架（path 形如 `/System/Library/PrivateFrameworks/Foo.framework/Foo`） |
| **`dlsymAddr`** | `(h, name) → {addr:"0x…"}` 或 `{err}` | 符号地址（已含 ASLR slide）；`h=0` 用 RTLD_DEFAULT 全镜像搜索 |
| `symResolve`（bridge_xpc.js） | `(fwPath, symNames[])` | dlopen+dlsym 一次到位 |

### 沙盒 / 钥匙串 / 进程（V2 新增）🟡
| 原语 | 签名 | 说明 |
|---|---|---|
| **`sandboxCheck`** | `(op) → {ret, errno}` | sandbox_check **原始返回值**（苹果语义模糊，不解读，探针自行比对） |
| **`keychainProbe`** | `(cls, svc, acct) → {status, exists, stHex}` | SecItem 只查不取不弹框：0=存在可读，-25300=不存在，-34018=缺 entitlement；cls: genp/inet/cert/keys/idnt |
| **`procListPids`** | `() → {n, pids[]}` | proc_listallpids；沙盒内多 EPERM（错误本身即测量结果） |
| **`posixSpawn`** | `(path, argvArr, timeoutMs) → {pid, exit/signal/timeout}` | 沙盒内多被拒（spawn 错误码原样回传）；timeoutMs≤30000，超时不 reap（僵尸进程表可见=信号） |
| `keychainScan` / `sandboxScan` / `machScan`（bridge_xpc.js） | 批量版 | 多 service/op/service-name 一把梭出矩阵 |

### 网络 🟡
| 原语 | 签名 | 说明 |
|---|---|---|
| **`httpRequest`** | `(opts) → JSON` | **同步 HTTP(S)**：`{url,method,headers,body,timeout}` → `{ok,status,body,len,error}`。调 AI 后端/局域网服务首选 |
| `tcpConnect` | `(host, port) → "OPEN"/…` | 单端口（0.3s 超时） |
| `tcpScan` | `(host, start, end)` | 端口段扫描 |
| `tcpSend` | `(host, port, hexPayload)` | 原始 TCP（payload 是 hex） |
| `canOpenURL` / `openURL` / `installIPA`🔴 | | scheme 可达性 / 打开 URL / itms-services 安装 |

### 设备与系统 🟢（`runCommand` 是 🔴）
`appInfo()`、`getPid()`、`getEntitlements()`、`sysctlGet(name)`、`getPasteboard()`、`setPasteboard(s)`、`runCommand(cmd)`🔴

### 文件（相对路径基于 Documents；`/` 开头为绝对路径）🟡
| 原语 | 说明 |
|---|---|
| `readFile(path)` | 失败返回 `[readFile error] …` |
| `writeFile(path, content)` | **整文件覆盖** |
| **`fileAppend(path, content)`** | **追加**——跨轮次 checkpoint 唯一手段 |
| `fileExists(path)` / `fileSize(path)` / `fileDelete(path)` | 存在性 / 字节数 / 删除 |
| `listDir(path)` / `mkdir(name)` | 目录列表 / 建目录 |

### 时间与控制
| 原语 | 说明 |
|---|---|
| **`now()`** | → `{wall, mono}`；测耗时用 `mono`（单调、不跳变） |
| **`sleep(ms)`** | 阻塞休眠（上限 120s）。**限速/间隔专用**（JSC 没有 setTimeout） |
| `print(...)` | 回传通道 |
| `require("bridge_x.js")` | 动态加载桥库（改 JS 不用重编 IPA） |

### 桥库函数（`RyConsoleScripts/*.js`，随 bundle 加载）
- `bridge_iokit.js`：`jbIokitEnum()`、`jbProbeIOKit(...)`、`jbIokitVerdict(...)`、`jbV3Battery()`、`jbV3Report()`、`jbV3MethodCall(...)`、**`iokitMapTry(conn,types?)`**、**`krName/krHex/krWhy/krHint`**
- **`bridge_guard.js`（V2.2.5 新增）**：`installGuards()` —— 给 33 个原语套**类型参数守卫**，把 JSC 英文 `TypeError` 换成自解释串（热更新即生效，不用重编）

### ★ 装桥 / 改桥：一条命令（V2.2.5，不用重编 IPA）

桥是动态层：**Documents 的同名文件优先于包内默认**。所以改桥 = 写进 Documents。
用 `RyConsole/tools/ryc_bridge.py`（纯标准库）：

```bash
python tools/ryc_bridge.py <iPadIP> list         # 谁在用 Documents 覆盖 / 谁用包内默认 / 两边字节数
python tools/ryc_bridge.py <iPadIP> versions     # ★ 设备上**实际加载**的每个桥版本（各桥自报 RYC_BRIDGES）
python tools/ryc_bridge.py <iPadIP> push bridge_xpc.js     # 装/改单个桥（写完回读校验字节数）
python tools/ryc_bridge.py <iPadIP> pushall                # 本地 RyConsoleScripts/*.js 全推
python tools/ryc_bridge.py <iPadIP> get bridge_objc.js     # 把设备当前生效源码拉回来（含包内默认）
python tools/ryc_bridge.py <iPadIP> rm bridge_xpc.js       # 删覆盖 → 回落包内默认
python tools/ryc_bridge.py <iPadIP> check                  # 总览：连通/覆盖数/版本/崩溃日志大小
```

**排查"改了没生效"就靠这三条**：`versions`（在跑哪版）→ `list`（有没有 Documents 覆盖、和包内差多少）→ `get`（把设备上真正在跑的那份拉回来比对）。

**约定**：每个桥顶部 `var BRIDGE_VERSION="vX.Y (build YYYY-MM-DD)"` + `RYC_BRIDGES["bridge_x"]=BRIDGE_VERSION;` + 末尾 `print("[bridge_x] 已加载: …")`。缺版本号就无法判断设备跑的是哪版（V2.2.5 已把 8 个桥全补齐）。
- **`bridge_help.js`（V2.2.4 新增）**：**`primHelp(过滤词?)`**、**`primErrors()`**、**`primMissing()`** —— 设备上的原语说明书，写探针前先问它
- `bridge_info.js`：`dumpIdentity()`、`dumpEntitlements()`
- `bridge_net.js`：`scanCommonPorts(host)`、`httpGet(host,port,path)`、`hexEncode(str)`
- `bridge_ui.js`：`enumSchemes()`
- `bridge_objc.js`：`objPtr(hex)`、`lsWorkspace()`、`lsAppList(offset,limit)`、`lsAppCount()`、`lsAppListInfo()`、`lsAppInfo(bid)`、`lsOpenURL(url)`、`lsOpenApp(bid)`、`objCall(hex,sel)`
- `bridge_xpc.js`：`xpcCall(svc,msg,timeout)`、`machScan(names)`、`symResolve(fw,syms)`、`keychainScan(services)`、`sandboxScan(ops)`、**`machKrWhy(kr)`** ｜ `jbV3StructProbe.js`：`zeroStructB64(n)`、`krStr(code)`、`log(...)`

### ★ 必带：IOReturn 错误码字典（回喂给 AI 时用）

```js
// 建议直接用桥里的 krWhy(kr) / krName(kr) / krHint(kr)（bridge_iokit.js）
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
// 常用有符号值：BadArgument -536870206 / BadMessageID -536870202 / Unsupported -536870201 /
//              NotPrivileged -536870207 / NotPermitted -536870174 / NotOpen -536870195 / NoSpace -536870181
function kr(c) {
  var n = (typeof c === "string" && /^0x/i.test(c)) ? parseInt(c, 16) : Number(c);
  return IOKIT_KR_HEX[((n >>> 0).toString(16)).padStart(8, "0")] || ("unknown(" + c + ")");
}
```

### 保活与灵动岛（V2.2；只在监听期间生效）🟡
| 原语 | 签名 | 说明 |
|---|---|---|
| **`keepAliveStatus()`** | `() → string` | 一行状态，形如 `保活: 开(音频√ 重启0 续期12)` |
| **`keepAliveInfo()`** | `() → JSON` | `{active, reason, audioPlaying, audioRestarts, bgTaskRenewals, background, status}` |
| **`liveActivityStatus()`** | `() → JSON` | `{available, active}` —— 灵动岛实时活动是否被系统允许 / 当前是否在跑 |

- 保活**由 Autorun 监听开关驱动**：`autorunStart` 自动开、`autorunStop` 立刻释放；JS 只能查不能改。
- 机制：静音（≈-78 dBFS）音频循环 + `beginBackgroundTask` 每 8s 无限续期 + 8s 脉冲自愈（被通话/录音抢走音频会话后自动要回）。
- 效果：**监听期间可切后台 / 锁屏**，电脑端仍能连；灵动岛 / 锁屏实时活动显示「监听中」+ 天线图标 + 端口 + 连接数 + 已运行时长，每次 HTTP 命中都会刷新连接数。
  - 注意：灵动岛**紧凑态只显示一个图标**（V2.2.1 起，为避免"强开灵动岛"被双元素撑变形）；端口/连接数在**展开态**与锁屏横幅里看。想验证数字刷新，让用户点开灵动岛或看锁屏。
- 限制（诚实）：低电量模式、系统回收压力、录音占用仍可能中断。**判断"还活着"只认 ping**，不要只看灵动岛在不在。

### 没有的能力（别浪费时间找）
`setTimeout/setInterval`（用 `sleep`）、跨执行保留变量（落盘）、返回 `float`/`struct` 的方法（msgSend 只取整型/指针寄存器）、
block 参数方法、开放 Keychain 明文（`keychainProbe` 只做读探测）、
**内核内存 / 页表**（`memRead` 实现是 `vm_read(mach_task_self())`，只能读**本进程**映射；读内核地址返回 `kr=2` KERN_INVALID_ADDRESS —— 不崩，但也读不到）、
永久后台常驻（保活是"极大延长"不是豁免）。

## 安全红线（不可由被执行的代码自行决定）

1. **只对自有设备**运行；不碰他人设备。
2. **只读优先**：默认只发查询类调用；写/擦除类 selector 需人工确认。
3. **一轮一事、留间隔**：连续失败就停，不要猛跑。
4. **危险面留人工**：AI 负责「提候选 + 跑 + 读结果」，破坏性的那一步由人决定。
5. **先确认设备上无不可替代数据**（这台 iPad 是唯一研究设备时尤其重要）。
6. 发现漏洞走**负责任披露**，不武器化。

## 历史与依赖

- 服务实现：`RyConsole/PayloadApp/AutorunServer.{h,m}`（原生，监听 + 极简 HTTP + 任务队列 + 面板）
- **原生桥完整参考：`RyConsole/PRIMITIVES.md`**（68 个原语的签名/返回值/安全分级/用法示例，比本技能更详细）
- 保活实现：`RyConsole/PayloadApp/KeepAlive.{h,m}` ｜ 灵动岛：`PayloadApp/LiveActivity.swift` + `PayloadApp/Widget/RyConsoleWidget.swift` + `PayloadApp/LiveActivityBridge.h`（Widget Extension target `RyConsoleWidget`；改动需重编）
- 使用说明：`RyConsole/AUTORUN.md` ｜ 协议与后端设计：`RyConsole/AI_BACKEND.md`
- 安全条款：`RyConsole/DISCLAIMER.md`
- 改了原生代码（`main.m` 的 `installPrimitives` / `AutorunServer.m`）需重编 IPA；只改 JS 探针无需重编。
