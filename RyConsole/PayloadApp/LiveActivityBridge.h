//
//  LiveActivityBridge.h
//  RyConsole —— 实时活动（灵动岛）的 C 桥声明
//
//  实现体在 LiveActivity.swift（Swift），用 @_cdecl 导出这些 C 符号。
//  App 侧 ObjC 只依赖这份原型，不依赖 Xcode 生成的 "-Swift.h"（那份头路径易飘）。
//
//  约定：返回 1 = 成功 / 可用；0 = 不可用或失败。不会抛异常，返回时状态已生效或已放弃。
//

#ifndef RY_LIVE_ACTIVITY_BRIDGE_H
#define RY_LIVE_ACTIVITY_BRIDGE_H

#import <Foundation/Foundation.h>

/// 系统层面是否允许实时活动（设置里可关掉）
int32_t ryLiveActivityAvailable(void);

/// 当前是否已有一个"监听中"活动在跑
int32_t ryLiveActivityActive(void);

/// 开启"监听中"实时活动（可重入；已有则复用）
int32_t ryLiveActivityStart(int32_t port);

/// 刷新连接计数 / 最近来源（peer 可为 NULL）
int32_t ryLiveActivityUpdate(int32_t hits, const char *peer);

/// 结束并立刻移除
int32_t ryLiveActivityStop(void);

/// 只续「保鲜期」（数字不动）。保活脉冲定期调用，避免还在监听却被系统标成陈旧。
int32_t ryLiveActivityTouch(void);

/// V2.4 权限请求提醒：后台调用被禁命令时，用灵动岛 / 锁屏把"要调用 xxx 命令"顶出来。
/// title/sub 拼成一行文案（sub 可 NULL）；title 传 "" 或 NULL = 清除提醒。
int32_t ryLiveActivityAlert(const char *title, const char *sub);

/// 清扫上一个进程残留的活动（用户强杀 App 后灵动岛不消失的补救），App 启动时调一次。
/// 返回清掉的个数。
int32_t ryLiveActivitySweep(void);

#endif
