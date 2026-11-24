#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface SpringBoard : UIApplication
@end

// ============================================================================
// 方案 v7：彻底消除「闹钟胶囊闪现」
//
// 问题：v6 用 250ms 定时器轮询，闹钟容器出现后要等下一轮扫描才被隐藏，
//       这 250ms 空窗就是用户看到的闪现（且会挤压大时钟布局）。
//
// 解决：双保险，从「事后补救」改为「出现前拦截」
//   1) 运行时 method swizzling：一旦 CSAdjunctItemView 类加载进内存，立即替换它的
//      setHidden: / didMoveToWindow: / layoutSubviews，强制永远 hidden=YES + alpha=0。
//      这样系统每次想显示胶囊（开睡眠模式时），在视图进入窗口/布局的第一时间就被压住，
//      根本来不及渲染 —— Zero flicker。
//   2) 20ms 高频定时器遍历作为兜底，隐藏任何漏网的远程视图实例。
//
// 说明：不直接 %hook CSAdjunctItemView 是因为 CoverSheetKit 私有类在 tweak 注入时
//       可能尚未加载，%hook 会静默失效。改用 objc_getClass 检测到类后再动态 swizzle，
//       保证类存在时一定生效。
// ============================================================================

static NSString *const AxsLogPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";
static dispatch_source_t AxsTimer = nil;
static BOOL AxsSwizzled = NO;
static BOOL AxsDidHide = NO;
static int AxsTickCount = 0;

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

// —— 被 swizzle 的方法实现 ——

// 无论系统传 YES/NO，一律强制隐藏（调用原始实现确保 layer 真正隐藏）
static void AxsForcedSetHidden(id self, SEL _cmd, BOOL hidden) {
    if (AxsOrigSetHidden) AxsOrigSetHidden(self, _cmd, YES);
}

// 视图加入窗口的第一时间就隐藏（在布局/渲染之前）
static void AxsForcedDidMove(id self, SEL _cmd) {
    if (AxsOrigDidMove) AxsOrigDidMove(self, _cmd);
    AxsForceHideView((UIView *)self);
}

// 每次布局后立即隐藏，防止被系统重新显示
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

// 在类上覆盖一个方法：保存原实现（自身或父类的）到 origOut，再换成 newImp
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

// 一旦 CSAdjunctItemView 类出现，立即安装 swizzle
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
    AxsLog(@"=== swizzle installed on CSAdjunctItemView ===");
}

// —— 兜底：高频遍历隐藏远程视图 ——

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

static void AxsTick(void) {
    AxsTickCount++;

    // 每轮都尝试安装 swizzle（类可能是懒加载，晚一点才出现）
    AxsInstallSwizzleIfReady();

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
    if (hidden > 0 && !AxsDidHide) {
        AxsDidHide = YES;
        AxsLog([NSString stringWithFormat:@"=== first hide tick=%d views=%d ===",
                AxsTickCount, hidden]);
    }
}

static void AxsStartTimer(void) {
    if (AxsTimer) return;
    AxsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                      dispatch_get_main_queue());
    dispatch_source_set_timer(AxsTimer,
                              dispatch_walltime(NULL, 0),
                              20 * NSEC_PER_MSEC,   // 每 20ms（兜底，swizzle 是主力）
                              5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(AxsTimer, ^{
        AxsTick();
    });
    dispatch_resume(AxsTimer);
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    [@"" writeToFile:AxsLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    AxsLog(@"=== tweak v7 loaded (swizzle + fast scan) ===");
    // 尽早启动，1 秒后（原本 3 秒太晚，闪现就发生在这段时间）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        AxsStartTimer();
    });
}

%end
