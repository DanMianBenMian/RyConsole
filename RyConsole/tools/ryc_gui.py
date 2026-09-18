#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ryc_gui.py —— RyConsole Autorun 电脑端图形界面（Windows / tkinter，零第三方依赖）

作用：在一台与 iPad 同局域网的电脑上，把 JS 代码送到 iPad 的 RyConsole Autorun 执行，
      并实时看到「提交 -> 轮询(3s x12) -> 回传」全过程。

同时内置两种给 AI（Ryan）用的接口：
  ① CLI  : ryc_autorun.py（技能 ryconsole-autorun 用的就是它）
  ② 控制接口: 本窗口内置 127.0.0.1 上的极简 HTTP 服务，Agent 可 POST 代码、读结果
  另外每次交互都会追加到 tools/logs/autorun_gui.jsonl，Agent 直接读文件也能取结果。

用法：
  python ryc_gui.py                                  # 打开窗口
  python ryc_gui.py --host 192.168.0.110 --port 8899 # 预填目标
  python ryc_gui.py --selftest                       # 无界面自测核心逻辑（不开窗）
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import sys
import threading
import time
import traceback
import urllib.parse as up
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# 复用已有客户端：HTTP 请求 + 轮询契约只保留一套实现，避免两边行为漂移
import ryc_autorun as cli  # noqa: E402

# ---------------------------------------------------------------- 主题（与 iPad 端一致）
BG = "#0d1117"       # 窗口底
PANEL = "#161b22"    # 面板底
PANEL2 = "#1c2128"   # 次级面板
BORDER = "#30363d"   # 1px 细边框
FG = "#c9d1d9"       # 主文字
MUTED = "#8b949e"    # 次要文字
ACCENT = "#2f81f7"   # 主色（GitHub 蓝）
OK = "#3fb950"       # 成功绿
WARN = "#d29922"     # 进行中黄
ERR = "#f85149"      # 失败红
MONO = ("Consolas", 10)
MONO_S = ("Consolas", 9)
UI = ("Microsoft YaHei UI", 10)
UI_S = ("Microsoft YaHei UI", 9)

APP_TITLE = "RyConsole Autorun - PC Console"
DEFAULT_CONTROL_PORT = 8877
LOG_DIR = os.path.join(_HERE, "logs")
JSONL = os.path.join(LOG_DIR, "autorun_gui.jsonl")
LOGFILE = os.path.join(LOG_DIR, "autorun_gui.log")


def _ensure_logdir():
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
    except Exception:
        pass


def append_jsonl(obj):
    """把一次交互追加进 jsonl（Agent 可直接读文件拿结果）。追加写，绝不覆盖。"""
    _ensure_logdir()
    try:
        with open(JSONL, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except Exception:
        pass


def append_text(line):
    _ensure_logdir()
    try:
        with open(LOGFILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ================================================================ 核心逻辑（无 UI，可自测）
class RyCore:
    """与 iPad 交互的核心。不依赖任何 UI，GUI / HTTP 控制接口 / 自测共用同一份。"""

    def __init__(self, on_event=None):
        self.host = ""
        self.port = cli.DEFAULT_PORT
        self.connected = False
        self.busy = False
        self.last = {}
        self.jobs = {}
        self.history = []
        self._lock = threading.Lock()
        self._on_event = on_event or (lambda kind, payload: None)
        self.last_error = ""
        self.events = []          # 事件文本（供 /log 读取）
        self._ev_lock = threading.Lock()

    # ---- 事件：可能来自工作线程，调用方自行决定如何搬运到 UI 线程
    def emit(self, kind, payload=None):
        payload = payload if payload is not None else {}
        try:
            self._on_event(kind, payload)
        except Exception:
            pass

    def log(self, text, level="info"):
        line = "[%s] %s" % (time.strftime("%H:%M:%S"), text)
        with self._ev_lock:
            self.events.append((level, line))
            if len(self.events) > 500:
                del self.events[:200]
        append_text(line)
        self.emit("log", {"level": level, "text": text})

    # ---- 连通性
    def ping(self, host=None, port=None, timeout=6.0):
        host = (host or self.host or "").strip()
        port = int(port or self.port)
        if not host:
            raise cli.RyError("还没填 iPad 的 IP")
        self.log("ping %s:%d ..." % (host, port))
        r = cli._request(host, port, "/ping", timeout=timeout)
        self.host, self.port = host, port
        self.connected = bool(r.get("ok"))
        if self.connected:
            self.log("连接成功 · iPad IP=%s · 端口=%s" % (r.get("lanIP", "?"), r.get("port")), "ok")
        else:
            self.log("服务返回异常：%s" % json.dumps(r, ensure_ascii=False)[:200], "err")
        self.emit("ping", r)
        return r

    def disconnect(self):
        self.connected = False
        self.emit("ping", {"ok": False})

    # ---- 执行：submit + 轮询（严格按 3s x 12 契约，节奏由服务端下发）
    def exec_code(self, code, timeout_ms=None, host=None, port=None):
        with self._lock:
            if self.busy:
                raise cli.RyError("已有任务在执行，等它结束再发（或点停止）")
            self.busy = True
        try:
            host = (host or self.host or "").strip()
            port = int(port or self.port)
            if not host:
                raise cli.RyError("还没填 iPad 的 IP")
            code = code if code is not None else ""
            t0 = time.time()

            self.emit("phase", {"phase": "提交", "color": WARN})
            self.log("提交代码 %d 字节 -> %s:%d" % (len(code.encode("utf-8")), host, port))
            sub = cli._request(host, port, "/submit", method="POST", payload={"code": code})
            if not sub.get("ok"):
                raise cli.RyError(sub.get("error") or "提交被拒绝")

            jid = sub.get("id")
            interval = (sub.get("pollIntervalMs") or int(cli.POLL_INTERVAL * 1000)) / 1000.0
            max_polls = int(sub.get("maxPolls") or cli.MAX_POLLS)
            self.log("已提交 id=%s，开始轮询（每 %.0fs，最多 %d 次）" % (jid, interval, max_polls))
            self.emit("submitted", {"id": jid, "interval": interval, "maxPolls": max_polls})

            last = {"status": "running", "id": jid}
            for i in range(1, max_polls + 1):
                time.sleep(interval)
                try:
                    last = cli._request(host, port, "/result?id=%s" % jid)
                except cli.RyError as e:
                    last = {"status": "error", "error": str(e), "id": jid}
                st = last.get("status")
                self.emit("poll", {"i": i, "max": max_polls, "status": st})
                self.log("  第 %d/%d 次轮询：%s" % (i, max_polls, st))
                if st == "done":
                    break

            last = dict(last or {})
            last["id"] = jid
            last["elapsedMs"] = int((time.time() - t0) * 1000)
            last["code"] = code
            last["host"] = host
            last["port"] = port

            if last.get("status") != "done":
                self.log("轮询 %d 次后仍未完成（status=%s）" % (max_polls, last.get("status")), "warn")
                self.emit("phase", {"phase": "回传失败", "color": ERR})
            elif last.get("ok"):
                self.log("已回传 · 成功 · %s ms" % last.get("ms"), "ok")
                self.emit("phase", {"phase": "已回传", "color": OK})
            else:
                self.log("已回传 · 执行报错：%s" % str(last.get("error"))[:200], "err")
                self.emit("phase", {"phase": "已回传(报错)", "color": ERR})

            self.last = last
            self.jobs[jid] = last
            self.history.append({"ts": time.time(), "id": jid, "host": host,
                                 "port": port, "code": code, "result": last})
            if len(self.history) > 200:
                del self.history[:50]
            append_jsonl({"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "id": jid,
                          "host": host, "port": port, "code": code, "result": last})
            self.emit("done", last)
            return last
        except Exception as e:
            self.last_error = str(e)
            self.emit("phase", {"phase": "出错", "color": ERR})
            self.emit("error", {"error": str(e)})
            raise
        finally:
            self.busy = False

    def proxy_result(self, jid):
        return cli._request(self.host, self.port, "/result?id=%s" % jid)

    def recent_log(self, n=80):
        with self._ev_lock:
            items = list(self.events)[-int(n):]
        return "\n".join(t for _lv, t in items)

    def status(self, control_port=None):
        return {
            "ok": True,
            "target": "%s:%d" % (self.host or "?", self.port),
            "connected": bool(self.connected),
            "busy": bool(self.busy),
            "lastId": self.last.get("id"),
            "lastStatus": self.last.get("status"),
            "lastOk": self.last.get("ok"),
            "jobs": len(self.jobs),
            "controlPort": control_port,
            "jsonl": JSONL,
        }


# ================================================================ 本地控制接口（给 AI 用）
class RyControlHandler(BaseHTTPRequestHandler):
    core = None                 # RyCore
    port_holder = {"port": None}
    on_remote_code = None       # 回调：把远端发来的代码显示到 GUI

    server_version = "RyConsoleAutorunGUI/1.0"

    def log_message(self, *a):  # 静音
        pass

    # ---- 工具
    def _send(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except Exception:
            n = 0
        if n <= 0:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            return {}

    # ---- GET
    def do_GET(self):
        u = up.urlparse(self.path)
        q = up.parse_qs(u.query)
        core = self.core
        try:
            if u.path in ("/status", "/"):
                return self._send(core.status(self.port_holder.get("port")))
            if u.path == "/ping":
                host = (q.get("host") or [None])[0]
                port = (q.get("port") or [None])[0]
                return self._send(core.ping(host, port))
            if u.path == "/result":
                jid = (q.get("id") or [None])[0]
                if not jid:
                    return self._send({"ok": False, "error": "缺少 id"}, 400)
                return self._send(core.proxy_result(jid))
            if u.path == "/log":
                n = int((q.get("n") or [80])[0])
                return self._send({"ok": True, "log": core.recent_log(n)})
            if u.path == "/history":
                n = int((q.get("n") or [20])[0])
                items = [{k: v for k, v in h.items() if k != "code"} for h in core.history[-n:]]
                return self._send({"ok": True, "count": len(items), "history": items})
            if u.path == "/last":
                return self._send(core.last or {"ok": False, "error": "还没有任何结果"})
            return self._send({"ok": False, "error": "未知路径 " + u.path}, 404)
        except cli.RyError as e:
            return self._send({"ok": False, "error": str(e)}, 200)
        except Exception as e:
            return self._send({"ok": False, "error": repr(e)}, 500)

    # ---- POST
    def do_POST(self):
        core = self.core
        body = self._body()
        u = up.urlparse(self.path)
        try:
            if u.path == "/exec":
                code = body.get("code") or ""
                host = body.get("host") or None
                port = body.get("port") or None
                if not code.strip():
                    return self._send({"ok": False, "error": "body 里没有 code"}, 400)
                if self.on_remote_code:
                    try:
                        self.on_remote_code(code, self.client_address[0], host, port)
                    except Exception:
                        pass
                res = core.exec_code(code, host=host, port=port)
                return self._send(res)
            if u.path == "/stop":
                core.disconnect()
                return self._send({"ok": True, "connected": False})
            return self._send({"ok": False, "error": "未知路径 " + u.path}, 404)
        except cli.RyError as e:
            return self._send({"ok": False, "error": str(e), "status": "error"}, 200)
        except Exception as e:
            return self._send({"ok": False, "error": repr(e), "status": "error"}, 500)


class RyControlServer:
    """把 GUI 背后的 RyCore 暴露成 127.0.0.1 上的 HTTP，供 Agent 调用。"""

    def __init__(self, core, port=DEFAULT_CONTROL_PORT, on_remote_code=None):
        self.core = core
        self.port = int(port)
        self.httpd = None
        self.thread = None
        self.on_remote_code = on_remote_code

    def start(self):
        handler = type("H", (RyControlHandler,), {})
        handler.core = self.core
        handler.on_remote_code = staticmethod(self.on_remote_code) if self.on_remote_code else None
        handler.port_holder = {"port": self.port}
        self.httpd = ThreadingHTTPServer(("127.0.0.1", self.port), handler)
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       kwargs={"poll_interval": 0.3}, daemon=True)
        self.thread.start()
        return self.port

    def stop(self):
        try:
            if self.httpd:
                self.httpd.shutdown()
                self.httpd.server_close()
        except Exception:
            pass
        self.httpd = None


# ================================================================ GUI
class RyGui:
    def __init__(self, root, host="", port=cli.DEFAULT_PORT, control_port=DEFAULT_CONTROL_PORT,
                 auto_control=True):
        import tkinter as tk
        from tkinter import filedialog, messagebox

        self.tk = tk
        self.filedialog = filedialog
        self.messagebox = messagebox
        self.root = root
        self.q = queue.Queue()
        self.core = RyCore(on_event=self._thread_event)
        self.core.host = host
        self.core.port = int(port)
        self.server = None
        self.control_port = int(control_port)
        self.phase_job = None

        root.title(APP_TITLE)
        root.configure(bg=BG)
        root.geometry("980x720")
        root.minsize(760, 560)

        self._build_topbar()
        self._build_code_area()
        self._build_result_area()
        self._build_log_area()
        self._build_statusbar()

        if auto_control:
            self._start_control(silent=True)

        root.bind("<Control-Return>", lambda e: (self.on_run(), "break")[1])
        root.after(80, self._drain)
        self.core.log("面板就绪。填 iPad IP -> 点『连接』-> 贴代码 -> 『执行』（Ctrl+Enter）")

    # ---------------------------------------------------------- 构建：顶栏
    def _build_topbar(self):
        tk = self.tk
        bar = tk.Frame(self.root, bg=PANEL, highlightthickness=1,
                       highlightbackground=BORDER)
        bar.pack(fill="x", side="top")

        tk.Label(bar, text="RyConsole", bg=PANEL, fg=FG,
                 font=("Microsoft YaHei UI", 13, "bold")).pack(side="left", padx=(14, 6), pady=10)
        tk.Label(bar, text="Autorun 电脑端", bg=PANEL, fg=MUTED,
                 font=UI_S).pack(side="left", pady=(12, 10))

        # 状态灯
        self.dot = tk.Canvas(bar, width=12, height=12, bg=PANEL, highlightthickness=0)
        self.dot.pack(side="left", padx=(18, 4))
        self.dot_id = self.dot.create_oval(2, 2, 10, 10, fill=MUTED, outline="")
        self.conn_label = tk.Label(bar, text="未连接", bg=PANEL, fg=MUTED, font=UI_S)
        self.conn_label.pack(side="left")

        # 右侧：目标 IP / 端口 / 按钮
        self.port_var = tk.StringVar(value=str(self.core.port))
        self.host_var = tk.StringVar(value=self.core.host or "")

        btn = self._mk_button(bar, "连接", self.on_ping, ACCENT, width=8)
        btn.pack(side="right", padx=(6, 14))
        tk.Entry(bar, textvariable=self.port_var, bg=PANEL2, fg=FG, insertbackground=FG,
                 font=MONO_S, width=6, relief="flat",
                 highlightthickness=1, highlightbackground=BORDER).pack(side="right", padx=4, pady=8)
        tk.Label(bar, text="端口", bg=PANEL, fg=MUTED, font=UI_S).pack(side="right")
        tk.Entry(bar, textvariable=self.host_var, bg=PANEL2, fg=FG, insertbackground=FG,
                 font=MONO_S, width=18, relief="flat",
                 highlightthickness=1, highlightbackground=BORDER).pack(side="right", padx=4, pady=8)
        tk.Label(bar, text="iPad IP", bg=PANEL, fg=MUTED, font=UI_S).pack(side="right")

    def _mk_button(self, parent, text, cmd, fg=FG, width=None, bg=None):
        tk = self.tk
        b = tk.Button(parent, text=text, command=cmd, bg=bg or PANEL2, fg=fg,
                      activebackground=BORDER, activeforeground=FG,
                      font=UI, relief="flat", bd=0, highlightthickness=0,
                      padx=12, pady=5, cursor="hand2")
        if width:
            b.configure(width=width)
        b.bind("<Enter>", lambda e: b.configure(bg=BORDER))
        b.bind("<Leave>", lambda e: b.configure(bg=bg or PANEL2))
        return b

    # ---------------------------------------------------------- 构建：代码区
    def _build_code_area(self):
        tk = self.tk
        box = tk.Frame(self.root, bg=BG)
        box.pack(fill="both", expand=True, padx=12, pady=(10, 0))

        head = tk.Frame(box, bg=BG)
        head.pack(fill="x")
        tk.Label(head, text="发送到 iPad 的代码（JavaScript）", bg=BG, fg=MUTED,
                 font=UI).pack(side="left")

        for txt, cmd in (("清空", self.on_clear_code),
                         ("载入 .js", self.on_load_code),
                         ("另存 .js", self.on_save_code),
                         ("执行 ▶", self.on_run)):
            fg = OK if txt.startswith("执行") else FG
            self._mk_button(head, txt, cmd, fg=fg).pack(side="right", padx=(6, 0))

        wrap = tk.Frame(box, bg=BORDER, highlightthickness=0)
        wrap.pack(fill="both", expand=True, pady=(6, 0))
        self.code = tk.Text(wrap, bg="#0b0f14", fg="#e6edf3", insertbackground=ACCENT,
                            font=MONO, relief="flat", bd=0, wrap="none", undo=True,
                            height=13, selectbackground="#264f78")
        csc = tk.Scrollbar(wrap, command=self.code.yview, bg=PANEL, troughcolor=BG,
                           relief="flat", bd=0, width=12)
        self.code.configure(yscrollcommand=csc.set)
        csc.pack(side="right", fill="y")
        self.code.pack(side="left", fill="both", expand=True, padx=1, pady=1)
        self.code.insert("1.0", "// 示例：先来一段只读探测\n"
                                "print('hello from PC');\n"
                                "return JSON.stringify({ok:true, ts: Date.now()});\n")

    # ---------------------------------------------------------- 构建：结果区
    def _build_result_area(self):
        tk = self.tk
        box = tk.Frame(self.root, bg=BG)
        box.pack(fill="both", expand=True, padx=12, pady=(12, 0))

        head = tk.Frame(box, bg=BG)
        head.pack(fill="x")
        tk.Label(head, text="执行结果 / 回传内容", bg=BG, fg=MUTED, font=UI).pack(side="left")

        self.phase = tk.Label(head, text="待命", bg=PANEL2, fg=MUTED, font=UI_S,
                              padx=10, pady=2)
        self.phase.pack(side="left", padx=10)
        self.elapsed = tk.Label(head, text="", bg=BG, fg=MUTED, font=MONO_S)
        self.elapsed.pack(side="left")
        self._mk_button(head, "复制", self.on_copy_result).pack(side="right")

        wrap = tk.Frame(box, bg=BORDER)
        wrap.pack(fill="both", expand=True, pady=(6, 0))
        self.out = tk.Text(wrap, bg="#0b0f14", fg=FG, font=MONO, relief="flat", bd=0,
                           wrap="word", height=12, selectbackground="#264f78")
        osc = tk.Scrollbar(wrap, command=self.out.yview, bg=PANEL, troughcolor=BG,
                           relief="flat", bd=0, width=12)
        self.out.configure(yscrollcommand=osc.set)
        osc.pack(side="right", fill="y")
        self.out.pack(side="left", fill="both", expand=True, padx=1, pady=1)
        self.out.tag_configure("ok", foreground=OK)
        self.out.tag_configure("err", foreground=ERR)
        self.out.tag_configure("warn", foreground=WARN)
        self.out.tag_configure("dim", foreground=MUTED)
        self.out.configure(state="disabled")

    # ---------------------------------------------------------- 构建：日志区
    def _build_log_area(self):
        tk = self.tk
        box = tk.Frame(self.root, bg=BG)
        box.pack(fill="both", expand=False, padx=12, pady=(12, 0))

        head = tk.Frame(box, bg=BG)
        head.pack(fill="x")
        tk.Label(head, text="事件日志", bg=BG, fg=MUTED, font=UI).pack(side="left")
        self._mk_button(head, "清空日志", self.on_clear_log).pack(side="right")

        wrap = tk.Frame(box, bg=BORDER)
        wrap.pack(fill="both", expand=True, pady=(6, 0))
        self.log = tk.Text(wrap, bg=PANEL, fg=MUTED, font=MONO_S, relief="flat", bd=0,
                           wrap="none", height=8)
        lsc = tk.Scrollbar(wrap, command=self.log.yview, bg=PANEL, troughcolor=BG,
                           relief="flat", bd=0, width=12)
        self.log.configure(yscrollcommand=lsc.set)
        lsc.pack(side="right", fill="y")
        self.log.pack(side="left", fill="both", expand=True, padx=1, pady=1)
        self.log.tag_configure("ok", foreground=OK)
        self.log.tag_configure("err", foreground=ERR)
        self.log.tag_configure("warn", foreground=WARN)
        self.log.tag_configure("info", foreground=MUTED)
        self.log.configure(state="disabled")

    # ---------------------------------------------------------- 构建：底栏
    def _build_statusbar(self):
        tk = self.tk
        bar = tk.Frame(self.root, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        bar.pack(fill="x", side="bottom")
        self.control_label = tk.Label(bar, text="AI 控制接口：未启动", bg=PANEL, fg=MUTED, font=UI_S)
        self.control_label.pack(side="left", padx=12, pady=6)
        self._ctl_btn = self._mk_button(bar, "启动 AI 控制接口", self.on_toggle_control, ACCENT)
        self._ctl_btn.pack(side="right", padx=12, pady=4)
        self._mk_button(bar, "打开日志目录", self.on_open_logdir).pack(side="right", pady=4)

    # ---------------------------------------------------------- 事件搬运（工作线程 -> UI 线程）
    def _thread_event(self, kind, payload):
        self.q.put((kind, payload))

    def _drain(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                self._apply(kind, payload)
        except queue.Empty:
            pass
        except Exception:
            pass
        self.root.after(80, self._drain)

    def _apply(self, kind, payload):
        if kind == "log":
            self._log_line(payload.get("text", ""), payload.get("level", "info"))
        elif kind == "phase":
            self._set_phase(payload.get("phase", "?"), payload.get("color", MUTED))
        elif kind == "ping":
            ok = bool(payload.get("ok"))
            color = OK if ok else ERR
            self.dot.itemconfigure(self.dot_id, fill=color)
            self.conn_label.configure(text=("已连接 " + str(payload.get("lanIP") or "")) if ok else "未连接",
                                      fg=color)
            if ok:
                self._set_phase("已连接", OK)
        elif kind == "done":
            self._render_result(payload)
        elif kind == "_remote_code":
            # Agent 通过控制接口发来的代码：显示在编辑区（让用户看得见正在跑什么）
            try:
                self.code.delete("1.0", "end")
                self.code.insert("1.0", payload.get("code", ""))
            except Exception:
                pass
        elif kind == "error":
            self._set_phase("出错", ERR)
            self._out_write("!! " + str(payload.get("error")), "err")

    # ---------------------------------------------------------- 动作
    def on_ping(self):
        host = self.host_var.get().strip()
        try:
            port = int(self.port_var.get().strip() or cli.DEFAULT_PORT)
        except ValueError:
            self._log_line("端口不是数字", "err"); return
        if not host:
            self._log_line("先填 iPad 的 IP（Autorun 面板上有显示）", "warn"); return
        self._set_phase("连接中", WARN)
        threading.Thread(target=self._bg_ping, args=(host, port), daemon=True).start()

    def _bg_ping(self, host, port):
        try:
            self.core.ping(host, port)
        except cli.RyError as e:
            self.core.connected = False
            self.core.log(str(e), "err")
            self.core.emit("ping", {"ok": False})

    def on_run(self):
        code = self.code.get("1.0", "end-1c")
        if not code.strip():
            self._log_line("代码是空的", "warn"); return
        if not self.core.host:
            host = self.host_var.get().strip()
            if not host:
                self._log_line("先填 iPad 的 IP 并点『连接』", "warn"); return
            self.core.host = host
        try:
            self.core.port = int(self.port_var.get().strip() or cli.DEFAULT_PORT)
        except ValueError:
            pass
        if self.core.busy:
            self._log_line("上一段还在跑，等它结束", "warn"); return
        self._out_clear()
        self._set_phase("执行中", WARN)
        self.elapsed.configure(text="")
        threading.Thread(target=self._bg_run, args=(code,), daemon=True).start()

    def _bg_run(self, code):
        try:
            self.core.exec_code(code)
        except cli.RyError as e:
            self.core.log("执行失败：%s" % e, "err")
        except Exception as e:
            self.core.log("执行异常：%r" % e, "err")

    def on_clear_code(self):
        self.code.delete("1.0", "end")

    def on_load_code(self):
        p = self.filedialog.askopenfilename(title="载入 JS",
                                            filetypes=[("JavaScript", "*.js"), ("所有文件", "*.*")])
        if not p:
            return
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                self.code.delete("1.0", "end")
                self.code.insert("1.0", f.read())
            self._log_line("已载入 %s" % os.path.basename(p))
        except Exception as e:
            self._log_line("载入失败：%r" % e, "err")

    def on_save_code(self):
        p = self.filedialog.asksaveasfilename(title="另存 JS", defaultextension=".js",
                                              filetypes=[("JavaScript", "*.js")])
        if not p:
            return
        try:
            with open(p, "w", encoding="utf-8") as f:
                f.write(self.code.get("1.0", "end-1c"))
            self._log_line("已保存 %s" % os.path.basename(p))
        except Exception as e:
            self._log_line("保存失败：%r" % e, "err")

    def on_copy_result(self):
        txt = self.out.get("1.0", "end-1c")
        self.root.clipboard_clear()
        self.root.clipboard_append(txt)
        self._log_line("结果已复制（%d 字符）" % len(txt))

    def on_clear_log(self):
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

    def on_open_logdir(self):
        _ensure_logdir()
        try:
            os.startfile(LOG_DIR)  # noqa: 仅 Windows
        except Exception as e:
            self._log_line("打开失败：%r" % e, "err")

    def on_toggle_control(self):
        if self.server:
            try:
                self.server.stop()
            finally:
                self.server = None
            self.control_label.configure(text="AI 控制接口：已停止", fg=MUTED)
            self._ctl_btn.configure(text="启动 AI 控制接口")
            self.core.log("AI 控制接口已停止")
        else:
            self._start_control(silent=False)

    def _start_control(self, silent=True):
        try:
            self.server = RyControlServer(self.core, self.control_port,
                                          on_remote_code=self._remote_code_hook)
            self.server.start()
            addr = "http://127.0.0.1:%d" % self.control_port
            self.control_label.configure(text="AI 控制接口：%s" % addr, fg=OK)
            self._ctl_btn.configure(text="停止 AI 控制接口")
            self.core.log("AI 控制接口已启动 %s（Agent 可 POST /exec 传入代码）" % addr)
        except Exception as e:
            self.server = None
            self.control_label.configure(text="AI 控制接口：启动失败 %s" % e, fg=ERR)
            self.core.log("控制接口启动失败：%r" % e, "err")

    def _remote_code_hook(self, code, peer, host, port):
        """远端（Agent）发来代码时，让用户在界面上看到它。"""
        self.q.put(("log", {"level": "warn", "text": "收到 AI 发来的代码（%d 字节，来自 %s）" % (len(code), peer)}))
        self.q.put(("_remote_code", {"code": code}))

    # ---------------------------------------------------------- 渲染
    def _set_phase(self, text, color):
        try:
            self.phase.configure(text=text, fg=color)
        except Exception:
            pass

    def _log_line(self, text, level="info"):
        try:
            self.log.configure(state="normal")
            self.log.insert("end", "[%s] %s\n" % (time.strftime("%H:%M:%S"), text), level)
            self.log.see("end")
            self.log.configure(state="disabled")
        except Exception:
            pass

    def _out_write(self, text, tag=None):
        try:
            self.out.configure(state="normal")
            self.out.insert("end", text + "\n", tag) if tag else self.out.insert("end", text + "\n")
            self.out.see("end")
            self.out.configure(state="disabled")
        except Exception:
            pass

    def _out_clear(self):
        try:
            self.out.configure(state="normal")
            self.out.delete("1.0", "end")
            self.out.configure(state="disabled")
        except Exception:
            pass

    def _render_result(self, r):
        r = r or {}
        if r.get("elapsedMs") is not None:
            self.elapsed.configure(text="往返 %s ms" % r.get("elapsedMs"))
        st = r.get("status")
        if st != "done":
            self._set_phase("未回传", ERR)
            self._out_write("⚠ 轮询结束仍未拿到结果（status=%s）" % st, "warn")
            self._out_write(json.dumps({k: v for k, v in r.items() if k != "code"},
                                       ensure_ascii=False, indent=2), "dim")
            return
        if r.get("ok"):
            self._set_phase("已回传", OK)
            self._out_write("状态：成功   耗时：%s ms" % r.get("ms"), "ok")
        else:
            self._set_phase("已回传(报错)", ERR)
            self._out_write("状态：失败", "err")
            if r.get("error"):
                self._out_write("错误：%s" % r.get("error"), "err")
        if r.get("output"):
            self._out_write("\n---- print 输出 ----", "dim")
            self._out_write(r["output"])
        if r.get("result") is not None:
            self._out_write("\n---- 返回值 ----", "dim")
            self._out_write(str(r["result"]))


# ================================================================ 自测（不开窗口）
def selftest(host, port):
    """不创建 Tk：验证 RyCore + 控制接口。用 mock 服务端跑。"""
    print("=== RyCore 自测 target=%s:%d ===" % (host, port))
    events = []
    core = RyCore(on_event=lambda k, p: events.append((k, p)))

    r = core.ping(host, port)
    assert r.get("ok"), "ping 失败: %r" % r
    print("  ping OK  lanIP=%s running=%s" % (r.get("lanIP"), r.get("running")))

    res = core.exec_code('print("st from selftest"); return "done-selftest"')
    assert res.get("status") == "done", "exec 未 done: %r" % res
    assert res.get("ok"), "exec 报错: %r" % res
    print("  exec OK  ms=%s  output=%r  result=%r" %
          (res.get("ms"), (res.get("output") or "")[:40], res.get("result")))
    kinds = [k for k, _ in events]
    assert "submitted" in kinds and "poll" in kinds and "done" in kinds, kinds
    polls = [p for k, p in events if k == "poll"]
    print("  轮询事件 %d 次 (max=%s) 契约 OK" % (len(polls), polls[0]["max"] if polls else "?"))

    # 控制接口
    srv = RyControlServer(core, 18877)
    srv.start()
    import urllib.request
    try:
        with urllib.request.urlopen("http://127.0.0.1:18877/status", timeout=10) as f:
            st = json.loads(f.read().decode())
        assert st.get("ok") and st.get("controlPort") == 18877, st
        print("  /status OK  target=%s connected=%s" % (st["target"], st["connected"]))

        req = urllib.request.Request(
            "http://127.0.0.1:18877/exec",
            data=json.dumps({"code": 'return "via-control-api"'}).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=120) as f:
            got = json.loads(f.read().decode())
        assert got.get("status") == "done" and got.get("ok"), got
        print("  /exec OK  result=%r  (AI 接口可用)" % got.get("result"))

        with urllib.request.urlopen("http://127.0.0.1:18877/log?n=5", timeout=10) as f:
            lg = json.loads(f.read().decode())
        print("  /log OK  %d 字符" % len(lg.get("log", "")))
    finally:
        srv.stop()
    print("GUI_CORE_SELFTEST_PASSED")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="RyConsole Autorun 电脑端图形界面")
    ap.add_argument("--host", default="", help="预填 iPad IP")
    ap.add_argument("--port", type=int, default=cli.DEFAULT_PORT, help="iPad 上的监听端口")
    ap.add_argument("--control-port", type=int, default=DEFAULT_CONTROL_PORT,
                    help="本机 AI 控制接口端口（127.0.0.1）")
    ap.add_argument("--no-control", action="store_true", help="不自动启动 AI 控制接口")
    ap.add_argument("--selftest", action="store_true", help="无界面自测（需要一个 mock 服务）")
    args = ap.parse_args(argv)

    _ensure_logdir()

    if args.selftest:
        return selftest(args.host or "127.0.0.1", args.port)

    import tkinter as tk
    root = tk.Tk()
    RyGui(root, host=args.host, port=args.port, control_port=args.control_port,
          auto_control=not args.no_control)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
