#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================================
// DisableBgKeepalive —— 通用「禁用后台保活」tweak（iOS 16 全集）
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
//   [I] UIApplication setKeepAliveTimeout:handler:
//       —— 老式 VoIP 保活（iOS 9 起弃用，但很多 App 仍调，按固定间隔把 App 唤醒保活）
//   [J] CBPeripheralManager initWithDelegate:queue:options:
//       —— BLE 外设模式后台恢复保活（对应 UIBackgroundModes bluetooth-peripheral）
//   [K] 静默推送 application:didReceiveRemoteNotification:fetchCompletionHandler:
//       —— 非前台收到 content-available 推送（被拉起/唤醒）→ 回 completion 并直接退出 App；
//          前台收到 → 走原实现，不杀
//
// 运行时钩不到、只能改 App 的 Info.plist 的保活（注记，不在本 dylib 内）：
//   - UIBackgroundModes 里的 audio / voip / fetch / location / processing / bluetooth*
//     / remote-notification 是静态声明，系统启动即读，无 API 可运行时吊销。要彻底掐，
//     对目标 App 的 Info.plist 删掉对应 mode（Swiftgram 已做过）。这些多为音乐/导航/
//     VoIP 等「本就该有后台」的 App，一般保留。
//   - UIBackgroundModes 里若含 remote-notification，可由 strip 脚本一并删掉；
//     静默推送的运行时回调已由 [K] 在 dylib 内处理：非前台收到直接回 completion 并退出 App。
// ============================================================================

static BOOL nb_isForeground(void) {
    UIApplication *app = [UIApplication sharedApplication];
    return app && [app applicationState] == UIApplicationStateActive;
}

// [K] 静默推送：捕获 delegate 后运行时 swizzle 其回调
//  - 不在前台（被静默推送拉起/唤醒，非用户主动打开）→ 立即回 completion 并退出 App，杜绝后台保活
//  - 前台收到 → 走原始实现，正常处理
//  原始 IMP 按 delegate 类存于关联对象，避免多 delegate 类互相串台
static void nb_replaced_didReceiveRemoteNotification(id self, SEL _cmd, UIApplication *app, NSDictionary *userInfo, void (^completion)(UIBackgroundFetchResult)) {
    if (!nb_isForeground()) {
        if (completion) completion(UIBackgroundFetchResultNoData);
        NSDictionary *aps = userInfo[@"aps"];
        BOOL isSilent = ([aps[@"content-available"] isEqual:@1] ||
                         [userInfo[@"content-available"] isEqual:@1]);
        if (isSilent) {
            // 静默推送拉起的：延迟一小会儿确保 completion 已处理，再退出 App
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!nb_isForeground()) {           // 退出前再确认一次：这瞬间用户没主动打开
                    SEL term = NSSelectorFromString(@"terminateWithSuccess");
                    if ([app respondsToSelector:term]) [app performSelector:term];
                    else exit(0);
                }
            });
        }
        return;
    }
    Class cls = [self class];
    NSValue *v = objc_getAssociatedObject(cls, "nb_silentpush_orig");
    if (v) {
        void (*orig)(id, SEL, UIApplication *, NSDictionary *, void (^)(UIBackgroundFetchResult)) =
            (void (*)(id, SEL, UIApplication *, NSDictionary *, void (^)(UIBackgroundFetchResult)))[v pointerValue];
        orig(self, _cmd, app, userInfo, completion);
    }
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

// [K] 静默推送：捕获 delegate 后运行时 swizzle 其
//     application:didReceiveRemoteNotification:fetchCompletionHandler:，
//     不在前台时立即回 completion，App 借不到后台运行时
- (void)setDelegate:(id)delegate {
    %orig;
    if (delegate) {
        SEL sel = @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:);
        Class cls = [delegate class];
        Method m = class_getInstanceMethod(cls, sel);
        Method mSuper = class_getInstanceMethod(class_getSuperclass(cls), sel);
        if (m && m != mSuper && ![objc_getAssociatedObject(cls, "nb_silentpush") boolValue]) {
            IMP orig = method_getImplementation(m);
            method_setImplementation(m, (IMP)nb_replaced_didReceiveRemoteNotification);
            objc_setAssociatedObject(cls, "nb_silentpush_orig", [NSValue valueWithPointer:orig], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(cls, "nb_silentpush", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
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
