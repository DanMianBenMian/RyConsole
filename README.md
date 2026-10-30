# RyConsole
RyConsole 研究控制台（未签名 IPA 云构建）

> 当前版本：**V2.4.26**

## 更新说明
- **V2.4.26**：基于 V2.4.24 远程连接能力持续迭代，修复若干问题并增强沙盒逃逸 JS 探针（详见 GitHub Releases）。
- **V2.4.24**：新增「远程连接」模式 —— RyConsoleServer（PC 端 aiohttp 双 WS 中继 + 内置 cloudflared quick tunnel 隧道 + token 鉴权），并支持远程保活与灵动岛实时活动。
- 历史版本与完整变更见 Releases 页面。

## 简介
iOS / iPadOS 安全研究 harness（越狱 / 自签侧载环境）。原生 C 底座 + JS 桥动态加载，提供原生原语（mach / ioctl / syscall / 内存读写等）与 JS 桥动态探针，用于沙盒逃逸、LPE、内核审计等研究。

## 安装
未签名 IPA，需自签侧载（全能签 / 牛蛙 / TrollStore 等，依设备环境）。仅用于研究场景。

## 目录
- `RyConsole/`：iOS 端源码（XcodeGen `project.yml`，云构建未签名 IPA）
- `RyConsoleServer/`：PC 端中继服务（aiohttp 双 WS + cloudflared 隧道，CLI / tkinter GUI 双入口）

## 免责
仅供 iOS 安全研究学习，使用者须遵守当地法律与 Apple 许可协议。


<!-- MERGED 2026-10-30: RyConsole is now public; RyConsole-Autorun client folded in below -->
## RyConsoleAutorun (PC 端探针客户端, 已并入本仓库)

原 `RyConsole-Autorun` 仓库的 PC 端探针客户端已合并到本仓库 `RyConsoleAutorun/`：

- `RyConsoleAutorun/ryc_autorun.py`：连上 iPad、提交 JS 探针、轮询结果。
- `RyConsoleAutorun/probe_env.js`：示例探针。
- `RyConsoleAutorun/skill/`：给 AI Agent 用的操作指南 Skill。

用法见 `RyConsoleAutorun/README.md`。仅在你拥有 / 授权的设备上使用。
