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
//    （request(attributes:content:pushType:) / update(_:) / end(_:dismissalPolicy:)）
//    避开 16.1→16.2 那批已废弃的老签名，编译期不会踩 deprecated。
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
        do {
            activity = try Activity.request(attributes: attrs, content: state, pushType: nil)
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
        Task { await a.update(state) }
    }

    /// 结束并立刻移除。
    func stop() {
        guard let a = activity else { return }
        activity = nil
        let state = RYListenAttributes.ContentState(port: port, hits: hits,
                                                    lastPeer: peer, startedAt: startedAt)
        Task { await a.end(state, dismissalPolicy: .immediate) }
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
