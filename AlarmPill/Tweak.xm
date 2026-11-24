#import <UIKit/UIKit.h>
#include <objc/runtime.h>

static NSString *const AxsHideAlarmPillLogPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";
static char AxsHideAlarmPillSigKey;

static void AxsHideAlarmPillWrite(NSString *msg) {
    NSString *line = [msg stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AxsHideAlarmPillLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:AxsHideAlarmPillLogPath atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
    }
}

// 时间下方的闹钟 element：dump 已确认 slot 是 CSProminentEmptyElementView
// (frame y=140,h=72)，闹钟显示时通常替换为 CSProminentLabeledElementView。
static BOOL AxsHideAlarmPillIsTarget(NSString *cls) {
    return [cls hasPrefix:@"CSProminent"] &&
           ([cls containsString:@"Labeled"] ||
            [cls containsString:@"Alarm"] ||
            [cls containsString:@"Empty"]);
}

static void AxsHideAlarmPillCollect(UIView *view, NSMutableString *sig, NSMutableArray *found) {
    NSString *cls = NSStringFromClass([view class]);
    if ([cls hasPrefix:@"CSProminent"]) {
        [sig appendFormat:@"%@,", cls];
    }
    if (AxsHideAlarmPillIsTarget(cls)) {
        [found addObject:view];
    }
    for (UIView *sub in view.subviews) {
        AxsHideAlarmPillCollect(sub, sig, found);
    }
}

%hook CSProminentDisplayView

- (void)layoutSubviews {
    %orig;

    NSMutableString *sig = [NSMutableString string];
    NSMutableArray *found = [NSMutableArray array];
    AxsHideAlarmPillCollect(self, sig, found);

    // 视图树变化时记一次，便于确认闹钟胶囊的真实类名
    NSString *old = objc_getAssociatedObject(self, &AxsHideAlarmPillSigKey);
    if (![old isEqualToString:sig]) {
        objc_setAssociatedObject(self, &AxsHideAlarmPillSigKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);
        AxsHideAlarmPillWrite([NSString stringWithFormat:@"tree: %@", sig]);
    }

    for (UIView *v in found) {
        if (!v.hidden) {
            v.hidden = YES;
            AxsHideAlarmPillWrite([NSString stringWithFormat:@"hidden %@", NSStringFromClass([v class])]);
        }
    }
}

%end

// 兜底：部分 iOS 版本胶囊不走 CSProminentDisplayView 子树
%hook CSProminentLabeledElementView
- (void)layoutSubviews {
    %orig;
    if (!self.hidden) {
        self.hidden = YES;
        AxsHideAlarmPillWrite(@"hidden labeled-direct");
    }
}
%end
