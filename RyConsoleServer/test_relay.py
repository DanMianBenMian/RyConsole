#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地闭环测试：模拟设备 + 模拟控制台，验证 push_js→result 中继。
用法: python -u test_relay.py   （服务端须已在 8765 运行）"""
import asyncio
import json
import re
import sys
import os

import aiohttp

BASE = "http://127.0.0.1:8765"
TOKEN = re.search(r'"token":\s*"([^"]+)"',
                  open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "config.json"), encoding="utf-8").read()).group(1)


async def device(ready):
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect(BASE + "/ws/device") as ws:
            await ws.send_json({"type": "auth", "token": TOKEN})
            w = json.loads((await ws.receive()).data)
            assert w["type"] == "welcome", w
            await ws.send_json({"type": "hello", "name": "RyConsole 2.4.24 (fake)"})
            print("[device] authed + hello", flush=True)
            ready.set()
            async for m in ws:
                d = json.loads(m.data)
                if d.get("type") == "push_js":
                    print(f"[device] push_js id={d['id']} code={d['code'][:40]!r}", flush=True)
                    await ws.send_json({"type": "log", "text": "executing..."})
                    await ws.send_json({"type": "result", "id": d["id"], "ok": True,
                                        "output": "FAKE-RESULT<" + d["code"][-20:] + ">"})


async def console(ready):
    await ready.wait()
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect(BASE + "/ws/console") as ws:
            await ws.send_json({"type": "auth", "token": TOKEN})
            d = {}
            for _ in range(30):
                d = json.loads((await asyncio.wait_for(ws.receive(), 10)).data)
                if d.get("type") in ("welcome", "devices") and d.get("list"):
                    break
            print("[console] devices:", [x["name"] for x in d.get("list", [])], flush=True)
            await ws.send_json({"type": "run", "code": "return 6*7;", "target": "all"})
            t0 = asyncio.get_event_loop().time()
            while asyncio.get_event_loop().time() - t0 < 20:
                d = json.loads((await asyncio.wait_for(ws.receive(), 20)).data)
                if d.get("type") == "log":
                    print("[console][log]", d.get("text"), flush=True)
                elif d.get("type") == "result":
                    print("[console] RESULT ok=%s output=%r" % (d["ok"], d["output"]), flush=True)
                    if "FAKE-RESULT<return 6*7;>" in d["output"]:
                        print("=== RELAY TEST PASS ===", flush=True)
                        return
                    sys.exit(2)
                elif d.get("type") == "error":
                    print("[console][error]", d, flush=True); sys.exit(1)
            print("TIMEOUT waiting result", flush=True); sys.exit(3)


async def main():
    ready = asyncio.Event()
    dev = asyncio.create_task(device(ready))
    con = asyncio.create_task(console(ready))
    done, pending = await asyncio.wait({dev, con}, timeout=30, return_when=asyncio.FIRST_EXCEPTION)
    for t in pending:
        t.cancel()
    for t in done:
        if t.exception():
            raise t.exception()
    if any(t.done() and not t.exception() for t in done):
        print("TEST DONE", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
