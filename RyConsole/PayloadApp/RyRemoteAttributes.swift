//
//  RyRemoteAttributes.swift
//  RyConsole —— 远程连接实时活动（Live Activity）共享模型
//
//  ⚠️ 本文件被**同时编译进两个 target**（与 RyListenAttributes.swift 同规则）：
//      · RyConsole（主 App，负责 request / update / end）
//      · RyConsoleWidget（Widget Extension，负责渲染锁屏胶囊 / 灵动岛）
//    两份定义必须逐字一致 —— ActivityKit 靠类型名 + 结构匹配两端，
//    任何字段差异都会让 Activity.request 静默失败（不报错、就是不显示）。
//
//  这是「远程连接（连接 PC）」专属的活动，与监听(Autorun)的 RYListenAttributes 平行并存；
//  因为二者互斥（监听与远程只能开一个），同一时刻最多只有一个活动在跑，互不干扰。
//

import ActivityKit
import Foundation

struct RyRemoteAttributes: ActivityAttributes {

    /// 随状态变化的部分
    public struct ContentState: Codable, Hashable {
        /// 隧道/服务端主机（如 favors-passes-...trycloudflare.com）
        var server: String
        /// 已收到并执行的 JS 段数（"数据"指标）
        var codes: Int
        /// 最近一次 PC 推来的代码预览（短，用于展开态展示）
        var lastCode: String
        /// 开始连接时刻（用于显示已连接时长）
        var startedAt: Date
        /// 通道模式："ws" | "lp"（长轮询降级）
        var mode: String
        /// ★ V2.4：待用户确认的**权限请求提醒**（空串 = 无待确认）。
        var alert: String
    }

    /// 固定不变的部分
    var title: String
}
