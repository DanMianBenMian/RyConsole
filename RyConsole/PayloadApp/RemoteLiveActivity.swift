//
//  RemoteLiveActivity.swift
//  RyConsole —— 远程连接实时活动（灵动岛 / 锁屏「远程连接中」）
//
//  与监听用的 RYLiveActivityManager 平行：专管「远程连接（连接 PC）」活动。
//  二者互斥（监听与远程只能开一个）→ 同一时刻只有一个活动在跑，互不干扰。
//
//  为什么用 @_cdecl 而不是 #import "RyConsole-Swift.h"：
//    主 target 是纯 ObjC，加 Swift 后依赖 Xcode 生成的 `<产品名>-Swift.h`，
//    那个头的路径/命名在某些 SDK 组合下会飘。改成导出 C ABI 函数，ObjC 侧只声明
//    extern 原型最稳（见 RemoteLiveActivityBridge.h）。
//
//  API 面：只用 iOS 17+ 的新式 ActivityKit 调用（Activity.request/update/end 都吃
//    ActivityContent 包装）；旧 16.1 那套 update(using:)/end(using:) 已废弃且不能结束
//    新 API 起出来的活动。
//
//  ★ V2.4.x 推送管线（与监听端同款，已修过"保持 0 / 焊死不刷"）：
//    变更全部汇入 pushQ（串行）→ 推送单飞（inFlight + dirty 追赶，永远推最新快照）
//    → 计数类更新合并进 0.5s 窗口（避开系统节流）；touch 也走同一条管线续保鲜期。
//    doPush 用 defer 无论如何复位管道，杜绝一次异常把灵动岛焊死在旧值。
//

import ActivityKit
import Foundation

@available(iOS 17.0, *)
final class RYRemoteLiveActivityManager {

    static let shared = RYRemoteLiveActivityManager()

    private var activity: Activity<RyRemoteAttributes>?
    private var server = ""
    private var codes = 0
    private var lastCode = ""
    private var startedAt = Date()
    private var mode = "ws"
    /// V2.4：待确认的权限请求文案（空 = 无）
    private var alertText = ""

    // ---- 推送管线：串行化 + 合并 + 保序 ----
    private let pushQ = DispatchQueue(label: "ry.remotela.push")
    private var pushInFlight = false
    private var pushDirty = false
    private var lastPushAt: TimeInterval = 0
    private static let coalesceWindow: TimeInterval = 0.5

    /// 活动「保鲜期」。远程连接期间由保活脉冲定期 touch（见 rmtStartLATimer）。
    /// App 被强杀（无回调）→ 超时后系统标 stale（变灰），下次启动 sweep 清掉。
    private static let staleWindow: TimeInterval = 900

    private func makeContent() -> ActivityContent<RyRemoteAttributes.ContentState> {
        ActivityContent(state: RyRemoteAttributes.ContentState(server: server, codes: codes,
                                                    lastCode: lastCode, startedAt: startedAt,
                                                    mode: mode, alert: alertText),
                        staleDate: Date().addingTimeInterval(Self.staleWindow))
    }

    var isActive: Bool { activity != nil }

    /// 开启"远程连接中"实时活动。已有则复用（可重入）。
    @discardableResult
    func start(server: String, mode: String) -> Bool {
        if activity != nil { return true }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[RemoteLiveActivity] 系统未开启实时活动（设置→RyConsole→实时活动）")
            return false
        }

        self.server = server
        self.codes = 0
        self.lastCode = ""
        self.startedAt = Date()
        self.mode = mode

        let attrs = RyRemoteAttributes(title: "RyConsole · Remote")
        let state = RyRemoteAttributes.ContentState(server: server, codes: 0,
                                                    lastCode: "", startedAt: startedAt,
                                                    mode: mode, alert: alertText)
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleWindow))
        do {
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            NSLog("[RemoteLiveActivity] 已启动 id=%@", activity?.id ?? "-")
            pushQ.async { [weak self] in
                self?.pushInFlight = false
                self?.pushDirty = false
                self?.lastPushAt = 0
            }
            return true
        } catch {
            NSLog("[RemoteLiveActivity] 启动失败: %@", error.localizedDescription)
            return false
        }
    }

    /// 弹出/更新"权限请求提醒"。传空串 = 清除。没有活动在跑时会自动起一个（server 传 ""）。
    @discardableResult
    func alert(_ text: String) -> Bool {
        if activity == nil { _ = start(server: "", mode: "") }
        pushQ.async { [weak self] in
            guard let self else { return }
            self.alertText = text
            self.pushImmediate()
        }
        return activity != nil
    }

    /// 推一次当前快照（绕过合并窗口；保留为兼容入口）
    func refresh() {
        pushQ.async { [weak self] in self?.pushImmediate() }
    }

    private func pushImmediate() {
        if pushInFlight { pushDirty = true; return }
        doPush()
    }

    private func pushCount() {
        if pushInFlight { pushDirty = true; return }
        if lastPushAt == 0 { doPush(); return }
        let delta = Date().timeIntervalSince1970 - lastPushAt
        if delta < Self.coalesceWindow {
            pushInFlight = true
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
            defer {
                self?.pushQ.async {
                    guard let self else { return }
                    self.pushInFlight = false
                    if self.pushDirty { self.pushDirty = false; self.pushCount() }
                }
            }
            do {
                try await a.update(content)
            } catch {
                NSLog("[RemoteLiveActivity] update 失败（已忽略，管道继续）: %@", "\(error)")
            }
        }
    }

    /// 刷新活动内容。
    /// - codes >= 0：收到代码数更新（走合并窗口）
    /// - codes <  0：**只续保鲜期**（保活脉冲用，数字不动）
    func update(codes newCodes: Int, lastCode newLast: String) {
        pushQ.async { [weak self] in
            guard let self else { return }
            if newCodes >= 0 { self.codes = newCodes }
            if !newLast.isEmpty { self.lastCode = newLast }
            self.pushCount()
        }
    }

    /// 结束并立刻移除。
    func stop() {
        pushQ.async { [weak self] in
            guard let self, let a = self.activity else { return }
            self.activity = nil
            let content = ActivityContent(state: RyRemoteAttributes.ContentState(
                server: self.server, codes: self.codes, lastCode: self.lastCode,
                startedAt: self.startedAt, mode: self.mode, alert: self.alertText),
                staleDate: Date())
            Task { await a.end(content, dismissalPolicy: .immediate) }
        }
    }

    /// 清扫"上一个进程残留"的活动（强杀后灵动岛不消失的补救）。App 启动时调用一次。
    @discardableResult
    func sweepOrphans() -> Int {
        if activity != nil { return 0 }
        let orphans = Activity<RyRemoteAttributes>.activities
        guard !orphans.isEmpty else { return 0 }
        for a in orphans {
            let content = ActivityContent(state: a.content.state, staleDate: Date())
            Task { await a.end(content, dismissalPolicy: .immediate) }
        }
        NSLog("[RemoteLiveActivity] 清扫残留活动 %d 个", orphans.count)
        return orphans.count
    }
}

// MARK: - 暴露给 ObjC 的 C ABI
// 返回 1 = 成功 / 已开启，0 = 不可用或失败（不抛异常，ObjC 侧无需 @try）

@_cdecl("ryRemoteLiveActivityAvailable")
public func ryRemoteLiveActivityAvailable() -> Int32 {
    if #available(iOS 17.0, *) {
        return ActivityAuthorizationInfo().areActivitiesEnabled ? 1 : 0
    }
    return 0
}

@_cdecl("ryRemoteLiveActivityActive")
public func ryRemoteLiveActivityActive() -> Int32 {
    if #available(iOS 17.0, *) {
        return RYRemoteLiveActivityManager.shared.isActive ? 1 : 0
    }
    return 0
}

@_cdecl("ryRemoteLiveActivityStart")
public func ryRemoteLiveActivityStart(_ server: UnsafePointer<CChar>?, _ mode: UnsafePointer<CChar>?) -> Int32 {
    if #available(iOS 17.0, *) {
        let s = server.map { String(cString: $0) } ?? ""
        let m = mode.map { String(cString: $0) } ?? "ws"
        return RYRemoteLiveActivityManager.shared.start(server: s, mode: m) ? 1 : 0
    }
    return 0
}

@_cdecl("ryRemoteLiveActivityUpdate")
public func ryRemoteLiveActivityUpdate(_ codes: Int32, _ lastCode: UnsafePointer<CChar>?) -> Int32 {
    if #available(iOS 17.0, *) {
        let c = lastCode.map { String(cString: $0) } ?? ""
        RYRemoteLiveActivityManager.shared.update(codes: Int(codes), lastCode: c)
        return 1
    }
    return 0
}

@_cdecl("ryRemoteLiveActivityStop")
public func ryRemoteLiveActivityStop() -> Int32 {
    if #available(iOS 17.0, *) {
        RYRemoteLiveActivityManager.shared.stop()
        return 1
    }
    return 0
}

/// 只续保鲜期（数字不动）。保活脉冲定期调用，保证"还在连接"期间活动永不 stale。
@_cdecl("ryRemoteLiveActivityTouch")
public func ryRemoteLiveActivityTouch() -> Int32 {
    if #available(iOS 17.0, *) {
        RYRemoteLiveActivityManager.shared.update(codes: -1, lastCode: "")
        return 1
    }
    return 0
}

/// 权限请求提醒（后台调用被禁命令时，用灵动岛/锁屏顶出来）。title/sub 拼一行；空 title = 清除。
@_cdecl("ryRemoteLiveActivityAlert")
public func ryRemoteLiveActivityAlert(_ title: UnsafePointer<CChar>?, _ sub: UnsafePointer<CChar>?) -> Int32 {
    if #available(iOS 17.0, *) {
        let t = title.map { String(cString: $0) } ?? ""
        let u = sub.map { String(cString: $0) } ?? ""
        let text = t.isEmpty ? "" : (u.isEmpty ? t : "\(t)：\(u)")
        return RYRemoteLiveActivityManager.shared.alert(text) ? 1 : 0
    }
    return 0
}

/// 清扫上次进程残留的活动（强杀后灵动岛不消失的补救）。App 启动时调用一次。
@_cdecl("ryRemoteLiveActivitySweep")
public func ryRemoteLiveActivitySweep() -> Int32 {
    if #available(iOS 17.0, *) {
        return Int32(RYRemoteLiveActivityManager.shared.sweepOrphans())
    }
    return 0
}
