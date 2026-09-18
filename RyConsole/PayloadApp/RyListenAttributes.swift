//
//  RyListenAttributes.swift
//  RyConsole —— 实时活动（Live Activity）共享模型
//
//  ⚠️ 本文件被**同时编译进两个 target**：
//      · RyConsole（主 App，负责 request / update / end）
//      · RyConsoleWidget（Widget Extension，负责渲染锁屏胶囊 / 灵动岛）
//    两份定义必须逐字一致 —— ActivityKit 靠类型名 + 结构匹配两端，
//    任何字段差异都会让 Activity.request 静默失败（不报错、就是不显示）。
//

import ActivityKit
import Foundation

struct RYListenAttributes: ActivityAttributes {

    /// 随状态变化的部分
    public struct ContentState: Codable, Hashable {
        /// 监听端口
        var port: Int
        /// 已处理连接数（"数据"指标）
        var hits: Int
        /// 最近一次连接来源（空串 = 还没有人来过）
        var lastPeer: String
        /// 开始监听时刻（用于显示已运行时长）
        var startedAt: Date
        /// ★ V2.4：待用户确认的**权限请求提醒**（空串 = 无待确认）。
        ///   后台禁用命令被调用时，灵动岛/锁屏用它把"要调用 xxx 命令"顶出来。
        var alert: String
    }

    /// 固定不变的部分
    var title: String
}
