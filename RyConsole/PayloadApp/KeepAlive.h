//
//  KeepAlive.h
//  RyConsole —— 监听期后台保活（V2.2）
//
//  只在 Autorun 监听开启时生效；监听一停立刻释放（省电 + 不做后台偷跑）。
//  对 JS 暴露：keepAliveStatus() / keepAliveInfo()
//

#import <Foundation/Foundation.h>

@interface RYKeepAlive : NSObject

+ (instancetype)shared;

/// 是否处于保活态（= 正在监听）
@property (nonatomic, readonly) BOOL active;

/// 监听开始：进入保护（可重入）
- (void)begin:(NSString *)reason;

/// 监听结束：释放全部保活资源
- (void)end;

/// 一行人类可读状态，给 UI / JS 用
- (NSString *)statusLine;

/// JSON 形态状态，给 JS / 回传用
- (NSString *)statusJSON;

@end
