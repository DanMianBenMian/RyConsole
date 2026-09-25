#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ryc_autorun.py —— RyConsole Autorun 电脑端客户端

作用：把一段 JS 代码送到 iPad 上执行，并取回结果。
AI（Ryan）通过本程序与 iPad 交互：iPad 只负责"执行 + 回传"，AI 在电脑端。

协议（iPad 上是极简 HTTP 服务）：
  GET  /ping                    -> {"ok":true,"running":true,"port":8899,...}
  POST /eval    {"code":...,"timeoutMs":...}   -> 同步执行，直接返回结果
  POST /submit  {"code":...}                   -> 立即返回 {"id":"j1","status":"accepted"}
  GET  /result?id=j1                           -> {"status":"running"} / {"status":"done",...}

用法：
  # 连通性检查
  python ryc_autorun.py ping --host 192.168.0.110

  # 同步执行（简单、快）
  python ryc_autorun.py eval --host 192.168.0.110 --code 'return 1+1'
  python ryc_autorun.py eval --host 192.168.0.110 --code-file probe.js

  # 异步 + 轮询（推荐：代码可能跑很久）
  python ryc_autorun.py run --host 192.168.0.110 --code-file probe.js
  #   == submit + 每 3 秒查一次，最多 12 次

  # 手动两步
  python ryc_autorun.py submit --host 192.168.0.110 --code-file probe.js
  python ryc_autorun.py result --host 192.168.0.110 --id j1

  # 机器可读输出（技能用这个）
  python ryc_autorun.py run --host ... --code-file probe.js --json

退出码：0 = 成功；1 = 失败/超时；2 = 参数或网络错误
"""

import argparse
import json
import os
import sys


def _setup_console():
    """★ 2026-09-18 修复：程序"莫名崩溃"的真凶就在这里。

    中文 Windows 控制台默认代码页是 936(GBK)，而本脚本会打印 ✅/❌ 这类字符。
    Python 往 GBK 流写 UTF-8 无法表示的字符 → 抛 UnicodeEncodeError
    → PyInstaller 打包的程序没有兜底 → **整个进程直接退出**（命令行看到的
    "Failed to execute script" 就是这个）。

    这里做两件事：
      ① 把控制台输出代码页切成 65001(UTF-8)，让 cmd 能正常渲染 emoji/中文；
      ② 把 stdout/stderr 强制成 utf-8 + errors="replace" —— 万一还有编码问题，
         也只会显示成 ? 而**不会再把程序打死**。
    """
    try:
        if os.name == "nt":
            import ctypes
            ctypes.windll.kernel32.SetConsoleOutputCP(65001)
            ctypes.windll.kernel32.SetConsoleCP(65001)
    except Exception:
        pass
    for name in ("stdout", "stderr"):
        s = getattr(sys, name, None)
        if s is None:
            continue
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


_setup_console()

import time
import urllib.error
import urllib.request

DEFAULT_PORT = 8899
POLL_INTERVAL = 3.0     # 秒
MAX_POLLS = 12          # 最多轮询 12 次（约 36 秒，足够跑完代码并回传）
HTTP_TIMEOUT = 60.0


class RyError(Exception):
    pass


def _request(host, port, path, method="GET", payload=None, timeout=HTTP_TIMEOUT):
    url = "http://%s:%d%s" % (host, port, path)
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = ""
        try:
            raw = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        try:
            return json.loads(raw)
        except Exception:
            raise RyError("HTTP %s：%s" % (e.code, raw[:400] or "(空响应)"))
    except urllib.error.URLError as e:
        raise RyError("连不上 %s：%s\n  ─ 确认：①iPad 上 Autorun 已启动 ②同一局域网 "
                      "③面板点过「启动监听」（V2.2 起监听期自动保活，可切后台/锁屏）④端口一致；"
                      "若刚崩过，重开 App 再点启动" % (url, e.reason))
    except Exception as e:
        raise RyError("请求失败 %s：%r" % (url, e))
    try:
        return json.loads(body)
    except Exception:
        raise RyError("返回不是 JSON（前 400 字）：%s" % body[:400])


def _read_code(args):
    if args.code_file:
        with open(args.code_file, "r", encoding="utf-8") as f:
            return f.read()
    if args.code:
        return args.code
    if not sys.stdin.isatty():
        return sys.stdin.read()
    raise RyError("没有代码：用 --code / --code-file，或从 stdin 管道输入")


def _emit(obj, as_json, human_lines=None):
    if as_json:
        print(json.dumps(obj, ensure_ascii=False, indent=2))
    else:
        if human_lines:
            for l in human_lines:
                print(l)
        else:
            print(json.dumps(obj, ensure_ascii=False, indent=2))
    return obj


def cmd_ping(args):
    r = _request(args.host, args.port, "/ping")
    ok = bool(r.get("ok"))
    lines = ["连接成功 ✅" if ok else "服务返回异常 ❌",
             "  服务    : %s %s" % (r.get("name", "?"), r.get("version", "")),
             "  监听    : %s (端口 %s)" % ("是" if r.get("running") else "否", r.get("port")),
             "  iPad IP : %s" % r.get("lanIP", "?"),
             "  忙      : %s   任务数: %s" % (r.get("busy"), r.get("jobs")),
             # ★ 以下几项是 2026-09-18 新增的诊断字段：一眼看出"服务是否重启过 / 收到的代码对不对"
             "  进程 pid: %s   会话: %s" % (r.get("pid"), r.get("session")),
             "  累计连接: %s" % r.get("hits"),
             "  上次收码: %s 字节 (来源 %s)" % (r.get("lastCodeLen"), r.get("lastSrcKind")),
             "  上次原语: %s" % r.get("lastPrim")]
    _emit(r, args.json, lines)
    return 0 if ok else 1


def cmd_eval(args):
    code = _read_code(args)
    r = _request(args.host, args.port, "/eval",
                 method="POST", payload={"code": code, "timeoutMs": args.timeout_ms})
    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    else:
        print(_format_result(r))
    return 0 if r.get("ok") else 1


def cmd_submit(args):
    code = _read_code(args)
    r = _request(args.host, args.port, "/submit", method="POST", payload={"code": code})
    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    else:
        print("已提交：id=%s  status=%s" % (r.get("id"), r.get("status")))
    return 0 if r.get("ok") else 1


def cmd_result(args):
    r = _request(args.host, args.port, "/result?id=%s" % args.id)
    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    else:
        print(_format_result(r))
    return 0 if r.get("status") == "done" and r.get("ok") else 1


def cmd_run(args):
    """submit + 轮询：每 POLL_INTERVAL 秒查一次，最多 MAX_POLLS 次。"""
    code = _read_code(args)
    sub = _request(args.host, args.port, "/submit", method="POST", payload={"code": code})
    if not sub.get("ok"):
        print(json.dumps(sub, ensure_ascii=False, indent=2) if args.json
              else "提交失败：%s" % sub.get("error"))
        return 1

    jid = sub.get("id")
    # 优先级：CLI --interval/--max-polls > 服务端建议值 > 内置默认
    interval = args.interval if getattr(args, "interval", None) else (
        (sub.get("pollIntervalMs") or int(POLL_INTERVAL * 1000)) / 1000.0)
    max_polls = args.max_polls if getattr(args, "max_polls", None) else (
        sub.get("maxPolls") or MAX_POLLS)

    if not args.quiet and not args.json:
        print("已提交 id=%s，开始轮询（每 %.0fs，最多 %d 次）..." % (jid, interval, max_polls))

    last = None
    for i in range(1, int(max_polls) + 1):
        time.sleep(interval)
        try:
            last = _request(args.host, args.port, "/result?id=%s" % jid)
        except RyError as e:
            if not args.quiet and not args.json:
                print("  第 %d 次轮询异常：%s" % (i, e))
            last = {"status": "error", "error": str(e)}
            continue
        st = last.get("status")
        if not args.quiet and not args.json:
            print("  第 %d 次轮询：%s" % (i, st))
        if st == "done":
            break
        # ★ 2026-09-18：服务端明确告知"任务被清理/没这个 id"时立刻停止轮询并说明原因，
        #   不再傻等满 12 次（老版本只会打印裸 JSON，看起来像"结果丢了"）。
        if last.get("error") in ("job_expired", "unknown_job"):
            if not args.quiet and not args.json:
                print("  服务端已清理该任务：%s" % last.get("error"))
                if last.get("hint"):
                    print("  提示：%s" % last["hint"])
                if last.get("error") == "unknown_job":
                    print("  多半是 iPad 上 RyConsole 崩溃/重开过（job 表随进程消失）——"
                          "用 `ping` 看 pid 是否变了。")
            break

    if last is None:
        last = {"status": "unknown", "error": "没有拿到任何结果"}

    if args.json:
        print(json.dumps(last, ensure_ascii=False, indent=2))
    else:
        if last.get("status") != "done":
            print("⚠️  轮询 %s 次后仍未完成（status=%s）" % (max_polls, last.get("status")))
            print(json.dumps(last, ensure_ascii=False, indent=2))
        else:
            print(_format_result(last))
    return 0 if last.get("status") == "done" and last.get("ok") else 1


def _format_result(r):
    if r is None:
        return "(无结果)"
    if r.get("status") == "running":
        return "仍在执行中（status=running）"
    out = []
    out.append("状态      : %s" % ("成功 ✅" if r.get("ok") else "失败 ❌"))
    if r.get("ms") is not None:
        out.append("耗时      : %s ms" % r.get("ms"))
    if r.get("error"):
        out.append("错误      : %s" % r.get("error"))
    if r.get("output"):
        out.append("---- print 输出 ----")
        out.append(r["output"])
    if r.get("result") is not None:
        out.append("---- 返回值 ----")
        out.append(str(r["result"]))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="RyConsole Autorun 电脑端客户端")
    ap.add_argument("cmd", choices=["ping", "eval", "submit", "result", "run"])
    ap.add_argument("--host", required=True, help="iPad 的局域网 IP 或主机名")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--code", help="要执行的 JS 代码")
    ap.add_argument("--code-file", help="从文件读取 JS 代码")
    ap.add_argument("--id", help="result 命令用的任务 id")
    ap.add_argument("--timeout-ms", type=int, default=15000, help="eval 的执行超时（毫秒）")
    ap.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    ap.add_argument("--quiet", action="store_true", help="不打印轮询过程")
    # ★ 2026-09-25：自定义轮询（run 用）。给了就覆盖服务端建议值。
    ap.add_argument("--interval", type=float, default=None,
                    help="run 的轮询间隔秒数（默认取服务端 pollIntervalMs，再退 3s）")
    ap.add_argument("--max-polls", type=int, default=None,
                    help="run 的最大轮询次数（默认取服务端 maxPolls，再退 12）；长探针调大，如 --max-polls 100")
    args = ap.parse_args()

    handlers = {"ping": cmd_ping, "eval": cmd_eval, "submit": cmd_submit,
                "result": cmd_result, "run": cmd_run}
    if args.cmd == "result" and not args.id:
        ap.error("result 命令需要 --id")
    try:
        return handlers[args.cmd](args)
    except RyError as e:
        if args.json:
            print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False, indent=2))
        else:
            print("错误：%s" % e, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\n已中断", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
