#import <UIKit/UIKit.h>

@interface SpringBoard : UIApplication
@end

// ============================================================================
// 方案 v4：点击触发（诊断 + 高置信度隐藏 二合一）
//
// 为什么改架构：之前的定时扫描在锁屏熄屏时会被系统暂停，解锁后定时器才
// 恢复、但那时胶囊已经消失，所以从来没抓到过真正的闹钟胶囊。
//
// 新方案：监听 SpringBoard 的 sendEvent:，锁屏上每次点击都抓取整棵视图树。
//   1) 高置信度隐藏：只隐藏类名明确含 Alarm/Wake/Sleep/Bedtime 的视图。
//      这些词和时间视图（CSProminentTimeView / TextElementView）无关，绝不会误伤时间。
//   2) 完整诊断：把整棵树写文件，关键视图写剪贴板，一次拿到胶囊真实类名。
// 这样要么这次直接解决，要么一次拿到确切数据精准收尾。
// ============================================================================

static NSString *const AxsTapLogPath = @"/var/mobile/Documents/AxsTapDump.txt";
static NSString *const AxsMarkPath   = @"/var/mobile/Documents/AxsHideAlarmPill.log";
static CFAbsoluteTime sLastDump = 0;
static NSInteger sDumpCount = 0;
static BOOL sWasLockScreen = NO;

// 收集视图上所有显示文本（含无障碍标签——可点击控件通常有）
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

// 高置信度关键词：这些类必然是闹钟相关，和时间视图无关，可以安全隐藏
static BOOL AxsSafeHideKeyword(NSString *cls) {
    NSString *low = [cls lowercaseString];
    return [low rangeOfString:@"alarm"].location != NSNotFound ||
           [low rangeOfString:@"wake"].location != NSNotFound ||
           [low rangeOfString:@"bedtime"].location != NSNotFound ||
           [low rangeOfString:@"sleep"].location != NSNotFound;
}

// 记录用关键词（范围更宽，只为定位，不用于隐藏）
static BOOL AxsNoteKeyword(NSString *cls, NSString *txt) {
    NSString *all = [NSString stringWithFormat:@"%@ %@", cls, txt];
    NSString *low = [all lowercaseString];
    if (AxsSafeHideKeyword(cls)) return YES;
    return [low rangeOfString:@"clock"].location != NSNotFound ||
           [low rangeOfString:@"next"].location != NSNotFound;
}

// 记录父视图链，便于从命中视图反推它属于哪一棵子树
static NSString *AxsParentChain(UIView *v) {
    NSMutableArray *names = [NSMutableArray array];
    UIView *cur = v.superview;
    int n = 0;
    while (cur && n++ < 7) {
        [names addObject:NSStringFromClass([cur class])];
        cur = cur.superview;
    }
    return [names componentsJoinedByString:@" < "];
}

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

static NSInteger AxsWalk(UIView *v, NSInteger depth, NSMutableString *full,
                         NSMutableString *brief, NSMutableArray *toHide) {
    NSString *cls = NSStringFromClass([v class]);
    NSString *txt = AxsViewText(v);
    CGRect f = [v convertRect:v.bounds toView:nil];
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];

    BOOL safeHide = AxsSafeHideKeyword(cls);
    BOOL note = AxsNoteKeyword(cls, txt) || safeHide;
    NSString *mark = safeHide ? @"[HIDE] " : (note ? @"[NOTE] " : @"       ");
    NSString *line = [NSString stringWithFormat:@"%@%@%@ f=(%.0f,%.0f,%.0f,%.0f) hid=%d tap=%lu %@\n",
                      pad, mark, cls, f.origin.x, f.origin.y, f.size.width, f.size.height,
                      v.hidden, (unsigned long)v.gestureRecognizers.count, txt];
    [full appendString:line];
    if (note) {
        [brief appendString:line];
        [brief appendFormat:@"%@  PARENT: %@\n", pad, AxsParentChain(v)];
    }

    NSInteger count = note ? 1 : 0;
    if (safeHide && !v.hidden) [toHide addObject:v];

    for (UIView *sub in v.subviews) {
        count += AxsWalk(sub, depth + 1, full, brief, toHide);
    }
    return count;
}

static void AxsDumpNow(UIView *tapped) {
    sDumpCount++;
    NSMutableString *full = [NSMutableString stringWithFormat:@"=== TAP DUMP #%ld (v4) ===\n", (long)sDumpCount];
    NSMutableString *brief = [NSMutableString stringWithFormat:@"=== KEY VIEWS #%ld ===\n", (long)sDumpCount];
    NSMutableArray *toHide = [NSMutableArray array];

    // 【最关键】手指直接点到的那个 view —— 如果点的是胶囊，它就是胶囊本身
    if (tapped) {
        [brief appendFormat:@"\n>>>>>> TAPPED VIEW: %@\n", NSStringFromClass([tapped class])];
        [brief appendFormat:@">>>>>> TAPPED TEXT: %@\n", AxsViewText(tapped)];
        [brief appendFormat:@">>>>>> TAPPED FRAME: %@\n", NSStringFromCGRect([tapped convertRect:tapped.bounds toView:nil])];
        [brief appendFormat:@">>>>>> TAPPED CHAIN: %@\n", AxsParentChain(tapped)];
        // 从点击点向上找最近的可点击容器（胶囊按钮本体通常在更上层）
        UIView *cur = tapped;
        for (int i = 0; i < 5 && cur.superview; i++) {
            cur = cur.superview;
            [brief appendFormat:@">>>>>> ANCESTOR[%d]: %@ frame=%@\n",
                i + 1, NSStringFromClass([cur class]),
                NSStringFromCGRect([cur convertRect:cur.bounds toView:nil])];
        }
        [brief appendString:@"\n"];
    }

    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden) continue;
            [full appendFormat:@"WINDOW %@\n", NSStringFromClass([w class])];
            AxsWalk(w, 1, full, brief, toHide);
        }
    }
    [full appendString:@"=== END ===\n"];
    [full writeToFile:AxsTapLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [UIPasteboard generalPasteboard].string = brief;

    // 高置信度隐藏：只动 Alarm/Wake/Sleep/Bedtime 类，时间/日期视图绝不碰
    for (UIView *v in toHide) {
        v.hidden = YES;
        AxsWriteMark([NSString stringWithFormat:@"HIDDEN %@ f=(%.0f,%.0f,%.0f,%.0f)",
                      NSStringFromClass([v class]), v.frame.origin.x, v.frame.origin.y,
                      v.frame.size.width, v.frame.size.height]);
    }
    AxsWriteMark([NSString stringWithFormat:@"dump#%ld noteViews=%lu hidden=%lu",
                  (long)sDumpCount, (unsigned long)brief.length, (unsigned long)toHide.count]);
}

// 判断当前是否在锁屏（主屏隐藏 + CoverSheet 可见）
static BOOL AxsLockScreenVisible(void) {
    UIApplication *app = [UIApplication sharedApplication];
    BOOL homeHidden = NO, coverVisible = NO;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSString *cls = NSStringFromClass([w class]);
            if ([cls rangeOfString:@"SBHomeScreenWindow"].location != NSNotFound && w.hidden) {
                homeHidden = YES;
            }
            if (!w.hidden && [cls rangeOfString:@"CoverSheet"].location != NSNotFound) {
                coverVisible = YES;
            }
        }
    }
    return homeHidden && coverVisible;
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    AxsWriteMark(@"=== tweak v4 loaded (tap-trigger) ===");
}

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;

    // 在点击这一刻判断锁屏状态并存下来（避免延迟后状态已变）
    if (AxsLockScreenVisible()) sWasLockScreen = YES;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sLastDump < 0.4) return;
    sLastDump = now;

    BOOL wasLocked = sWasLockScreen;
    sWasLockScreen = NO;

    if (!wasLocked) return;

    // 抓住这次点击的 touch view（在 %orig 之后它已被 hitTest 确定）
    UIView *tappedView = [[[event allTouches] anyObject] view];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AxsDumpNow(tappedView);
    });
}

%end
