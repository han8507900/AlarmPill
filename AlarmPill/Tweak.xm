#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface SpringBoard : UIApplication
@end

// ============================================================================
// 方案 v8：零轮询省电版
//
// v7 的问题：20ms 定时器永久运行，每秒 50 次全树遍历，主线程持续占用、耗电。
//
// 核心认知：真正消除闪现的是 swizzle（事件驱动、零开销），定时器只是
//           「等懒加载类出现以便装 swizzle」的临时手段。swizzle 一旦装好，
//           定时器就是纯冗余 —— 应当立即停止。
//
// v8 做法：
//   1) 低频探测定时器（1 秒）仅在启动初期等待 CSAdjunctItemView 类加载；
//   2) 检测到类 → 装 swizzle → 【立刻 stop 定时器】，之后零轮询；
//   3) 保留「锁屏完成」Darwin 通知，仅在该事件触发时做一次性兜底扫描
//      （防止极端懒加载时序下 swizzle 漏装），不是持续轮询；
//   4) swizzle 主力：视图 setHidden:/didMoveToWindow:/layoutSubviews 时强制隐藏，
//      事件驱动、平时 CPU 开销为零。
//
// 结果：解锁后日常使用、锁屏静止期间 —— 插件不扫描、不耗电。
// ============================================================================

static NSString *const AxsLogPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";
static dispatch_source_t AxsProbeTimer = nil;   // 仅用于等待类加载，装好 swizzle 后立即停止
static BOOL AxsSwizzled = NO;
static BOOL AxsLogged = NO;
static int AxsScanCount = 0;

// 原始实现保存
static void (*AxsOrigSetHidden)(id, SEL, BOOL) = NULL;
static void (*AxsOrigDidMove)(id, SEL) = NULL;
static void (*AxsOrigLayout)(id, SEL) = NULL;

static void AxsLog(NSString *line) {
    NSString *s = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AxsLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [s writeToFile:AxsLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static void AxsForceHideView(UIView *v) {
    if (!v) return;
    if (!v.hidden) v.hidden = YES;
    if (v.alpha > 0.0) v.alpha = 0.0;
    v.userInteractionEnabled = NO;
}

// —— 被 swizzle 的方法实现（事件驱动，零轮询）——

static void AxsForcedSetHidden(id self, SEL _cmd, BOOL hidden) {
    if (AxsOrigSetHidden) AxsOrigSetHidden(self, _cmd, YES);
}

static void AxsForcedDidMove(id self, SEL _cmd) {
    if (AxsOrigDidMove) AxsOrigDidMove(self, _cmd);
    AxsForceHideView((UIView *)self);
}

static void AxsForcedLayout(id self, SEL _cmd) {
    if (AxsOrigLayout) AxsOrigLayout(self, _cmd);
    AxsForceHideView((UIView *)self);
}

// 判断类自身是否实现了某方法（不含继承）
static BOOL AxsClassOwnsMethod(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { own = YES; break; }
    }
    free(list);
    return own;
}

static void AxsOverrideMethod(Class cls, SEL sel, IMP newImp, void **origOut) {
    if (AxsClassOwnsMethod(cls, sel)) {
        Method own = class_getInstanceMethod(cls, sel);
        *origOut = (void *)method_getImplementation(own);
        method_setImplementation(own, newImp);
    } else {
        Method inherited = class_getInstanceMethod(class_getSuperclass(cls), sel);
        if (inherited) {
            *origOut = (void *)method_getImplementation(inherited);
            class_addMethod(cls, sel, newImp, method_getTypeEncoding(inherited));
        }
    }
}

// ★ 省电关键：停止探测定时器（异步 cancel，避免在 handler 内取消自身）
static void AxsStopProbeTimer(void) {
    if (!AxsProbeTimer) return;
    dispatch_source_t t = AxsProbeTimer;
    AxsProbeTimer = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_source_cancel(t);
    });
}

// —— 一次性兜底扫描（只在锁屏事件触发，非轮询）——

static BOOL AxsIsTarget(NSString *cls) {
    return [cls isEqualToString:@"CSAdjunctItemView"] ||
           [cls isEqualToString:@"CSRemoteContentInlineView"] ||
           [cls isEqualToString:@"_UIRemoteView"];
}

static int AxsHideTree(UIView *v) {
    int n = 0;
    if (AxsIsTarget(NSStringFromClass([v class]))) {
        if (!v.hidden) { v.hidden = YES; n++; }
        if (v.alpha > 0.0) v.alpha = 0.0;
        v.userInteractionEnabled = NO;
    }
    for (UIView *sub in v.subviews) {
        n += AxsHideTree(sub);
    }
    return n;
}

static void AxsScanOnce(void) {
    AxsScanCount++;
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *cover = nil;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.hidden) continue;
            NSString *wc = NSStringFromClass([w class]);
            if ([wc rangeOfString:@"CoverSheet"].location != NSNotFound) {
                cover = w;
                break;
            }
        }
        if (cover) break;
    }
    if (!cover) return;
    int hidden = AxsHideTree(cover);
    if (!AxsLogged) {
        AxsLogged = YES;
        AxsLog([NSString stringWithFormat:@"=== one-shot scan#%d hidden=%d ===",
                AxsScanCount, hidden]);
    }
}

// 一旦 CSAdjunctItemView 类出现，装 swizzle 并立即停掉定时器
static void AxsInstallSwizzleIfReady(void) {
    if (AxsSwizzled) return;
    Class cls = objc_getClass("CSAdjunctItemView");
    if (!cls) return;

    AxsOverrideMethod(cls, @selector(setHidden:), (IMP)AxsForcedSetHidden,
                      (void **)&AxsOrigSetHidden);
    AxsOverrideMethod(cls, @selector(didMoveToWindow), (IMP)AxsForcedDidMove,
                      (void **)&AxsOrigDidMove);
    AxsOverrideMethod(cls, @selector(layoutSubviews), (IMP)AxsForcedLayout,
                      (void **)&AxsOrigLayout);

    AxsSwizzled = YES;
    AxsLog(@"=== swizzle installed -> scan timer STOPPED (zero polling) ===");
    AxsStopProbeTimer();   // ★ 装好即停，之后不再有任何持续扫描
}

// 低频探测定时器：仅在启动初期等待懒加载类出现
static void AxsStartProbe(void) {
    if (AxsProbeTimer || AxsSwizzled) return;
    AxsProbeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           dispatch_get_main_queue());
    dispatch_source_set_timer(AxsProbeTimer,
                              dispatch_walltime(NULL, 0),
                              1 * NSEC_PER_SEC,   // 1 秒一次，开销可忽略
                              500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(AxsProbeTimer, ^{
        AxsInstallSwizzleIfReady();   // 内部装好后会 stop 自己
    });
    dispatch_resume(AxsProbeTimer);
}

// 锁屏完成事件：一次性兜底（非持续轮询）
static void AxsOnLockComplete(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object,
                              CFDictionaryRef userInfo) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AxsInstallSwizzleIfReady();
        if (AxsSwizzled) AxsScanOnce();
    });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    [@"" writeToFile:AxsLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    AxsLog(@"=== tweak v8 loaded (zero-poll) ===");

    // 注册锁屏通知：仅在锁屏那一刻做一次性兜底
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &AxsOnLockComplete,
        CFSTR("com.apple.springboard.lockcomplete"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 1 秒后启动低频探测，等待懒加载类出现（装好 swizzle 即停）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        AxsStartProbe();
    });
}

%end
