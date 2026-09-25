//
//  S3TextKeyboardFix.m
//
//  修复「截图标记」(cn.llld.biaoji, biaoji.dylib) 在 Snapper3 / StayShot 里
//  「点文字工具后弹不出键盘、无法打字」的问题。
//
//  原实现的 -[S3TextEditViewController ensureTextKeyboard] 只做了两件事：
//    1) 如果 self.view.window 不是 keyWindow 就 makeKeyWindow
//    2) dispatch_async 到主队列，取 viewWithTag:200 的 UITextView 后 becomeFirstResponder
//  在 iOS 15/16 的 SpringBoard 里这条路会静默失效（window 没有 windowScene /
//  makeKeyWindow 不生效 / 键盘窗口层级低于标注窗口），于是键盘永远不出来。
//
//  本补丁把 ensureTextKeyboard 换成「原实现 + 增强」：
//    a. 兜底找 window（view.window 为空时遍历 UIApplication.windows）
//    b. window 没有 windowScene 时补绑当前 active 的 UIWindowScene
//    c. 强制 makeKeyAndVisible
//    d. 多次重试 becomeFirstResponder
//    e. 键盘弹出后把键盘窗口层级抬到标注窗口之上（否则键盘被透明的高层窗口吃掉触摸）
//    f. 若 2.5s 内键盘仍未出现，启用「独立输入窗口」兜底，把输入同步回真实 textView
//
//  日志：/var/mobile/Documents/S3TextKeyboardFix.log
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>

#pragma mark - 日志

static NSString * const S3FixLogPath = @"/var/mobile/Documents/S3TextKeyboardFix.log";

static void S3FixLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[S3TextFix] %@", msg);

    NSString *line = [msg stringByAppendingString:@"\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *dir = [S3FixLogPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    if (![fm fileExistsAtPath:S3FixLogPath]) {
        [data writeToFile:S3FixLogPath atomically:YES];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:S3FixLogPath];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
    }
}

#pragma mark - 状态

static BOOL S3FixInstalled = NO;
static BOOL S3FixKeyboardDidShow = NO;   // 最近一次是否真的弹出了键盘
static BOOL S3FixFallbackActive = NO;    // 兜底输入窗口是否已启用
static CGFloat S3FixBaseLevel = 0.0;     // 标注窗口的 windowLevel
static void (*S3FixOrigEnsure)(id, SEL) = NULL;

static UIWindow *S3FixHelperWindow = nil;
static UITextView *S3FixHelperField = nil;
static __weak UIView *S3FixRealField = nil;
static NSTimer *S3FixWatchTimer = nil;

#pragma mark - 工具

static UIWindowScene *S3FixActiveScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(connectedScenes)]) return nil;

    UIWindowScene *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
        if (!fallback) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

static UIWindow *S3FixWindowForView(UIView *view) {
    if (!view) return nil;
    if (view.window) return view.window;

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if ([view isDescendantOfView:w]) return w;
    }
    return nil;
}

// 键盘窗口（UITextEffectsWindow / UIRemoteKeyboardWindow 等）层级低于标注窗口时，
// 键盘虽然"存在"但会被高层透明窗口吃掉触摸 —— 看起来就像没弹出来。
static void S3FixRaiseKeyboardWindow(CGFloat minLevel) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *cls = NSStringFromClass([w class]);
        BOOL isKeyboard = [cls rangeOfString:@"TextEffects"].location != NSNotFound ||
                          [cls rangeOfString:@"RemoteKeyboard"].location != NSNotFound;
        if (!isKeyboard) continue;

        if (w.windowLevel < minLevel) {
            S3FixLog(@"raise keyboard window %@ : %.0f -> %.0f", cls, w.windowLevel, minLevel);
            w.windowLevel = minLevel;
        }
    }
}

static UIView *S3FixTextFieldIn(UIViewController *vc) {
    UIView *v = [vc.view viewWithTag:200];
    if (!v) return nil;
    if (![v respondsToSelector:@selector(becomeFirstResponder)]) return nil;
    return v;
}

static void S3FixTryBecomeFirstResponder(UIViewController *vc) {
    UIView *field = S3FixTextFieldIn(vc);
    if (!field) {
        S3FixLog(@"tag 200 text view not found");
        return;
    }
    if ([field isFirstResponder]) return;

    if (![field canBecomeFirstResponder]) {
        S3FixLog(@"text view canBecomeFirstResponder = NO");
        return;
    }
    BOOL ok = [field becomeFirstResponder];
    S3FixLog(@"becomeFirstResponder -> %d (window=%@ key=%d)",
             ok, field.window, field.window.isKeyWindow);
}

#pragma mark - 兜底：独立输入窗口

@interface S3FixInputSink : NSObject <UITextViewDelegate>
@property (nonatomic, weak) UIView *target;
@end

@implementation S3FixInputSink
- (void)textViewDidChange:(UITextView *)textView {
    UIView *t = self.target;
    if (!t) return;
    if ([t isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)t;
        if (![tv.text isEqualToString:textView.text]) {
            tv.text = textView.text;
            [tv setNeedsDisplay];
        }
    } else if ([t respondsToSelector:@selector(setText:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [t performSelector:@selector(setText:) withObject:textView.text];
#pragma clang diagnostic pop
        [t setNeedsDisplay];
    }
}
@end

static S3FixInputSink *S3FixSink = nil;

static void S3FixStopFallback(void) {
    if (!S3FixFallbackActive) return;
    S3FixFallbackActive = NO;

    [S3FixWatchTimer invalidate];
    S3FixWatchTimer = nil;

    if (S3FixHelperWindow) {
        S3FixHelperWindow.hidden = YES;
        S3FixHelperWindow.rootViewController = nil;
        S3FixHelperWindow = nil;
    }
    S3FixHelperField = nil;
    S3FixLog(@"fallback stopped");
}

// 真实输入框所在场景/窗口始终无法承载键盘时的最后手段：
// 建一个带 scene 的极小窗口，让它的 textView 成为第一响应者，再把输入同步回去。
static void S3FixStartFallback(UIViewController *vc) {
    if (S3FixFallbackActive) return;

    UIView *realField = S3FixTextFieldIn(vc);
    if (!realField) return;

    NSString *initialText = @"";
    UIFont *initialFont = [UIFont systemFontOfSize:16];
    if ([realField isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)realField;
        initialText = tv.text ?: @"";
        initialFont = tv.font ?: initialFont;
    }

    UIWindowScene *scene = S3FixActiveScene();
    if (!scene) {
        S3FixLog(@"fallback aborted: no UIWindowScene");
        return;
    }

    CGRect screen = [UIScreen mainScreen].bounds;
    UIWindow *win;
    if ([UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
        win = [[UIWindow alloc] initWithWindowScene:scene];
        win.frame = CGRectMake(0, CGRectGetMaxY(screen) - 6, 4, 4);
    } else {
        win = [[UIWindow alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(screen) - 6, 4, 4)];
    }
    win.backgroundColor = [UIColor clearColor];
    win.windowLevel = (S3FixBaseLevel > 0 ? S3FixBaseLevel : UIWindowLevelNormal) + 1;

    UIViewController *holder = [[UIViewController alloc] init];
    holder.view.backgroundColor = [UIColor clearColor];
    holder.view.frame = CGRectMake(0, 0, 4, 4);

    UITextView *field = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, 4, 4)];
    field.text = initialText;
    field.font = initialFont;
    field.textColor = [UIColor clearColor];
    field.backgroundColor = [UIColor clearColor];
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    [holder.view addSubview:field];

    win.rootViewController = holder;
    win.hidden = NO;
    [win makeKeyAndVisible];

    if (!S3FixSink) S3FixSink = [[S3FixInputSink alloc] init];
    S3FixSink.target = realField;
    field.delegate = S3FixSink;

    S3FixHelperWindow = win;
    S3FixHelperField = field;
    S3FixRealField = realField;
    S3FixFallbackActive = YES;

    S3FixLog(@"fallback started (level=%.0f)", win.windowLevel);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL ok = [field becomeFirstResponder];
        S3FixLog(@"fallback becomeFirstResponder -> %d", ok);
        S3FixRaiseKeyboardWindow(win.windowLevel + 1);
    });

    // 文字编辑页被关掉后清理兜底窗口，并把 key 还给标注窗口
    __weak UIViewController *weakVC = vc;
    S3FixWatchTimer = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        UIViewController *strong = weakVC;
        BOOL gone = (strong == nil) || (strong.view.window == nil) || strong.isBeingDismissed;
        if (!gone) return;
        [timer invalidate];
        S3FixWatchTimer = nil;
        S3FixStopFallback();
        S3FixKeyboardDidShow = NO;
    }];
}

#pragma mark - 主修复

static void S3FixEnsureKeyboard(id self, SEL _cmd) {
    // 先跑原实现，保证原有行为不被破坏
    if (S3FixOrigEnsure) S3FixOrigEnsure(self, _cmd);

    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)self;

    UIView *view = vc.view;
    UIWindow *win = S3FixWindowForView(view);

    S3FixLog(@"ensureTextKeyboard: vc=%@ view=%@ win=%@", vc, view, win);

    if (!win) {
        S3FixLog(@"no window, abort");
        return;
    }

    S3FixBaseLevel = win.windowLevel;

    // 兜底已启用时不要再抢 key，否则会把键盘收回去
    if (S3FixFallbackActive) {
        S3FixLog(@"fallback active, skip key change");
        S3FixTryBecomeFirstResponder(vc);
        return;
    }

    // a. 补绑 windowScene：没有 scene 的 window 在 iOS 13+ 上无法承载键盘
    if ([win respondsToSelector:@selector(windowScene)] && !win.windowScene) {
        UIWindowScene *scene = S3FixActiveScene();
        S3FixLog(@"window has no scene, try bind: %@", scene);
        if (scene) {
            SEL sel = NSSelectorFromString(@"_setWindowScene:");
            if ([win respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [win performSelector:sel withObject:scene];
#pragma clang diagnostic pop
            } else {
                @try {
                    [win setValue:scene forKey:@"windowScene"];
                } @catch (NSException *e) {
                    S3FixLog(@"KVC windowScene failed: %@", e);
                }
            }
            S3FixLog(@"window scene now: %@", win.windowScene);
        }
    }

    // b. 可见 + key
    if (win.hidden) {
        win.hidden = NO;
        S3FixLog(@"window was hidden -> NO");
    }
    [win makeKeyAndVisible];
    S3FixLog(@"after makeKeyAndVisible: isKey=%d level=%.0f scene=%@",
             win.isKeyWindow, win.windowLevel, win.windowScene);

    // c. 多次重试成为第一响应者
    S3FixTryBecomeFirstResponder(vc);
    for (NSNumber *num in @[@0.15, @0.4, @0.9]) {
        NSTimeInterval delay = [num doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (S3FixFallbackActive) return;
            if (![win isKeyWindow]) [win makeKeyAndVisible];
            S3FixTryBecomeFirstResponder(vc);
            S3FixRaiseKeyboardWindow(win.windowLevel + 1);
        });
    }

    // d. 键盘弹出后把键盘窗口抬到标注窗口之上
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        S3FixRaiseKeyboardWindow(win.windowLevel + 1);
    });

    // e. 2.5s 后仍没键盘 -> 启用兜底输入窗口
    S3FixKeyboardDidShow = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (S3FixKeyboardDidShow || S3FixFallbackActive) return;
        UIViewController *strong = vc;
        if (!strong || strong.view.window == nil) return;
        S3FixLog(@"keyboard never showed, start fallback");
        S3FixStartFallback(strong);
    });
}

#pragma mark - 键盘通知（诊断 + 提级）

static void S3FixRegisterKeyboardObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIKeyboardWillShowNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        S3FixKeyboardDidShow = YES;
        S3FixLog(@"UIKeyboardWillShow");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CGFloat base = S3FixBaseLevel > 0 ? S3FixBaseLevel : UIWindowLevelNormal;
            S3FixRaiseKeyboardWindow(base + 1);
        });
    }];
    [nc addObserverForName:UIKeyboardDidShowNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        S3FixKeyboardDidShow = YES;
    }];
}

#pragma mark - 安装

static BOOL S3FixInstall(void) {
    Class cls = NSClassFromString(@"S3TextEditViewController");
    if (!cls) return NO;

    SEL sel = NSSelectorFromString(@"ensureTextKeyboard");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        S3FixLog(@"S3TextEditViewController found but ensureTextKeyboard missing");
        return NO;
    }

    IMP orig = method_getImplementation(m);
    S3FixOrigEnsure = (void (*)(id, SEL))orig;

    method_setImplementation(m, imp_implementationWithBlock(^(id self) {
        @autoreleasepool {
            S3FixEnsureKeyboard(self, sel);
        }
    }));

    S3FixLog(@"hook installed on S3TextEditViewController");
    return YES;
}

static void S3FixPoll(void) {
    if (S3FixInstalled) return;
    if (S3FixInstall()) {
        S3FixInstalled = YES;
        S3FixRegisterKeyboardObservers();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        S3FixPoll();
    });
}

__attribute__((constructor))
static void S3FixInit(void) {
    @autoreleasepool {
        S3FixLog(@"----- S3TextKeyboardFix loaded (pid=%d) -----", getpid());

        dispatch_async(dispatch_get_main_queue(), ^{
            S3FixPoll();
        });

        [[NSNotificationCenter defaultCenter]
         addObserverForName:UIApplicationDidFinishLaunchingNotification
                     object:nil
                      queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
            S3FixLog(@"app finished launching, install hook");
            S3FixPoll();
        }];
    }
}
