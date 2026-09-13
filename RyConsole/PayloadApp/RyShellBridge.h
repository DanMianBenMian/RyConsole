//
//  RyShellBridge.h
//  RyConsole —— 外壳与 main.m 之间的最小桥
//

#import <UIKit/UIKit.h>

// 返回"经典界面"（旧的 InputVC + 导航栈），供设置页里按钮弹出，保留原有脚本/桥/修补功能。
UIViewController *RYMakeLegacyConsoleVC(void);
