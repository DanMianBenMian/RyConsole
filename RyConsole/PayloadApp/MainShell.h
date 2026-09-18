//
//  MainShell.h
//  RyConsole —— 新外壳（终端 / Autorun / 设置 / 资源管理器 四个面板）
//

#import <UIKit/UIKit.h>

/// 由 main.m 实现：资源管理器（脚本 / 桥）VC 的工厂。
/// 外壳不直接依赖 main.m 内部的 @interface（前向声明类型无法 alloc/init）。
UIViewController *RYMakeResourceManagerVC(void);        // 模态弹出（经典界面入口用）
UIViewController *RYMakeResourceManagerPane(void);      // ★ 外壳内嵌面板（现代样式，非弹窗）
void RYResourceManagerRefresh(UIViewController *vc);    // 面板显示时刷新列表

@interface RYShellVC : UIViewController
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, assign) BOOL bottomMode;
@property (nonatomic, strong) UIViewController *resourcePane;   // 第 4 个面板（懒加载）
@end
