//
//  S3TextKeyboardFix.m
//
//  修复「截图标记」(cn.llld.biaoji / biaoji.dylib) 里
//  「点文字工具后键盘被盖住、看不到也点不到」的问题。
//
//  ── 真实根因（2026-09-26 设备实测确认） ───────────────────────────────
//  插件在 SpringBoard 里自建 window 承载标注界面，并把层级设成：
//      win.windowLevel = UIWindowLevelStatusBar + 1        // = 1001
//  而系统键盘窗口的层级远低于 1001。结果：
//      * UIKit 其实**成功**把原生键盘弹了出来
//      * 但键盘被 level 1001 的标注窗口整个盖住 → 视觉上"键盘没出来"
//  所以问题的本质是「**层级遮挡**」，不是"键盘没被创建"。
//  （早期日志里 `becomeFirstResponder -> 1` + 光标闪烁 + UIKeyboardWillShow
//    三件事同时发生，正是"键盘确实弹了、只是被盖住"的典型特征。）
//
//  ── 修法 ────────────────────────────────────────────────────────────
//  不改插件本体，只在「文字编辑页出现 → 消失」这段期间，
//  临时把标注窗口的 windowLevel 压到键盘之下，让原生键盘露出来。
//  文字页关闭后自动恢复原来的层级（屏幕上的标注界面不会被破坏）。
//
//  实现要点：
//    * swizzle -[S3TextEditViewController ensureTextKeyboard] 作为"文字编辑开始"的钩子
//    * swizzle -[S3TextEditViewController viewDidDisappear:] 作为"文字编辑结束"的钩子
//    * 记下标注窗口原始层级，降级到 UIWindowLevelNormal + 1（键盘之上、普通 UI 之下）
//    * 兜底轮询：文字编辑 VC 不在屏幕上了就恢复层级（防止漏 hook 导致层级永久被改）
//    * 全程保留诊断日志：/var/mobile/Documents/S3TextKeyboardFix.log
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
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:S3FixLogPath];
        if (h) { [h seekToEndOfFile]; [h writeData:data]; [h closeFile]; }
    }
}

#pragma mark - 状态

static BOOL S3FixInstalled = NO;

static __weak UIWindow *S3FixAnnoWindow = nil;   // 被降级的标注窗口
static CGFloat S3FixSavedLevel = 0.0;            // 它原来的层级
static BOOL S3FixLevelLowered = NO;
static __weak UIViewController *S3FixActiveVC = nil;

static void (*S3FixOrigEnsure)(id, SEL) = NULL;
static void (*S3FixOrigViewDidDisappear)(id, SEL, BOOL) = NULL;

#pragma mark - 工具

static UIWindow *S3FixWindowForView(UIView *view) {
    if (!view) return nil;
    if (view.window) return view.window;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if ([view isDescendantOfView:w]) return w;
    }
    return nil;
}

static UIView *S3FixFindEditable(UIView *root) {
    if (!root) return nil;
    UIView *byTag = [root viewWithTag:200];
    if (byTag && [byTag respondsToSelector:@selector(becomeFirstResponder)]) return byTag;

    for (UIView *sub in root.subviews) {
        UIView *r = S3FixFindEditable(sub);
        if (r) return r;
    }
    if ([root isKindOfClass:[UITextView class]] ||
        [root isKindOfClass:[UITextField class]]) {
        return root;
    }
    return nil;
}

// 把系统键盘窗口（UITextEffectsWindow / UIRemoteKeyboardWindow 等）抬到指定层级之上。
// SpringBoard 下这些窗口可能不在 [UIApplication windows] 里，所以额外用私有类名兜底查找。
static void S3FixRaiseSystemKeyboardWindow(CGFloat minLevel) {
    NSMutableArray<UIWindow *> *cands = [NSMutableArray array];
    [cands addObjectsFromArray:[UIApplication sharedApplication].windows];

    // 兜底：直接拿系统维护的键盘窗口单例
    NSArray<NSString *> *clsNames = @[@"UITextEffectsWindow",
                                      @"UIRemoteKeyboardWindow",
                                      @"UIKeyboardWindow"];
    for (NSString *n in clsNames) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        id shared = nil;
        if ([c respondsToSelector:@selector(sharedTextEffectsWindow)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            shared = [c performSelector:@selector(sharedTextEffectsWindow)];
#pragma clang diagnostic pop
        }
        if ([shared isKindOfClass:[UIWindow class]] && ![cands containsObject:shared]) {
            [cands addObject:shared];
        }
        // 也可能有多个实例，从 windows 里已经捞到的不重复
    }

    for (UIWindow *w in cands) {
        NSString *cls = NSStringFromClass([w class]);
        BOOL isKb = [cls rangeOfString:@"TextEffects"].location != NSNotFound ||
                    [cls rangeOfString:@"RemoteKeyboard"].location != NSNotFound ||
                    [cls rangeOfString:@"KeyboardWindow"].location != NSNotFound;
        if (!isKb) continue;

        if (w.windowLevel < minLevel) {
            S3FixLog(@"raise kb window %@ : %.0f -> %.0f", cls, w.windowLevel, minLevel);
            w.windowLevel = minLevel;
        }
    }
}

#pragma mark - 降级 / 恢复标注窗口层级

// 文字编辑开始时：把标注窗口压到键盘之下，让原生键盘可见
static void S3FixLowerAnnoWindowForKeyboard(UIViewController *vc) {
    UIWindow *win = S3FixWindowForView(vc.view);
    if (!win) {
        S3FixLog(@"lower: no window for vc %@", vc);
        return;
    }

    if (S3FixLevelLowered) {
        S3FixLog(@"lower: already lowered (level=%.0f)", win.windowLevel);
        S3FixActiveVC = vc;
        return;
    }

    S3FixSavedLevel = win.windowLevel;
    S3FixAnnoWindow = win;
    S3FixActiveVC = vc;

    // 关键：把标注窗口降到「普通 UI 之上、系统键盘之下」。
    // 原来的 1001 (UIWindowLevelStatusBar + 1) 会盖住键盘，这里降到 10 左右：
    //   * 仍高于普通 App / 桌面元素（level 0），标注面板依旧可见、可点
    //   * 低于系统键盘窗口（键盘在 SpringBoard 里层级比这高），键盘能露出来
    CGFloat target = 10.0;

    S3FixLog(@"lower: anno window level %.0f -> %.0f (saved %.0f)",
             S3FixSavedLevel, target, S3FixSavedLevel);

    win.windowLevel = target;
    S3FixLevelLowered = YES;

    // 键盘稍后才建出来，抬到标注窗口之上确保不被二次遮挡
    CGFloat raiseTo = target + 1.0;
    for (NSNumber *n in @[@0.05, @0.2, @0.5, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)([n doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            S3FixRaiseSystemKeyboardWindow(raiseTo);
        });
    }
}

// 文字编辑结束时：恢复标注窗口原来的层级
static void S3FixRestoreAnnoWindow(void) {
    if (!S3FixLevelLowered) return;

    UIWindow *win = S3FixAnnoWindow;
    if (win) {
        S3FixLog(@"restore: anno window level %.0f -> %.0f", win.windowLevel, S3FixSavedLevel);
        win.windowLevel = S3FixSavedLevel;
        // 恢复后重新成为 key，保证标注界面触摸正常
        if (!win.isKeyWindow) [win makeKeyWindow];
    } else {
        S3FixLog(@"restore: anno window gone, nothing to restore");
    }

    S3FixLevelLowered = NO;
    S3FixActiveVC = nil;
    S3FixAnnoWindow = nil;
    S3FixSavedLevel = 0.0;
}

#pragma mark - 钩子

static void S3FixEnsureKeyboard(id self, SEL _cmd) {
    // 先跑原实现（它会 makeKeyWindow + becomeFirstResponder，触发系统弹键盘）
    if (S3FixOrigEnsure) S3FixOrigEnsure(self, _cmd);

    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)self;

    UIWindow *win = S3FixWindowForView(vc.view);
    S3FixLog(@"ensureTextKeyboard: vc=%@ win=%@ level=%.0f", vc, win, win.windowLevel);

    dispatch_async(dispatch_get_main_queue(), ^{
        // 降级标注窗口，让原生键盘露出来
        S3FixLowerAnnoWindowForKeyboard(vc);

        // 顺带确保输入框是第一响应者（原实现是异步做的，这里补一次）
        UIView *field = S3FixFindEditable(vc.view);
        if (field && ![field isFirstResponder]) {
            BOOL ok = [field becomeFirstResponder];
            S3FixLog(@"becomeFirstResponder -> %d", ok);
        }
    });
}

static void S3FixViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (S3FixOrigViewDidDisappear) S3FixOrigViewDidDisappear(self, _cmd, animated);

    S3FixLog(@"S3TextEditViewController viewDidDisappear, restore anno window");
    S3FixRestoreAnnoWindow();
}

#pragma mark - 兜底轮询

static void S3FixTidy(void) {
    if (!S3FixLevelLowered) return;

    UIViewController *vc = S3FixActiveVC;
    BOOL gone = (vc == nil) ||
                (vc.view.window == nil) ||
                vc.isBeingDismissed ||
                vc.isViewLoaded == NO;

    if (gone) {
        S3FixLog(@"tidy: text edit vc gone, restore");
        S3FixRestoreAnnoWindow();
    }
}

#pragma mark - 安装

static BOOL S3FixInstall(void) {
    Class cls = NSClassFromString(@"S3TextEditViewController");
    if (!cls) return NO;

    SEL ensureSel = NSSelectorFromString(@"ensureTextKeyboard");
    Method m1 = class_getInstanceMethod(cls, ensureSel);
    if (!m1) { S3FixLog(@"ensureTextKeyboard missing"); return NO; }

    S3FixOrigEnsure = (void (*)(id, SEL))method_getImplementation(m1);
    method_setImplementation(m1, imp_implementationWithBlock(^(id self) {
        @autoreleasepool { S3FixEnsureKeyboard(self, ensureSel); }
    }));

    // viewDidDisappear: 作为"编辑结束"钩子
    SEL disSel = NSSelectorFromString(@"viewDidDisappear:");
    Method m2 = class_getInstanceMethod(cls, disSel);
    if (m2) {
        S3FixOrigViewDidDisappear = (void (*)(id, SEL, BOOL))method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^(id self, BOOL animated) {
            @autoreleasepool { S3FixViewDidDisappear(self, disSel, animated); }
        }));
        S3FixLog(@"hooked viewDidDisappear:");
    } else {
        S3FixLog(@"viewDidDisappear: not found, rely on tidy timer");
    }

    S3FixLog(@"hook installed on S3TextEditViewController");
    return YES;
}

static void S3FixPoll(void) {
    if (S3FixInstalled) return;
    if (S3FixInstall()) {
        S3FixInstalled = YES;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ S3FixPoll(); });
}

__attribute__((constructor))
static void S3FixInit(void) {
    @autoreleasepool {
        S3FixLog(@"----- S3TextKeyboardFix v3 (native keyboard, level fix) loaded (pid=%d) -----",
                 getpid());

        dispatch_async(dispatch_get_main_queue(), ^{ S3FixPoll(); });

        // 兜底：万一 viewDidDisappear: 没被调到，也要恢复层级
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            S3FixTidy();
        }];
    }
}
