// _probe_uaf_read.js v1 — objc_msgSend 悬垂（UAF）零崩溃回归判据
//
// 背景（Ry-JB 在帖 #20 comment 30 给出的铁证 + 判据，原文照抄其结论）：
//   ★ JavaScriptCore 在**每次 native block 返回时** drain 本次调用期间的 autorelease pool。
//     所以「把上一次 objc_msgSend 的返回值当接收者」必然是 use-after-free：
//     allocator 物理上不可能把同一块内存同时发给两个活着的对象。
//   ★ 已释放对象的内存**仍然可读**（kalloc 元数据在用户指针之前的 header 里，
//     释放时不覆写用户数据），所以 vm_read 可读性门禁**拦不住**它 ——
//     它不是野指针，是**已死对象**。
//
// 判据（比「跑一遍会不会崩」可靠，且不产生任何崩溃）：
//   未修复（2.4.32）：两次独立 arrayWithObject: 返回**同一个堆地址** → same_addr = true
//   已修复（2.4.33+）：A 被存活表 g_objcLiveHandles 保活 → allocator 拿不到同一块
//                     → same_addr = false
//
// 用法：
//   python ryc_autorun.py run --host <ip> --code-file _probe_uaf_read.js
//   或直接在 RyConsole 的控制台/Autorun 里整段粘贴执行。
//
// 输出：JSON（见文末 schema）。判定：same_addr === false ⇒ UAF 已修复。

// ---------- 0. 原语存在性自检 ----------
function has(name) {
    try { return typeof eval(name) !== 'undefined'; } catch (e) { return false; }
}
var need = ['objc_getClass', 'objc_msgSendSafe', 'memRead'];
var missing = [];
for (var i = 0; i < need.length; i++) { if (!has(need[i])) missing.push(need[i]); }
if (missing.length) {
    return JSON.stringify({
        ok: false, error: 'missing primitives', missing: missing,
        hint: '本探针需要 objc_getClass / objc_msgSendSafe / memRead 三个原语'
    }, null, 2);
}

// ---------- 1. 工具 ----------
// objc_msgSendSafe 返回 JSON 串；解析出 value（hex 指针）
function safeValue(recv, sel, args) {
    var raw = objc_msgSendSafe(recv, sel, args || []);
    var o;
    try { o = JSON.parse(raw); }
    catch (e) { return { ok: false, error: 'unparsable', raw: String(raw) }; }
    if (!o || o.ok !== true) return { ok: false, error: (o && o.error) || 'call failed', raw: o };
    return { ok: true, value: o.value };
}
// 归一化 hex → 去掉 0x 前缀的小写十六进制串，便于字符串比较
function normHex(h) {
    if (typeof h !== 'string') return null;
    var s = h.trim().toLowerCase();
    if (s.indexOf('0x') === 0) s = s.slice(2);
    return s;
}

// ---------- 2. 主探针 ----------
// 用 NSArray 的 arrayWithObject: 造一个**真堆对象**（不是 tagged pointer，不是类对象）。
// 元素用 tagged pointer（NSNumber 的小整数即 tagged ptr），保证元素本身不干扰地址对比。
var AC = objc_getClass('NSArray');
var ELEM = { hex: '0x1' };   // tagged pointer 小整数

var out = {
    ok: true,
    probe: 'uaf_read',
    version: 'v1',
    rounds: [],
    same_addr: null,
    verdict: null
};

// 一轮 = 两次独立 arrayWithObject: + 三次 isa 读取
function oneRound() {
    var r = {};
    var a = safeValue(AC, 'arrayWithObject:', [ELEM]);
    if (!a.ok) return { ok: false, stage: 'A', err: a };
    r.A = a.value;

    // 立刻读 A 的 isa（前 8 字节）
    r.isa_A1 = memRead(a.value, 8);

    // 第二次独立调用（关键：如果 A 已被释放，allocator 会把同一块发给 B）
    var b = safeValue(AC, 'arrayWithObject:', [ELEM]);
    if (!b.ok) return { ok: false, stage: 'B', err: b };
    r.B = b.value;

    // 再读 A 和 B 的 isa
    r.isa_A2 = memRead(a.value, 8);
    r.isa_B1 = memRead(b.value, 8);

    // ★ 判据
    r.same_addr = (normHex(r.A) === normHex(r.B));
    // 三个 isa 全同 ⇒ A 与 B 极可能是同一块内存（内容也相同），即同址复用
    r.isa_all_equal = (r.isa_A1 === r.isa_A2 && r.isa_A2 === r.isa_B1);
    r.ok = true;
    return r;
}

// 连做 3 轮（每轮都重新创建对象；任一轮出现同址 ⇒ UAF 依然存在）
var rounds = 3;
for (var k = 0; k < rounds; k++) {
    var r = oneRound();
    if (!r.ok) {
        out.ok = false;
        out.error = r.err && r.err.error ? r.err.error : 'round failed';
        out.stage = r.stage;
        out.rounds.push(r);
        break;
    }
    out.rounds.push(r);
}

// ---------- 3. 汇总 ----------
if (out.ok) {
    var anySame = false;
    for (var j = 0; j < out.rounds.length; j++) {
        if (out.rounds[j].same_addr) { anySame = true; break; }
    }
    out.same_addr = anySame;               // true = 仍会 UAF；false = 已修复
    out.verdict = anySame
        ? 'FAIL — A 与 B 返回同一堆地址 ⇒ 对象在 native block 返回时被释放 ⇒ UAF 仍存在'
        : 'PASS — A 与 B 地址不同 ⇒ 存活表保活生效 ⇒ 悬垂接收者已修复';
}

return JSON.stringify(out, null, 2);

/*
输出 schema：
{
  "ok": true,
  "probe": "uaf_read",
  "version": "v1",
  "rounds": [
    { "A": "0x1494a8d70", "B": "0x1494a8d70", "isa_A1": "...", "isa_A2": "...",
      "isa_B1": "...", "same_addr": true, "isa_all_equal": true, "ok": true }
  ],
  "same_addr": true,
  "verdict": "FAIL — ..."
}

期望值（2.4.33 及以后）：same_addr = false，verdict 以 "PASS" 开头。
注意：这个判据**不产生任何崩溃**，可以放心反复跑。
*/
