#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================================
// DisableBgKeepalive —— 通用「禁用后台保活」tweak（iOS 16 全集）
// 同一份 dylib 用 TrollFools 注入任意 App 即可（Filter 的 bundle 列表对 TF 无效，
// TF 是你自己选 App 注入的）。注入后把该 App 在 iOS 16 上所有「申请 / 保后台」的
// 运行时通道全部掐断，App 一切到后台系统立刻 suspend，零 CPU。
//
// iOS 16 全部可运行时钩的保活通道（下方 A~M 全列掉）：
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
//   [K] 推送唤醒即退 application:didReceiveRemoteNotification:fetchCompletionHandler:
//       —— 被任意推送在后台唤醒/拉起（非用户主动打开）→ 回 completion 并直接退出 App；
//          前台(Active)/点通知打开(Inactive) → 走原实现，不杀
//
// 「只要不是我主动拉起就退出」——两条通用判据，覆盖所有后台拉起场景：
//   [L] 冷启动判定：application:didFinishLaunchingWithOptions: /
//       UIApplicationDidFinishLaunchingNotification
//       —— 判据 1：启动时 applicationState == Background（系统后台拉起的启动，
//          用户点图标/点通知启动是 Inactive，绝不会误杀）
//       —— 判据 2：launchOptions 含系统拉起 key（位置变化 LocationKey、蓝牙变化
//          BluetoothCentrals/PeripheralsKey、后台拉取 BackgroundFetchKey、
//          后台传输 BackgroundSessionIdentifierKey、Newsstand）
//          注：LocalNotification / RemoteNotification / ShortcutItem / UserActivity
//          属用户主动打开，不列入
//   [M] 看门狗兜底：UIApplicationDidEnterBackgroundNotification
//       —— 退后台后 8s 宽限内若仍在后台运行（= 被任何保活通道吊着没被 suspend，
//          或被位置/网络/蓝牙事件唤醒在后台跑）→ 退出；回到前台自动取消
//       —— 正常 App 退后台几秒即 suspend，GCD 定时器被冻结永不触发，故不会误杀
//
// 运行时钩不到、只能改 App 的 Info.plist 的保活（注记，不在本 dylib 内）：
//   - UIBackgroundModes 里的 audio / voip / fetch / location / processing / bluetooth*
//     / remote-notification 是静态声明，系统启动即读，无 API 可运行时吊销。要彻底掐，
//     对目标 App 的 Info.plist 删掉对应 mode（Swiftgram 已做过）。这些多为音乐/导航/
//     VoIP 等「本就该有后台」的 App，一般保留。
//   - UIBackgroundModes 里若含 remote-notification，可由 strip 脚本一并删掉；
//     推送唤醒即退已由 [K] 在 dylib 内处理：App 在后台被任意推送唤醒/拉起时直接回 completion 并退出 App。
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

// ---------------------------------------------------------------------------
// 线程模型（不卡主线程）：
//   - 自建后台串行队列 nb_queue() 承担「延迟等待 / 状态再确认 / 兜底退出」，
//     主线程只承担最后一次 terminate 调用（立即杀进程，不构成卡顿）
//   - applicationState 用原子变量 nb_state 缓存：主线程写、后台线程读，
//     避免后台线程跨线程访问 UIKit
// ---------------------------------------------------------------------------
static dispatch_queue_t nb_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.huhansibuxin.disablebgkeepalive.q",
                                  dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                          QOS_CLASS_UTILITY, 0));
    });
    return q;
}

static void nb_syncState(void) {          // 只允许在主线程调用
    UIApplication *app = [UIApplication sharedApplication];
    nb_state = app ? (int32_t)[app applicationState] : -1;
}

static BOOL nb_isBackgroundState(void) {  // 任意线程可读
    return __sync_add_and_fetch(&nb_state, 0) == UIApplicationStateBackground;
}

// 退出 App：后台队列直接 exit(0)，全程不碰主线程、不等 runloop、不做清理。
// 不追求优雅退出，唯一目标是「绝不占用主线程一帧」。
static void nb_terminateApp(void) {
    dispatch_async(nb_queue(), ^{
        if (!nb_isBackgroundState()) return;   // 退出前最后一次确认：这瞬间你没把 App 切回前台
        exit(0);
    });
}

// 系统后台拉起的 launch key（不含用户点通知 / Handoff / Shortcut：那些是用户主动）
static BOOL nb_isBackgroundLaunchOptions(NSDictionary *opts) {
    if (opts.count == 0) return NO;
    static NSSet *bgKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bgKeys = [[NSSet alloc] initWithObjects:
                  @"UIApplicationLaunchOptionsLocationKey",                    // 位置变化
                  @"UIApplicationLaunchOptionsBluetoothCentralsKey",           // 蓝牙中心变化
                  @"UIApplicationLaunchOptionsBluetoothPeripheralsKey",        // 蓝牙外设变化
                  @"UIApplicationLaunchOptionsNewsstandDownloadsKey",
                  @"UIApplicationLaunchOptionsBackgroundFetchKey",             // 后台拉取
                  @"UIApplicationLaunchOptionsBackgroundSessionIdentifierKey", // 后台传输
                  nil];
    });
    for (NSString *k in bgKeys) {
        if (opts[k]) return YES;
    }
    return NO;
}

// [M] 看门狗：退后台 N 秒后若仍在后台运行 = 被保活吊着或被事件唤醒 → 退出
// 宽限 15s：正常 App 退后台到 suspend 通常 <5s（且 [A]~[K] 已掐断后台窗口，会更快），
// 留足安全边际，避免误杀正常退后台清理期；真正被保活吊住的才会触发。
#define NB_BG_GRACE_SEC 15.0
static volatile int32_t nb_wdToken = 0;

static void nb_cancelWatchdog(void) {
    __sync_fetch_and_add(&nb_wdToken, 1);
}

static void nb_armWatchdog(void) {
    int32_t token = __sync_add_and_fetch(&nb_wdToken, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NB_BG_GRACE_SEC * NSEC_PER_SEC)),
                   nb_queue(), ^{
        if (__sync_add_and_fetch(&nb_wdToken, 0) != token) return;  // 已取消或已重新 arm
        if (nb_isBackgroundState()) nb_terminateApp();
    });
}

// [L] 冷启动判定：系统后台拉起 → 延迟一点后在后台队列确认并退出
static void nb_handlePossibleBackgroundLaunch(NSDictionary *opts) {
    if (!nb_isBackgroundState() && !nb_isBackgroundLaunchOptions(opts)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   nb_queue(), ^{
        if (nb_isBackgroundState()) nb_terminateApp();
    });
}

typedef BOOL (*nb_dfl_imp)(id, SEL, UIApplication *, NSDictionary *);
static BOOL nb_replaced_didFinishLaunching(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) {
    BOOL ok = YES;
    Class cls = [self class];
    NSValue *v = objc_getAssociatedObject(cls, "nb_dfl_orig");
    if (v) {
        nb_dfl_imp orig = (nb_dfl_imp)[v pointerValue];
        ok = orig(self, _cmd, app, opts);
    }
    nb_syncState();
    nb_handlePossibleBackgroundLaunch(opts);
    return ok;
}

// [K] 推送唤醒即退：捕获 delegate 后运行时 swizzle 其回调
//  - applicationState == Background（被静默 / 带 content-available 的普通推送在后台唤醒或拉起，
//    非用户主动打开）→ 立即回 completion 并退出 App，杜绝后台保活
//  - 前台(Active) 或 点通知打开(Inactive) → 走原始实现，正常处理
//  原始 IMP 按 delegate 类存于关联对象，避免多 delegate 类互相串台
static void nb_replaced_didReceiveRemoteNotification(id self, SEL _cmd, UIApplication *app, NSDictionary *userInfo, void (^completion)(UIBackgroundFetchResult)) {
    nb_syncState();                       // 回调在主线程 → 顺手刷新状态缓存
    if (nb_isBackgroundState()) {
        // 被推送（静默 / 普通）在后台唤醒或拉起，非用户主动打开 → 退出 App
        // 退出流程全在后台队列：主线程这里只回 completion，不等待、不 sleep
        if (completion) completion(UIBackgroundFetchResultNoData);
        nb_terminateApp();
        return;
    }
    // 前台(Active) / 点通知打开(Inactive) → 走原实现，正常处理
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
            objc_setAssociatedObject(cls, "nb_silentpush_orig", [NSValue valueWithPointer:(void *)orig], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(cls, "nb_silentpush", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        // [L] 冷启动判定：系统后台拉起（位置/蓝牙/后台拉取/后台传输）→ 启动后退出
        SEL selL = @selector(application:didFinishLaunchingWithOptions:);
        Method mL = class_getInstanceMethod(cls, selL);
        Method mLSuper = class_getInstanceMethod(class_getSuperclass(cls), selL);
        if (mL && mL != mLSuper && ![objc_getAssociatedObject(cls, "nb_dfl") boolValue]) {
            IMP origL = method_getImplementation(mL);
            method_setImplementation(mL, (IMP)nb_replaced_didFinishLaunching);
            objc_setAssociatedObject(cls, "nb_dfl_orig", [NSValue valueWithPointer:(void *)origL], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(cls, "nb_dfl", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// ---------------------------------------------------------------------------
// %ctor：生命周期通知 → 维护状态缓存 + 装配 [L] 冷启动判定 / [M] 看门狗
// 通知回调只做 O(1) 写入与后台派发，不做任何等待或耗时操作
// ---------------------------------------------------------------------------
%ctor {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mq = [NSOperationQueue mainQueue];

    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:mq
                usingBlock:^(NSNotification *n) {
        nb_state = UIApplicationStateActive;
        nb_cancelWatchdog();
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
        nb_cancelWatchdog();
    }];

    // [L] 冷启动：系统后台拉起（位置/蓝牙/后台拉取/后台传输）→ 判定后退出
    [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:mq
                usingBlock:^(NSNotification *n) {
        nb_syncState();                                   // 冷启动唯一一次直读真实状态
        nb_handlePossibleBackgroundLaunch(n.userInfo);
    }];

    // [M] 看门狗：退后台 8s 后若仍在后台运行 = 被保活吊着或被事件唤醒 → 退出
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil
                     queue:mq
                usingBlock:^(NSNotification *n) {
        nb_state = UIApplicationStateBackground;
        nb_armWatchdog();
    }];
}
