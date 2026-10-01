#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================================
// DisableBgKeepalive —— 通用「禁用后台保活」tweak（iOS 16 全集）
// 同一份 dylib 用 TrollFools 注入任意 App 即可（Filter 的 bundle 列表对 TF 无效，
// TF 是你自己选 App 注入的）。注入后把该 App 在 iOS 16 上所有「申请 / 保后台」的
// 运行时通道全部掐断，App 一切到后台系统立刻 suspend，零 CPU。
//
// iOS 16 全部可运行时钩的保活通道（下方 A~J 全列掉）：
//   [A] UIApplication beginBackgroundTask*            —— 退后台骗来的后台窗口
//       （Swiftgram 的 Postbox TimeBasedCleanupScan 就是靠它烧 CPU）
//   [B] BGTaskScheduler submitTaskRequest:error:      —— iOS 13+ BackgroundTasks
//       框架（BGAppRefreshTask / BGProcessingTask），系统稍后把 App 拉回后台跑
//   [C] PKPushRegistry setDesiredPushTypes:/setDelegate: —— VoIP（PushKit）注册，
//       注册了才会被 VoIP 推送唤醒并在后台保活
//   [D] CLLocationManager startUpdating*/startMonitoring* —— 定位保活（配合 location 模式）
//   [E] UIApplication setMinimumBackgroundFetchInterval: —— 老式 Background Fetch
//   [F] CBCentralManager initWithDelegate:queue:options: —— 蓝牙后台恢复保活
//   [G] URLSessionConfiguration backgroundSessionConfigurationWithIdentifier:
//       —— 后台传输（走系统守护，不烧本 App CPU，但属保活，一并掐）
//   [H] HKHealthStore enableBackgroundDeliveryForType:frequency:withCompletion:
//       —— HealthKit 后台投递
//   [I] UIApplication setKeepAliveTimeout:handler:
//       —— 老式 VoIP 保活（iOS 9 起弃用，但很多 App 仍调，按固定间隔把 App 唤醒保活）
//   [J] CBPeripheralManager initWithDelegate:queue:options:
//       —— BLE 外设模式后台恢复保活（对应 UIBackgroundModes bluetooth-peripheral）
//
// == 本分支（no-autoexit）相对 main 的差异 ==
// 本分支**只保留「掐断后台保活通道」的主体**，删除了 main 上所有「自动退出」逻辑：
//   [K] 推送唤醒即退（后台被静默/普通推送唤醒 → 退出 App）      —— 已删
//   [L] 冷启动判定（系统后台拉起 → 启动后退出 App）             —— 已删
//   [M] 看门狗兜底（退后台 N 秒仍在后台运行 → 退出 App）        —— 已删
//   以及它们共用的 nb_terminateApp() / nb_isBackgroundState()  —— 已删
// 目的：用于「让 App 切后台后继续干它该干的事（如抖音后台放音频），但不再被后台
// 保活通道吊着烧 CPU」的场景。任何情况下都**不会主动杀 App**，App 的进出完全交还系统。
//
// 运行时钩不到、只能改 App 的 Info.plist 的保活（注记，不在本 dylib 内）：
//   - UIBackgroundModes 里的 audio / voip / fetch / location / processing / bluetooth*
//     / remote-notification 是静态声明，系统启动即读，无 API 可运行时吊销。要彻底掐，
//     对目标 App 的 Info.plist 删掉对应 mode（Swiftgram 已做过）。这些多为音乐/导航/
//     VoIP 等「本就该有后台」的 App，一般保留。
//   - **重要**：本插件不触碰 plist 的 audio mode，所以「后台继续放音频」（如抖音后台
//     播放声音）不受影响。若配合 strip_bg_modes.sh 使用，务必不要删目标 App 的 audio，
//     否则后台音频会一起消失。
// ============================================================================

// 应用状态原子缓存：主线程（通知 / delegate 回调）写，钩子路径只读。 -1 = 尚未刷新
static volatile int32_t nb_state = -1;

// 前台状态判定：读原子缓存 → 钩子热路径零 UIKit 调用、零 GCD 派发、零锁
static BOOL nb_isForeground(void) {
    int32_t s = __sync_add_and_fetch(&nb_state, 0);
    if (s >= 0) return s == UIApplicationStateActive;
    // 缓存尚未就绪（dylib 加载极早期）→ 一次性直读，之后全由通知刷新
    UIApplication *app = [UIApplication sharedApplication];
    return app && [app applicationState] == UIApplicationStateActive;
}

static void nb_syncState(void) {          // 只允许在主线程调用
    UIApplication *app = [UIApplication sharedApplication];
    nb_state = app ? (int32_t)[app applicationState] : -1;
}

// ---------------------------------------------------------------------------
// [A] 后台断言：退后台时直接不给窗口
// ---------------------------------------------------------------------------
%hook UIApplication

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler {
    if (!nb_isForeground()) {
        return UIBackgroundTaskInvalid;
    }
    return %orig;
}

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)taskName
                                        expirationHandler:(void (^)(void))handler {
    if (!nb_isForeground()) {
        return UIBackgroundTaskInvalid;
    }
    return %orig;
}

// [E] 后台拉取：永远关掉
- (void)setMinimumBackgroundFetchInterval:(NSTimeInterval)interval {
    %orig(UIApplicationBackgroundFetchIntervalNever);
}

// [I] 老式 VoIP 保活：直接丢弃，App 不再被周期性唤醒
- (void)setKeepAliveTimeout:(NSTimeInterval)timeout handler:(void (^)(void))handler {
    // 不调用 %orig：彻底关掉 legacy VoIP keepalive 定时器
}

%end

// ---------------------------------------------------------------------------
// [B] 现代 BackgroundTasks 框架：拒绝所有调度，系统不再拉 App 回后台
// ---------------------------------------------------------------------------
%hook BGTaskScheduler

- (BOOL)submitTaskRequest:(id)taskRequest error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"NoBgCPU"
                                      code:1
                                  userInfo:@{NSLocalizedDescriptionKey: @"background tasks disabled"}];
    }
    return NO;
}

%end

// ---------------------------------------------------------------------------
// [C] VoIP / PushKit：禁止注册，彻底断掉 VoIP 后台唤醒与保活
// ---------------------------------------------------------------------------
%hook PKPushRegistry

- (void)setDesiredPushTypes:(NSSet *)types {
    // 不调用 %orig，App 永远注册不上 VoIP 推送
}

- (void)setDelegate:(id)delegate {
    // 不调用 %orig
}

%end

// ---------------------------------------------------------------------------
// [D] 定位保活：不在前台时禁止开启任何定位监听
// ---------------------------------------------------------------------------
%hook CLLocationManager

- (void)startUpdatingLocation {
    if (!nb_isForeground()) return;
    %orig;
}

- (void)startUpdatingHeading {
    if (!nb_isForeground()) return;
    %orig;
}

- (void)startMonitoringSignificantLocationChanges {
    if (!nb_isForeground()) return;
    %orig;
}

- (void)startMonitoringVisits {
    if (!nb_isForeground()) return;
    %orig;
}

- (void)startMonitoringForRegion:(id)region {
    if (!nb_isForeground()) return;
    %orig;
}

%end

// ---------------------------------------------------------------------------
// [F] 蓝牙后台恢复保活：去掉恢复标识，App 退后台不再被蓝牙事件拉起
// ---------------------------------------------------------------------------
%hook CBCentralManager

- (instancetype)initWithDelegate:(id)delegate
                           queue:(dispatch_queue_t)queue
                         options:(NSDictionary *)options {
    if (!nb_isForeground()) {
        NSMutableDictionary *m = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        [m removeObjectForKey:@"kCBCentralManagerOptionRestoreIdentifierKey"];
        options = m;
    }
    return %orig(delegate, queue, options);
}

%end

// ---------------------------------------------------------------------------
// [G] 后台传输：返回默认（非后台）配置，系统守护不再代跑后台下载
// ---------------------------------------------------------------------------
%hook NSURLSessionConfiguration

+ (instancetype)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    return [NSURLSessionConfiguration defaultSessionConfiguration];
}

%end

// ---------------------------------------------------------------------------
// [H] HealthKit 后台投递：拒绝注册
// ---------------------------------------------------------------------------
%hook HKHealthStore

- (void)enableBackgroundDeliveryForType:(id)type
                               frequency:(NSInteger)frequency
                          withCompletion:(void (^)(BOOL, NSError *))completion {
    if (completion) {
        NSError *e = [NSError errorWithDomain:@"NoBgCPU"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"health background delivery disabled"}];
        completion(NO, e);
    }
}

%end

// ---------------------------------------------------------------------------
// [J] BLE 外设恢复保活：去掉恢复标识，App 退后台不再被蓝牙外设事件拉起
// ---------------------------------------------------------------------------
%hook CBPeripheralManager

- (instancetype)initWithDelegate:(id)delegate
                           queue:(dispatch_queue_t)queue
                         options:(NSDictionary *)options {
    if (!nb_isForeground()) {
        NSMutableDictionary *m = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        [m removeObjectForKey:@"kCBPeripheralManagerOptionRestoreIdentifierKey"];
        options = m;
    }
    return %orig(delegate, queue, options);
}

%end

// ---------------------------------------------------------------------------
// %ctor：生命周期通知 → 维护状态缓存
// 通知回调只做 O(1) 写入，不做任何等待或耗时操作。
// 本分支已删除全部「自动退出」（原 [K]/[L]/[M]）及其看门狗/退出派发，
// 这里只保留 nb_state 缓存维护 —— nb_isForeground() 依赖它做前台判定。
// ---------------------------------------------------------------------------
%ctor {
    // 初始刷新一次：dylib 可能在冷启动极早期加载，此后一直由通知维护。
    nb_syncState();

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mq = [NSOperationQueue mainQueue];

    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:mq
                usingBlock:^(NSNotification *n) {
        nb_state = UIApplicationStateActive;
    }];

    [nc addObserverForName:UIApplicationWillResignActiveNotification
                    object:nil
                     queue:mq
                usingBlock:^(NSNotification *n) {
        nb_state = UIApplicationStateInactive;
    }];

    [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                    object:nil
                     queue:mq
                usingBlock:^(NSNotification *n) {
        nb_state = UIApplicationStateInactive;
    }];

    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil
                     queue:mq
                usingBlock:^(NSNotification *n) {
        nb_state = UIApplicationStateBackground;
    }];
}
