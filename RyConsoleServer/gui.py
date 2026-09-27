#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RyConsole Server GUI（tkinter 暗色，RyConsole 风格）"""
import queue
import threading
import tkinter as tk
import webbrowser
from tkinter import ttk

import server as core

BG, PANEL, PANEL2 = "#0a0e14", "#111823", "#0e1520"
LINE, TXT, DIM = "#1e2a3a", "#d7e2ee", "#7d8fa3"
ACC, WARN, BAD = "#3ddc84", "#ffb454", "#ff5f56"
MONO = ("Consolas", 10)


def launch(srv):
    App(srv).run()


class App:
    def __init__(self, srv):
        self.srv = srv
        self.thread = None
        self.q = queue.Queue()
        self.root = tk.Tk()
        self.root.title("RyConsole Server")
        self.root.configure(bg=BG)
        self.root.geometry("620x560")
        self.root.minsize(560, 480)
        self._build()
        self.root.after(120, self._poll)

    # ---------- widgets
    def _card(self, title):
        f = tk.Frame(self.root, bg=PANEL, highlightbackground=LINE,
                     highlightthickness=1, padx=14, pady=12)
        f.pack(fill="x", padx=14, pady=6)
        tk.Label(f, text=title, bg=PANEL, fg=DIM, font=(MONO[0], 9)).pack(anchor="w")
        return f

    def _build(self):
        tk.Label(self.root, text="RyConsole Server", bg=BG, fg=ACC,
                 font=(MONO[0], 16, "bold")).pack(anchor="w", padx=18, pady=(14, 0))
        tk.Label(self.root, text="iPad「远程连接」配套主机端 · 单面本面 × Ryan",
                 bg=BG, fg=DIM, font=(MONO[0], 9)).pack(anchor="w", padx=18, pady=(0, 8))

        # -- 启动控制
        c1 = self._card("启动")
        row = tk.Frame(c1, bg=PANEL); row.pack(fill="x")
        tk.Label(row, text="端口", bg=PANEL, fg=TXT, font=MONO).pack(side="left")
        self.port_var = tk.StringVar(value=str(self.srv.port))
        tk.Entry(row, textvariable=self.port_var, width=7, bg=PANEL2, fg=TXT,
                 insertbackground=TXT, relief="flat", highlightthickness=1,
                 highlightbackground=LINE, font=MONO).pack(side="left", padx=8)
        self.tunnel_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(row, text="cloudflared 隧道（外出场景）", variable=self.tunnel_var,
                        style="Dark.TCheckbutton").pack(side="left", padx=8)
        self.fw_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(row, text="防火墙规则(listen)", variable=self.fw_var,
                        style="Dark.TCheckbutton").pack(side="left", padx=8)
        row2 = tk.Frame(c1, bg=PANEL); row2.pack(fill="x", pady=(10, 0))
        self.btn_start = tk.Button(row2, text="启动", command=self.start, width=10,
                                   bg=ACC, fg="#04140b", relief="flat", font=(MONO[0], 10, "bold"))
        self.btn_start.pack(side="left")
        self.btn_stop = tk.Button(row2, text="停止", command=self.stop, width=10, state="disabled",
                                  bg=PANEL2, fg=TXT, relief="flat", font=MONO)
        self.btn_stop.pack(side="left", padx=8)
        tk.Button(row2, text="打开控制台", command=self.open_console, width=12, state="disabled",
                  bg=PANEL2, fg=TXT, relief="flat", font=MONO).pack(side="left", padx=8)
        tk.Button(row2, text="复制公网地址", command=self.copy_url, width=14, state="disabled",
                  bg=PANEL2, fg=TXT, relief="flat", font=MONO).pack(side="left", padx=8)

        # -- 状态
        c2 = self._card("状态")
        self.lbl_url = self._stat(c2, "本机地址", "-")
        self.lbl_tun = self._stat(c2, "公网地址", "-")
        self.lbl_dev = self._stat(c2, "在线设备", "0")

        # -- 口令
        c3 = self._card("访问口令（iPad 端填这个）")
        rowt = tk.Frame(c3, bg=PANEL); rowt.pack(fill="x")
        self.lbl_tok = tk.Label(rowt, text=self.srv.token, bg=PANEL, fg=ACC, font=MONO)
        self.lbl_tok.pack(side="left")
        tk.Button(rowt, text="复制", command=self.copy_token, width=6, bg=PANEL2, fg=TXT,
                  relief="flat", font=MONO).pack(side="left", padx=8)
        tk.Button(rowt, text="重新生成", command=self.regen, width=10, bg=PANEL2, fg=WARN,
                  relief="flat", font=MONO).pack(side="left")

        # -- 日志
        c4 = self._card("日志")
        self.txt = tk.Text(c4, height=12, bg=PANEL2, fg=TXT, insertbackground=TXT,
                           relief="flat", font=MONO, state="disabled")
        self.txt.pack(fill="both", expand=True)

        # dark style for ttk
        style = ttk.Style()
        style.theme_use("default")
        style.configure("Dark.TCheckbutton", background=PANEL, foreground=TXT, font=MONO)
        style.map("Dark.TCheckbutton", background=[("active", PANEL)])

    def _stat(self, parent, name, val):
        row = tk.Frame(parent, bg=PANEL); row.pack(fill="x", pady=1)
        tk.Label(row, text=name, bg=PANEL, fg=DIM, font=MONO, width=10, anchor="w").pack(side="left")
        lbl = tk.Label(row, text=val, bg=PANEL, fg=ACC, font=MONO, anchor="w")
        lbl.pack(side="left", fill="x", expand=True)
        return lbl

    # ---------- actions
    def start(self):
        try:
            self.srv.port = int(self.port_var.get())
        except ValueError:
            self._log("!! 端口必须是数字")
            return
        self.srv.on_event = self._event
        self.thread = threading.Thread(
            target=lambda: __import__("asyncio").run(self.srv.run_async()), daemon=True)
        self.thread.start()
        self.btn_start.config(state="disabled")
        self.btn_stop.config(state="normal", bg=BAD, fg="#fff")
        if self.tunnel_var.get():
            self.root.after(200, self.srv.start_tunnel)
        elif self.fw_var.get():
            self.root.after(200, self.srv.add_firewall_rule)

    def stop(self):
        self.srv.request_stop()
        self.btn_start.config(state="normal")
        self.btn_stop.config(state="disabled", bg=PANEL2, fg=TXT)

    def open_console(self):
        webbrowser.open(f"http://127.0.0.1:{self.srv.port}/")

    def copy_url(self):
        url = self.srv.tunnel_url or f"http://127.0.0.1:{self.srv.port}"
        self.root.clipboard_clear(); self.root.clipboard_append(url)
        self._log("copied: " + url)

    def copy_token(self):
        self.root.clipboard_clear(); self.root.clipboard_append(self.srv.token)
        self._log("token copied")

    def regen(self):
        self.srv.token = core.regen_token()
        self.lbl_tok.config(text=self.srv.token)
        self._log("!! token 已重新生成（旧口令立即失效）")

    # ---------- events
    def _event(self, kind, text):
        self.q.put((kind, text))

    def _log(self, line):
        self.txt.config(state="normal")
        self.txt.insert("end", line + "\n")
        self.txt.see("end")
        self.txt.config(state="disabled")

    def _poll(self):
        try:
            while True:
                kind, text = self.q.get_nowait()
                if kind == "log":
                    self._log(text)
                elif kind == "started":
                    self.lbl_url.config(text=text)
                    self.root.nametowidget(".")
                elif kind == "tunnel":
                    self.lbl_tun.config(text=text)
                elif kind == "tunnel_error":
                    self.lbl_tun.config(text=text, fg=WARN)
        except queue.Empty:
            pass
        n = len(self.srv.devices)
        self.lbl_dev.config(text=str(n))
        self.root.after(300, self._poll)

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    srv = core.RyServer()
    App(srv).run()
