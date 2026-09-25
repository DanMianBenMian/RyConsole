//
//  RySecurityPane.h
//  RyConsole —— 第 5 个面板「权限与安全」（V2.4）
//
//  四个小分类：
//    ① 权限诊断：逐项实测 entitlement / 能力，正常显示"可用"，否则给"禁用"和原因（V2.4.13 起完全动态，不写死表单）
//    ② 安全    ：命令可用性开关（默认全启用），高危命令带提示；禁用后被调用会弹权限确认
//    ③ 日志    ：顶部计数（高危 x 次 / 一般 n 次），下方列表可筛选，高危红、一般绿
//    ④ 环境    ：身份（UID / 组）+ 环境是否干净 + 一键重置；网络（热点 / 移动数据）接口与自动运行服务器开关（V2.4.13 新增）
//

#import <UIKit/UIKit.h>

UIViewController *RYMakeSecurityPane(void);      // 外壳内嵌面板（与资源管理器同一套路）
void RYSecurityPaneRefresh(UIViewController *vc); // 每次进入面板时刷新

@interface RYSecurityPaneVC : UIViewController
@end
