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
        // staleDate: nil = 不设过期（监听期间一直有效）；nil 的 pushType = 只由本 App 更新
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            NSLog("[LiveActivity] 已启动 id=%@", activity?.id ?? "-")
            return true
        } catch {
            NSLog("[LiveActivity] 启动失败: %@", error.localizedDescription)
            return false
        }
    }

    /// 连接计数 + 最近来源变化时刷新。
    func update(hits: Int, peer newPeer: String) {
        self.hits = hits
        if !newPeer.isEmpty { self.peer = newPeer }
        guard let a = activity else { return }
        let state = RYListenAttributes.ContentState(port: port, hits: hits,
                                                    lastPeer: peer, startedAt: startedAt)
        let content = ActivityContent(state: state, staleDate: nil)
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
