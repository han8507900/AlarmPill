#import <UIKit/UIKit.h>
#include <objc/runtime.h>

@interface SpringBoard : UIApplication
@end

// 持续监控探针：每 2 秒扫描一次，完整 dump 锁屏时钟区（CSProminent*）视图树。
// 只要视图结构发生变化（例如闹钟胶囊出现）就写入日志，不依赖锁屏时机。
// 只读，不隐藏任何视图。
static NSString *const AxsProbeLogPath = @"/var/mobile/Documents/AxsAlarmPillProbe.log";
static NSString *AxsProbeLastSig = nil;
static NSTimer *AxsProbeTimer = nil;

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

// 递归 dump 一棵子树，同时用类名序列累积结构签名
static void AxsProbeSubtree(UIView *view, NSInteger depth, NSMutableString *out, NSMutableString *sig) {
    NSString *cls = NSStringFromClass([view class]);
    CGRect f = view.frame;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ f=(%.0f,%.0f,%.0f,%.0f) h=%d t='%@'\n",
        pad, cls, f.origin.x, f.origin.y, f.size.width, f.size.height,
        view.hidden, AxsProbeText(view)];
    if ([cls hasPrefix:@"CSProminent"] ||
        [cls rangeOfString:@"Alarm"].location != NSNotFound ||
        [cls rangeOfString:@"Sleep"].location != NSNotFound) {
        [sig appendFormat:@"%@;", cls];
    }
    for (UIView *sub in view.subviews) {
        AxsProbeSubtree(sub, depth + 1, out, sig);
    }
}

// 找到最外层的 CSProminent* 视图作为根，dump 其完整子树
static void AxsProbeClockTrees(UIView *view, NSMutableString *out, NSMutableString *sig) {
    NSString *cls = NSStringFromClass([view class]);
    NSString *parentCls = view.superview ? NSStringFromClass([view.superview class]) : @"";
    if ([cls hasPrefix:@"CSProminent"] && ![parentCls hasPrefix:@"CSProminent"]) {
        [out appendFormat:@"--- CLOCK TREE (%@) ---\n", cls];
        AxsProbeSubtree(view, 0, out, sig);
    }
    for (UIView *sub in view.subviews) {
        AxsProbeClockTrees(sub, out, sig);
    }
}

static void AxsProbeDump(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *now = [fmt stringFromDate:[NSDate date]];

    NSMutableString *out = [NSMutableString stringWithFormat:@"=== probe %@ ===\n", now];
    NSMutableString *sig = [NSMutableString string];

    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }

    for (UIWindow *w in windows) {
        if (w.hidden) continue;
        AxsProbeClockTrees(w, out, sig);
    }

    // 只在结构签名变化（胶囊出现/消失）时写日志，避免刷屏
    if (![sig isEqualToString:AxsProbeLastSig]) {
        AxsProbeLastSig = [sig copy];
        [out appendFormat:@"SIG %@\n", sig];
        [out appendString:@"=== end ===\n"];
        AxsProbeWrite(out);
    }
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // 每次 respring 清空旧日志
    [@"" writeToFile:AxsProbeLogPath atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    AxsProbeLastSig = nil;
    if (!AxsProbeTimer) {
        AxsProbeTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                        repeats:YES
                                                          block:^(NSTimer *timer) {
            AxsProbeDump();
        }];
    }
}

%end
