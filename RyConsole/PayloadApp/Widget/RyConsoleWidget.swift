//
//  RyConsoleWidget.swift
//  RyConsoleWidget —— Widget Extension（只做实时活动：锁屏胶囊 + 灵动岛）
//
//  这里是唯一能"画"灵动岛的地方：主 App 无法自行绘制，只能 request/update 一个
//  Activity，真正的呈现由本扩展完成。
//
//  呈现形态：
//   · 灵动岛紧凑态：天线/信号图标（绿） + 已连接次数
//   · 灵动岛展开态："监听中" + 端口 + 连接数 + 已运行时长
//   · 锁屏 / 通知中心横幅：图标 + "监听中" + 端口 / 连接数
//
//  最低 iOS 16.1（ActivityKit 起始版本），本 target 的 deploymentTarget 已设为 16.1，
//  所以无需 @available 标注。
//

import ActivityKit
import SwiftUI
import WidgetKit

private let kAccent = Color(red: 0.20, green: 0.90, blue: 0.62)   // 与 App 的 RY_GREEN 同色系
/// 远程连接强调色（天蓝），与监听绿区分开，一眼能认出是「连接 PC」而不是「监听」
private let kRemoteAccent = Color(red: 0.35, green: 0.72, blue: 1.0)

/// 紧凑态里是否同时显示连接数。
/// ⚠️ 默认 **0 = 只显示图标**：原生 iPhone 灵动岛放两个元素没问题，
/// 但"强开灵动岛"（非原生，胶囊几何是假的）会被图标+数字两个元素撑变形。
/// 用原生灵动岛且想看数字的话，把它改成 1 重编即可。
private let kCompactShowsHits = 0

/// 紧凑态图标尺寸：写死，别让它参与自适应去撑胶囊宽度
private let kCompactIconSize: CGFloat = 12

@main
struct RyConsoleWidgetBundle: WidgetBundle {
    var body: some Widget {
        RYListenLiveActivity()
        RyRemoteLiveActivity()
    }
}

struct RYListenLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RYListenAttributes.self) { context in

            // ---- 锁屏 / 通知中心 ----
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(kAccent.opacity(0.18)).frame(width: 40, height: 40)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(kAccent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.alert.isEmpty ? "监听中" : "⚠️ 请求权限")
                        .font(.system(size: 15, weight: .semibold))
                    if !context.state.alert.isEmpty {
                        Text(context.state.alert)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Label(":\(context.state.port)", systemImage: "network")
                        Label("\(context.state.hits)", systemImage: "arrow.down.circle")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.72))
            .activitySystemActionForegroundColor(kAccent)

        } dynamicIsland: { context in

            DynamicIsland {
                // ---- 展开态 ----
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(kAccent)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(":\(context.state.port)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(kAccent)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("监听中")
                        .font(.system(size: 15, weight: .semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Label("\(context.state.hits) 次连接", systemImage: "arrow.down.circle")
                        Text(context.state.startedAt, style: .timer)
                            .monospacedDigit()
                        if !context.state.lastPeer.isEmpty {
                            Label(context.state.lastPeer, systemImage: "laptopcomputer")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            } compactLeading: {
                // ---- 紧凑态（左）：数据/信号图标（固定尺寸，不参与撑宽）----
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: kCompactIconSize, weight: .semibold))
                    .foregroundStyle(kAccent)
                    .frame(width: kCompactIconSize + 4, height: kCompactIconSize + 4)
                    .fixedSize()

            } compactTrailing: {
                // ---- 紧凑态（右）：默认留空（见 kCompactShowsHits 说明）----
                if kCompactShowsHits == 1 {
                    Text("\(context.state.hits)")
                        .font(.system(size: kCompactIconSize, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(kAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .fixedSize()
                } else {
                    EmptyView()
                }

            } minimal: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: kCompactIconSize, weight: .semibold))
                    .foregroundStyle(kAccent)
                    .fixedSize()
            }
            .keylineTint(kAccent)
            // 注意：这里**故意不挂 widgetURL**。
            // 之前挂了 "ryconsole://listen"，但 App 没注册这个 URL scheme ——
            // 在"强开灵动岛"的环境里点它会走到未注册 scheme 的处理路径（从灵动岛回 App 崩的嫌疑点）。
            // 去掉后点击仍由系统默认行为回到本 App，且不留隐患。
        }
    }
}

// MARK: - 远程连接（连接 PC）实时活动
//  与监听活动平行并存；二者互斥，同一时刻最多一个在跑。
//  呈现形态：
//   · 灵动岛紧凑态：云图标（天蓝）
//   · 灵动岛展开态："远程连接中" + 服务端主机 + 收到段数 + 已连接时长 + 通道模式
//   · 锁屏 / 通知中心横幅：云图标 + "远程连接中" + 服务端 / 段数 / 通道
struct RyRemoteLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RyRemoteAttributes.self) { context in

            // ---- 锁屏 / 通知中心 ----
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(kRemoteAccent.opacity(0.18)).frame(width: 40, height: 40)
                    Image(systemName: "icloud")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(kRemoteAccent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.alert.isEmpty ? "远程连接中" : "⚠️ 请求权限")
                        .font(.system(size: 15, weight: .semibold))
                    if !context.state.alert.isEmpty {
                        Text(context.state.alert)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Label(context.state.server.isEmpty ? "—" : context.state.server,
                              systemImage: "globe")
                        Label("\(context.state.codes) 段", systemImage: "doc.plaintext")
                        Label(context.state.mode == "ws" ? "WS" : "长轮询",
                              systemImage: "wave.3.right")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
                Spacer()
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.72))
            .activitySystemActionForegroundColor(kRemoteAccent)

        } dynamicIsland: { context in

            DynamicIsland {
                // ---- 展开态 ----
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "icloud")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(kRemoteAccent)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.server.isEmpty ? "—" : context.state.server)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(kRemoteAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("远程连接中")
                        .font(.system(size: 15, weight: .semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Label("\(context.state.codes) 段", systemImage: "doc.plaintext")
                        Text(context.state.startedAt, style: .timer)
                            .monospacedDigit()
                        Label(context.state.mode == "ws" ? "WS" : "长轮询",
                              systemImage: "wave.3.right")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            } compactLeading: {
                // ---- 紧凑态（左）：云图标（固定尺寸，不参与撑宽）----
                Image(systemName: "icloud")
                    .font(.system(size: kCompactIconSize, weight: .semibold))
                    .foregroundStyle(kRemoteAccent)
                    .frame(width: kCompactIconSize + 4, height: kCompactIconSize + 4)
                    .fixedSize()

            } compactTrailing: {
                // ---- 紧凑态（右）：默认留空（与监听同规则，避免强开灵动岛被撑变形）----
                if kCompactShowsHits == 1 {
                    Text("\(context.state.codes)")
                        .font(.system(size: kCompactIconSize, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(kRemoteAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .fixedSize()
                } else {
                    EmptyView()
                }

            } minimal: {
                Image(systemName: "icloud")
                    .font(.system(size: kCompactIconSize, weight: .semibold))
                    .foregroundStyle(kRemoteAccent)
                    .fixedSize()
            }
            .keylineTint(kRemoteAccent)
        }
    }
}
