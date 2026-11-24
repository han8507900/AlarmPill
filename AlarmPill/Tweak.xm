#import <UIKit/UIKit.h>
#include <objc/runtime.h>

@interface SpringBoard : UIApplication
@end

// 按「显示内容」定位闹钟胶囊：不再依赖类名（胶囊是可点击的独立控件，
// 不在 CSProminentEmptyElementView 里）。每秒扫描所有视图，找到显示
// HH:MM 的 UILabel，排除状态栏/大时间/日期/音乐进度后，隐藏其胶囊容器。
static NSString *const AxsLogPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";
static NSTimer *AxsTimer = nil;

static void AxsWrite(NSString *msg) {
    NSString *line = [msg stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AxsLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:AxsLogPath atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
    }
}

// 判断文本是否形如 "07:24" / "7:24"（闹钟时间）
static BOOL AxsIsTimeText(NSString *text) {
    if (text.length < 4 || text.length > 8) return NO;
    NSRange colon = [text rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0 ||
        colon.location + 1 >= text.length) return NO;
    NSString *hour = [text substringToIndex:colon.location];
    NSString *minute = [[text substringFromIndex:colon.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (hour.length > 2 || minute.length != 2) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([hour rangeOfCharacterFromSet:[digits invertedSet]].location != NSNotFound) return NO;
    if ([minute rangeOfCharacterFromSet:[digits invertedSet]].location != NSNotFound) return NO;
    return YES;
}

// 父链里是否含这些「不该动」的类：状态栏、大时间、日期、音乐进度
static BOOL AxsParentChainHas(UIView *view, NSArray *keywords) {
    UIView *cur = view.superview;
    while (cur) {
        NSString *cls = NSStringFromClass([cur class]);
        for (NSString *kw in keywords) {
            if ([cls rangeOfString:kw].location != NSNotFound) return YES;
        }
        cur = cur.superview;
    }
    return NO;
}

static NSArray *AxsExcludeKeywords(void) {
    static NSArray *kw = nil;
    if (!kw) {
        kw = @[@"STUIStatusBar", @"CSProminentTimeView",
               @"CSProminentSubtitleDateView", @"LHHNowPlaying",
               @"LockPlayer", @"GCpOYsFYFMebofGH"];
    }
    return kw;
}

// 从 label 向上找尺寸像「胶囊」的容器（宽 80-300，高 20-80）
static UIView *AxsFindPillContainer(UILabel *label) {
    UIView *cur = label;
    for (NSInteger i = 0; i < 6 && cur.superview; i++) {
        cur = cur.superview;
        CGRect f = cur.frame;
        if (f.size.width >= 80 && f.size.width <= 300 &&
            f.size.height >= 20 && f.size.height <= 80) {
            return cur;
        }
    }
    return label.superview ?: label;
}

static void AxsScanAndHide(UIView *view, NSMutableString *log) {
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)view).text ?: @"";
        if (AxsIsTimeText(text) && !AxsParentChainHas(view, AxsExcludeKeywords())) {
            CGRect lf = [view convertRect:view.bounds toView:nil];
            // 只处理屏幕上半部（闹钟胶囊在时间下方，约 y 150-420）
            if (lf.origin.y >= 150 && lf.origin.y <= 420) {
                UIView *pill = AxsFindPillContainer((UILabel *)view);
                NSString *pillCls = NSStringFromClass([pill class]);
                CGRect pf = [pill convertRect:pill.bounds toView:nil];
                [log appendFormat:@"MATCH text='%@' label=%@ labelFrame=(%.0f,%.0f) pill=%@ pillFrame=(%.0f,%.0f,%.0f,%.0f)\n",
                    text, NSStringFromClass([view class]), lf.origin.x, lf.origin.y,
                    pillCls, pf.origin.x, pf.origin.y, pf.size.width, pf.size.height];
                if (!pill.hidden) {
                    pill.hidden = YES;
                    [log appendFormat:@"HIDDEN %@ text='%@'\n", pillCls, text];
                }
            }
        }
    }
    for (UIView *sub in view.subviews) {
        AxsScanAndHide(sub, log);
    }
}

static void AxsTick(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableString *log = [NSMutableString string];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden) continue;
            AxsScanAndHide(w, log);
        }
    }
    if (log.length) AxsWrite(log);
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    AxsWrite(@"=== tweak loaded (content-based v1) ===");
    if (!AxsTimer) {
        AxsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
            AxsTick();
        }];
    }
}

%end
