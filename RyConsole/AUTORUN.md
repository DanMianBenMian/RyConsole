# Autorun 使用说明

> 一句话：**iPad 只当"执行手"，AI 在电脑端。**
> 电脑端把 JS 代码送到 iPad 执行，iPad 把结果回传。绕开端上算力的一切限制。

---

## 1. 架构

```
AI（电脑端）  ── POST /submit {code} ──▶  RyConsole（iPad）
     ▲                                          │ 独立 JSContext 执行
     │                                          │ 捕获 print + 返回值
     └──── GET /result?id=… （每 3 秒，最多 12 次）◀─┘
```

AI 不需要跑在设备上 —— 判断、迭代、下一步决策全在电脑端。
设备端只做两件事：**执行**、**回传**。

## 1.5 界面（新外壳）

App 主体是**左侧栏 + 右侧内容**的深色科技风布局，左侧三个板块：

| 板块 | 图标 | 内容 |
|---|---|---|
| **终端** | `terminal` | 上方代码输入框（默认可编辑）→ 点「执行」；下方流式输出（print 实时刷新） |
| **Autorun** | `antenna.radiowaves.left.and.right` | 最上方**状态条**：● 监听状态 + 端口、本机 IP、**回传状态 pill**（待命 / 执行中 / 已回传 / 回传失败）、请求来源 IP+时间；下面是「收到的代码」与「输出 / 结果」两个面板，加 启动/停止、清空、复制 IP |
| **设置** | `gearshape` | 端口、默认超时、清空日志、免责声明、**经典界面入口**（旧的脚本 / 桥 / 修补页） |

- 侧栏底部常驻显示监听状态（● 监听中 :8899）。
- **首次启动会弹免责声明**，必须点「我已知悉并同意」才继续（记在 `NSUserDefaults.ryc_disclaimer_accepted_v1`）。
- 授权与端口存在 `NSUserDefaults`（`ryc_port` / `ryc_timeout_ms`）。

相关文件：`PayloadApp/MainShell.{h,m}`（外壳与三个面板）、`PayloadApp/RyShellBridge.h`（取经典界面）。

## 2. 三步用起来

| 步骤 | 操作 |
|---|---|
| ① 装 | 用新代码构建 IPA 并安装（改了原生代码，**必须重编**） |
| ② 开 | 打开 RyConsole → **左侧栏点「Autorun」→ 点「启动监听」**；状态条会显示本机 IP（也可用控制台 `autorunStart(8899)` / `openAutorunPanel()`） |
| ③ 测 | 电脑端：`python ryc_autorun.py ping --host 192.168.0.110` |

**V2.2 起：②之后 App 会自动进入保活态**（静音音频 + 后台任务续期），**可以切后台、可以锁屏**，
电脑端仍能连；灵动岛 / 锁屏实时活动显示「监听中」+ 端口 + 连接数。点「停止」即释放保活。

## 3. iPad 端可用的 JS 原语

```js
autorunStart(8899)     // 启动监听，返回 "OK:listening:8899"
autorunStop()          // 停止
autorunStatus()        // 状态 JSON（含 running / port / lanIP / busy / jobs）
autorunLog()           // 最近日志文本
openAutorunPanel()     // 打开图形面板（端口框 + 启动/停止 + 实时日志）
```

## 4. 电脑端命令

```bash
# 连通性（永远先做）
python ryc_autorun.py ping --host <IP>

# ★ 主用法：提交 + 自动轮询（每 3s，最多 12 次）
python ryc_autorun.py run --host <IP> --code-file probe.js --json --quiet

# 快速同步执行
python ryc_autorun.py eval --host <IP> --code 'return 1+1'

# 手动两步
python ryc_autorun.py submit --host <IP> --code-file probe.js --json
python ryc_autorun.py result --host <IP> --id j1
```

脚本位置：`RyConsole/tools/ryc_autorun.py`（纯标准库，无依赖）

## 4.5 电脑端图形界面（GUI）

```bash
# 双击启动
tools\RunAutorunPanel.bat
# 或命令行（可预填目标 / 关掉控制接口）
python ryc_gui.py --host 192.168.0.110 --port 8899
python ryc_gui.py --no-control
python ryc_gui.py --selftest --port 18899      # 无界面自测（需 mock 服务）
```

深色科技风，与 iPad 端同一套配色。布局：

| 区域 | 内容 |
|---|---|
| 顶栏 | `iPad IP` / `端口` / 「连接」+ **状态灯**（灰=未连接，绿=已连接） |
| 中 | 「发送到 iPad 的代码」编辑区：`载入 .js` / `另存 .js` / `清空` / `执行 ▶`（`Ctrl+Enter` 同效） |
| 下 | 「执行结果 / 回传内容」：状态 pill（**待命 → 执行中 → 已回传 / 未回传**）、往返毫秒、`---- print 输出 ----`、`---- 返回值 ----`、错误段；可一键复制 |
| 底 | 「事件日志」：逐次打印轮询进度（`第 N/12 次轮询：running`） |
| 状态栏 | AI 控制接口地址、启动/停止、打开日志目录 |

**每次交互都会追加到 `tools/logs/autorun_gui.jsonl`**（追加写，不覆盖），Agent 直接读文件也能取结果。

### 内置 AI 控制接口（默认开，只绑 127.0.0.1:8877）

GUI 开着时，Agent 可以不走 CLI 直接驱动它 —— 好处是**用户能实时看到 AI 发了什么代码、回传了什么**：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/status` | 目标 / 连接 / 忙闲 / 最近结果摘要 |
| GET | `/ping` | 代理到 iPad |
| POST | `/exec` | `{"code":"…","host":"…","port":8899}`，**阻塞式**跑完 submit + 3s×12 轮询后返回最终 JSON |
| GET | `/result?id=j7` | 代理查结果 |
| GET | `/last` | 最近一次完整结果 |
| GET | `/log?n=80` | 事件日志文本 |
| GET | `/history?n=20` | 历史（不含代码，防爆量） |
| POST | `/stop` | 断开当前连接状态 |

`/exec` 发来的代码会**自动回显到 GUI 编辑区**，用户看得见正在跑什么。

## 5. 协议（想自己写客户端时看这里）

| 方法 | 路径 | 请求 | 返回 |
|---|---|---|---|
| GET | `/ping` | — | `{"ok":true,"running":true,"port":8899,"lanIP":"…","busy":false,"jobs":0}` |
| POST | `/eval` | `{"code":"…","timeoutMs":15000}` | 同步执行，直接返回结果 |
| POST | `/submit` | `{"code":"…"}` | `{"ok":true,"id":"j1","status":"accepted","pollIntervalMs":3000,"maxPolls":12}` |
| GET | `/result?id=j1` | — | `{"status":"running"}` 或 `{"status":"done","ok":…,"output":…,"result":…,"error":…,"ms":…}` |

一次连接一个请求（`Connection: close`），所以用 curl 也能测：

```bash
curl -s http://192.168.0.110:8899/ping
curl -s -X POST http://192.168.0.110:8899/eval \
     -H 'Content-Type: application/json' \
     -d '{"code":"print(\"hi\"); return 1+1"}'
```

## 6. 已知限制（都是设计取舍，不是 bug）

1. **后台挂起——已在 V2.2 用保活解决（非永久豁免）**：监听期间自动保活（静音音频 + `beginBackgroundTask` 续期），
   切后台/锁屏仍可连。但低电量模式、系统回收压力、录音占用仍可能中断；判断"还活着"只认 `ping`。
2. **一轮一个任务**：任务串行执行（同一时间只有一个 JS 在跑），结果保留最近 40 条。
3. **`print` 是回传通道**：设备端 `output` 字段 = 本次执行的所有 `print`；`result` = `return` 的值。
4. **执行环境是"一次性"的**：每次执行新建一个 JSContext（和原生 `RunCode` 一致）。
   所以**跨轮次的变量不会保留** —— 需要状态就写文件（`writeFile`）或每次重新计算。
5. **异常不会崩 App**：JS 异常被捕获后回传在 `error` 字段里。

## 7. 出问题怎么办

| 现象 | 排查 |
|---|---|
| 连不上 | ①面板点过启动没 ②同一个 Wi-Fi 没 ③灵动岛/锁屏是不是还显示「监听中」（保活被回收了）④端口对不对 |
| `执行器未注册` | 先在控制台跑任意一段 JS（会触发注册），再启动 Autorun |
| 一直 `running` | 看 iPad 屏幕：是不是弹了系统权限框（局域网权限）没点；或代码卡住了 |
| 端口被占用 | 面板换端口，电脑端 `--port` 同步改 |

## 8. 验证状态（诚实交底）

| 部分 | 状态 |
|---|---|
| ObjC 原生代码（`AutorunServer.m` / `MainShell.m` / `main.m`） | ✅ **已云端编译通过**，IPA 产出正常（`com.research.ryconsole`，MinimumOSVersion 16.0） |
| 电脑端 CLI（`ryc_autorun.py`） | ✅ 已用模拟服务端到端自测（ping / eval / submit+result / run 轮询 / --json / 连不上报错） |
| 电脑端 GUI（`ryc_gui.py`） | ✅ 隐藏窗口冒烟测试 10 项全过（构建 → 连接 → 执行 → 轮询 → 渲染 → AI 接口 → 代码回显 → jsonl 落盘） |
| `RYAutorunRunCapture` 真机执行 | ⚠️ **未在真机跑过** —— 首次请先用 `return 1+1` 这种最小代码验证通路 |

**编译时踩过的坑（已修，留档备查）**：
1. `project.yml` 引用的 `AppIcon.xcassets` / `RyConsoleScripts` 必须先推上去，否则 `xcodegen` 直接报
   `missing source directory`（构建 10 秒即失败，且**不产出任何日志 artifact**）。
2. `MainShell.m` 里「先调用后定义」且未声明的方法，clang 会把参数当 `id` → ARC 下传 `NSInteger` 直接 error
   （无参方法只是 warning）。修法：在调用点之前补声明。
3. 改了代码重新构建却**报一模一样的错、行号也一样** → 多半是**推送/触发竞态**（文件多、推送慢，
   dispatch 落在旧提交上）。判断法：比对 GitHub 上文件 sha256 与本地是否一致。

## 9. 安全

见 `DISCLAIMER.md`。要点：只对自有设备、只读优先、危险面留人工、先确认设备无不可替代数据。
