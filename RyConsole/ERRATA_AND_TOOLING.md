# 勘误与桥工具（安全测试交接）

更新时间 **2026-09-25** ｜ 对应发布 **V2.4.19**（Release tag `RyConsole-iPad-v2419`）

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
| **V2.4.19** | ★ **envReset 回归修复（JSC 桥转换坑）**。① 无参 `envReset()` 在真机竟停了服务端（违背 V2.4.15「默认不停服务端」）—— 根因 = JS 调 ObjC 原语不传参时 `undefined` 被 JSC 转成 `NSNumber`（非零/NaN），`[stopServer boolValue]` 返回 YES → 当成要停。**已修注册点**（main.m:1947）改用 `JSValue *` 参数 + 显式判 `isUndefined/isNull` 才默认 `NO`；`envReset(true/false)` 仍按调用方意图。② 通用坑：所有声明 `NSNumber*/BOOL` 形参的原语，无参调用都会踩同样的 undefined→非零 NSNumber，统一用 `JSValue` 参数 + 判空兜底。③ 本次仅此修复 + 版本号 2.4.19/50；liveHits 修复与 `envCred` 已在 V2.4.18 落地。|
| **V2.4.18** | ★ **新增 `envCred()` 身份原语 + 修复 liveHits 灵动岛焊接 Bug**。① **`envCred()`**：`() → {uid,euid,gid,egid,groupCount,groups[],login}`——专给 AI/脚本一键查进程凭据，**uid/euid 拆开报**是故意做成**实时 LPE 金丝雀**（见下★）：真提权时 uid→0（或 uid 仍 501 但 euid→0 的分歧 = 只抬了 effective 的半吊子提权），是链打穿凭据层的铁证。返回值是**原始数值**（501 这类绝不替换成名字丢掉），`login:"mobile"` 只是顺手提示。② **`envState()` 也补 `login` 字段**。③ ★ **liveHits 修复（V2.4.4 重做）**：`LiveActivity.swift` 的 `doPush()` 原本 `await a.update()` 抛错后收账代码被跳过 → `pushInFlight` 永久 `true` → 灵动岛焊死在 0、连接数不实时。**`defer` 兜底**后无论成功/抛错都复位管道并追 dirty，管道不再卡死；`start` 复位把 `lastPushAt` 设 0 → 首条连接立即上屏不再等 0.5s 合并窗口。④ **构建脚本 `build_ui.py` 推送清单修复**：旧清单只列 7 个文件，**漏推 `LiveActivity.swift`/`RyListenAttributes.swift`/`Widget` 等全部 Swift + 其余 .m/.h**，导致云构建用仓库旧版、修复白做；改为**完整遍历 `PayloadApp`/`RyConsoleScripts`/`tools`**（SKIP_DIRS 排除 `AppIcon.xcassets` 等纯资源）。|
| **V2.4.17** | ★ **「复制地址」改弹窗选择**（用户选的方案）。旧版 `MainShell.m` 的「复制 IP」按钮只复制 `http://<lanIP>:<port>` **一个**主地址，电脑若连的是热点就会复制到对不上的那条。改：① 点按钮弹 `UIAlertControllerStyleActionSheet`，列出 **Wi-Fi / 个人热点 / 蜂窝** 各自的地址（没有的那一类不出现），选中即复制并在标签回显「已复制 Wi-Fi：http://…」；② **只有一条可用时不弹窗直接复制**（少点一步）；③ 未启动监听仍拒绝给地址（沿用旧行为，避免复制到连不上的 URL）；④ 按钮文案「复制 IP」→「**复制地址**」（它复制的是 URL，且现在可选）；⑤ iPad 必须给 `popoverPresentationController` 锚点（锚在 tag 9112 按钮上），否则直接崩；⑥ 新增文件级 `RYTopVCForPresent()`（`RYAutorunPane` 原先拿不到顶层 VC，`ry_topVC` 属于另一个类）；⑦ **环境页网络段点条目即复制该条地址**，不必回主界面。
| **V2.4.16** | ★ **真正的优先级 Bug 修复 + Autorun 面板列出全部地址**（用户反馈：Autorun 只显示一个 IP 且仍是热点）。**根因比 V2.4.14 想的更深**：V2.4.14 只改了 `pri` 数组顺序，**但取值的循环是"扫一遍 ifaddrs，看谁在 pri 里就返回"—— 实际按的是枚举顺序，pri 顺序根本没生效**；用户设备上 `bridge100` 恰在 `en0` 之前，所以照样命中热点。修：① `RYReachableIP()` 与 `ryLANAddress()` 都改成**按 pri 顺序逐个接口名查找**（外层遍历 pri，内层找同名接口），优先级才真正落地；② Autorun 面板不再只给一个地址 —— 新增 `ryEndpointLines(port)` 按类列出 **Wi-Fi / 个人热点 / 蜂窝** 各自的 `http://<ip>:<port>/ping`（hintLabel 2→4 行，日志区下移），启动日志也逐条打印。③ 教训钉死：**"白名单 + 一遍扫描"的写法无法实现优先级**，必须以外层优先级驱动查找。
| **V2.4.15** | ★ **设计缺陷修正：重置环境不再停服务端**（用户反馈：追求半自动，重置不该中断工作流）。旧实现 `RYResetEnvironment()` 无条件调 `RYAutorunStop()`，把电脑端连着的监听一并掐断 → 每次重置都得重连、Autorun 面板要重新点启动，工作被反复打断。修：① **默认保留监听**（`envReset()` 与 UI 按钮 = `stopServer:NO`），只清共享字典 / 归零原子槽 / 回收竞态批次；要停就显式 `envReset(true)` 或用网络段的开关；② 返回值新增 `serverStopped` / `serverKeptRunning` / `serverWasRunning` 与 `note`；③ **`clean` 判定不再把「服务端运行中」算作污染** —— 旧逻辑导致"只要开着监听就永远显示环境不干净"，还会诱导用户去重置，而旧版重置又把监听停掉，形成恶性循环；`serverRunning` 仍作为独立信息字段返回。
| **V2.4.14** | ★ **网络端点分类 + 优先级 Bug 修复**（用户实测：连着 Wi-Fi，App 却优先报热点的 `172.20.10.1`，电脑在同网段 Wi-Fi 上根本连不到）：① **优先级改为 Wi-Fi 优先**（`en0/en1 → bridge100 → pdp_ip0/ipsec0`）；`RYHotspotIP` 因此改名 **`RYReachableIP`**（旧名正是排序写反的诱因）；**同名 Bug 在 `AutorunServer.m` 的 `ryLANAddress()` 里也有一份**（喂 `/ping` 的 `lanIP` 与启动 URL），一并修；② 新增 **`RYNetworkEndpointsJSON()`**：按类给端点 `{wifi?, hotspot?, cellular?, hasAny, all[]}` —— **没有的那一类不出现**（没连 Wi-Fi 就无 wifi 键，没开蜂窝就无 cellular 键）；③ **服务端绑 0.0.0.0，Wi-Fi 与热点/蜂窝其实同时可达** → 环境页按类各显示一行，启动后每行各自给出 `http://<该类IP>:<port>/ping`（电脑在哪个网就用哪个）；④ **网都没有 → 不监听并报错**：`envServerStart()` 在 `hasAny=false` 时直接返 `ok:false` + "无可用网络"，UI 的服务器开关同步置灰；⑤ 新增原语 **`envNet()`**，`envState()` 增加 `net`/`hasNetwork`，**`/ping` 增加 `endpoints`**（电脑端不用猜该连哪个）。接口归类 `RYIfKind()`：`en*`=wifi、`bridge*`=hotspot、`pdp_ip*`/`ipsec*`=cellular、`awdl*`/`lo*` 忽略（不算上网通道）。
| **V2.4.13** | ★ 环境重构（移动数据/热点可达 + 重置环境 + 第4选项卡「环境」+ 权限诊断全动态）：① **网络可达**：AutorunServer 本就绑 0.0.0.0（全接口可连），新增 `RYHotspotIP`/`RYInterfaceIPsJSON` 探测 bridge100(热点)/pdp_ip0·ipsec0(蜂窝)/en0·en1(Wi-Fi) 多接口 IP，环境页与 `/ping` 启动 URL 直接显示对连电脑可达的地址；② **重置环境命令** `envReset()` + 面板按钮：清共享字典、归零 16 原子槽、回收竞态批次（销毁闸锁/清零 done·guarded·taken/置空 results）、停服务端——环境污染无需重启 RyConsole；③ **第4选项卡「环境」**：身份（UID/EUID/GID/EGID/PID/所在组数组）+ 环境是否干净（干净=无共享字典/竞态/原子槽/服务端残留，否则列污染原因）+ 一键重置；网络段列全部接口 IP 与「自动运行服务器」开关（启动即给电脑可连 `http://IP:8899/ping`）；④ **权限诊断全动态**：去掉写死表单，运行时枚举真实 entitlement 键（内嵌段键 ∪ 已知键描述表），两处皆空则跳过；能力检测走数据驱动的 `capabilitySpecs` + `RYProbeCapabilityKind`，表单只承载权限*描述*。
| **V2.4.12** | ★ threadJoin 回归修复（测试侧 T0 对齐竞态受阻：spawn 返回 batch:N 但 join 全返 {done:0,batches:0}）：① **worker 内禁 threadJoin**（worker 拿全套原语，一旦在 worker 里调 join 会把批次表整批收割+回收，主脚本永远 join 不到——与回归现象完全吻合；worker 内调用直接返回结构化错误）；② join 空结果**不再静默**：无活跃批次/批次号不匹配时返回 ok:false + 当前活跃批次列表 + 参数序提示（旧版 {done:0,batches:0} 无法定位）；③ 新增 **threadBatches()** 调试原语：逐槽 dump 注册表（used/joined/id/n/ready/done/taken）+ seq，当场对账；④ 新增 **memWrite(addrHex, data)**：二进制写入（mach_vm_write_overwrite，kr 干净报错不崩），data 支持 hex 串 / "b64:…" / {b64:"…"}（mach_msg 构造硬前提，测试清单 #2），只对可写页生效，上限 64KB 与 memRead 对称。\n| **V2.4.11** | ★ 权限面板补动态注入键 + 二进制 plist 解析（用户实测反馈：全能签硬写 entitlement 后面板行数不变；Info.plist 文本打开乱码）：① RYEmbeddedEntitlementsDict —— 内嵌段/签名 blob（0xfade7171）用 NSPropertyListSerialization 解析，**二进制 plist（bplist00）与 XML 通吃**（旧代码按 UTF-8 文本子串匹配，二进制时全判「未声明」且显示乱码）；② 固定清单（5 个 ent 键）之外的注入键**动态成行**：内嵌 blob 解析出的每个键逐键查 SecTask 签名层，ok = 签名层有无值，detail 同时给内嵌段值与签名层值；③ 澄清：entitlements 不在 Info.plist，Info.plist 是二进制 plist 文本打开必乱码且与权限无关，改权限走全能签的 entitlements 编辑框（XML 明文）。\n| **V2.4.10** | ★ 权限面板 ent 检查改 **SecTask 签名层实测**（facepanel_fix.md，P107-P109）：内核 SecTask 校验读的是签名 blob，全能签重签注入的是签名层——与内嵌段（__TEXT,__entitlements）可分叉，旧面板只读内嵌段会漏报实际生效键（实测 system-task-ports 签名层生效但面板按旧状态显示）。新判定：主判定 = SecTaskCopyValueForEntitlement（dlsym，取不到符号回退旧语义）；内嵌段对比——签名层生效但内嵌段未含时给 ⚠「重签注入，两处分叉」标注；辅助功能探针：task_for_pid-allow → task_for_pid(1)、system-task-ports → mach_port_allocate + task_for_pid(self)、mobilehousearrest/containermanager → bootstrap_look_up 服务 kr（探针仅供参考，主判定以签名层为准）。0xE00002D9 已在 V2.4.5 收录（bridge_iokit.js krName/krWhy），facepanel 清单 #3 无需动作。
| **V2.4.9** | ★ P89–P105 收官清单落地（测试 Agent 转交项核对：#2 threadBarrier/threadId/共享原子、#4 krName 0xE00002D9、#5 callPtr 契约**均已在前版合入**，名字为 raceBarrier/__threadId/raceSlot*——P100 探针找字面名才误判未合入）：① **xpcConn 族线程安全修复**（P102–P104 SIGSEGV 定性=注册表字典非线程安全 + close 与 send 并发的连接生命周期竞争）：g_xpcLock 串行化注册表操作 + send 用强引用保活连接（并发 close 只 cancel 不 UAF），**send 不串行化**——XPC 并发研究仍可做；② **threadJoin 多批次**：批次注册表（8 槽循环复用），threadSpawn 返回 batch 号，threadJoin(timeoutMs[, batchId]) 不传 batchId=收割全部未收割批次，部分收割可补收，整批收齐自动回收槽位，spawn 失败槽位标记 done 保证批次必然可收割；worker 加 __threadBatch 变量（批内序号 __threadId 之外再加批次号）。
| **V2.4.8** | ★ 无灵动岛后台通道：Live Activities 不可用/被关的设备，脚本级权限确认在后台改发**本地推送**（UNUserNotificationCenter，点通知开 App → 确认框弹出，60s 内有效；首次调用申请通知授权，拒绝则退化为回 App 查看）。通道优先级：灵动岛/锁屏横幅 → 本地推送 → 回 App 直接看确认框。
| **V2.4.7** | ★ 权限确认的后台可达性修复：脚本级一次性确认在**后台/锁屏**时先灵动岛+锁屏横幅顶出提醒（LiveActivity alert 字段），等 App 回前台再弹确认框——60s 窗口内点开 App 都能确认；旧实现后台时 topViewController 取不到宿主会**静默驳回**（用户根本看不到）。超时驳回同时清灵动岛提醒；观察者 120s 兜底摘除防泄漏。
| **V2.4.6** | ★ 权限模型改**脚本级作用域**（用户需求：放行=当前脚本放行全部权限，拒绝=直接驳回）：RYExecStream/终端执行器入口扫描脚本文本里出现过的被禁受管命令 → 非空弹**一次**窗「请求权限：要调用 xx、xxx 命令」——允许=本脚本作用域全放行（进程级，含 race worker 线程）；不同意=作用域内被禁命令直接驳回不再弹窗；扫描为空不弹窗。出口（正常/兜底掀栈）一律 endScriptScope 清作用域。旧逐次弹窗仅保留为作用域外兜底（mode=0）。gScopeMode 为 C11 原子（gateCommand 任意线程读）。
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
