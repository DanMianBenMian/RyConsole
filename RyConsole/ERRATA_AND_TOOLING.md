# 勘误与桥工具（安全测试交接）

更新时间 **2026-09-19** ｜ 对应发布 **V2.4.5**（Release tag `RyConsole-iPad-v1`）

---

## 一、必须复核的勘误（**会污染已有结论**）

### 1. IOReturn 码表错了**两张**，现已修正，但旧输出可能被误标

| 位置 | 问题 | 状态 |
|---|---|---|
| `PRIMITIVES.md` §11（旧版） | 整张表**名字与 hex 错位**（例：`-536870163` 被标成 `Unsupported`；`0xe00002c7` 被标成 `BadArgument`） | ✅ 已按 `IOKitReturn.h` 重生成（hex 键、31 项） |
| `RyConsoleScripts/jbV3StructProbe.js` 的 `KR` 表 | 同样整张错位，**且错得危险**：`0xe00002e2` 旧标 **NotPrivileged**，实为 **NotPermitted（沙盒门禁）**；`0xc7` 旧标 NotReadable（实为 Unsupported）；`0xd2` 旧标 Unsupported（实为 StillOpen）；`0xc9/ca` 旧标 NoMemory/NoResources（实为 InternalError/IOError） | ✅ `krStr()` 改为**优先调用 `krWhy()`**（单一事实源）+ 兜底表重校，`PKG_VER` → `RyConsole#10 (kr表勘误)` |

**所以：**

- 判读任何返回码，一律用桥里的 **`krWhy(kr)`**（IOKit）/ **`machKrWhy(kr)`**（Mach/bootstrap），**不要**引用旧表或旧输出的语义名。
- **需要复核的结论类型**：凡是"某个 kr = X，所以判定 Y"的地方 —— 尤其把 **NotPermitted（沙盒门禁）误读成 NotPrivileged（缺 entitlement）** 这类。
  NotPermitted 意味着"用户态这条门根本进不去"，结论应更悲观；NotPrivileged 只表示缺权限位。两者对 V3 的意义不同。
- 已验证可放心用的表：`bridge_iokit.js` 的 `krName/krHex/krWhy/krHint`（31 项，按 `IOKitReturn.h` 生成 + 真机 3 码交叉验证：`-536870206` BadArgument / `-536870202` BadMessageID / `-536870174` NotPermitted）。

---

## 二、原语失败一律自解释（V2.2.4 起）

**判据一句话：返回串里出现 `] error]` 就是错误。**

| 形态 | 样子 | 怎么读 |
|---|---|---|
| 自解释串 | `[memRead error] len must be 1..65536`<br>`[sysctlGet error] unknown name "x" (errno 2 ENOENT 无此名字)` | 照它改参数 |
| 结构化 | `{ok:false, error:"[iokitMap error] …", hint:"…"}` | `error` = 是什么，`hint` = 下一步 |
| 裸码 | `iokitOpen("Foo")` → `-2`；`iokitCall(...).ret` → `0xe00002c2` | 先过 `krWhy()` |
| 类型错（V2.2.5） | `[iosurfaceCreate error] props must be an object… got string("x") \| 签名: … \| 查参数: primHelp("iosurfaceCreate")` | 由 `bridge_guard.js` 在进入原生前拦住（JSC 强类型参数原本会先抛英文 `TypeError`） |

**在设备上查文档（不必翻本文件）：**

```js
primHelp()            // 全部原语速查（标 ✅自解释 / ⚠裸码）
primHelp("iokitMap")  // 单个：参数名 / 类型 / 合法范围 / 返回 / 常见错误
primErrors()          // 错误约定机读版
primMissing()         // 还欠自解释的桥（诚实清单）
iokitMapTry(conn)     // 扫 memType 0..15，给"哪个可用 / 都不支持"的定论
```

---

## 三、装桥 / 改桥不用重编 IPA（V2.2.5）

桥是**动态层**：App 加载时 **Documents 的同名文件优先于包内默认**。

```bash
python tools/ryc_bridge.py <iPadIP> list         # 谁在用 Documents 覆盖 / 谁用包内默认 / 两边字节数
python tools/ryc_bridge.py <iPadIP> versions     # ★ 设备上**实际加载**的每个桥版本（各桥自报 RYC_BRIDGES）
python tools/ryc_bridge.py <iPadIP> push bridge_xpc.js    # 装/改单个桥（写完回读校验字节数）
python tools/ryc_bridge.py <iPadIP> pushall               # 本地 RyConsoleScripts/*.js 全推
python tools/ryc_bridge.py <iPadIP> get bridge_objc.js    # 把设备当前生效源码拉回来（含包内默认）
python tools/ryc_bridge.py <iPadIP> rm bridge_xpc.js      # 删覆盖 → 回落包内默认
python tools/ryc_bridge.py <iPadIP> check                 # 总览：连通 / 覆盖数 / 版本 / 崩溃日志大小
```

**"改了没生效"排查三连**：`versions`（在跑哪版）→ `list`（有没有覆盖、差多少）→ `get`（拉回来比对）。

同类脚本：`tools/bug6_hotpush.py`（错误语义回归，三档计数：JS / 原生 / 守卫）。

---

## 四、提交与轮询的硬约束（仍然有效）

- **必须 JSON body**：`{"code": "<js>", "timeoutMs": N}`。form 分支现在会做 percent-decode 了，但 JSON 更稳。
- **job 只活 300s**：超过会给 `job_expired`（不是裸 404）。探针尽量 **< 30s**，重活拆多轮。
- **服务单线程**：并发提交会被 429 `busy` 或断连 → **严格串行**，拿到结果再发下一条。
- **崩溃后**：`readFile("ryconsole_crash.log")` 取栈 + `/ping`（或 `autorunStatus()`）看 **`lastPrim`**（崩溃时正在跑哪个原语）。
- **定位崩溃别再按 `block_invoke_N` 序号反查源码** —— 极易错位（已踩）。

---

## 四之二、崩溃兜底（V2.2.6 起，**改变崩溃检测方式**）

探针触发的**用户态信号崩溃**（SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP）不再重启进程：
执行以「触发崩溃，已兜底」返回，App 存活。

```js
crashGuardStatus()   // {enabled, hits, lastSignal, lastAddr, lastPrim, degraded, …}
crashGuardSet(0)     // 关掉 → 恢复"真崩"（需要真崩时用，跑完 crashGuardSet(1) 恢复）
```

**★ 三条必读（直接影响你的测试方法）**

1. **pid 差分法在兜底开着时失效** —— 被拦下的崩溃不改 pid。改看：
   - `/eval` 返回里的 **`guarded: true`** + `guardSignal / guardAddr / guardPrim`；
   - `/ping` 的 `guardOn / guardHits / guardLastPrim / guardDegraded`。
2. **`guarded:true` ≠ 普通失败**：它的语义是"这条代码确实会把 App 打崩，只是被拦了"。
   这是**有价值的结论**（找到了一个真实的崩溃面），别当成偶发错误重试。
3. **兜住 ≠ 无损**：被拦下的那次执行是被掀栈结束的，锁/内存/JSC 状态可能不干净
   （`/ping` 的 `guardDegraded:true`）。若后续行为诡异（莫名失败、卡住），**重启 App 复位**再继续。

覆盖边界（别误判）：✅ 用户态信号崩溃；❌ **内核 panic**（IOKit/驱动内核侧触发 → 设备重启，用户态无解）、
❌ 看门狗卡死（0x8badf00d）、❌ 非布点线程上的崩溃、❌ 外部 kill。
另：内核 panic 时崩溃日志通常来不及写 —— 设备重启后如果没有新日志，大概率是内核侧。

> **V2.2.6 → V2.2.7 重要勘误**：V2.2.6 的兜底**实测没有生效**（处理器跑了、日志写了，但 App 仍死）——
> 根因是 `sigsetjmp` 会"返回两次"，撤点语句写在它后面**正常路径也会执行**，等于布完点立刻撤了。
> V2.2.7 已修（撤点只在"跳回"分支做）。**判断你手上跑的是不是修过的版本：发一条给垃圾对象发消息的探针，
> 若返回 `guarded:true` 且 App 活着 → 是 V2.2.7+；若 App 直接死了 → 还是 V2.2.6。**

---

## 五、版本对应

| IPA | 关键内容 |
|---|---|
| **V2.4.5** | ★ 竞态 harness 三项扩展（测试 Agent 请求）：① **起跑闸升级**——worker 建好 JSContext/原语后报 ready，最后一名到齐 `pthread_cond_broadcast` 放行全员（旧版创建完即放行，建 context 时差 = 毫秒级起跑偏差；失败路径/join 超时也强制放行防悬挂）；② **共享原子槽** `raceSlotSet/Get/AtomicAdd/AtomicCas`（16×64bit 原生 `_Atomic` 槽，JS number 53 位精度 → 64 位 handle/地址一律 `"0x…"` hex 进出，跨线程 handle 传递不再走字符串/NSNumber 编码；槽跨轮保留可做累计器）；③ **自动多轮** `raceRounds(fnBodyStr, nWorkers, rounds 1..100, timeoutMs)`（逐轮 spawn/join 聚合，纪律内置：超时未完/guarded 命中自动停）。★ krWhy 码表补 `e00002d7 kIOReturnOffline` / `e00002d9 kIOReturnNotAttached`（close 交界过渡码，竞态高频 open/close 常见） |
| **V2.4.4** | ★ 灵动岛连接次数滞后/回跳修复（LiveActivity.swift 推送管线重写）：① 去掉 update 的主线程绕行（Autorun 连接线程高频轮询时主队列积压 = 滞后根因）；② 推送单飞 + dirty 追赶（Task 完成顺序不定导致旧快照后落 = 回跳根因，现在永远推最新快照）；③ 计数类更新合并进 0.5s 窗口（避开系统对高频 Live Activity 更新的节流）；④ 权限提醒（alert）绕过窗口立即推。行为变化：连接数最多滞后 ~0.5s 但单调递增不回跳 |
| **V2.4.3** | ★ Stage2 竞态 harness 合入（RACE_plan_v2 方案A，8 原语）：`threadSpawn(fnBodyStr, nWorkers 1..8)`（每 worker 独立 JSContext+全套原语，起跑闸同步）/ `threadJoin(timeoutMs)` / `raceBarrier(n)`（sense-reversing 会合）/ `raceSharedSet/Get`（跨线程传 conn handle）/ `threadProgress`（落盘 race_progress.json 防 panic 丢数据）/ `threadStop/Flag`（协作停）。★ 崩溃兜底状态 `__thread` 化（worker 各布各的检查点；worker 内 SIGSEGV → 该线程 guarded:true，进程存活；主线程布点不再被 worker 覆盖）。M1 探针骨架 `RyConsoleScripts/race_probe_m1.js`（并发版 close-then-use，spawn→barrier→race→join） |
| **V2.4.2** | ★ callPtr 返回契约钉死（见 §5.1）：闸门驳回从纯文本 `权限请求驳回` 改为统一 JSON `{ok:false,error:"权限请求驳回…",rejected:true,cmd:n}`；验收脚本 `RyConsoleScripts/callptr_acceptance.js`（strlen / getcwd / mach_port_allocate / MCM null 三连）。**MCM SIGSEGV@0x58 定性**：非 callPtr 回归（源码 diff 证明参数侧 V2.3.0→32 零变化，ARC strong 传参推断不成立），根因 = build 29 起嵌入 entitlements 后 MCM 内部 entitlement 检查通过走深路径 → NULL+0x58 解引用；未签名 build 同样调用返 0。兜底会拦成 `guarded:true`（App 存活），属预期行为 |
| **V2.4.0** | ★ 新增第5选项卡「权限与安全」：①**权限诊断**（逐项实测 entitlement/能力，可用/禁用各自独立显示）②**安全**（命令可用性开关，默认全启用，高危命令带提示；被禁用的命令调用时请求用户确认——后台优先灵动岛提醒、前台/无岛直接弹窗，主标题「请求权限」、子标题「要调用 xxx、xx 命令」，不同意回 AI「权限请求驳回」）③**日志**（顶层「高危命令 x 次 / 一般命令 n 次」计数 + 可筛选列表，高危红、一般绿）。原语统一经 `__ry_gate` 闸门；灵动岛 `LiveActivity` 加 `alert` 字段承载权限提醒 |
| **V2.3.0** | ★ **`callPtr`**（C 函数指针调用/FFI，规格 `RYCONSOLE_CALLPTR_SPEC.md`；地址 vm_read 体检 + crashGuard 兜底）+ 版本号显示修复（UI/`/ping` 从 Bundle 读，本版 = 2.3.0）|
| **V2.2.7** | ★ 修兜底"没拦到"的真 bug（sigsetjmp 返回两次，撤点在正常路径也跑 → 布完即撤）；`objc_msgSendSafe` 加**接收方体检**（vm_read 探 16 字节，垃圾指针 → 结构化错误不崩） |
| **V2.2.6** | ★ 崩溃兜底（sigsetjmp/siglongjmp + sigaction/altstack；`crashGuardStatus/Set`；`/eval` 带 `guarded*`、`/ping` 带 `guard*`）+ 修「资源管理器跑脚本无反应」回归 |
| **V2.2.5** | 默认桥整修（探针 kr 表勘误、3 个桥补版本号、8 个桥自报版本）+ `bridge_guard.js` 类型守卫 + `tools/ryc_bridge.py` |
| **V2.2.4** | Bug 6 自解释错误 + `bridge_help.js`（`primHelp`）+ `iokitMapTry` + IOReturn 表勘误 |
| **V2.2.3** | `objc_msgSend` 返回值 ARC 血案修复（`__unsafe_unretained`） |
| **V2.2.2** | 缺陷报告 5 条 + `lastPrim` 崩溃点名 + `/ping` 诊断字段 |
| **V2.2.1** | 灵动岛崩溃 / 强杀残留 / 崩溃日志自动记录 |

### 5.1 callPtr 返回契约（钉死 · V2.4.2 起，脚本按此写）

callPtr 自身**永远返回 JSON 字符串**（这个从 V2.3.0 起就没变过），但一次调用有三种可能的落点，脚本必须按序判：

1. **正常返回**：`{"ok":true,"value":"0x…"[,"out":{"buf0":"<base64>",…}]}`（`value`=返回值寄存器 x0；`out.bufK`=第 k 个 `{buf:}`/`{str:}` 缓冲内容）
2. **崩溃兜底拦截**（调用把进程打出 SIGSEGV/SIGBUS 等）：Autorun 信封整体变为
   `{"ok":false,"guarded":true,"guardSignal":11,"guardAddr":"0x58","guardPrim":"callPtr","output":…,"result":null,"error":…}`
   —— **先判 `guarded` 再取 `result`**；`guarded:true` ⇒ 结论是"这调用会崩但 App 还活着"，不要当普通失败重试。@0x58 = NULL+88 解引用（MCM 实测）。
3. **权限闸门驳回**（命令被禁用且用户拒绝/60s 超时）：V2.4.2 起返回统一 JSON
   `{"ok":false,"error":"权限请求驳回（<命令名>）","rejected":true,"cmd":"<命令名>"}`（旧版返回纯文本，JSON.parse 会炸——已修）。

**MCM 三函数实测结论（V2.4.x，写脚本时须知）**：对 `MCMGetContainerUrlForIdentifier` 等传 null，在**未签名 build（≤28）返 0**；在**嵌入 entitlements 的 build（≥29）SIGSEGV@0x58（被兜底拦成 guarded）**。这不是 callPtr 的 bug——是 MCM 框架内部 entitlement 检查在声明层通过后走了更深路径。验收标准：**App 存活**（返 0x0 或 guarded:true 均算 PASS）。
| **V2.2** | 监听期后台保活（静音音频 + bgTask）+ 灵动岛实时活动 |
