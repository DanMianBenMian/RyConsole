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
    private var startedAt = Date()

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
                                                    lastPeer: "", startedAt: startedAt)
        // pushType: nil = 只由本 App 更新；staleDate = 保鲜期（由保活脉冲续）
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleWindow))
        do {
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            NSLog("[LiveActivity] 已启动 id=%@", activity?.id ?? "-")
            return true
        } catch {
            NSLog("[LiveActivity] 启动失败: %@", error.localizedDescription)
            return false
        }
    }

    /// 刷新活动内容。
    /// - hits >= 0：连接计数更新
    /// - hits <  0：**只续保鲜期**（保活脉冲用，数字不动）
    func update(hits newHits: Int, peer newPeer: String) {
        // 调用方可能是 Autorun 的网络线程（handleConnection）→ 统一回主线程改状态，
        // 避免与保活脉冲/前台切换并发读写同一批字段。
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.update(hits: newHits, peer: newPeer)
            }
            return
        }
        if newHits >= 0 { self.hits = newHits }
        if !newPeer.isEmpty { self.peer = newPeer }
        guard let a = activity else { return }
        let state = RYListenAttributes.ContentState(port: port, hits: hits,
                                                    lastPeer: peer, startedAt: startedAt)
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleWindow))
        Task { await a.update(content) }
    }

    /// 结束并立刻移除。
    func stop() {
        guard let a = activity else { return }
        activity = nil
        let state = RYListenAttributes.ContentState(port: port, hits: hits,
                                                    lastPeer: peer, startedAt: startedAt)
        let content = ActivityContent(state: state, staleDate: Date())
        Task { await a.end(content, dismissalPolicy: .immediate) }
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
