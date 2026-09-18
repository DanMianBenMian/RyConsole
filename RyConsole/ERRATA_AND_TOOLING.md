# 勘误与桥工具（安全测试交接）

更新时间 **2026-09-18** ｜ 对应发布 **V2.2.5**（Release tag `RyConsole-iPad-v1`）

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

## 五、版本对应

| IPA | 关键内容 |
|---|---|
| **V2.2.5** | 默认桥整修（探针 kr 表勘误、3 个桥补版本号、8 个桥自报版本）+ `bridge_guard.js` 类型守卫 + `tools/ryc_bridge.py` |
| **V2.2.4** | Bug 6 自解释错误 + `bridge_help.js`（`primHelp`）+ `iokitMapTry` + IOReturn 表勘误 |
| **V2.2.3** | `objc_msgSend` 返回值 ARC 血案修复（`__unsafe_unretained`） |
| **V2.2.2** | 缺陷报告 5 条 + `lastPrim` 崩溃点名 + `/ping` 诊断字段 |
| **V2.2.1** | 灵动岛崩溃 / 强杀残留 / 崩溃日志自动记录 |
| **V2.2** | 监听期后台保活（静音音频 + bgTask）+ 灵动岛实时活动 |
