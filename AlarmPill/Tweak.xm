#import <UIKit/UIKit.h>
#include <objc/runtime.h>

@interface SpringBoard : UIApplication
@end

// 稳健方案：不 hook 懒加载的 CSProminent* 私有类（注入时类未加载会静默失效），
// 改为 hook 必定存在的 SpringBoard，定时遍历视图树直接操作目标视图。
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

// 递归遍历视图树，隐藏时间下方的闹钟槽位 CSProminentEmptyElementView。
// 不碰 CSProminentTimeView（大时间）和 CSProminentSubtitleDateView（日期）。
static void AxsHideSlotInTree(UIView *view, NSMutableString *log) {
    NSString *cls = NSStringFromClass([view class]);

    if ([cls isEqualToString:@"CSProminentEmptyElementView"]) {
        CGRect f = view.frame;
        if (!view.hidden) {
            view.hidden = YES;
            [log appendFormat:@"HIDDEN slot f=(%.0f,%.0f,%.0f,%.0f)\n",
                f.origin.x, f.origin.y, f.size.width, f.size.height];
        }
        return;
    }

    for (UIView *sub in view.subviews) {
        AxsHideSlotInTree(sub, log);
    }
}

static void AxsTick(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }

    NSMutableString *log = [NSMutableString string];
    for (UIWindow *w in windows) {
        if (w.hidden) continue;
        AxsHideSlotInTree(w, log);
    }

    if (log.length) AxsWrite(log);
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    AxsWrite(@"=== tweak loaded ===");
    if (!AxsTimer) {
        AxsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
            AxsTick();
        }];
    }
}

%end
