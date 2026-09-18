//
//  MainShell.h
//  RyConsole —— 新外壳（左侧栏 + 三板块：终端 / Autorun / 设置）
//

#import <UIKit/UIKit.h>

@interface RYShellVC : UIViewController
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, assign) BOOL bottomMode;
@end
