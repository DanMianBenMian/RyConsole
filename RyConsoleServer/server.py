#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RyConsole Server — PC 端配套程序
================================
让不在同一局域网的 iPad（RyConsole App「远程连接」）连回这台电脑。

两种模式：
  tunnel  内置 cloudflared 隧道（零注册/零实名，推荐外出场景）
  listen  本机直接监听（同局域网 / IPv6 公网直通时用）

协议（JSON over WebSocket）：
  设备端  /ws/device   auth{token} → hello{name}
                       收 push_js{id,code} → 回 result{id,ok,output} / log{text}
  控制台  /ws/console  auth{token} → welcome{devices}
                       发 run{code,target} ；收 devices/result/log/tunnel
CLI:
  python server.py serve [--port N] [--tunnel] [--headless] [--no-firewall]
  python server.py token            # 重新生成口令
  python server.py where-cloudflared
"""
import argparse
import asyncio
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import uuid

from aiohttp import web, WSMsgType

APP_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(APP_DIR, "config.json")
CLOUDFLARED_CANDIDATES = [
    r"C:\Program Files (x86)\cloudflared\cloudflared.exe",
    r"C:\Program Files\cloudflared\cloudflared.exe",
]


# ---------------------------------------------------------------- config
def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_config(cfg):
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def get_token():
    cfg = load_config()
    tok = cfg.get("token")
    if not tok:
        tok = secrets.token_hex(16)
        cfg["token"] = tok
        save_config(cfg)
    return tok


def regen_token():
    cfg = load_config()
    cfg["token"] = secrets.token_hex(16)
    save_config(cfg)
    return cfg["token"]


def find_cloudflared():
    p = shutil.which("cloudflared")
    if p:
        return p
    for c in CLOUDFLARED_CANDIDATES:
        if os.path.exists(c):
            return c
    return None


# ---------------------------------------------------------------- core
class RyServer:
    def __init__(self, port=8765, token=None, on_event=None):
        self.port = port
        self.token = token or get_token()
        self.on_event = on_event or (lambda kind, text: None)
        self.devices = {}      # device_id -> dict(ws, name, addr)
        self.consoles = {}     # console_id -> ws
        self.runner = None
        self.site = None
        self.stop_event = asyncio.Event()
        self.tunnel_proc = None
        self.tunnel_url = None

    # ---------- helpers
    async def _broadcast_consoles(self, msg: dict):
        dead = []
        for cid, ws in list(self.consoles.items()):
            try:
                await ws.send_json(msg)
            except Exception:
                dead.append(cid)
        for cid in dead:
            self.consoles.pop(cid, None)

    async def _devices_snapshot(self):
        return [{"id": d, "name": v["name"]} for d, v in self.devices.items()]

    async def _push_devices_list(self):
        await self._broadcast_consoles({"type": "devices", "list": await self._devices_snapshot()})

    def log(self, text):
        line = f"[{time.strftime('%H:%M:%S')}] {text}"
        self.on_event("log", line)

    # ---------- auth helper
    def _check_auth(self, raw) -> bool:
        try:
            m = json.loads(raw)
            return m.get("type") == "auth" and secrets.compare_digest(
                str(m.get("token", "")), self.token)
        except Exception:
            return False

    # ---------- device WS
    async def handle_device(self, request):
        ws = web.WebSocketResponse(heartbeat=25)
        await ws.prepare(request)
        first = await ws.receive(timeout=15)
        if first.type != WSMsgType.TEXT or not self._check_auth(first.data):
            await ws.send_json({"type": "error", "text": "unauthorized"})
            await ws.close()
            return ws
        dev_id = uuid.uuid4().hex[:12]
        self.devices[dev_id] = {"ws": ws, "name": "device", "addr": request.remote}
        self.log(f"device connected {dev_id} from {request.remote}")
        await ws.send_json({"type": "welcome", "id": dev_id})
        await self._push_devices_list()
        try:
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    try:
                        m = json.loads(msg.data)
                    except Exception:
                        continue
                    t = m.get("type")
                    if t in ("result", "log"):
                        m["from"] = dev_id
                        await self._broadcast_consoles(m)
                        if t == "log":
                            self.log(f"[{self.devices[dev_id]['name']}] {m.get('text','')}")
                    elif t == "hello":
                        self.devices[dev_id]["name"] = str(m.get("name", "device"))[:64]
                        await self._push_devices_list()
                    elif t == "pong":
                        pass
                elif msg.type == WSMsgType.ERROR:
                    break
        finally:
            self.devices.pop(dev_id, None)
            self.log(f"device disconnected {dev_id}")
            await self._push_devices_list()
        return ws

    # ---------- console WS
    async def handle_console(self, request):
        ws = web.WebSocketResponse(heartbeat=25)
        await ws.prepare(request)
        first = await ws.receive(timeout=15)
        if first.type != WSMsgType.TEXT or not self._check_auth(first.data):
            await ws.send_json({"type": "error", "text": "unauthorized"})
            await ws.close()
            return ws
        cid = uuid.uuid4().hex[:12]
        self.consoles[cid] = ws
        self.log(f"console connected {cid}")
        await ws.send_json({"type": "welcome", "you": cid,
                            "list": await self._devices_snapshot(),
                            "tunnel": self.tunnel_url})
        try:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                try:
                    m = json.loads(msg.data)
                except Exception:
                    continue
                if m.get("type") == "run":
                    code = str(m.get("code", ""))
                    target = m.get("target", "all")
                    push = {"type": "push_js", "id": uuid.uuid4().hex[:8], "code": code}
                    targets = list(self.devices.items()) if target == "all" else [
                        (d, v) for d, v in self.devices.items() if d == target]
                    if not targets:
                        await ws.send_json({"type": "error", "text": "no device online"})
                        continue
                    self.log(f"push_js -> {len(targets)} device(s), {len(code)} chars")
                    for d, v in targets:
                        try:
                            await v["ws"].send_json(push)
                        except Exception:
                            self.devices.pop(d, None)
                elif m.get("type") == "list":
                    await ws.send_json({"type": "devices", "list": await self._devices_snapshot()})
        finally:
            self.consoles.pop(cid, None)
            self.log(f"console disconnected {cid}")
        return ws

    # ---------- routes
    async def handle_index(self, request):
        return web.Response(text=CONSOLE_HTML, content_type="text/html", charset="utf-8")

    async def handle_ping(self, request):
        return web.json_response({"ok": True, "ts": time.time()})

    # ---------- tunnel
    def start_tunnel(self):
        cf = find_cloudflared()
        if not cf:
            self.on_event("tunnel_error",
                          "cloudflared not found (winget install Cloudflare.cloudflared)")
            return None
        cmd = [cf, "tunnel", "--url", f"http://127.0.0.1:{self.port}", "--no-autoupdate"]
        self.log("starting cloudflared tunnel ...")
        self.tunnel_proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace")
        import threading
        threading.Thread(target=self._tunnel_reader, daemon=True).start()
        return self.tunnel_proc

    def _tunnel_reader(self):
        pat = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
        for line in self.tunnel_proc.stdout:
            m = pat.search(line)
            if m and not self.tunnel_url:
                self.tunnel_url = m.group(0)
                self.log(f"tunnel ready: {self.tunnel_url}")
                self.on_event("tunnel", self.tunnel_url)

    def stop_tunnel(self):
        if self.tunnel_proc:
            self.tunnel_proc.terminate()
            self.tunnel_proc = None
        self.tunnel_url = None

    def add_firewall_rule(self):
        rule = f"RyConsoleServer-{self.port}"
        try:
            subprocess.run(["netsh", "advfirewall", "firewall", "delete", "rule", f"name={rule}"],
                           capture_output=True)
            r = subprocess.run(["netsh", "advfirewall", "firewall", "add", "rule", f"name={rule}",
                                "dir=in", "action=allow", "protocol=TCP",
                                f"localport={self.port}"], capture_output=True, text=True)
            ok = (r.returncode == 0)
            self.log("firewall rule added" if ok else
                     "firewall rule FAILED (need admin?); allow port manually if LAN test fails")
            return ok
        except Exception as e:
            self.log(f"firewall error: {e}")
            return False

    # ---------- lifecycle
    async def run_async(self):
        app = web.Application()
        app.router.add_get("/", self.handle_index)
        app.router.add_get("/ping", self.handle_ping)
        app.router.add_get("/ws/device", self.handle_device)
        app.router.add_get("/ws/console", self.handle_console)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        self.site = web.TCPSite(self.runner, "0.0.0.0", self.port)
        await self.site.start()
        self.log(f"RyConsole Server listening on 0.0.0.0:{self.port}")
        self.log(f"token: {self.token[:4]}...{self.token[-4:]} (full in config.json / GUI)")
        self.on_event("started", f"http://127.0.0.1:{self.port}")
        await self.stop_event.wait()
        self.stop_tunnel()
        await self.runner.cleanup()
        self.log("server stopped")

    def request_stop(self):
        self.stop_event.set()


CONSOLE_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RyConsole Server</title>
<style>
:root{--bg:#0a0e14;--panel:#111823;--panel2:#0e1520;--line:#1e2a3a;
--txt:#d7e2ee;--dim:#7d8fa3;--acc:#3ddc84;--warn:#ffb454;--bad:#ff5f56;--blue:#59a7ff;}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:"Segoe UI","Microsoft YaHei",monospace,sans-serif;padding:24px 14px 60px}
.wrap{max-width:900px;margin:0 auto}
h1{font-size:20px}.g{color:var(--acc)}
.sub{color:var(--dim);font-size:12px;margin:6px 0 18px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:14px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
input,textarea,select{background:var(--panel2);border:1px solid var(--line);border-radius:8px;
color:var(--txt);padding:9px 12px;font-size:14px;font-family:inherit;outline:none}
input:focus,textarea:focus{border-color:var(--acc)}
button{background:var(--acc);color:#04140b;border:0;border-radius:8px;padding:10px 18px;
font-weight:700;font-size:14px;cursor:pointer}
button.gray{background:var(--panel2);color:var(--txt);border:1px solid var(--line)}
button.bad{background:var(--bad);color:#fff}
#devices{font-size:13px;color:var(--dim)}#devices b{color:var(--acc)}
textarea{width:100%;min-height:150px;resize:vertical;font-family:Consolas,monospace;font-size:13px;line-height:1.5}
#out{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:12px;
min-height:120px;max-height:340px;overflow:auto;white-space:pre-wrap;font-family:Consolas,monospace;
font-size:12.5px;line-height:1.55;margin-top:10px}
.pill{font-size:11px;padding:2px 9px;border-radius:10px;background:var(--panel2);border:1px solid var(--line)}
.on{color:var(--acc)}.off{color:var(--dim)}
.hint{color:var(--dim);font-size:12px;margin-top:8px;line-height:1.6}
</style></head><body><div class="wrap">
<h1>RyConsole <span class="g">Server</span> 控制台</h1>
<div class="sub">iPad 端 RyConsole App「远程连接」连入后即可远程推送 JS · 假期愉快 awa</div>

<div class="card">
  <div class="row">
    <input id="tok" placeholder="访问口令 token" size="28">
    <button id="btnConn">连接</button>
    <span class="pill" id="st">未连接</span>
    <span class="pill" id="tun">tunnel: -</span>
  </div>
  <div class="hint" id="devices">在线设备：<b class="off">无</b></div>
</div>

<div class="card">
  <div class="row" style="margin-bottom:8px">
    <select id="target"><option value="all">全部设备</option></select>
    <button id="btnRun">▶ 运行 JS</button>
    <button class="gray" id="btnClear">清空输出</button>
  </div>
  <textarea id="code" spellcheck="false">// 在这写要推给 RyConsole 执行的 JS
return {hello: "world", ts: Date.now()};</textarea>
  <div id="out">输出会显示在这里。</div>
  <div class="hint">推送的是 JS 源码，设备端经 JSContext 执行；返回值/打印流式回传。</div>
</div>
</div>
<script>
let ws=null, sel=null;
const $=id=>document.getElementById(id);
function log(t){const o=$("out");o.textContent+=t+"\n";o.scrollTop=o.scrollHeight;}
function setDevices(list){
  const d=$("devices"); sel=$("target"); sel.innerHTML="";
  if(!list.length){d.innerHTML='在线设备：<b class="off">无</b>';sel.innerHTML='<option value="all">全部设备</option>';return;}
  d.innerHTML="在线设备："+list.map(x=>`<b>${x.name}</b>`).join("、");
  for(const x of list){const o=document.createElement("option");o.value=x.id;o.textContent=x.name;sel.appendChild(o);}
}
function connect(){
  const tok=$("tok").value.trim(); if(!tok){alert("先填 token");return;}
  const proto=location.protocol==="https:"?"wss":"ws";
  ws=new WebSocket(proto+"://"+location.host+"/ws/console");
  ws.onopen=()=>{$("st").textContent="已连接";$("st").className="pill on";};
  ws.onclose=()=>{$("st").textContent="已断开";$("st").className="pill off";};
  ws.onmessage=e=>{const m=JSON.parse(e.data);
    if(m.type==="welcome"){ws.send(JSON.stringify({type:"auth",token:tok}));}
    else if(m.type==="ok"){$("st").textContent="已认证";$("st").className="pill on";setDevices(m.list||[]);
      if(m.tunnel)$("tun").textContent="tunnel: "+m.tunnel;}
    else if(m.type==="devices")setDevices(m.list);
    else if(m.type==="result")log("── "+(m.from||"dev")+(m.ok?" ✓":" ✗")+" ──\n"+(m.output||"(空)"));
    else if(m.type==="log")log("["+m.from+"] "+m.text);
    else if(m.type==="error"){alert(m.text);ws.close();}
  };
}
$("btnConn").onclick=connect;
$("btnRun").onclick=()=>{if(!ws||ws.readyState!==1){alert("先连接");return;}
  ws.send(JSON.stringify({type:"run",code:$("code").value,target:$("target").value}));};
$("btnClear").onclick=()=>{$("out").textContent="";};
</script></body></html>"""


# ---------------------------------------------------------------- CLI
def cli_serve(args):
    token = get_token()
    srv = RyServer(port=args.port, token=token)

    def on_event(kind, text):
        if kind == "log":
            print(text, flush=True)
        elif kind == "tunnel":
            print(f"\n★ 公网地址: {text}", flush=True)
            print("  iPad RyConsole「远程连接」填上面地址 + token 即可", flush=True)
        elif kind == "tunnel_error":
            print(f"!! tunnel: {text}", flush=True)

    srv.on_event = on_event  # headless CLI 也要接事件（否则 tunnel URL 无人打印）

    if not args.headless:
        try:
            import gui
            gui.launch(srv)
            return
        except Exception as e:
            print(f"GUI launch failed ({e}); fallback to CLI mode")
    if args.tunnel:
        srv.start_tunnel()
    if args.firewall and not args.tunnel:
        srv.add_firewall_rule()
    try:
        asyncio.run(srv.run_async())
    except KeyboardInterrupt:
        srv.request_stop()


def main():
    ap = argparse.ArgumentParser(description="RyConsole Server")
    sub = ap.add_subparsers(dest="cmd")
    sp = sub.add_parser("serve")
    sp.add_argument("--port", type=int, default=8765)
    sp.add_argument("--tunnel", action="store_true", help="spawn cloudflared quick tunnel")
    sp.add_argument("--headless", action="store_true", help="no GUI")
    sp.add_argument("--no-firewall", dest="firewall", action="store_false")
    sub.add_parser("token")
    sub.add_parser("where-cloudflared")
    args = ap.parse_args()
    if args.cmd == "token":
        print("new token:", regen_token())
    elif args.cmd == "where-cloudflared":
        print(find_cloudflared() or "not found")
    else:
        cli_serve(args)


if __name__ == "__main__":
    main()
