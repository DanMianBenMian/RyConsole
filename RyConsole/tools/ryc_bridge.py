# -*- coding: utf-8 -*-
"""ryc_bridge.py — RyConsole 桥管理命令（给 AI / 人用；纯标准库，Windows 直接跑）

为什么有这条命令：
  桥（RyConsoleScripts/bridge_*.js）是**动态层** —— App 加载时 Documents 里的同名文件优先于包内默认。
  所以"装桥 / 改桥"根本不用重编重装 IPA，写进 Documents 即生效。本命令把这件事做成一键操作。

用法
  python ryc_bridge.py <host> [port] <命令> [参数...]

命令
  list  | ls            列出设备上的桥：Documents 覆盖 + 包内默认（含字节数与差异标记）
  versions              设备上**实际加载**的桥版本（来自各桥的 RYC_BRIDGES 自报）
  push  <file.js>...    安装/更新桥（写进 Documents，立刻生效；写完回读校验字节数）
  pushall [dir]         把本地 RyConsoleScripts/*.js 全部推上去（默认 = 本脚本上一级的 RyConsoleScripts）
  get   <name> [outdir] 把设备当前生效的桥源码拉回本地（Documents 优先，含包内默认）
  rm    <name>...       删除 Documents 覆盖 → 回落到包内默认（也是"还原"手段）
  eval  "<js>"          在设备上跑任意 JS（调试用）
  check                 总览：连通 / 桥开关 / 覆盖数 / 版本 / 崩溃日志大小

示例
  python ryc_bridge.py 192.168.10.102 list
  python ryc_bridge.py 192.168.10.102 push bridge_iokit.js
  python ryc_bridge.py 192.168.10.102 pushall
  python ryc_bridge.py 192.168.10.102 versions
  python ryc_bridge.py 192.168.10.102 get bridge_objc.js ./pulled

退出码：0 成功；1 有失败项；2 连不上设备
"""
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_HOST = '192.168.10.102'
DEFAULT_PORT = '8899'
SRC_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'RyConsoleScripts'))


def _setup_console():
    """中文 Windows 控制台是 GBK：直接打某些字符会 UnicodeEncodeError 把进程干掉（踩过）。"""
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


def ev(code, base, timeout=60, timeout_ms=30000):
    """在设备上执行一段 JS，返回 dict（含 result / output / error …）。"""
    body = json.dumps({'code': code, 'timeoutMs': timeout_ms}).encode('utf-8')
    req = urllib.request.Request(base + '/eval', data=body,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode('utf-8', 'replace'))
    except Exception as e:
        return {'_error': str(e)}


def ping(base):
    try:
        with urllib.request.urlopen(base + '/ping', timeout=6) as r:
            return json.loads(r.read().decode('utf-8', 'replace'))
    except Exception:
        return None


def res(r):
    """取 result 字段（没有就给个可读的替代）。"""
    if r is None:
        return None
    if '_error' in r:
        return r['_error']
    v = r.get('result')
    if v is None:
        v = r.get('error') or r.get('output') or ''
    return v


# --------------------------------------------------------------------------- JS 片段
JS_ENV = (
    'var out={};'
    'var ai=appInfo();'
    'var m=/exec: (\\S+)/.exec(ai);'
    'out.exec = m?m[1]:"";'
    'out.bundleDir = out.exec ? out.exec.replace(/\\/[^\\/]+$/,"") : "";'
    'function ls(p){ var s=listDir(p); return (s.indexOf("error]")>=0)?[]:s.split("\\n"); }'
    'out.docs = ls("").filter(function(n){return /\\.js$/.test(n);});'
    'out.bundle = out.bundleDir ? ls(out.bundleDir).filter(function(n){return /\\.js$/.test(n);}) : [];'
    'out.versions = (typeof RYC_BRIDGES!=="undefined") ? RYC_BRIDGES : null;'
)
JS_LIST = (JS_ENV +
    'var rows=[];'
    'var all={};'
    'out.bundle.forEach(function(n){ all[n]={src:"bundle"}; });'
    'out.docs.forEach(function(n){ all[n]={src:"docs"}; });'
    'Object.keys(all).sort().forEach(function(n){'
    '  var d=fileExists(n);'
    '  rows.push({name:n, override:d, docSize:(d?fileSize(n):0),'
    '             bundleSize:fileSize(out.bundleDir+"/"+n)});'
    '});'
    'return JSON.stringify({bundleDir:out.bundleDir, versions:out.versions, rows:rows});')


def cmd_list(base, args):
    r = ev(JS_LIST, base)
    v = res(r)
    if not isinstance(v, str) or not v.startswith('{'):
        print('  [!!] 取列表失败:', str(v)[:200])
        return 1
    d = json.loads(v)
    print('  包内目录: %s' % d['bundleDir'])
    print('  %-22s %-9s %10s %10s  %s' % ('桥', '覆盖', 'Documents', '包内默认', '状态'))
    for row in d['rows']:
        ov = '是' if row['override'] else '-'
        st = '★ 用 Documents 覆盖' if row['override'] else '用包内默认'
        if row['override'] and row['bundleSize'] > 0 and row['docSize'] != row['bundleSize']:
            st += '（与包内不同）'
        print('  %-22s %-9s %10d %10d  %s' % (row['name'], ov, row['docSize'], row['bundleSize'], st))
    vv = d.get('versions')
    print('\n  设备实际加载的桥版本:')
    if not vv:
        print('    (无 —— 桥可能没启用，或版本还没带自报字段)')
    else:
        for k in sorted(vv):
            print('    %-22s %s' % (k, vv[k]))
    return 0


def cmd_versions(base, args):
    v = res(ev('return JSON.stringify((typeof RYC_BRIDGES!=="undefined")?RYC_BRIDGES:{});', base))
    print('  ' + str(v))
    return 0


def _push_one(base, path, name=None):
    name = name or os.path.basename(path)
    if not os.path.exists(path):
        print('  [!!] 本地不存在: %s' % path)
        return False
    src = open(path, encoding='utf-8').read()
    if not name.endswith('.js'):
        name += '.js'
    # 首行注释让人在 iPad「收到的代码」里也能看出这是哪条（可选但有用）
    code = ('// [ryc_bridge] 装入 %s（%d 字符）\n'
            'var ok = writeFile(%s, %s);\n'
            'return ok + "|" + fileSize(%s);'
            % (name, len(src), json.dumps(name), json.dumps(src, ensure_ascii=False), json.dumps(name)))
    r = ev(code, base, timeout=90)
    got = str(res(r))
    want = len(src.encode('utf-8'))
    if got.startswith('ok|') and got.split('|', 1)[1].strip() == str(want):
        print('  [OK] %-22s %6d B 已写入 Documents 并回读校验通过' % (name, want))
        return True
    print('  [!!] %-22s 写入异常: %s（本地 %d B）' % (name, got[:120], want))
    return False


def cmd_push(base, args):
    if not args:
        print('  用法: push <file.js>...（相对当前目录，或绝对路径）')
        return 1
    ok = 0
    for a in args:
        if _push_one(base, a):
            ok += 1
    print('  RESULT: %d/%d' % (ok, len(args)))
    print('  （桥已热加载生效；设备的 Documents 优先于包内默认 → 不用重装 IPA）')
    return 0 if ok == len(args) else 1


def cmd_pushall(base, args):
    d = args[0] if args else SRC_DIR
    files = sorted(f for f in os.listdir(d) if f.startswith('bridge_') and f.endswith('.js'))
    if not files:
        print('  [!!] 目录里没有 bridge_*.js: %s' % d)
        return 1
    print('  源目录: %s' % d)
    ok = 0
    for f in files:
        if _push_one(base, os.path.join(d, f)):
            ok += 1
    print('  RESULT: %d/%d' % (ok, len(files)))
    return 0 if ok == len(files) else 1


def cmd_get(base, args):
    if not args:
        print('  用法: get <name.js> [outdir]')
        return 1
    name = args[0] if args[0].endswith('.js') else args[0] + '.js'
    outdir = args[1] if len(args) > 1 else '.'
    code = (JS_ENV +
            'var n=%s;'
            'var p = fileExists(n) ? n : (out.bundleDir + "/" + n);'
            'var s = readFile(p);'
            'return JSON.stringify({path:p, override:fileExists(n), src:s});' % json.dumps(name))
    v = res(ev(code, base))
    try:
        d = json.loads(v)
    except Exception:
        print('  [!!] 拉取失败:', str(v)[:200])
        return 1
    src = d.get('src', '')
    if not src or src.startswith('[readFile error]'):
        print('  [!!] 读取失败: %s' % src[:160])
        return 1
    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, name)
    open(out, 'w', encoding='utf-8', newline='\n').write(src)
    print('  [OK] %-22s ← %s  (%d 字符, %s)' % (name, d.get('path'),
          len(src), 'Documents 覆盖' if d.get('override') else '包内默认'))
    print('       已存到: %s' % os.path.abspath(out))
    return 0


def cmd_rm(base, args):
    if not args:
        print('  用法: rm <name.js>...（删掉 Documents 覆盖，回落包内默认）')
        return 1
    ok = 0
    for a in args:
        name = a if a.endswith('.js') else a + '.js'
        got = str(res(ev('return fileDelete(%s);' % json.dumps(name), base)))
        print('  %s %-22s %s' % ('[OK]' if got == 'ok' else '[!!]', name, got))
        if got == 'ok':
            ok += 1
    print('  RESULT: %d/%d（删除后该桥回落到包内默认）' % (ok, len(args)))
    return 0 if ok == len(args) else 1


def cmd_eval(base, args):
    if not args:
        print('  用法: eval "<js>"')
        return 1
    r = ev(args[0], base)
    print('  result: %s' % str(r.get('result'))[:2000])
    if r.get('output'):
        print('  output:\n%s' % str(r['output'])[:2000])
    if r.get('error'):
        print('  error : %s' % str(r['error'])[:1000])
    return 0


def cmd_check(base, args):
    p = ping(base)
    if not p:
        print('  [!!] 连不上 %s —— 先在设备上打开 RyConsole 并点「启动监听」' % base)
        return 2
    print('  连通 : OK  pid=%s session=%s hits=%s' % (p.get('pid'), p.get('session'), p.get('hits')))
    print('  服务 : %s v%s  端口 %s  在监听=%s' % (p.get('name'), p.get('version'),
                                                 p.get('port'), p.get('running')))
    v = res(ev(JS_ENV + 'return JSON.stringify({bundleDir:out.bundleDir,'
               'docs:out.docs.length, bundle:out.bundle.length, versions:out.versions,'
               'crash:fileSize("ryconsole_crash.log"),'
               'bridgesOn:true});', base))
    try:
        d = json.loads(v)
        print('  桥    : 包内 %d 个 / Documents 覆盖 %d 个' % (d['bundle'], d['docs']))
        vv = d.get('versions') or {}
        print('  版本  : %s' % (', '.join('%s=%s' % (k.replace('bridge_', ''), v) for k, v in sorted(vv.items())) or '(无自报)'))
        print('  崩溃日志: %s 字节%s' % (d.get('crash'), '  ← 取它：readFile("ryconsole_crash.log")' if (d.get('crash') or 0) > 0 else ''))
    except Exception:
        print('  桥    : 查询失败: %s' % str(v)[:200])
    return 0


COMMANDS = {
    'list': cmd_list, 'ls': cmd_list, 'versions': cmd_versions,
    'push': cmd_push, 'pushall': cmd_pushall, 'get': cmd_get,
    'rm': cmd_rm, 'del': cmd_rm, 'eval': cmd_eval, 'check': cmd_check,
}


def main():
    _setup_console()
    argv = sys.argv[1:]
    if not argv or argv[0] in ('-h', '--help', 'help'):
        print(__doc__)
        return 0
    host = argv.pop(0)
    port = DEFAULT_PORT
    if argv and argv[0].isdigit():
        port = argv.pop(0)
    if not argv:
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    fn = COMMANDS.get(cmd)
    if not fn:
        print('  未知命令: %s\n  可用: %s' % (cmd, ', '.join(sorted(set(COMMANDS)))))
        return 1
    base = 'http://%s:%s' % (host, port)
    if cmd != 'check' and not ping(base):
        print('  [!!] 连不上 %s —— 先在设备上打开 RyConsole 并点「启动监听」' % base)
        return 2
    print('== ryc_bridge %s @ %s ==' % (cmd, base))
    return fn(base, rest)


if __name__ == '__main__':
    sys.exit(main())
