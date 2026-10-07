// bridge_help.js — 原语自解释手册（Bug6 的推广形态，2026-09-18）
// 目的：把 Bug6 报告里"别的桥该照 memRead 的格式给出参数名 + 合法范围"做成可执行文档 ——
//       不用查源码、不用问人，在设备上直接敲 primHelp() 就能知道每个桥该怎么传参、错了看哪里。
//
// 用法：
//   primHelp()                → 全部桥的一行速查表（按分类）
//   primHelp("iokit")         → 名字含 iokit 的桥详表（子串匹配，不区分大小写）
//   primHelp("iokitMap")      → 单个桥完整说明（含参数范围/返回/常见错误）
//   primErrors()              → 错误约定总说明（返回值形态 / 错误串格式 / kr 怎么读）
//   primMissing()             → 还没做成自解释错误的桥（诚实清单）
var HELP_VERSION = "bridge_help v1.1 (build 2026-09-19)";
var BRIDGE_VERSION = "v1.1 (build 2026-09-19)";
if (typeof RYC_BRIDGES === "undefined") { var RYC_BRIDGES = {}; }
RYC_BRIDGES["bridge_help"] = BRIDGE_VERSION;

// err: "self" = 失败返回 "[桥名 error] 参数名 + 合法范围"（memRead 风格，自解释）
//      "code" = 返回数字/裸码，需用 krName/krWhy/machKrWhy 解码
//      "ok"   = 基本不会因参数失败
var PRIM_DOC = [
  // ---------- IOKit UserClient（V3 主战场）----------
  { cat: "IOKit", name: "iokitOpen", sig: "iokitOpen(cls, type)", err: "code",
    args: [{ n: "cls", t: "string", r: "非空；必须是 IORegistry 里真实注册的类名（可用 iokitEnum() 查）" },
           { n: "type", t: "uint32", r: "UserClient 类型，常见 0..5" }],
    ret: ">0 = io_connect_t 句柄（沙盒可达，V3 命中）",
    errs: "-2 类不存在；-3 类名为空（参数错，不是类不存在）；-536870174 = 0xe00002e2 NotPermitted（沙盒门禁）；-9999 原生抛异常；其它负值 = kr",
    hint: "拿到的 conn 是**本进程**的 Mach port name，跨执行/重启即失效" },
  { cat: "IOKit", name: "iokitCall", sig: "iokitCall(conn, sel, inputs)", err: "self",
    args: [{ n: "conn", t: "number", r: "iokitOpen() 返回的句柄，必须 >0" },
           { n: "sel", t: "uint32", r: "externalMethod selector 编号" },
           { n: "inputs", t: "number[]", r: "标量输入，最多 16 个（非数字项会被忽略并在 note 里点名）" }],
    ret: "{ret, outputs:[…], inCount, ok}   ret=0 即方法可调成功",
    errs: "conn 非法/失效 → {ok:false, error:\"[iokitCall error] conn …\"}；拿不到 struct 输入时改用 iokitCallStruct",
    hint: "ret=0xe00002c2(BadArgument) 说明 selector 存在但 check* 拒绝了这个输入形状 → 换标量个数/结构体" },
  { cat: "IOKit", name: "iokitCallStruct", sig: "iokitCallStruct(conn, sel, scalarInputs, structB64, outSize)", err: "self",
    args: [{ n: "conn", t: "number", r: ">0" }, { n: "sel", t: "uint32", r: "selector" },
           { n: "scalarInputs", t: "number[]", r: "≤16 个标量" },
           { n: "structB64", t: "string", r: "inputStruct 的 base64（可空串 = 不传结构体）" },
           { n: "outSize", t: "number", r: "输出 struct 缓冲 1..65536（传 0/超界会兜底 4096 并在 note 说明）" }],
    ret: "{ret, outputs, outStruct(base64), outStructSize, ok}",
    errs: "参数错 → {ok:false, error:\"[iokitCallStruct error] …\"}；内核要更大缓冲时（kIOReturnNoSpace 0xe00002db）会自动按回报值重试一次",
    hint: "这是打 struct/OOL 型 externalMethod 的正路（iokitCall 把 inputStruct 传 NULL）" },
  { cat: "IOKit", name: "iokitMap", sig: "iokitMap(conn, memType)", err: "self",
    args: [{ n: "conn", t: "number", r: ">0" },
           { n: "memType", t: "uint32", r: "内存类型编号，常见 0..15" }],
    ret: "{ret:0, ok:true, addr, size}",
    errs: "{ok:false, error:\"[iokitMap error] …\", hint:\"…\"}；kr=0xe00002c2 时多为该 UserClient 未实现 clientMemoryForType",
    hint: "不确定 memType 时先 iokitMapTry(conn) 扫 0..15；IOSurface 不必 map，直接 IOSurfaceGetBaseAddress" },
  { cat: "IOKit", name: "iokitMapTry", sig: "iokitMapTry(conn, types?)   [桥]", err: "self",
    args: [{ n: "conn", t: "number", r: ">0" }, { n: "types", t: "number[]", r: "可选，默认 [0..15]" }],
    ret: "{ok, tried, hits:[{memType,addr,size}], verdict, lastError}",
    errs: "参数错 → {ok:false, error:\"[iokitMapTry error] …\"}",
    hint: "诊断用：一次扫完所有 memType 并给结论；扫中会留下映射（原生未暴露 Unmap），别在循环里反复跑" },
  { cat: "IOKit", name: "iokitClose", sig: "iokitClose(conn)", err: "code",
    args: [{ n: "conn", t: "number", r: ">0" }], ret: "0 = 成功", errs: "返回 kr", hint: "探针后应归还连接，否则句柄泄漏" },
  { cat: "IOKit", name: "iokitEnum", sig: "iokitEnum()", err: "ok",
    args: [], ret: "string[]（IORegistry 全部类名，去重）", errs: "一般不会失败", hint: "攻击面地图：先看有哪些类，再挑候选 open" },
  { cat: "IOKit", name: "krName / krWhy / krHint", sig: "krWhy(kr)   [桥]", err: "ok",
    args: [{ n: "kr", t: "number", r: "有符号/无符号 kr 均可（内部按 >>>0 处理）" }],
    ret: "字符串，如 \"kIOReturnBadArgument (0xe00002c2) — 参数形状被拒…\"",
    errs: "未收录码返回 \"未收录码 <hex>\"（不会抛）", hint: "所有裸 kr 都该用这个转成人话，别再贴数字给用户" },

  // ---------- IOSurface ----------
  { cat: "IOSurface", name: "iosurfaceProbe", sig: "iosurfaceProbe()", err: "ok",
    args: [], ret: "文本报告（CREATE_OK / MAP_OK / CREATE_FAILED + 原因）", errs: "失败时文本里带 [iosurfaceProbe error]", hint: "最省事的「内核相邻面是否可用」一枪测" },
  { cat: "IOSurface", name: "iosurfaceCreate", sig: "iosurfaceCreate(props)", err: "self",
    args: [{ n: "props", t: "object", r: "★ 必须带最小集 {IOSurfaceWidth:4, IOSurfaceHeight:4, IOSurfaceBytesPerElement:4, IOSurfaceBytesPerRow:16}（实测省略/空对象都返回 NULL）" }],
    ret: ">0 = 句柄（本进程内有效）", errs: "失败返回 \"[iosurfaceCreate error] …\" 字符串（不是 -1）",
    hint: "句柄跨调用存活（原生注册表持有），用完 iosurfaceRelease" },
  { cat: "IOSurface", name: "iosurfaceGetID", sig: "iosurfaceGetID(handle)", err: "self",
    args: [{ n: "handle", t: "number", r: "iosurfaceCreate/Lookup 返回的句柄" }],
    ret: "uint32 surface id（可跨进程 lookup 的凭据）", errs: "句柄无效 → \"[iosurfaceGetID error] unknown handle N…\"" },
  { cat: "IOSurface", name: "iosurfaceSetValue / GetValue", sig: "iosurfaceSetValue(handle, key, value) / iosurfaceGetValue(handle, key)", err: "self",
    args: [{ n: "handle", t: "number", r: "有效句柄" }, { n: "key", t: "string", r: "属性名，空串按 \"k\" 处理" },
           { n: "value", t: "string", r: "base64 会被当 CFData 存，其它按 CFString" }],
    ret: "\"[set] ok\" / 属性描述；key 不存在返回 \"[get] key \\\"x\\\" 不存在（不是错误）\"", errs: "句柄无效 → \"[…] error] unknown handle N…\"" },
  { cat: "IOSurface", name: "iosurfaceRelease", sig: "iosurfaceRelease(handle)", err: "self",
    args: [{ n: "handle", t: "number", r: "有效句柄" }], ret: "\"[release] ok\"", errs: "重复 release / 未创建 → \"[iosurfaceRelease error] …\"" },
  { cat: "IOSurface", name: "iosurfaceLookup", sig: "iosurfaceLookup(cid)", err: "self",
    args: [{ n: "cid", t: "uint32", r: "本机当前活着的 surface id" }], ret: ">0 = 新句柄",
    errs: "查不到 → \"[iosurfaceLookup error] IOSurfaceLookup(N) 返回 NULL…\"" },

  { cat: "FFI", name: "callPtr", sig: "callPtr(addrHex, args?, opts?)", err: "self",
    args: [{ n: "addrHex", t: "string", r: "函数地址 0x…（dlsymAddr/symResolve 给的；会先做可读性体检）" },
           { n: "args", t: "array", r: "≤8 个：number=位槽 / string=C 字符串 / {hex}=原始指针 / {buf:n} 或 {str:..}=可写缓冲(内容按 base64 回传 out.bufN) / null=NULL" },
           { n: "opts", t: "object", r: "可选；{bufSize:n} 设 {buf:true} 未指大小时的默认（1024，上限 65536）" }],
    ret: "{ok:true, value:\"0x…\", out?:{buf0:base64}}   value=x0 按 uintptr_t 转 hex",
    errs: "[callPtr error] 地址不可读 / too many args (>8) / buf alloc failed / exception …",
    hint: "★ 红线：只支持整型·指针返回，float/struct 不适用；调用未知函数可能崩（crashGuard 会拦成 guarded:true，内核 panic 拦不住）。例：callPtr(dlsymAddr(0,'strlen').addr,['hello']) 期望 value=\"0x5\"" },

  // ---------- syscall 族（V2.4.27，bridge_syscall.js） ----------
  { cat: "FFI", name: "syscall", sig: "syscall(number, a, b, c, d, opts?)", err: "self",
    args: [{ n: "number", t: "number", r: "syscall 号；必须 0 <= number < kern.nsysent" },
           { n: "a", t: "number", r: "可选实参 a（0 是合法值，不会丢）；最多 a+b+c+d 四个" },
           { n: "b", t: "number", r: "可选" }, { n: "c", t: "number", r: "可选" }, { n: "d", t: "number", r: "可选" },
           { n: "opts", t: "object", r: "可选；{allowDead:true} 放行死亡名单（自杀式号，自负风险）" }],
    ret: "透传 syscallN：{\"ok\":true,\"value\":\"0x…\",\"ret\":-1,\"errno\":N,\"syscallNo\":M}  —— ret=-1 时看 .errno",
    errs: "号越界 → {ok:false,\"error\":\"[syscallN error] syscall 号 N 越界（nsysent=…)\"}；45=csops 默认拦截；返回串以 \"[syscall error]\" 开头 = number 不是整数",
    hint: "★ 沙盒在 syscall 号上普遍有检查点，返回 EPERM(1)/ENOSYS(38) 是**预期结果**，不是桥坏了。号别猜：syscallName(n) 速查，权威表 readFile('/usr/include/sys/syscall_sw.h')；kern.nsysent 用 sysctlGet('kern.nsysent') 看。超界号在 27B2 上 = 内核 SIGSYS 杀进程（JS 拦不住，原生层已先拦一层）" },
  { cat: "FFI", name: "syscallRaw / syscallName / serrno", sig: "syscallRaw(number, args, opts?) / syscallName(n) / serrno(e)", err: "self",
    args: [{ n: "args", t: "array", r: "syscallRaw 第二参：显式实参数组（要比糖版精确控制槽位时用）" },
           { n: "n", t: "number", r: "syscallName 的号 / serrno 的 errno 值" }],
    ret: "syscallName → \"202 = sysctl\"（未收录如实报未收录）；serrno → \"EPERM 权限不足（沙盒/AMFI 拒绝）\"",
    errs: "号/errno 没收录 → 明说未收录并给查表路径，不会编一个假名出来",
    hint: "号表只收高置信的二十来条，剩下的去设备上读 /usr/include/sys/syscall_sw.h；errno 表同理看 /usr/include/sys/errno.h" },
  { cat: "FFI", name: "sysctlSock", sig: "sysctlSock(ctl, name, bufSize?)", err: "self",
    args: [{ n: "ctl", t: "number", r: "mib[0]，如 1=CTL_KERN" },
           { n: "name", t: "number", r: "mib[1]，如 1=KERN_VERSION、9=KERN_BOOTARGS" },
           { n: "bufSize", t: "number", r: "可选，默认 512，上限 65536" }],
    ret: "{ok:true, ret, len, hex, errno}  —— hex 为输出缓冲的十六进制",
    errs: "socket(AF_SYSCTL,...) 失败 → {ok:false,\"error\":\"[sysctlSock error] …AF_SYSCTL 这条路上现代 iOS 多半已封\"}",
    hint: "⚠ 未经真机验证：AF_SYSCTL(2) 域把 sysctl 逻辑伪装成 getsockopt(117) 号进内核，目的是绕开沙盒在 SYS_sysctl(202) 号上的检查点；xnu 会把输出缓冲区**头 4 字节**当 mib[1] 读，所以先往 buf 写 mib[1]。第一次跑先看 socket 那步的 errno —— 现代 iOS 多半已经封死这条路，封了就别硬凑" },

  // ---------- Stage2 竞态 harness（V2.4.3，RACE_plan_v2 方案A） ----------
  { cat: "竞态", name: "threadSpawn", sig: "threadSpawn(fnBodyStr, nWorkers)", err: "self",
    args: [{ n: "fnBodyStr", t: "string", r: "worker 体 JS 源码（每 worker 独立 JSContext + 全套原语）" },
           { n: "nWorkers", t: "number", r: "1..8（默认 2）；起跑闸同步，全部创建完才同时开跑" }],
    ret: "{ok:true, threads:N, threadIds:[0..N-1], batch:B}",
    errs: "\"[threadSpawn error] fnBodyStr must be… / pthread_create failed at N\"",
    hint: "★ worker 内可 raceBarrier/raceSharedSet/Get/threadProgress/threadStopFlag；worker 崩溃被兜底拦下 → 该线程结果带 guarded:true（进程存活）；内核 panic 兜不住" },
  { cat: "竞态", name: "threadJoin", sig: "threadJoin(timeoutMs)", err: "self",
    args: [{ n: "timeoutMs", t: "number", r: "等待上限（默认 60000，上限 600000）" }, { n: "batchId", t: "number", r: "可选；threadSpawn 返回的批次号。不传 = 收割全部未收割批次（V2.4.9 起支持多批次）" }],
    ret: "{ok:true, batches:N, done:N, stillRunning:[{batch,thread}], results:[{batch,thread,guarded,result}]}",
    hint: "先看 guarded 再解析 result；stillRunning 非空 = 有 worker 没跑完（可再 join 或 threadStop）。worker 内 __threadId=批内序号，__threadBatch=批次号；spawn 后不 join 的批次占槽（8 槽上限）" },
  { cat: "竞态", name: "threadBatches", sig: "threadBatches()", err: "self",
    ret: "{ok:true, seq:N, batches:[{slot,used,joined,id,n,ready,done,taken}]}",
    args: [],
    errs: "无（纯只读 dump）",
    hint: "V2.4.12 调试原语：spawn 返回的 batch 在 join 侧看不到时当场对账（used=1 且 joined=0 = 活跃批次）。注意 threadJoin 正确参数序是 (timeoutMs, batchId)，别把 batch 放第一位" },
  { cat: "竞态", name: "raceBarrier", sig: "raceBarrier(n)", err: "self",
    args: [{ n: "n", t: "number", r: "参与者数 1..8（worker 体里调；全员到齐才一起放行，可多轮）" }],
    ret: "{ok:true}",
    hint: "⚠ 计数必须等于同时调用的参与者数；主线程脚本别和 worker 混调（主线程阻塞等 worker = 死锁）" },
  { cat: "竞态", name: "raceSharedSet / raceSharedGet", sig: "raceSharedSet(key, val) / raceSharedGet(key)", err: "self",
    args: [{ n: "key", t: "string", r: "槽名" }, { n: "val", t: "string|number", r: "Set：字符串/数字（其它类型降级为描述串）；null=删除" }],
    ret: "Set: {ok:true} ｜ Get: 值本身（无值 → null）",
    hint: "跨线程传对象/字符串用（worker 的 JSContext 相互独立）；64 位 handle/地址优先用 raceSlotSet/Get（无损原子槽）" },
  { cat: "竞态", name: "threadProgress / threadStop / threadStopFlag", sig: "threadProgress(obj) / threadStop() / threadStopFlag()", err: "self",
    args: [{ n: "obj", t: "object", r: "Progress：任意可 JSON 化对象（建议带 th/iter）" }],
    ret: "Progress: {ok:true}（覆盖写 Documents/race_progress.json）｜ Stop: {ok:true} ｜ Flag: 0/1",
    hint: "iters 大循环里每 N 次调 threadProgress（防内核 panic 丢数据）；循环条件用 threadStopFlag() 协作停" },
  { cat: "竞态", name: "raceSlotSet / raceSlotGet", sig: "raceSlotSet(idx, val) / raceSlotGet(idx)", err: "self",
    args: [{ n: "idx", t: "number", r: "槽号 0..15" }, { n: "val", t: "number|string", r: "number 或 \"0x…\" hex 串（64 位值必须走 hex，JS number 只保 53 位）" }],
    ret: "{ok,slot,value:\"0x…\"} ｜ Get 同形",
    hint: "★ 跨线程 handle 传递的新通道（原生 uint64 原子槽，无损）：线程 A raceSlotSet(0, conn)，线程 B raceSlotGet(0) 拿 hex 再 callPtr/{hex:} 用。threadSpawn 不清槽（跨轮累计器）" },
  { cat: "竞态", name: "raceAtomicAdd / raceAtomicCas", sig: "raceAtomicAdd(idx, delta) / raceAtomicCas(idx, expect, swap)", err: "self",
    args: [{ n: "idx", t: "number", r: "槽号 0..15" }, { n: "delta/expect/swap", t: "number|string", r: "number 或 \"0x…\" hex" }],
    ret: "Add: {ok,slot,old:\"0x…\",now:\"0x…\"} ｜ Cas: {ok,slot,swapped,old,now}",
    hint: "无锁协作：Add 原子自增（回旧值）；Cas 比较交换（swapped=true 表示已换入 swap）。抢锁/发令牌/进度统计用它，别再用 raceSharedSet 模拟" },
  { cat: "竞态", name: "raceRounds", sig: "raceRounds(fnBodyStr, nWorkers, rounds, timeoutMs)", err: "self",
    args: [{ n: "fnBodyStr", t: "string", r: "同 threadSpawn 的 worker 体（__threadId 分角色）" },
           { n: "nWorkers", t: "number", r: "1..8" }, { n: "rounds", t: "number", r: "轮数 1..100" },
           { n: "timeoutMs", t: "number", r: "每轮 join 上限（默认/上限 600000）" }],
    ret: "{ok,rounds,ran,totalGuarded,earlyStop,stopReason,rounds:[{round,done,guarded,stillRunning,results}]}",
    hint: "★ 极限压力入口：1e6+ iters + 自动多轮。槽跨轮保留可做累计器。纪律内置：超时未完 / guarded 命中 → 自动停（earlyStop+stopReason 说明原因）" },

  // ---------- 内存 / ObjC runtime ----------
  { cat: "内存", name: "memRead", sig: "memRead(hex, len)", err: "self",
    args: [{ n: "hex", t: "string", r: "地址，\"0x…\" 或纯 hex" }, { n: "len", t: "number", r: "1..65536" }],
    ret: "十六进制串", errs: "\"[memRead error] null address\" / \"len must be 1..65536\" / \"vm_read kr=N\"",
    hint: "★ 自解释错误的标杆（Bug6 就是照它推广的）" },
  { cat: "内存", name: "memWrite", sig: "memWrite(addrHex, data)", err: "self",
    ret: "{ok:true, written:N, addr:\"0x...\"}",
    args: [{ n: "addrHex", t: "string", r: "目标地址 0x…（须可写页；__TEXT 只读页返回 kr=4）" },
           { n: "data", t: "string|object", r: "hex 串（偶数长度）或 \"b64:…\" 或 {b64:\"…\"}——mach_msg 构造传二进制用 b64" }],
    errs: "\"null address\" / \"hex data 必须是偶数长度\" / \"vm_write_overwrite kr=N\"（2=未映射 4=页只读）",
    hint: "V2.4.12 新增：mach_vm_write_overwrite 实现，kr 干净报错不崩；上限 64KB 与 memRead 对称。用途：mach_msg 消息体写进缓冲区后再 callPtr" },
  { cat: "内存", name: "objc_getClass / sel_registerName", sig: "objc_getClass(name) / sel_registerName(name)", err: "ok",
    args: [{ n: "name", t: "string", r: "类名 / selector 名" }], ret: "指针串（\"0x…\"），失败 \"0x0\"" },
  { cat: "内存", name: "objc_msgSend / objc_msgSendSafe", sig: "objc_msgSend(recv, sel, args)", err: "code",
    args: [{ n: "recv", t: "指针串/对象", r: "来自 objc_getClass 或 objc_msgSend 返回" },
           { n: "sel", t: "string", r: "selector 名" }, { n: "args", t: "array", r: "≤7 个参数（超出被拒）" }],
    ret: "{\"ok\":true,\"value\":\"0x…\"}",
    errs: "**红线**：返回值必须按标量/对象区分 —— 返回整数的 selector（count/length/BOOL）会崩（ARC 把整数当对象 retain，已改 __unsafe_unretained 修复）；仍建议：只对「确定返回对象 id」的 selector 用 msgSend，标量用 objc_msgSendSafe",
    hint: "objcDesc(hex) 可把指针转成对象描述（带体检，标量不会崩）" },
  { cat: "内存", name: "objcDesc", sig: "objcDesc(hex)", err: "ok",
    args: [{ n: "hex", t: "string", r: "指针串" }], ret: "对象 description / \"(nil)\" / 标量提示串" },

  // ---------- XPC / dyld ----------
  { cat: "XPC", name: "xpcConn / xpcSendMsg / xpcClose", sig: "xpcConn(svc) → {h} / xpcSendMsg(h, msg, timeoutSec) / xpcClose(h)", err: "code",
    args: [{ n: "svc", t: "string", r: "服务名，如 com.apple.securityd（先 machScan 验证可见）" },
           { n: "msg", t: "object", r: "可 JSON 化嵌套对象" }, { n: "timeoutSec", t: "number", r: "默认 2.5；≤0 = 只发不收" }],
    ret: "连接 {h} / 回传对象", errs: "{err:\"…\"}；常见事件名见 XPC_ERR（connection-invalid / peer-terminated / timed-out）",
    hint: "一次性调用直接用 xpcCall(svc, msg, timeoutSec)" },
  { cat: "XPC", name: "machScan", sig: "machScan(svcNames)   [桥]", err: "self",
    args: [{ n: "svcNames", t: "string[]", r: "非空数组；元素须为非空服务名字符串" }],
    ret: "{服务名: {kr, port, reason?}}（保持旧形状）",
    errs: "参数错 → {error:\"[machScan error] svcNames must be a non-empty array of service-name strings…\"}；单项失败不报错，在 reason 里给 machKrWhy",
    hint: "kr=5 多为沙盒挡了 mach-lookup；kr=1102 = 服务未注册/看不见" },
  { cat: "XPC", name: "symResolve", sig: "symResolve(fwPath, symNames)   [桥]", err: "self",
    args: [{ n: "fwPath", t: "string", r: "**必须以 / 开头的绝对路径，且指向 .framework 里的可执行文件**（不是 .framework 目录）" },
           { n: "symNames", t: "string[]", r: "非空数组；符号名（C 符号带下划线前缀，C++ 是 _ZN…）" }],
    ret: "{fw, h, syms:{名:地址或说明}, notFound:[…]}",
    errs: "参数错/dlopen 失败 → {stage:\"arg\"|\"dlopen\", error:\"[symResolve error] …\"}",
    hint: "dlsym 返回 NULL 时 syms 里直接写上原因串，不再是裸 0x0" },
  { cat: "XPC", name: "dlopenFW / dlsymAddr", sig: "dlopenFW(path, mode) / dlsymAddr(handle, name)", err: "code",
    args: [{ n: "path", t: "string", r: "框架可执行文件的绝对路径" }, { n: "mode", t: "int", r: "dlopen flag，一般 0（RTLD_LAZY 见 dlfcn.h）" },
           { n: "handle", t: "number", r: "dlopenFW 返回的 h" }, { n: "name", t: "string", r: "符号名" }],
    ret: "{h}/{err} ; 地址（0 = 找不到）" },

  // ---------- 沙盒 / 钥匙串 / 进程 ----------
  { cat: "沙盒", name: "sandboxCheck", sig: "sandboxCheck(operation)", err: "code",
    args: [{ n: "operation", t: "string", r: "如 file-read-data / file-write-data / mach-lookup / process-exec / network-outbound" }],
    ret: "原始 ret（0 前后语义自行比对）", hint: "批量用 sandboxScan([…])" },
  { cat: "沙盒", name: "keychainProbe", sig: "keychainProbe(cls, service, account)", err: "code",
    args: [{ n: "cls", t: "string", r: "钥匙串类，常用 \"genp\"" }, { n: "service", t: "string", r: "服务名" },
           { n: "account", t: "string", r: "账户名（可 null）" }],
    ret: "{status}  ；-25300 = not found，0 = 存在且可读", hint: "批量用 keychainScan([…])" },
  { cat: "进程", name: "procListPids", sig: "procListPids()", err: "code",
    args: [], ret: "{err?, n}  —— 沙盒下通常 n=0（列不到别的进程，属预期）" },
  { cat: "进程", name: "posixSpawn", sig: "posixSpawn(path, argv, timeoutMs)", err: "code",
    args: [{ n: "path", t: "string", r: "可执行文件绝对路径" }, { n: "argv", t: "string[]", r: "参数数组（argv[0] 一般是文件名）" },
           { n: "timeoutMs", t: "number", r: "等待上限，毫秒" }],
    ret: "{…}", hint: "沙盒内多半被 process-exec 挡住，返回码就是证据" },

  // ---------- 文件 ----------
  { cat: "文件", name: "readFile / writeFile", sig: "readFile(path) / writeFile(path, content)", err: "ok",
    args: [{ n: "path", t: "string", r: "**相对 Documents 的路径**（不是绝对路径）" }, { n: "content", t: "string", r: "文本内容（write 会整文件覆盖，追加用 fileAppend）" }],
    ret: "文本 / \"ok\"" },
  { cat: "文件", name: "listDir / mkdir / fileExists / fileSize / fileDelete / fileAppend", sig: "listDir(path) / mkdir(name) / …", err: "ok",
    args: [{ n: "path/name", t: "string", r: "相对 Documents 的路径/目录名（空串是错的）" }],
    ret: "清单 / \"ok\" / bool / 字节数(-1 不存在)", errs: "mkdir 失败带原因；fileAppend 断开会回 \"cannot open\"" },
  { cat: "文件", name: "bytesB64 / b64Bytes", sig: "bytesB64(number[]) / b64Bytes(base64)", err: "ok",
    args: [{ n: "number[]", t: "number[]", r: "0..255 字节数组" }, { n: "base64", t: "string", r: "标准 base64" }] },

  // ---------- 系统信息 / 时间 / 网络 ----------
  { cat: "系统", name: "sysctlGet", sig: "sysctlGet(name)", err: "self",
    args: [{ n: "name", t: "string", r: "非空，必须真实存在，如 kern.version / kern.bootargs / hw.memsize" }],
    ret: "字符串 或 数字",
    errs: "\"[sysctlGet error] unknown name \\\"x\\\" (errno 2 ENOENT 无此名字)…\"（旧版只回 <sysctl err 2>）" },
  { cat: "系统", name: "appInfo / getPid / getEntitlements / now", sig: "appInfo() / getPid() / getEntitlements() / now()", err: "ok",
    args: [], ret: "文本 / 数字 / entitlements plist 文本 / {wall, mono（秒）}" },
  { cat: "系统", name: "sleep", sig: "sleep(ms)", err: "ok",
    args: [{ n: "ms", t: "number", r: "1..120000（超界不生效，防呆）" }], ret: "传入值",
    hint: "JavaScriptCore 没有 setTimeout，只能阻塞 sleep —— 探针要短" },
  { cat: "网络", name: "tcpConnect / tcpSend / tcpScan", sig: "tcpConnect(host, port) / tcpSend(host, port, hex) / tcpScan(host, startPort, endPort)", err: "code",
    args: [{ n: "host", t: "string", r: "IP 或域名" }, { n: "port", t: "number", r: "1..65535" }, { n: "hex", t: "string", r: "要发送的字节的 hex" }],
    ret: "可达性/响应" },
  { cat: "网络", name: "httpRequest", sig: "httpRequest(opts)", err: "code",
    args: [{ n: "opts", t: "object", r: "见源码（url/method/headers/body 等）" }], ret: "响应文本" },
  { cat: "网络", name: "canOpenURL / openURL / installIPA / getPasteboard / setPasteboard", sig: "canOpenURL(scheme) / openURL(url) / …", err: "code",
    args: [{ n: "scheme/url", t: "string", r: "如 \"cydia\" / \"https://…\"" }, { n: "text", t: "string", r: "剪贴板文本" }],
    ret: "bool / 结果串" },

  // ---------- Autorun / 保活 ----------
  { cat: "Autorun", name: "autorunStart / Stop / Status / Log", sig: "autorunStart(port) / autorunStop() / autorunStatus() / autorunLog()", err: "ok",
    args: [{ n: "port", t: "number", r: "1..65535（默认 8899）" }], ret: "状态文本 / 日志文本",
    hint: "监听期间才有保活（切后台/锁屏也能收码）；日志尾部是 crash log 之外的最近活动" },
  { cat: "Autorun", name: "autorunStatus / keepAliveInfo / liveActivityStatus", sig: "autorunStatus() / keepAliveInfo() / liveActivityStatus()", err: "ok",
    args: [], ret: "JSON 文本（含 pid / hits / lastPrim 崩溃点名 / 保活态 / 灵动岛态）",
    hint: "**崩溃后先看 /ping 的 lastPrim** —— 它会点名最后执行的原语（Bug6 之后新增的仪表）" },
  { cat: "桥", name: "require", sig: "require(\"名字\")", err: "ok",
    args: [{ n: "名字", t: "string", r: "脚本/桥名（可省 .js）" }], ret: "加载结果文本；找不到回 \"[require] not found: x\"" },
  { cat: "桥", name: "primHelp / primErrors / primMissing", sig: "primHelp(过滤词?) / primErrors() / primMissing()", err: "ok",
    args: [{ n: "过滤词", t: "string", r: "可选；子串匹配（不区分大小写），如 \"iokit\" / \"surface\"" }],
    ret: "本文档（字符串）", hint: "这就是你现在看的这份东西 —— 桥自带的说明书" }
];

function _hpMatch(e, f) {
  if (!f) return true;
  f = String(f).toLowerCase();
  return e.name.toLowerCase().indexOf(f) >= 0 || e.cat.toLowerCase().indexOf(f) >= 0;
}

function primHelp(filter) {
  var hits = PRIM_DOC.filter(function (e) { return _hpMatch(e, filter); });
  if (!hits.length)
    return "[primHelp] 没有匹配 \"" + filter + "\" 的原语。试试 primHelp()（全部）或 primHelp(\"iokit\")。";
  if (hits.length === 1) return _hpDetail(hits[0]);
  var out = "[primHelp] " + (filter ? ("匹配 \"" + filter + "\" 的 ") : "") + hits.length + " 个原语：\n";
  var cat = "";
  hits.forEach(function (e) {
    if (e.cat !== cat) { cat = e.cat; out += "\n── " + cat + " ──\n"; }
    var mark = e.err === "self" ? "✅自解释" : (e.err === "code" ? "⚠裸码" : "  ok  ");
    out += "  " + mark + "  " + e.sig + "\n";
    if (e.ret) out += "            → " + e.ret + "\n";
  });
  out += "\n提示：primHelp(\"<名字片段>\") 看单个的完整说明；primErrors() 看错误约定；primMissing() 看还欠自解释的桥。";
  return out;
}

function _hpDetail(e) {
  var out = "【" + e.name + "】" + e.cat + "\n";
  out += "  签名   : " + e.sig + "\n";
  if (e.args && e.args.length) {
    out += "  参数   :\n";
    e.args.forEach(function (a) {
      out += "    - " + a.n + " : " + a.t + " —— " + (a.r || "(未注明)") + "\n";
    });
  } else {
    out += "  参数   : 无\n";
  }
  if (e.ret) out += "  返回   : " + e.ret + "\n";
  if (e.errs) out += "  错误   : " + e.errs + "\n";
  out += "  错误风格: " + (e.err === "self" ? "失败返回 \"[" + e.name + " error] 参数名 + 合法范围\"（memRead 风格，自解释）"
                                          : (e.err === "code" ? "返回数字/裸码 —— 用 krWhy(kr) 或 machKrWhy(kr) 解码再看" : "参数基本不会导致失败")) + "\n";
  if (e.hint) out += "  要点   : " + e.hint + "\n";
  return out;
}

// 错误约定总说明：拿到一个返回值先判断"它属于哪种形态"
function primErrors() {
  return [
    "[错误约定] RyConsole 原语返回值分四种形态，先分类再解读：",
    "",
    " 1) 自解释错误串（✅ 自解释，Bug6 目标形态）",
    "     形态:  \"[<桥名> error] <参数名> + <合法范围/原因>\"",
    "     例:    memRead(h, 0)   → \"[memRead error] len must be 1..65536\"",
    "            iokitMap(1, 0) → {ok:false, error:\"[iokitMap error] …\", hint:\"…\"}",
    "     ★ 判据: 字符串里出现 \"] error]\" 就是错误，不用猜。",
    "",
    " 2) 结构化结果（dict）",
    "     形态:  {ret/kr, ok, outputs, error?, hint?, note?}",
    "     ★ ok:false + error 必备；hint 是「下一步该怎么办」。",
    "",
    " 3) 裸数字 / 裸码（⚠ 需解码，不是错误信息不全就是内核只给了码）",
    "     例:    iokitOpen(\"Foo\") → -2 / -536870174 / -3",
    "            iokitCall(...).ret → 0xe00002c2 之类",
    "     ★ 一律先过 krWhy(kr)（IOKit）或 machKrWhy(kr)（Mach/bootstrap）再判断。",
    "       别把 -536870206 直接贴给人看。",
    "",
    " 4) 单例哨兵（-1 / -2 / -3 / 0x0 / \"\"）",
    "     ★ -1 常见于\"操作失败但原因在内核里\"; -3 = 参数错(空类名); 0x0 = 类/符号不存在。",
    "",
    " 通用排查顺序：",
    "   ① 是不是参数错 → 看有没有 \"] error]\" 或 ok:false",
    "   ② 是不是句柄错 → iokitMap/iokitCall 会明说 conn 不是有效 send right",
    "   ③ 是不是门禁   → kr=0xe00002e2(kIOReturnNotPermitted)=沙盒/entitlement，纯用户态无解",
    "   ④ 是不是形状错 → kr=0xe00002c2(BadArgument)=驱动的 check* 拒了 (selector,标量数,struct 大小) 组合",
    "   ⑤ 是不是不存在 → kr=0xe00002c6(BadMessageID)=selector 没注册；-2 = 类名错",
    "",
    " 崩溃后定位：/ping 与 autorunStatus() 里的 lastPrim 会点名「最后执行的原语」，配合 crash log 用。"
  ].join("\n");
}

// 诚实清单：还没做成自解释错误的桥（Bug6 只覆盖了报告点名的 + V3 主线）
function primMissing() {
  var pending = PRIM_DOC.filter(function (e) { return e.err === "code"; }).map(function (e) { return e.name; });
  return "[primMissing] 仍是裸码风格（失败只给数字，需自行 krWhy 解码）的原语：\n  "
    + pending.join("\n  ")
    + "\n\n这些不是「坏」，只是错误信息还没做到 memRead 那样自解释。要推进就照 primHelp(\"memRead\") 的格式改。";
}

print("[bridge_help] 已加载: primHelp / primErrors / primMissing / krName(krWhy 见 bridge_iokit) (" + HELP_VERSION + ")");
