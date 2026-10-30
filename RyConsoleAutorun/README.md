# RyConsole Autorun

让 AI 在电脑端把 **JS 探针** 发到局域网里的 iPad（**RyConsole**）执行，再把结果回传——用于 iOS 安全研究的自测与动态验证。

## 架构

- **iPad 端**：RyConsole 研究控制台，内置 `AutorunServer`（默认监听 `8899`），执行 JS 探针并回传。
- **PC 端**：`ryc_autorun` 客户端（本仓库），连上 iPad、提交探针、轮询结果。

整条链路走**局域网**，探针只在你自己的设备沙盒内运行，不上传任何云端。

## 快速开始

1. iPad 装好 RyConsole（未签名 IPA 侧载），打开并切到**前台**。
2. 左侧 **Autorun** 点「启动监听」（圆点变绿，显示 `:8899`）。
3. 电脑端测试连通：
   ```bash
   ryc_autorun.exe ping --host <iPadIP>
   ```
4. 发送探针：
   ```bash
   ryc_autorun.exe run --host <iPadIP> --code-file probe_env.js --json --quiet
   ```

> iOS 在 App 后台 / 锁屏时会挂起网络监听，测试期间请保持 RyConsole 在前台、不要锁屏。

## 子命令

| 命令 | 作用 |
|------|------|
| `ping` | 连通性测试 |
| `run` | 提交 + 自动轮询（每 3s，最多 12 次） |
| `eval` | 同步执行（代码片段很快时用） |
| `submit` | 仅提交，返回任务 id |
| `result` | 按 id 取结果 |

## 安全边界

- 仅在自己**拥有 / 授权**的设备上使用。
- App 仍在沙盒内：`externalMethod` 有二次门禁，`OPEN_OK` ≠ 可利用。
- 遵循 Responsible Disclosure，不用于未授权目标。

## 构建

纯标准库，无第三方依赖。Windows 单 exe 由 PyInstaller `--onefile` 打包：

```bash
pyinstaller --onefile --name ryc_autorun ryc_autorun.py
```

## License

MIT © 单面本面 (DanMianBenMian)
