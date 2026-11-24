#import <UIKit/UIKit.h>

@interface SpringBoard : UIApplication
@end

// ============================================================================
// 方案 v6：精准隐藏「锁屏时间下方的闹钟胶囊」
//
// 真机 dump 实锤的视图结构（9 次扫描一致）：
//   CSProminentTimeView          大时间
//   CSProminentSubtitleDateView  日期
//   CSAdjunctItemView f=(0,214,393,65)   ★ 时间下方的附属项容器
//     PLPlatterView
//       CSRemoteContentInlineView
//         _UIRemoteView          ★ 远程视图，闹钟文字 07:24 在别的进程渲染
//
// 关键结论：胶囊内容走 _UIRemoteView（跨进程），所以遍历 SpringBoard 视图树
//   永远扫不到 "07:24" 这个文字 —— 这就是之前十几轮全部扑空的根本原因。
//   正确做法是隐藏 SpringBoard 侧的容器 CSAdjunctItemView 本身。
//
// 策略：hook 必定存在的 SpringBoard，用主队列 GCD 定时器持续扫描，
//   找到 CSAdjunctItemView 直接 hidden。用 GCD 而非 NSTimer 是因为
//   NSTimer 在锁屏/滚动切到 UITrackingRunLoopMode 后会暂停。
//   每 0.25s 重复设置，防止系统布局把它重新显示出来。
//   只碰 CSAdjunctItemView 及其远程子视图，绝对不动时间/日期视图。
// ============================================================================

static NSString *const AxsLogPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";
static dispatch_source_t AxsTimer = nil;
static BOOL AxsDidHide = NO;
static BOOL AxsDidFirstDiag = NO;
static int AxsTickCount = 0;

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

// 是否是需要隐藏的附属项/远程视图容器
static BOOL AxsIsTarget(NSString *cls) {
    return [cls isEqualToString:@"CSAdjunctItemView"] ||
           [cls isEqualToString:@"CSRemoteContentInlineView"] ||
           [cls isEqualToString:@"_UIRemoteView"];
}

// 诊断用的关键词：即使没命中，也把相关的类名记录下来供收敛
static BOOL AxsDiagKeyword(NSString *cls) {
    NSString *low = [cls lowercaseString];
    return [low rangeOfString:@"adjunct"].location != NSNotFound ||
           [low rangeOfString:@"remote"].location != NSNotFound ||
           [low rangeOfString:@"platter"].location != NSNotFound ||
           [low rangeOfString:@"inline"].location != NSNotFound;
}

// 递归隐藏附属项容器及其内部的远程视图；返回本次隐藏的数量
static int AxsHideAdjunct(UIView *v, NSMutableString *diag) {
    int n = 0;
    NSString *cls = NSStringFromClass([v class]);

    BOOL isTarget = AxsIsTarget(cls);

    if (isTarget || AxsDiagKeyword(cls)) {
        CGRect f = [v convertRect:v.bounds toView:nil];
        [diag appendFormat:@"%@ %@ f=(%.0f,%.0f,%.0f,%.0f) aLabel='%@'\n",
            isTarget ? @"HIT " : @"see ", cls,
            f.origin.x, f.origin.y, f.size.width, f.size.height,
            v.accessibilityLabel ?: @""];
    }

    if (isTarget) {
        if (!v.hidden) { v.hidden = YES; n++; }
        if (v.alpha > 0.0) v.alpha = 0.0;
        v.userInteractionEnabled = NO;
    }

    for (UIView *sub in v.subviews) {
        n += AxsHideAdjunct(sub, diag);
    }
    return n;
}

static void AxsTick(void) {
    AxsTickCount++;
    UIApplication *app = [UIApplication sharedApplication];

    // 找到可见的锁屏窗口
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

    NSMutableString *diag = [NSMutableString string];
    int hidden = AxsHideAdjunct(cover, diag);

    // 首次扫描写一次诊断快照（无论是否命中），供失败时收敛类名
    if (!AxsDidFirstDiag) {
        AxsDidFirstDiag = YES;
        AxsLog(@"=== FIRST SCAN DIAG ===");
        AxsLog(diag.length ? diag : @"(no adjunct/remote/platter/inline view found)");
    }

    if (hidden > 0 && !AxsDidHide) {
        AxsDidHide = YES;
        AxsLog([NSString stringWithFormat:@"=== HIDDEN alarm pill, tick=%d views=%d ===",
                AxsTickCount, hidden]);
        AxsLog(diag);
    }
}

static void AxsStartTimer(void) {
    if (AxsTimer) return;
    AxsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                      dispatch_get_main_queue());
    dispatch_source_set_timer(AxsTimer,
                              dispatch_walltime(NULL, 0),
                              250 * NSEC_PER_MSEC,   // 每 0.25 秒
                              50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(AxsTimer, ^{
        AxsTick();
    });
    dispatch_resume(AxsTimer);
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    [@"" writeToFile:AxsLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    AxsLog(@"=== tweak v6 loaded (adjunct hide) ===");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        AxsStartTimer();
    });
}

%end
