#import <UIKit/UIKit.h>

// ============================================================================
// NoBgCPU —— 通用「斩后台」tweak（iOS 16 全集）
// 同一份 dylib 用 TrollFools 注入任意 App 即可（Filter 的 bundle 列表对 TF 无效，
// TF 是你自己选 App 注入的）。注入后把该 App 在 iOS 16 上所有「申请 / 保后台」的
// 运行时通道全部掐断，App 一切到后台系统立刻 suspend，零 CPU。
//
// iOS 16 全部可运行时钩的保活通道（下方 A~H 全列掉）：
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
//
// 运行时钩不到、只能改 App 的 Info.plist 的保活（注记，不在本 dylib 内）：
//   - UIBackgroundModes 里的 audio / voip / fetch / location / processing / bluetooth*
//     / remote-notification 是静态声明，系统启动即读，无 API 可运行时吊销。要彻底掐，
//     对目标 App 的 Info.plist 删掉对应 mode（Swiftgram 已做过）。这些多为音乐/导航/
//     VoIP 等「本就该有后台」的 App，一般保留。
//   - 静默推送 content-available 由系统 APNs 拉起，运行时钩不到（需删 plist 的
//     remote-notification 或关系统「后台 App 刷新」）。
// ============================================================================

static BOOL nb_isForeground(void) {
    UIApplication *app = [UIApplication sharedApplication];
    return app && [app applicationState] == UIApplicationStateActive;
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
