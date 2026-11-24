#import <UIKit/UIKit.h>
#include <objc/runtime.h>

// 显式声明被 hook 的私有类继承自 UIView。
// Logos 默认只生成 @class 前向声明，编译器不知道它们的父类，
// 会导致「无法作为 UIView* 传参」和「找不到 hidden 属性」两类编译错误。
@interface CSProminentDisplayView : UIView
@end

@interface CSProminentTextElementView : UIView
@end

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

// 真机日志确认：闹钟胶囊的类名是 CSProminentTextElementView。
// 它在睡眠模式胶囊出现时才挂载到 CSProminentDisplayView 子树。
static BOOL AxsHideAlarmPillIsTarget(NSString *cls) {
    return [cls isEqualToString:@"CSProminentTextElementView"];
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

    // 视图树变化时记一次，便于确认隐藏是否命中
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

// 兜底：胶囊自身布局时直接隐藏，覆盖不走父视图遍历的情况
%hook CSProminentTextElementView
- (void)layoutSubviews {
    %orig;
    if (!self.hidden) {
        self.hidden = YES;
        AxsHideAlarmPillWrite(@"hidden text-direct");
    }
}
%end
