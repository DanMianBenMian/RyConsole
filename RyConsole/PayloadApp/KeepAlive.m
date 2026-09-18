//
//  KeepAlive.m
//  RyConsole —— 监听期后台保活（V2.2）
//
//  设计要点（自签 IPA 场景下的"能拖多久拖多久"）：
//   · 主路径：静音音频循环保活。AVAudioSession(category=playback) 一旦激活且
//     有正在播放的音频，进程就不会被系统挂起；UIBackgroundModes=audio 声明在
//     Info.plist 里，个人开发者签名同样生效，不需要额外 entitlement。
//   · 辅路径：beginBackgroundTaskWithName 无限续期（定时器每 8s 换一个新的），
//     在音频被系统打断的窗口里兜住，避免直接进 suspended。
//   · 兜底：周期性重新 setActive:YES，处理"被录音/通话/其它 App 抢走音频会话"
//     以及路由变化（拔耳机）导致 playback 被中断的情况。
//   · 音频样本用 ±4/32767(≈ -78 dBFS) 的 1kHz 正弦，而不是绝对静音：
//     历史上系统对"全零样本"轨道的保活判定不稳定；留 1 个 LSB 级别的真实样本
//     最稳，这个幅度人耳在任何音量下都听不见。
//   · 不打扰用户：options 带 MixWithOthers，用户自己在放歌/播客不会被掐断。
//
//  线程约定：begin/end 内部自行切主线程（定时器、UIApplication 都在主线程用）。
//

#import "KeepAlive.h"
#import "LiveActivityBridge.h"   // 脉冲里给灵动岛续保鲜期（ryLiveActivityTouch）

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <stdlib.h>

#define RY_KA_PULSE_SEC   8.0     // 兜底脉冲周期
#define RY_KA_WAV_SECONDS 2       // 循环音频时长

#pragma mark - 极低幅度正弦 WAV（内存里现造，不带任何资源文件）

static NSData *ryKeepAliveWavData(void) {
    const int32_t rate    = 8000;
    const int32_t frames  = rate * RY_KA_WAV_SECONDS;
    const int32_t dataLen = frames * 2;          // 16-bit 单声道
    const int16_t channels = 1, bits = 16;
    const int32_t fmtSize = 16, riffSize = 36 + dataLen, subSize = dataLen;
    const int32_t byteRate = rate * channels * bits / 8;
    const int16_t blockAlign = channels * bits / 8;
    const int16_t pcmFmt = 1;

    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataLen];
    [d appendBytes:"RIFF" length:4];
    [d appendBytes:&riffSize length:4];
    [d appendBytes:"WAVEfmt " length:8];
    [d appendBytes:&fmtSize length:4];
    [d appendBytes:&pcmFmt length:2];
    [d appendBytes:&channels length:2];
    [d appendBytes:&rate length:4];
    [d appendBytes:&byteRate length:4];
    [d appendBytes:&blockAlign length:2];
    [d appendBytes:&bits length:2];
    [d appendBytes:"data" length:4];
    [d appendBytes:&subSize length:4];

    int16_t *pcm = (int16_t *)calloc((size_t)frames, sizeof(int16_t));
    if (!pcm) return d;                          // 退化：只有头部，player 会失败 → 走 bgTask 兜底
    for (int32_t i = 0; i < frames; i++) {
        double t = (double)i / (double)rate;
        double v = 4.0 * sin(2.0 * M_PI * 1000.0 * t);
        pcm[i] = (int16_t)lrint(v);
    }
    [d appendBytes:pcm length:(NSUInteger)dataLen];
    free(pcm);
    return d;
}

#pragma mark -

@interface RYKeepAlive ()
@property (nonatomic, assign) BOOL active;
@property (nonatomic, copy)   NSString *reason;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *pulse;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
/// 是否"确实持有"一个有效的后台任务。
/// ★ 不能只靠 bgTask != UIBackgroundTaskInvalid 判断：任务被系统回收/过期后，
///   标识符本身不会变 0，重复对它调 endBackgroundTask: 会让系统抛异常 → App 崩。
///   之前"从灵动岛切回 App 就崩"就是这个竞态（onBecomeActive 收尾时重复 end）。
@property (nonatomic, assign) BOOL hasBgTask;
@property (nonatomic, assign) BOOL pulsing;
@property (nonatomic, assign) NSInteger pulseCount;
@property (nonatomic, assign) NSInteger audioRestarts;
@end

@implementation RYKeepAlive

+ (instancetype)shared {
    static RYKeepAlive *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RYKeepAlive alloc] init]; });
    return s;
}

- (id)init {
    self = [super init];
    if (self) {
        _active = NO;
        _reason = @"";
        _bgTask = UIBackgroundTaskInvalid;
        _hasBgTask = NO;
        _pulsing = NO;
        _pulseCount = 0;
        _audioRestarts = 0;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onAudioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(onAudioRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
        [nc addObserver:self selector:@selector(onEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        NSLog(@"[KeepAlive] 已加载");
    }
    return self;
}

#pragma mark - 对外

- (void)begin:(NSString *)reason {
    if (![NSThread isMainThread]) {
        __weak RYKeepAlive *ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws begin:reason]; });
        return;
    }
    if (self.active) { [self pulseOnce]; return; }

    self.active = YES;
    self.reason = reason ?: @"";
    self.pulseCount = 0;
    self.audioRestarts = 0;

    BOOL audioOK = [self startAudio];
    NSLog(@"[KeepAlive] 启动保活(理由=%@) 音频=%@", self.reason, audioOK ? @"OK" : @"FAIL");

    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        [self beginBgTask];
    }

    [self.pulse invalidate];
    self.pulse = [NSTimer timerWithTimeInterval:RY_KA_PULSE_SEC target:self selector:@selector(pulseOnce) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pulse forMode:NSRunLoopCommonModes];
}

- (void)end {
    if (![NSThread isMainThread]) {
        __weak RYKeepAlive *ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws end]; });
        return;
    }
    if (!self.active) return;
    self.active = NO;
    NSLog(@"[KeepAlive] 释放保活（音频重启 %ld 次）", (long)self.audioRestarts);

    [self.pulse invalidate];
    self.pulse = nil;

    [self.player stop];
    self.player = nil;

    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:&err];

    [self endBgTask];
}

- (NSString *)statusLine {
    if (!self.active) return @"保活: 关";
    return [NSString stringWithFormat:@"保活: 开(音频%@ 重启%ld 续期%ld)",
            self.player.isPlaying ? @"√" : @"×", (long)self.audioRestarts, (long)self.pulseCount];
}

- (NSString *)statusJSON {
    NSDictionary *d = @{ @"active": @(self.active),
                         @"reason": self.reason ?: @"",
                         @"audioPlaying": @(self.player.isPlaying),
                         @"audioRestarts": @(self.audioRestarts),
                         @"bgTaskRenewals": @(self.pulseCount),
                         @"background": @([UIApplication sharedApplication].applicationState == UIApplicationStateBackground),
                         @"status": [self statusLine] };
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    return j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
}

#pragma mark - 音频

- (BOOL)startAudio {
    NSError *err = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    // MixWithOthers：用户自己在听歌/播客时不被我们打断
    [s setCategory:AVAudioSessionCategoryPlayback
              mode:AVAudioSessionModeDefault
           options:AVAudioSessionCategoryOptionMixWithOthers
             error:&err];
    [s setActive:YES error:&err];

    self.player = [[AVAudioPlayer alloc] initWithData:ryKeepAliveWavData() error:&err];
    if (!self.player) {
        NSLog(@"[KeepAlive] AVAudioPlayer 初始化失败: %@", err.localizedDescription);
        return NO;
    }
    self.player.numberOfLoops = -1;
    self.player.volume = 1.0;       // 样本本身已≈不可闻，音量不必再压
    [self.player prepareToPlay];
    return [self.player play];
}

#pragma mark - 后台任务（★ 全部在主线程串行处理，绝不允许重复 end）

- (void)beginBgTask {
    if (![NSThread isMainThread]) {
        __weak RYKeepAlive *ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws beginBgTask]; });
        return;
    }
    [self endBgTask];                       // 先安全收尾旧的（内部自带有效性判断）

    UIApplication *app = [UIApplication sharedApplication];
    __weak RYKeepAlive *ws = self;
    UIBackgroundTaskIdentifier tid =
        [app beginBackgroundTaskWithName:@"RyConsole.AutorunKeepAlive"
                       expirationHandler:^{
        // 到期回调跑在系统线程。★ 绝不在回调里直接 end/begin（会重复 end 已失效的 task → 抛异常）。
        // 只把状态交给主线程，由主线程决定是否再要一个。
        dispatch_async(dispatch_get_main_queue(), ^{
            RYKeepAlive *ss = ws;
            if (!ss) return;
            ss.hasBgTask = NO;              // 系统已收走它，flag 先清（关键：防止之后重复 end）
            ss.bgTask = UIBackgroundTaskInvalid;
            if (ss.active) [ss beginBgTask];  // 还在监听就无限续期
        });
    }];

    if (tid == UIBackgroundTaskInvalid) {
        self.hasBgTask = NO;
        self.bgTask = UIBackgroundTaskInvalid;
    } else {
        self.hasBgTask = YES;
        self.bgTask = tid;
    }
}

- (void)endBgTask {
    if (![NSThread isMainThread]) {
        __weak RYKeepAlive *ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws endBgTask]; });
        return;
    }
    // 先清 flag 再调 end：保证任何重入路径都不会对同一个 task end 两次
    if (!self.hasBgTask || self.bgTask == UIBackgroundTaskInvalid) {
        self.hasBgTask = NO;
        self.bgTask = UIBackgroundTaskInvalid;
        return;
    }
    UIBackgroundTaskIdentifier tid = self.bgTask;
    self.hasBgTask = NO;
    self.bgTask = UIBackgroundTaskInvalid;
    @try {
        [[UIApplication sharedApplication] endBackgroundTask:tid];
    } @catch (NSException *e) {
        NSLog(@"[KeepAlive] endBackgroundTask 异常（已吞）: %@", e.reason);
    }
}

#pragma mark - 兜底脉冲

- (void)pulseOnce {
    if (![NSThread isMainThread]) {
        __weak RYKeepAlive *ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws pulseOnce]; });
        return;
    }
    if (!self.active || self.pulsing) return;   // pulsing：防重入（音频重建可能触发通知回调）
    self.pulsing = YES;
    @try {
        self.pulseCount++;

        NSError *err = nil;
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setActive:YES error:&err];           // 被通话/录音抢走后重新要回

        if (!self.player.isPlaying) {
            self.audioRestarts++;
            NSLog(@"[KeepAlive] 音频已停，重新拉起（第 %ld 次）", (long)self.audioRestarts);
            if (![self.player play]) {          // player 彻底废了就重建
                [self startAudio];
            }
        }
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
            [self beginBgTask];
        }
        // 每 ~6 分钟给灵动岛续一次保鲜期（数字不动），避免"还在监听却被标成陈旧"
        if (self.pulseCount % 45 == 0) ryLiveActivityTouch();
    } @catch (NSException *e) {
        NSLog(@"[KeepAlive] pulse 异常（已吞）: %@", e.reason);
    }
    self.pulsing = NO;
}

#pragma mark - 系统通知

// ★ 这些通知可能来自任意线程、且可能在 App 状态切换的中间态触发；
//   一律 @try 兜底 + 状态校验，绝不让它把 App 带崩。
- (void)onAudioInterruption:(NSNotification *)n {
    if (!self.active) return;
    @try {
        NSInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
        if (type == AVAudioSessionInterruptionTypeEnded) {
            NSError *err = nil;
            [[AVAudioSession sharedInstance] setActive:YES error:&err];
            if (!self.player.isPlaying) [self.player play];
            NSLog(@"[KeepAlive] 音频中断结束，已恢复");
        }
    } @catch (NSException *e) { NSLog(@"[KeepAlive] interruption 异常（已吞）: %@", e.reason); }
}

- (void)onAudioRouteChange:(NSNotification *)n {
    if (!self.active) return;
    @try {
        NSInteger why = [n.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
        if (why == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {   // 拔耳机等
            NSError *err = nil;
            [[AVAudioSession sharedInstance] setActive:YES error:&err];
            if (!self.player.isPlaying) [self.player play];
        }
    } @catch (NSException *e) { NSLog(@"[KeepAlive] routeChange 异常（已吞）: %@", e.reason); }
}

- (void)onEnterBackground:(NSNotification *)n {
    if (!self.active) return;
    @try {
        [self beginBgTask];
        NSLog(@"[KeepAlive] 进入后台，保活态: %@", [self statusLine]);
    } @catch (NSException *e) { NSLog(@"[KeepAlive] enterBackground 异常（已吞）: %@", e.reason); }
}

- (void)onBecomeActive:(NSNotification *)n {
    if (!self.active) return;
    @try {
        [self endBgTask];                   // 前台不需要续期，别白占
        if (!self.player.isPlaying) [self.player play];
    } @catch (NSException *e) { NSLog(@"[KeepAlive] becomeActive 异常（已吞）: %@", e.reason); }
}

@end
