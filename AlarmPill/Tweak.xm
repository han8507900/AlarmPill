#import <UIKit/UIKit.h>

@interface SpringBoard : UIApplication
@end

// ============================================================================
// 方案 v5：全锁屏持续扫描（不再局限于时钟区，不再靠点击时机）
//
// 教训：
//  1) 之前只 dump CSProminentDisplayView（时钟区），但闹钟胶囊挂在 CoverSheet
//     的其他容器下（本次抓到的是 LockPlayerContainerView / CSFixedFooterView 那棵）。
//  2) 点击后延迟抓取会抓到"锁屏上滑收起"的负坐标状态。
//  3) 定时扫描在熄屏时被暂停——但屏幕亮着（用户看胶囊）时定时器是运行的。
//
// 新方案：屏幕亮且锁屏时，每 0.5s 扫描整个 SBCoverSheetWindow 的所有视图，
//   自动标记出"显示时间格式文字"或"含闹钟语义类名"的视图。
//   结构变化时才追加写日志（避免刷屏），同时把命中行写到剪贴板。
//   这样只要胶囊在锁屏上显示几秒，就一定会被抓到。
// ============================================================================

static NSString *const AxsDumpPath = @"/var/mobile/Documents/AxsCoverSheetDump.txt";
static NSString *const AxsMarkPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";
static dispatch_source_t AxsTimerSource = nil;
static NSString *AxsLastSig = nil;

static void AxsWriteMark(NSString *line) {
    NSString *s = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AxsMarkPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [s writeToFile:AxsMarkPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static void AxsAppendDump(NSString *text) {
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AxsDumpPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [text writeToFile:AxsDumpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// 视图上所有显示文本
static NSString *AxsViewText(UIView *v) {
    NSMutableArray *parts = [NSMutableArray array];
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length) [parts addObject:[NSString stringWithFormat:@"text='%@'", l.text]];
        if (l.attributedText.string.length) {
            [parts addObject:[NSString stringWithFormat:@"attr='%@'", l.attributedText.string]];
        }
    }
    if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)v currentTitle];
        if (t.length) [parts addObject:[NSString stringWithFormat:@"btn='%@'", t]];
    }
    if (v.accessibilityLabel.length) {
        [parts addObject:[NSString stringWithFormat:@"aLabel='%@'", v.accessibilityLabel]];
    }
    if (v.accessibilityValue.length) {
        [parts addObject:[NSString stringWithFormat:@"aValue='%@'", v.accessibilityValue]];
    }
    return [parts componentsJoinedByString:@" "];
}

// 文本里是否含 HH:MM / H:MM 时间格式（闹钟时间）
static BOOL AxsHasTime(NSString *s) {
    if (s.length < 3) return NO;
    NSRange colon = [s rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0 || colon.location + 2 >= s.length) return NO;
    NSCharacterSet *d = [NSCharacterSet decimalDigitCharacterSet];
    unichar before = [s characterAtIndex:colon.location - 1];
    unichar after  = [s characterAtIndex:colon.location + 1];
    return [d characterIsMember:before] && [d characterIsMember:after];
}

// 类名是否含闹钟语义
static BOOL AxsAlarmName(NSString *cls) {
    NSString *low = [cls lowercaseString];
    return [low rangeOfString:@"alarm"].location != NSNotFound ||
           [low rangeOfString:@"wake"].location != NSNotFound ||
           [low rangeOfString:@"bedtime"].location != NSNotFound;
}

static NSString *AxsParentChain(UIView *v) {
    NSMutableArray *a = [NSMutableArray array];
    UIView *cur = v.superview;
    int n = 0;
    while (cur && n++ < 8) {
        [a addObject:NSStringFromClass([cur class])];
        cur = cur.superview;
    }
    return [a componentsJoinedByString:@" < "];
}

static void AxsWalk(UIView *v, int depth, NSMutableString *full,
                    NSMutableString *hits, NSMutableString *sig, int *hitCount) {
    NSString *cls = NSStringFromClass([v class]);
    NSString *txt = AxsViewText(v);
    CGRect f = [v convertRect:v.bounds toView:nil];
    NSString *pad = [@"" stringByPaddingToLength:depth withString:@" " startingAtIndex:0];

    BOOL timeText = AxsHasTime(txt);
    BOOL alarmName = AxsAlarmName(cls);
    BOOL mark = timeText || alarmName;

    NSString *line = [NSString stringWithFormat:@"%@%@%@ f=(%.0f,%.0f,%.0f,%.0f) hid=%d %@\n",
                      pad, mark ? @"★ " : @"  ", cls,
                      f.origin.x, f.origin.y, f.size.width, f.size.height, v.hidden, txt];
    [full appendString:line];
    [sig appendFormat:@"%@|%@|%@;", cls, NSStringFromCGRect(f), txt];

    if (mark) {
        (*hitCount)++;
        [hits appendString:line];
        [hits appendFormat:@"%@   CHAIN: %@\n", pad, AxsParentChain(v)];
    }

    for (UIView *sub in v.subviews) {
        AxsWalk(sub, depth + 1, full, hits, sig, hitCount);
    }
}

static void AxsTick(void) {
    UIApplication *app = [UIApplication sharedApplication];

    // 只在屏幕亮着且锁屏（有可见 CoverSheet）时扫描
    UIWindow *cover = nil;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.hidden) continue;
            NSString *cls = NSStringFromClass([w class]);
            if ([cls rangeOfString:@"CoverSheet"].location != NSNotFound) { cover = w; break; }
        }
        if (cover) break;
    }
    if (!cover) return;

    NSMutableString *full = [NSMutableString string];
    NSMutableString *hits = [NSMutableString string];
    NSMutableString *sig  = [NSMutableString string];
    int hitCount = 0;
    [full appendString:@"=== COVERSHEET SCAN ===\n"];
    AxsWalk(cover, 1, full, hits, sig, &hitCount);
    [full appendString:@"=== END ===\n"];

    // 结构没变化就不重复写
    if ([AxsLastSig isEqualToString:sig]) return;
    AxsLastSig = [sig copy];

    NSMutableString *block = [NSMutableString string];
    [block appendFormat:@"\n########## SCAN hit=%d ##########\n", hitCount];
    [block appendString:full];
    AxsAppendDump(block);

    // 写剪贴板：命中放前面，后面附完整树，无论如何都能拿到数据
    NSMutableString *clip = [NSMutableString string];
    [clip appendFormat:@"=== 闹钟候选 hit=%d ===\n", hitCount];
    [clip appendString:hits];
    [clip appendString:@"\n=== 完整树(最后一片) ===\n"];
    [clip appendString:full];
    [UIPasteboard generalPasteboard].string = clip;
}

// 主队列 GCD 定时器：不受 run loop mode 切换影响（NSTimer 在锁屏/滚动时会被
// 切到 UITrackingRunLoopMode 而暂停），同时保证 UIKit 操作都在主线程。
static void AxsStartScan(void) {
    if (AxsTimerSource) return;
    AxsTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
    dispatch_source_set_timer(AxsTimerSource,
                              dispatch_walltime(NULL, 0),
                              500 * NSEC_PER_MSEC,   // 每 0.5 秒
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(AxsTimerSource, ^{
        AxsTick();
    });
    dispatch_resume(AxsTimerSource);
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // respring 时清空旧日志
    [@"" writeToFile:AxsDumpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    AxsWriteMark(@"=== tweak v5 loaded (gcd coversheet scan) ===");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        AxsStartScan();
    });
}

%end
