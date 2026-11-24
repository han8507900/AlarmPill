#import <UIKit/UIKit.h>
#include <objc/runtime.h>

// 显式声明被 hook 的私有类继承自 UIView（Logos 默认只生成 @class，编译会报错）
@interface CSProminentDisplayView : UIView
@end
@interface CSProminentEmptyElementView : UIView
@end

// 真机完整视图树确认：
//   CSProminentTimeView          → 大时间
//   CSProminentSubtitleDateView  → 日期
//   CSProminentEmptyElementView  → 时间下方槽位(y=140,h=72)，闹钟胶囊装在这里
// TextElementView 是时间本身，不能碰（上次误伤导致时间消失）。
static NSString *const AxsLogPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";

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

static void AxsDescribe(UIView *view, NSInteger depth, NSMutableString *out) {
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    CGRect f = view.frame;
    NSString *text = @"";
    if ([view isKindOfClass:[UILabel class]]) text = ((UILabel *)view).text ?: @"";
    [out appendFormat:@"%@%@ f=(%.0f,%.0f,%.0f,%.0f) t='%@'\n",
        pad, NSStringFromClass([view class]), f.origin.x, f.origin.y,
        f.size.width, f.size.height, text];
    for (UIView *sub in view.subviews) {
        AxsDescribe(sub, depth + 1, out);
    }
}

// 在 DisplayView 子树中找到闹钟槽位，隐藏它，并记录它装了什么内容
static void AxsHideAlarmSlot(UIView *view, NSMutableString *log) {
    NSString *cls = NSStringFromClass([view class]);
    if ([cls isEqualToString:@"CSProminentEmptyElementView"]) {
        if (!view.hidden) {
            view.hidden = YES;
            [log appendString:@"hidden via tree: CSProminentEmptyElementView\n"];
            [log appendString:@"slot content:\n"];
            AxsDescribe(view, 1, log);
        }
        return;
    }
    for (UIView *sub in view.subviews) {
        AxsHideAlarmSlot(sub, log);
    }
}

%hook CSProminentDisplayView

- (void)layoutSubviews {
    %orig;
    NSMutableString *log = [NSMutableString string];
    AxsHideAlarmSlot(self, log);
    if (log.length) AxsWrite(log);
}

%end

%hook CSProminentEmptyElementView

- (void)layoutSubviews {
    %orig;
    if (!self.hidden) {
        self.hidden = YES;
        AxsWrite(@"hidden via self layout");
    }
}

// 强制该槽位永远保持隐藏，防止系统或其他 tweak 把它设回显示
- (void)setHidden:(BOOL)hidden {
    %orig(YES);
}

%end
