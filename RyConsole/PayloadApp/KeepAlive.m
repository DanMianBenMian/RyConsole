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

- (void)beginBgTask {
    UIApplication *app = [UIApplication sharedApplication];
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
    __weak RYKeepAlive *ws = self;
    self.bgTask = [app beginBackgroundTaskWithName:@"RyConsole.AutorunKeepAlive"
                                 expirationHandler:^{
        // 到期立刻换一个新的（无限续期；系统最终仍可能强收，音频才是主路径）
        RYKeepAlive *ss = ws;
        if (!ss) return;
        [ss beginBgTask];
    }];
}

- (void)endBgTask {
    if (self.bgTask == UIBackgroundTaskInvalid) return;
    [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
    self.bgTask = UIBackgroundTaskInvalid;
}

#pragma mark - 兜底脉冲

- (void)pulseOnce {
    if (!self.active) return;
    self.pulseCount++;

    NSError *err = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setActive:YES error:&err];              // 被通话/录音抢走后重新要回

    if (!self.player.isPlaying) {
        self.audioRestarts++;
        NSLog(@"[KeepAlive] 音频已停，重新拉起（第 %ld 次）", (long)self.audioRestarts);
        if (![self.player play]) {             // player 彻底废了就重建
            [self startAudio];
        }
    }
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        [self beginBgTask];
    }
}

#pragma mark - 系统通知

- (void)onAudioInterruption:(NSNotification *)n {
    if (!self.active) return;
    NSInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
    if (type == AVAudioSessionInterruptionTypeEnded) {
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&err];
        if (!self.player.isPlaying) [self.player play];
        NSLog(@"[KeepAlive] 音频中断结束，已恢复");
    }
}

- (void)onAudioRouteChange:(NSNotification *)n {
    if (!self.active) return;
    NSInteger why = [n.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
    if (why == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {   // 拔耳机等
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&err];
        if (!self.player.isPlaying) [self.player play];
    }
}

- (void)onEnterBackground:(NSNotification *)n {
    if (!self.active) return;
    [self beginBgTask];
    NSLog(@"[KeepAlive] 进入后台，保活态: %@", [self statusLine]);
}

- (void)onBecomeActive:(NSNotification *)n {
    if (!self.active) return;
    [self endBgTask];                       // 前台不需要续期，别白占
    if (!self.player.isPlaying) [self.player play];
}

@end
