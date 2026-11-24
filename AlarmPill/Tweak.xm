#import <UIKit/UIKit.h>
#include <objc/runtime.h>

@interface SpringBoard : UIApplication
@end

static NSString *PillDumpPath(void) {
    return @"/var/mobile/Documents/AlarmPillDump.txt";
}

static NSString *ClassChain(id obj) {
    NSMutableString *chain = [NSMutableString string];
    Class cls = object_getClass(obj);
    while (cls) {
        if (chain.length) [chain appendString:@" < "];
        [chain appendFormat:@"%s", class_getName(cls)];
        cls = class_getSuperclass(cls);
    }
    return chain;
}

static void WalkView(UIView *view, int depth, NSMutableString *out) {
    if (!view) return;

    NSString *cls = NSStringFromClass([view class]);
    CGRect f = view.frame;
    BOOL hidden = view.hidden;
    CGFloat alpha = view.alpha;

    NSString *text = @"";
    if ([view isKindOfClass:[UILabel class]]) {
        text = ((UILabel *)view).text ?: @"";
    }

    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ frame=(%.0f,%.0f,%.0f,%.0f) hidden=%d alpha=%.2f text='%@'\n",
        pad, cls, f.origin.x, f.origin.y, f.size.width, f.size.height, hidden, alpha, text];

    for (UIView *sub in view.subviews) {
        WalkView(sub, depth + 1, out);
    }
}

static void DumpLockScreen(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"=== AlarmPill Probe v1 ===\n"];
    [out appendString:@"Device: iPhone / iOS 17.3.1 / RootHide\n\n"];

    UIApplication *app = [UIApplication sharedApplication];
    NSArray *windows = nil;

    if (@available(iOS 13.0, *)) {
        NSMutableArray *allWindows = [NSMutableArray array];
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [allWindows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        windows = allWindows;
    } else {
        windows = app.windows;
    }

    [out appendFormat:@"Windows found: %lu\n\n", (unsigned long)windows.count];
    for (UIWindow *w in windows) {
        [out appendFormat:@"--- WINDOW %@ frame=(%.0f,%.0f,%.0f,%.0f) hidden=%d ---\n",
            NSStringFromClass([w class]), w.frame.origin.x, w.frame.origin.y,
            w.frame.size.width, w.frame.size.height, w.hidden];
        WalkView(w, 1, out);
        [out appendString:@"\n"];
    }

    [out appendString:@"=== END ===\n"];

    NSString *path = PillDumpPath();
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = out;
}

static void OnLockComplete(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        DumpLockScreen();
    });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &OnLockComplete,
        CFSTR("com.apple.springboard.lockcomplete"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

%end
