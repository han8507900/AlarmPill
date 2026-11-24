#import <UIKit/UIKit.h>
#include <objc/runtime.h>

@interface SpringBoard : UIApplication
@end

// 只读探针：不隐藏任何视图。扫描屏幕上所有「看起来像时间」的文字标签
// （含冒号数字或闹钟符号），记录其类名、frame 与完整父视图链，
// 用于精确定位睡眠模式锁屏上的闹钟胶囊视图。
static NSString *const AxsProbeLogPath = @"/var/mobile/Documents/AxsAlarmPillProbe.log";

static void AxsProbeWrite(NSString *msg) {
    NSString *line = [msg stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AxsProbeLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:AxsProbeLogPath atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
    }
}

static NSString *AxsProbeText(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        return ((UILabel *)view).text ?: @"";
    }
    return @"";
}

static BOOL AxsProbeIsTimeLike(NSString *text) {
    if (text.length == 0) return NO;
    if ([text containsString:@"⏰"] || [text containsString:@"闹"]) return YES;
    NSRange colon = [text rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) return NO;
    NSString *head = [text substringToIndex:colon.location];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return head.length > 0 && [head rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static void AxsProbeScanView(UIView *view, NSMutableString *out) {
    NSString *text = AxsProbeText(view);
    if (AxsProbeIsTimeLike(text)) {
        NSMutableString *chain = [NSMutableString string];
        UIView *cur = view;
        while (cur) {
            CGRect f = cur.frame;
            [chain appendFormat:@"%@(%.0f,%.0f,%.0f,%.0f,'%@') < ",
                NSStringFromClass([cur class]), f.origin.x, f.origin.y,
                f.size.width, f.size.height, AxsProbeText(cur)];
            cur = cur.superview;
        }
        [out appendFormat:@"CANDIDATE: %@\n", chain];
    }
    for (UIView *sub in view.subviews) {
        AxsProbeScanView(sub, out);
    }
}

// 区域扫描：胶囊位于屏幕中部（393x852 下大致 x 100-300 / y 250-520）。
// 即使文字是绘制的、不是 UILabel，也能靠坐标把这个视图抓出来。
static void AxsProbeScanRegion(UIView *view, NSMutableString *out) {
    CGRect f = view.frame;
    BOOL inVerticalBand = (f.origin.y >= 120 && f.origin.y <= 560);
    BOOL pillSized = (f.size.width >= 80 && f.size.width <= 300 &&
                      f.size.height >= 20 && f.size.height <= 90);
    if (inVerticalBand && pillSized) {
        [out appendFormat:@"REGION %@ frame=(%.0f,%.0f,%.0f,%.0f) text='%@'\n",
            NSStringFromClass([view class]), f.origin.x, f.origin.y,
            f.size.width, f.size.height, AxsProbeText(view)];
    }
    for (UIView *sub in view.subviews) {
        AxsProbeScanRegion(sub, out);
    }
}

static void AxsProbeDump(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"=== alarm pill probe ===\n"];

    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }

    for (UIWindow *w in windows) {
        if (w.hidden) continue;
        [out appendFormat:@"WINDOW %@\n", NSStringFromClass([w class])];
        AxsProbeScanView(w, out);
        AxsProbeScanRegion(w, out);
    }

    [out appendString:@"=== end ===\n"];
    AxsProbeWrite(out);
}

static void AxsProbeOnLock(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ AxsProbeDump(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ AxsProbeDump(); });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &AxsProbeOnLock,
        CFSTR("com.apple.springboard.lockcomplete"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

%end
