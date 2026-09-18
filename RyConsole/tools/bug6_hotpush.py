# -*- coding: utf-8 -*-
"""Bug6 修复的验证脚本（可在设备上直接跑，不用重装 IPA 就能验 JS 那一半）。

分两类检查：
  [JS 侧]  桥层修复 —— 热推 JS 后立刻生效（krWhy / primHelp / iokitMapTry / machScan / symResolve）
  [原生侧] main.m 修复 —— 只有装了 V2.2.4 IPA 才有新行为（iokitMap 句柄体检 / sysctlGet / iosurfaceCreate / iokitCall inputs）

用法: python bug6_hotpush.py [host] [port] [--no-push]
      --no-push  只验证，不推 JS
"""
import json
import os
import subprocess
import sys

HOST = '192.168.10.102'
PORT = '8899'
files = []
do_push = True
for a in sys.argv[1:]:
    if a == '--no-push':
        do_push = False
    elif a.isdigit():
        PORT = a
    elif '.' in a and not a.endswith('.js'):
        HOST = a
    else:
        files.append(a)

SRC_DIR = r'C:/Users/单面本面/WorkBuddy/2026-07-22-11-14-51/ryconsole_src/RyConsole/RyConsoleScripts'
if not files:
    files = ['bridge_guard.js', 'bridge_iokit.js', 'bridge_xpc.js', 'bridge_help.js']
BASE = 'http://%s:%s' % (HOST, PORT)


def ev(code, timeout=60):
    body = json.dumps({'code': code, 'timeoutMs': 30000})
    p = subprocess.run(['curl', '-s', '--max-time', str(timeout), '-X', 'POST',
                        '-H', 'Content-Type: application/json',
                        '--data-binary', '@-', BASE + '/eval'],
                       input=body.encode(), capture_output=True)
    try:
        return json.loads(p.stdout.decode('utf-8', 'replace'))
    except Exception:
        return {'_raw': p.stdout.decode('utf-8', 'replace')[:300]}


def alive():
    p = subprocess.run(['curl', '-s', '--max-time', '6', BASE + '/ping'], capture_output=True)
    return b'"ok"' in p.stdout and b'true' in p.stdout


if not alive():
    print('App 不可达（先在 iPad 上打开 RyConsole 并点「启动监听」）')
    sys.exit(2)

ping = ev('return autorunStatus();')
print('设备在线。会话: %s\n' % str(ping.get('result'))[:150])

if do_push:
    print('== 热推 JS 桥（Documents 优先，无需重装 IPA）==')
    for f in files:
        src = open(os.path.join(SRC_DIR, f), encoding='utf-8').read()
        lit = json.dumps(src, ensure_ascii=False)
        # 首行注释：人在 iPad「收到的代码」里能一眼看出这条在干嘛（否则只看到一大坨 writeFile）
        r = ev('// [热推 %d/%d] %s（%d 字符）\nvar ok = writeFile(%s, %s); print("wrote %s " + ok); return ok;'
               % (files.index(f) + 1, len(files), f, len(src), json.dumps(f), lit, f))
        print('  %-18s -> %s' % (f, str(r.get('result') or r)[:70]))
        if not alive():
            print('  ✗ 推送过程中 App 失去响应'); sys.exit(1)
    print()

# ---- 检查项：(名字, 代码, 期望, 属于哪一侧) ----
CHECKS = [
    ('krWhy 码表', 'return krWhy(-536870206);',
     'kIOReturnBadArgument', 'JS'),
    ('krWhy 哨兵', 'return krWhy(-3);',
     'EMPTY_CLASS', 'JS'),
    ('primHelp 过滤', 'return primHelp("iokitMap").split("\\n")[0];',
     'primHelp', 'JS'),
    ('primErrors', 'return primErrors().split("\\n")[0];',
     '错误约定', 'JS'),
    ('primMissing', 'return primMissing().split("\\n")[0];',
     '裸码风格', 'JS'),
    ('machKrWhy', 'return machKrWhy(1102);',
     'BOOTSTRAP_UNKNOWN_SERVICE', 'JS'),
    ('iokitMapTry 参数校验', 'return JSON.stringify(iokitMapTry(0));',
     'iokitMapTry error', 'JS'),
    ('machScan 参数校验', 'return JSON.stringify(machScan([])).slice(0,60);',
     'machScan error', 'JS'),
    ('symResolve 参数校验', 'return JSON.stringify(symResolve("rel/Foo", ["x"])).slice(0,60);',
     'symResolve error', 'JS'),
    # ---- 以下需要 V2.2.4 原生 ----
    ('iokitMap 句柄体检(原生)', 'return JSON.stringify(iokitMap(0,0));',
     'iokitMap error', '原生'),
    ('sysctlGet 名字校验(原生)', 'return sysctlGet("");',
     'sysctlGet error', '原生'),
    ('sysctlGet 未知名(原生)', 'return sysctlGet("no.such.ctl");',
     'sysctlGet error', '原生'),
    ('iosurfaceCreate 参数(原生)', 'return String(iosurfaceCreate("x"));',
     'iosurfaceCreate error', '原生'),
    ('iokitCall inputs 校验(原生)', 'return JSON.stringify(iokitCall(0, 0, []));',
     'iokitCall error', '原生'),
    # ---- 参数守卫（bridge_guard，纯 JS 覆盖原生全局；解决"传入类型错 → JSC 英文 TypeError"）----
    ('守卫: 已装载', 'return String(iosurfaceCreate.__ryGuarded === true);',
     'true', '守卫'),
    ('守卫: 字符串当 props', 'return String(iosurfaceCreate("x"));',
     'iosurfaceCreate error', '守卫'),
    ('守卫: 字符串当 conn', 'return String(iokitMap("1", 0));',
     'iokitMap error', '守卫'),
    ('守卫: 缺参点名', 'return String(memRead("0x1000"));',
     'len is required', '守卫'),
    ('守卫: 数组混非数字', 'return String(iokitCall(7, 0, [1, "x"]));',
     'array of numbers', '守卫'),
    ('守卫: 放行给原生', 'return String(iokitCall(7, 0, []).error || "(无)").slice(0, 40);',
     'iokitCall error', '守卫'),
]

SEEN = {'JS': 0, '原生': 0, '守卫': 0}
PASSED = {'JS': 0, '原生': 0, '守卫': 0}
print('== Bug6 行为回归 ==')
for idx, (name, code, expect, side) in enumerate(CHECKS):
    # 每条探针首行写注释：iPad「收到的代码」里能直接看出这是什么（人能看懂，别只给机器看）
    code = '// [%d/%d][%s] %s\n%s' % (idx + 1, len(CHECKS), side, name, code)
    r = ev(code)
    got = r.get('result')
    got = '' if got is None else str(got)
    passed = (expect in got)
    SEEN[side] += 1
    if passed:
        PASSED[side] += 1
    tag = '✅' if passed else ('⏳' if side == '原生' else '❌')
    print('  %s [%s] %-26s %s' % (tag, side, name, got[:110].replace('\n', ' ')))
    if not alive():
        print('  ★ %s 把 App 弄崩了 —— 立刻停手' % name)
        sys.exit(1)

print('')
for k in ('JS', '原生', '守卫'):
    extra = '（⏳ = 需要装 V2.2.4 IPA 才会变；JS 热推改变不了原生行为）' if k == '原生' else ''
    print('%s 侧: %d/%d 通过 %s' % (k, PASSED[k], SEEN[k], extra))
