//
//  MainShell.h
//  RyConsole —— 新外壳（左侧栏 + 三板块：终端 / Autorun / 设置）
//

#import <UIKit/UIKit.h>

/// 由 main.m 实现：资源管理器（脚本 / 桥）VC 的工厂。
/// 外壳只负责弹出，不直接依赖 main.m 内部的 @interface（前向声明类型无法 alloc/init）。
UIViewController *RYMakeResourceManagerVC(void);

@interface RYShellVC : UIViewController
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, assign) BOOL bottomMode;
@end
