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

**②之后到测试完，别让 App 切到后台或锁屏** —— iOS 会挂起监听。

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

1. **App 必须在前台**：iOS 会挂起后台 socket。锁屏/切后台 = 连接断开。
2. **一轮一个任务**：任务串行执行（同一时间只有一个 JS 在跑），结果保留最近 40 条。
3. **`print` 是回传通道**：设备端 `output` 字段 = 本次执行的所有 `print`；`result` = `return` 的值。
4. **执行环境是"一次性"的**：每次执行新建一个 JSContext（和原生 `RunCode` 一致）。
   所以**跨轮次的变量不会保留** —— 需要状态就写文件（`writeFile`）或每次重新计算。
5. **异常不会崩 App**：JS 异常被捕获后回传在 `error` 字段里。

## 7. 出问题怎么办

| 现象 | 排查 |
|---|---|
| 连不上 | ①面板点过启动没 ②同一个 Wi-Fi 没 ③App 是不是切后台了 ④端口对不对 |
| `执行器未注册` | 先在控制台跑任意一段 JS（会触发注册），再启动 Autorun |
| 一直 `running` | 看 iPad 屏幕：是不是弹了系统权限框（局域网权限）没点；或代码卡住了 |
| 端口被占用 | 面板换端口，电脑端 `--port` 同步改 |

## 8. ⚠️ 尚未验证的部分（诚实交底）

- ObjC 新代码（`AutorunServer.m`）**本地无法编译验证**（Windows 没有 Xcode）。
  已做静态自检：括号配平零差、`main.m` 五处接线齐全。
  **第一次云端构建可能需要改一两处**——如果编译报错，把错误贴出来即可快速修掉。
- `RYAutorunRunCapture` 复用了 `RunCode` 的 ctx 装配流程（安装原语 → 加载桥 → 载入 engine.js），
  但**没有在真机上跑过**，首次执行请先用 `return 1+1` 这种最小代码验证通路。

## 9. 安全

见 `DISCLAIMER.md`。要点：只对自有设备、只读优先、危险面留人工、先确认设备无不可替代数据。
