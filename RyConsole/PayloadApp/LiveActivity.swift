//
//  LiveActivity.swift
//  RyConsole —— App 侧实时活动控制（灵动岛 / 锁屏"监听中"）
//
//  为什么用 @_cdecl 而不是 #import "RyConsole-Swift.h"：
//    主 target 是纯 ObjC，加 Swift 后要依赖 Xcode 生成的 `<产品名>-Swift.h`；
//    那个头的路径/命名在某些 SDK 组合下会飘（构建报 "file not found"）。
//    这里改成导出 4 个 C ABI 函数，ObjC 侧只声明 extern 原型，最稳。
//
//  API 面：只用 iOS 17+ 的新式 ActivityKit 调用
//    · Activity.request(attributes:content:pushType:)   ← content 必须是 ActivityContent 包装
//    · activity.update(content)                          ← 无标签，同样吃 ActivityContent
//    · activity.end(content, dismissalPolicy:)           ← 同上
//    注意别用 16.1 那套 update(using:) / end(using:dismissalPolicy:)：那些吃裸 ContentState，
//    在 16.2 已废弃，且**不能结束用新 API 起出来的活动**（会静默失败）。
//
//  线程：ActivityKit 的 async 接口自己会切，ObjC 侧从任意线程调都安全。
//

import ActivityKit
import Foundation

@available(iOS 17.0, *)
final class RYLiveActivityManager {

    static let shared = RYLiveActivityManager()

    private var activity: Activity<RYListenAttributes>?
    private var port = 0
    private var hits = 0
    private var peer = ""
    /// V2.4：待确认的权限请求文案（空 = 无）
    private var alertText = ""
    private var startedAt = Date()

    // ---- V2.4.4 推送管线：串行化 + 合并 + 保序 ----
    //  真机现象：连接次数显示滞后/回跳。两个叠加根因：
    //   ① 旧实现每次 update 都 DispatchQueue.main.async 绕主线程 —— Autorun 连接线程
    //      高频轮询时主队列积压，数字滞后；
    //   ② 每次 update 起一个 Task 推送 —— Task 完成顺序不定，旧快照可能后落（回跳）；
    //      且高频 update 会被系统节流合并，越频繁越迟。
    //  方案：变更全部汇入 pushQ（串行）→ 推送单飞（inFlight + dirty 追赶，永远推最新
    //        快照）→ 计数类更新合并进 0.5s 窗口（避开系统节流）；提醒类绕过窗口立即推。
    private let pushQ = DispatchQueue(label: "ry.liveactivity.push")
    private var pushInFlight = false             // 仅 pushQ 触碰
    private var pushDirty = false                // 仅 pushQ 触碰
    private var lastPushAt: TimeInterval = 0     // 仅 pushQ
    private static let coalesceWindow: TimeInterval = 0.5

    private func makeContent() -> ActivityContent<RYListenAttributes.ContentState> {
        ActivityContent(state: RYListenAttributes.ContentState(port: port, hits: hits,
                                                    lastPeer: peer, startedAt: startedAt,
                                                    alert: alertText),
                        staleDate: Date().addingTimeInterval(Self.staleWindow))
    }

    /// 活动「保鲜期」。监听期间由保活脉冲定期 touch（见 KeepAlive.pulseOnce）；
    /// 一旦 App 被强杀（强杀没有回调可走），超时后系统会把活动标成 stale（变灰），
    /// 下次打开 RyConsole 再由 sweep 清掉 —— 这是 iOS 允许的唯一"自动过期"表达。
    private static let staleWindow: TimeInterval = 900

    var isActive: Bool { activity != nil }

    /// 开启"监听中"实时活动。已有则复用（可重入）。
    @discardableResult
    func start(port: Int) -> Bool {
        if activity != nil { return true }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivity] 系统未开启实时活动（设置→RyConsole→实时活动）")
            return false
        }

        self.port = port
        self.hits = 0
        self.peer = ""
        self.startedAt = Date()

        let attrs = RYListenAttributes(title: "RyConsole · Autorun")
        let state = RYListenAttributes.ContentState(port: port, hits: 0,
                                                    lastPeer: "", startedAt: startedAt,
                                                    alert: alertText)
        // pushType: nil = 只由本 App 更新；staleDate = 保鲜期（由保活脉冲续）
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleWindow))
        do {
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            NSLog("[LiveActivity] 已启动 id=%@", activity?.id ?? "-")
            // 管线复位：start 的起算点也计为"刚推过"（首帧 content 已带全量状态）
            pushQ.async { [weak self] in
                self?.pushInFlight = false
                self?.pushDirty = false
                self?.lastPushAt = Date().timeIntervalSince1970
            }
            return true
        } catch {
            NSLog("[LiveActivity] 启动失败: %@", error.localizedDescription)
            return false
        }
    }

    /// V2.4：弹出/更新"权限请求提醒"（后台禁用命令被调用时用）。
    /// 传空串 = 清除提醒。没有活动在跑时会自动起一个（port 传 0）。
    @discardableResult
    func alert(_ text: String) -> Bool {
        if activity == nil { _ = start(port: 0) }
        pushQ.async { [weak self] in
            guard let self else { return }
            self.alertText = text
            self.pushImmediate()          // 提醒类：绕过合并窗口，在推的单落地后立即追最新
        }
        return activity != nil
    }

    /// 推一次当前快照（V2.4.4：绕过合并窗口；保留为兼容入口）
    func refresh() {
        pushQ.async { [weak self] in self?.pushImmediate() }
    }

    /// 用当前字段重推一次内容（内部：立即推送，仍受 inFlight/dirty 追赶约束）
    private func pushImmediate() {
        if pushInFlight { pushDirty = true; return }
        doPush()
    }

    // 计数类：走 0.5s 合并窗口
    private func pushCount() {
        if pushInFlight { pushDirty = true; return }
        let delta = Date().timeIntervalSince1970 - lastPushAt
        if delta < Self.coalesceWindow {
            pushInFlight = true           // 占住管道，窗口到点推最新快照
            pushQ.asyncAfter(deadline: .now() + (Self.coalesceWindow - delta)) { [weak self] in
                self?.doPush()
            }
            return
        }
        doPush()
    }

    private func doPush() {
        pushInFlight = true
        lastPushAt = Date().timeIntervalSince1970
        guard let a = activity else { pushInFlight = false; return }
        let content = makeContent()
        Task { [weak self] in
            await a.update(content)
            guard let self else { return }
            self.pushQ.async {                       // 推完回队列收账，追 dirty
                self.pushInFlight = false
                if self.pushDirty { self.pushDirty = false; self.pushCount() }
            }
        }
    }

    /// 刷新活动内容。
    /// - hits >= 0：连接计数更新（走合并窗口）
    /// - hits <  0：**只续保鲜期**（保活脉冲用，数字不动）
    func update(hits newHits: Int, peer newPeer: String) {
        // V2.4.4：不再绕主线程（那是滞后根因之一）。所有字段变更统一汇入 pushQ，
        // 与推送管线同队列 → 快照一致、顺序有保、主队列零压力。
        pushQ.async { [weak self] in
            guard let self else { return }
            if newHits >= 0 { self.hits = newHits }
            if !newPeer.isEmpty { self.peer = newPeer }
            self.pushCount()
        }
    }

    /// 结束并立刻移除。
    func stop() {
        pushQ.async { [weak self] in
            guard let self, let a = self.activity else { return }
            self.activity = nil
            let content = ActivityContent(state: RYListenAttributes.ContentState(
                port: self.port, hits: self.hits, lastPeer: self.peer,
                startedAt: self.startedAt, alert: self.alertText),
                staleDate: Date())
            Task { await a.end(content, dismissalPolicy: .immediate) }
        }
    }

    /// 清扫"上一个进程残留"的活动。
    /// 场景：用户从后台把 App 划掉（强杀）→ 系统不会回调我们 → 灵动岛留在那儿。
    /// 这里是唯一能补救的时机：**下次启动时**，如果本进程还没开始监听，就把系统里所有
    /// 属于本 App 的活动全部结束掉（并立刻移除）。
    /// - Returns: 清掉的数量
    @discardableResult
    func sweepOrphans() -> Int {
        if activity != nil { return 0 }             // 本进程正在监听 → 不动
        let orphans = Activity<RYListenAttributes>.activities
        guard !orphans.isEmpty else { return 0 }
        for a in orphans {
            let content = ActivityContent(state: a.content.state, staleDate: Date())
            Task { await a.end(content, dismissalPolicy: .immediate) }
        }
        NSLog("[LiveActivity] 清扫残留活动 %d 个", orphans.count)
        return orphans.count
    }
}

// MARK: - 暴露给 ObjC 的 C ABI
// 返回 1 = 成功 / 已开启，0 = 不可用或失败（不抛异常，ObjC 侧无需 @try）

@_cdecl("ryLiveActivityAvailable")
public func ryLiveActivityAvailable() -> Int32 {
    if #available(iOS 17.0, *) {
        return ActivityAuthorizationInfo().areActivitiesEnabled ? 1 : 0
    }
    return 0
}

@_cdecl("ryLiveActivityActive")
public func ryLiveActivityActive() -> Int32 {
    if #available(iOS 17.0, *) {
        return RYLiveActivityManager.shared.isActive ? 1 : 0
    }
    return 0
}

@_cdecl("ryLiveActivityStart")
public func ryLiveActivityStart(_ port: Int32) -> Int32 {
    if #available(iOS 17.0, *) {
        return RYLiveActivityManager.shared.start(port: Int(port)) ? 1 : 0
    }
    return 0
}

@_cdecl("ryLiveActivityUpdate")
public func ryLiveActivityUpdate(_ hits: Int32, _ peer: UnsafePointer<CChar>?) -> Int32 {
    if #available(iOS 17.0, *) {
        let p = peer.map { String(cString: $0) } ?? ""
        RYLiveActivityManager.shared.update(hits: Int(hits), peer: p)
        return 1
    }
    return 0
}

@_cdecl("ryLiveActivityStop")
public func ryLiveActivityStop() -> Int32 {
    if #available(iOS 17.0, *) {
        RYLiveActivityManager.shared.stop()
        return 1
    }
    return 0
}

/// V2.4：权限请求提醒（后台调用被禁命令时，用灵动岛/锁屏顶出来）。
/// title/sub 拼成一行文案；传空 title 表示清除提醒。
@_cdecl("ryLiveActivityAlert")
public func ryLiveActivityAlert(_ title: UnsafePointer<CChar>?, _ sub: UnsafePointer<CChar>?) -> Int32 {
    if #available(iOS 17.0, *) {
        let t = title.map { String(cString: $0) } ?? ""
        let u = sub.map { String(cString: $0) } ?? ""
        let text = t.isEmpty ? "" : (u.isEmpty ? t : "\(t)：\(u)")
        return RYLiveActivityManager.shared.alert(text) ? 1 : 0
    }
    return 0
}

/// 只续保鲜期（数字不动）。保活脉冲定期调用，保证"App 还活着"期间活动永不 stale。
@_cdecl("ryLiveActivityTouch")
public func ryLiveActivityTouch() -> Int32 {
    if #available(iOS 17.0, *) {
        RYLiveActivityManager.shared.update(hits: -1, peer: "")
        return 1
    }
    return 0
}

/// 清扫上次进程残留的活动（强杀后灵动岛不消失的补救）。App 启动时调用一次。
/// - Returns: 清掉的个数
@_cdecl("ryLiveActivitySweep")
public func ryLiveActivitySweep() -> Int32 {
    if #available(iOS 17.0, *) {
        return Int32(RYLiveActivityManager.shared.sweepOrphans())
    }
    return 0
}
