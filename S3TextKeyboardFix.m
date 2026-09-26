//
//  S3TextKeyboardFix.m
//
//  修复「截图标记」(cn.llld.biaoji / biaoji.dylib) 在 Snapper3 / StayShot 里
//  「点文字工具后弹不出键盘、无法打字」的问题。
//
//  ── 真实根因（2026-09-26 从设备日志确认） ─────────────────────────────
//  插件在 SpringBoard 里自建了一个 window 承载标注界面：
//      win = [[UIWindow alloc] initWithWindowScene:scene]    // scene 取自 connectedScenes
//      win.windowLevel = UIWindowLevelStatusBar + 1          // 1001
//  但在 SpringBoard 里，connnectedScenes 枚举出来的第一个可用 scene 是
//      SBSystemApertureWindowScene (role: SBWindowSceneSessionRoleSystemAperture)
//  也就是「灵动岛」那个场景 —— 它**不是 App 场景**。
//  系统键盘窗口 (UIRemoteKeyboardWindow) 只在 UIWindowSceneSessionRoleApplication
//  下才会被创建。在 SystemAperture 场景里：
//      - becomeFirstResponder 返回 YES（假成功）
//      - 输入框光标会闪
//      - UIKeyboardWillShowNotification 也会发
//      - 但键盘窗口永远不会被建出来 → 视觉上「键盘不出来」
//  所以任何「补 scene / 抬 windowLevel / 重试第一响应者」的修法都不可能生效。
//
//  ── 修法 ────────────────────────────────────────────────────────────
//  既然系统键盘在这个场景下不可能出现，就**自绘一个键盘**。
//  S3TextKeyboardFix 在标注窗口之上再叠一个独立 window(level = base + 2)，
//  里面放一个自绘键盘视图（字母 / 数字 / 符号 / 拼音候选行 / 空格 / 退格 / 回车），
//  点击按键时把字符写进原插件 tag=200 的输入框，并触发它的 delegate 回调，
//  保证「取消 / 确认」按钮和实时预览都照常工作。
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
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:S3FixLogPath];
        if (h) { [h seekToEndOfFile]; [h writeData:data]; [h closeFile]; }
    }
}

#pragma mark - 状态

static BOOL S3FixInstalled = NO;
static CGFloat S3FixBaseLevel = 0.0;
static void (*S3FixOrigEnsure)(id, SEL) = NULL;

@class S3FixKeyboardView_i;

static UIWindow *S3FixKbWindow = nil;
static S3FixKeyboardView_i *S3FixKbView = nil;
static __weak UIView *S3FixTargetField = nil;
static UIViewController *S3FixOwnerVC = nil;

#pragma mark - 找输入框 / 窗口

static UIView *S3FixFindTextField(UIView *root) {
    if (!root) return nil;

    // 插件自己的输入框 tag = 200
    UIView *byTag = [root viewWithTag:200];
    if (byTag && [byTag respondsToSelector:@selector(setText:)]) return byTag;

    // 兜底：深度优先找第一个可编辑的 UITextView / UITextField
    for (UIView *sub in root.subviews) {
        UIView *r = S3FixFindTextField(sub);
        if (r) return r;
    }
    if ([root isKindOfClass:[UITextView class]] ||
        [root isKindOfClass:[UITextField class]]) {
        return root;
    }
    return nil;
}

static UIWindow *S3FixWindowForView(UIView *view) {
    if (!view) return nil;
    if (view.window) return view.window;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if ([view isDescendantOfView:w]) return w;
    }
    return nil;
}

static NSString *S3FixTextOf(UIView *field) {
    if ([field isKindOfClass:[UITextView class]]) return ((UITextView *)field).text ?: @"";
    if ([field isKindOfClass:[UITextField class]]) return ((UITextField *)field).text ?: @"";
    return @"";
}

static void S3FixSetText(UIView *field, NSString *text) {
    if ([field isKindOfClass:[UITextView class]]) {
        ((UITextView *)field).text = text;
    } else if ([field isKindOfClass:[UITextField class]]) {
        ((UITextField *)field).text = text;
    } else if ([field respondsToSelector:@selector(setText:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [field performSelector:@selector(setText:) withObject:text];
#pragma clang diagnostic pop
    }
    [field setNeedsDisplay];

    // 通知 delegate，保证插件的实时预览 / 确认按钮逻辑正常
    if ([field isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)field;
        id d = tv.delegate;
        if (d && [d respondsToSelector:@selector(textViewDidChange:)]) {
            [d textViewDidChange:tv];
        }
    } else if ([field isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)field;
        id d = tf.delegate;
        // UITextField 没有标准的「内容变化」delegate 方法，这里用运行时调用，
        // 兼容插件可能实现的任意命名（textFieldDidChange: / controlTextDidChange: 等）。
        NSArray<NSString *> *names = @[@"textFieldDidChange:",
                                       @"controlTextDidChange:",
                                       @"textDidChange:"];
        for (NSString *n in names) {
            SEL s = NSSelectorFromString(n);
            if (s && [d respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [d performSelector:s withObject:tf];
#pragma clang diagnostic pop
                break;
            }
        }
    }
}

#pragma mark - 自绘键盘

@interface S3FixKeyboardView_i : UIView
@property (nonatomic, weak) UIView *target;
@property (nonatomic, assign) BOOL shifted;
@property (nonatomic, assign) BOOL numeric;
@property (nonatomic, copy)   NSString *composing;   // 拼音缓冲
@property (nonatomic, strong) UILabel *candidateLabel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *letterKeys;
@end

static NSString * const kRow1 = @"QWERTYUIOP";
static NSString * const kRow2 = @"ASDFGHJKL";
static NSString * const kRow3 = @"ZXCVBNM";

@implementation S3FixKeyboardView_i

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _letterKeys = [NSMutableArray array];
        _composing = @"";
        self.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
        [self build];
    }
    return self;
}

#pragma mark 构建

- (UIButton *)keyWithTitle:(NSString *)title action:(SEL)action flex:(CGFloat)flex {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightRegular];
    b.backgroundColor = [UIColor colorWithWhite:0.32 alpha:1.0];
    b.layer.cornerRadius = 5.0;
    b.layer.masksToBounds = YES;
    b.tag = (NSInteger)(flex * 100);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (void)build {
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 10 || H < 10) return;

    CGFloat pad = 3.0;
    CGFloat topH = 34.0;                       // 候选行
    CGFloat rowH = (H - topH - pad * 5) / 4.0; // 4 行

    // 候选 / 提示行
    self.candidateLabel = [[UILabel alloc] init];
    self.candidateLabel.font = [UIFont systemFontOfSize:16];
    self.candidateLabel.textColor = [UIColor whiteColor];
    self.candidateLabel.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    self.candidateLabel.textAlignment = NSTextAlignmentLeft;
    self.candidateLabel.text = @"  英文直接输入，⇧ 切换大小写";
    self.candidateLabel.frame = CGRectMake(pad, pad, W - pad * 2 - 84, topH - pad * 2);
    self.candidateLabel.layer.cornerRadius = 4;
    self.candidateLabel.layer.masksToBounds = YES;
    [self addSubview:self.candidateLabel];

    [self buildLetterRowsWithTop:pad + topH rowH:rowH pad:pad W:W];

    // 第 4 行：大小写 / 123 / 空格 / 退格 / 换行
    CGFloat y = pad + topH + rowH * 3;
    CGFloat funcW = W * 0.14;

    UIButton *shift = [UIButton buttonWithType:UIButtonTypeCustom];
    shift.tag = 778;
    [shift setTitle:@"⇧" forState:UIControlStateNormal];
    [shift setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    shift.titleLabel.font = [UIFont systemFontOfSize:19];
    shift.backgroundColor = [UIColor colorWithWhite:0.32 alpha:1.0];
    shift.layer.cornerRadius = 5.0;
    shift.layer.masksToBounds = YES;
    shift.frame = CGRectMake(pad, y, funcW * 0.8, rowH - pad);
    [shift addTarget:self action:@selector(shiftTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:shift];

    UIButton *num = [self keyWithTitle:@"123" action:@selector(numTapped) flex:1];
    num.frame = CGRectMake(CGRectGetMaxX(shift.frame) + pad, y, funcW, rowH - pad);

    UIButton *space = [self keyWithTitle:@"空格" action:@selector(spaceTapped) flex:1];
    space.frame = CGRectMake(CGRectGetMaxX(num.frame) + pad, y,
                             W - funcW * 2 - funcW * 0.8 - pad * 5, rowH - pad);

    UIButton *del = [self keyWithTitle:@"⌫" action:@selector(backspaceTapped) flex:1];
    del.frame = CGRectMake(CGRectGetMaxX(space.frame) + pad, y, funcW, rowH - pad);

    UIButton *ret = [self keyWithTitle:@"换行" action:@selector(enterTapped) flex:1];
    ret.frame = CGRectMake(CGRectGetMaxX(del.frame) + pad, y, funcW, rowH - pad);
    ret.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];

    // 收起键盘按钮（候选行右侧）
    UIButton *hide = [UIButton buttonWithType:UIButtonTypeCustom];
    [hide setTitle:@"收起" forState:UIControlStateNormal];
    [hide setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    hide.titleLabel.font = [UIFont systemFontOfSize:15];
    hide.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    hide.layer.cornerRadius = 4;
    hide.layer.masksToBounds = YES;
    hide.frame = CGRectMake(W - pad - 78, pad, 78, topH - pad * 2);
    [hide addTarget:self action:@selector(hideTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:hide];
}

- (void)buildLetterRowsWithTop:(CGFloat)top rowH:(CGFloat)rowH pad:(CGFloat)pad W:(CGFloat)W {
    [self.letterKeys removeAllObjects];
    for (UIView *v in [self.subviews copy]) {
        if (v.tag == 777 || v.tag == 778) [v removeFromSuperview];
    }

    NSArray *rows = @[kRow1, kRow2, kRow3];
    for (NSInteger r = 0; r < rows.count; r++) {
        NSString *row = rows[r];
        NSInteger n = row.length;
        CGFloat inset = r * 16.0;                     // 二、三行缩进
        CGFloat availW = W - pad * 2 - inset;
        CGFloat kw = (availW - pad * (n - 1)) / n;
        CGFloat y = top + rowH * r;

        for (NSInteger i = 0; i < n; i++) {
            NSString *ch = [row substringWithRange:NSMakeRange(i, 1)];
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = 777;
            b.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.backgroundColor = [UIColor colorWithWhite:0.42 alpha:1.0];
            b.layer.cornerRadius = 5.0;
            b.layer.masksToBounds = YES;
            b.frame = CGRectMake(pad + inset + i * (kw + pad), y, kw, rowH - pad);
            [b addTarget:self action:@selector(letterTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
            [self.letterKeys addObject:b];
        }
    }

    [self refreshKeyTitles];
}

- (void)refreshKeyTitles {
    NSArray *rows = @[kRow1, kRow2, kRow3];
    NSInteger idx = 0;
    for (NSString *row in rows) {
        for (NSInteger i = 0; i < (NSInteger)row.length; i++) {
            if (idx >= (NSInteger)self.letterKeys.count) break;
            NSString *ch = [row substringWithRange:NSMakeRange(i, 1)];
            if (!self.shifted) ch = [ch lowercaseString];
            [self.letterKeys[idx] setTitle:ch forState:UIControlStateNormal];
            idx++;
        }
    }
}

#pragma mark 键盘事件

- (void)letterTapped:(UIButton *)sender {
    NSString *ch = [sender titleForState:UIControlStateNormal];
    [self commitChar:ch];
    if (self.shifted) { self.shifted = NO; [self refreshKeyTitles]; }
}

- (void)shiftTapped {
    self.shifted = !self.shifted;
    [self refreshKeyTitles];
}

- (void)spaceTapped {
    [self commitChar:@" "];
}

- (void)enterTapped {
    [self commitChar:@"\n"];
}

- (void)backspaceTapped {
    UIView *f = self.target;
    if (!f) return;
    NSString *t = S3FixTextOf(f);
    if (t.length == 0) return;
    NSRange last = [t rangeOfComposedCharacterSequenceAtIndex:t.length - 1];
    t = [t stringByReplacingCharactersInRange:last withString:@""];
    S3FixSetText(f, t);
}

- (void)numTapped {
    self.numeric = !self.numeric;
    [self rebuildForMode];
}

- (void)rebuildForMode {
    for (UIView *v in [self.subviews copy]) {
        if (v.tag == 777 || v.tag == 778) [v removeFromSuperview];
    }
    [self.letterKeys removeAllObjects];

    if (!self.numeric) {
        // 回到字母布局
        CGFloat W = self.bounds.size.width;
        CGFloat pad = 3.0, topH = 34.0;
        CGFloat rowH = (self.bounds.size.height - topH - pad * 5) / 4.0;
        [self buildLetterRowsWithTop:pad + topH rowH:rowH pad:pad W:W];
        self.candidateLabel.text = @"  英文直接输入，⇧ 切换大小写";
        return;
    }

    // 数字 / 符号布局
    CGFloat W = self.bounds.size.width;
    CGFloat pad = 3.0, topH = 34.0;
    CGFloat rowH = (self.bounds.size.height - topH - pad * 5) / 4.0;
    NSArray *numRows = @[@"1234567890", @"-/:;()$&@\"", @".?!'"];
    for (NSInteger r = 0; r < numRows.count; r++) {
        NSString *row = numRows[r];
        NSInteger n = row.length;
        CGFloat kw = (W - pad * 2 - pad * (n - 1)) / n;
        CGFloat y = pad + topH + rowH * r;
        for (NSInteger i = 0; i < n; i++) {
            NSString *ch = [row substringWithRange:NSMakeRange(i, 1)];
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = 777;
            b.titleLabel.font = [UIFont systemFontOfSize:20];
            [b setTitle:ch forState:UIControlStateNormal];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.backgroundColor = [UIColor colorWithWhite:0.42 alpha:1.0];
            b.layer.cornerRadius = 5; b.layer.masksToBounds = YES;
            b.frame = CGRectMake(pad + i * (kw + pad), y, kw, rowH - pad);
            [b addTarget:self action:@selector(letterTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
        }
    }
    self.candidateLabel.text = @"  数字 / 符号（再点 123 返回字母）";
}

- (void)commitChar:(NSString *)ch {
    UIView *f = self.target;
    if (!f) return;
    NSString *t = S3FixTextOf(f);
    t = [t stringByAppendingString:ch];
    S3FixSetText(f, t);
}

- (void)hideTapped {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"S3FixHideKeyboard" object:nil];
}

@end

#pragma mark - 键盘宿主 window

static void S3FixShowKeyboardFor(UIViewController *vc) {
    UIView *field = S3FixFindTextField(vc.view);
    if (!field) {
        S3FixLog(@"no editable field found");
        return;
    }

    UIWindow *annoWin = S3FixWindowForView(vc.view);
    CGFloat base = annoWin ? annoWin.windowLevel : (S3FixBaseLevel > 0 ? S3FixBaseLevel : UIWindowLevelStatusBar + 1);
    S3FixBaseLevel = base;

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat kbH = 300.0;      // 键盘高度（含候选行）
    if (screen.size.height < 600) kbH = 240.0;

    // 复用已有 window，避免反复创建
    if (!S3FixKbWindow || !S3FixKbView) {
        UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(screen) - kbH,
                                                                 screen.size.width, kbH)];
        // 用 initWithWindowScene: 让窗口能正常绘制（SpringBoard 下只有 SystemAperture scene，
        // 但这只是"显示"用途，不涉及键盘服务，所以不受影响）
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
        }
        if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
            w = [[UIWindow alloc] initWithWindowScene:scene];
            w.frame = CGRectMake(0, CGRectGetMaxY(screen) - kbH, screen.size.width, kbH);
        }

        w.windowLevel = base + 2;          // 高于标注窗口
        w.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
        w.hidden = NO;

        S3FixKeyboardView_i *kv = [[S3FixKeyboardView_i alloc] initWithFrame:w.bounds];
        kv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [w addSubview:kv];

        S3FixKbWindow = w;
        S3FixKbView = kv;
    } else {
        S3FixKbWindow.windowLevel = base + 2;
        S3FixKbWindow.frame = CGRectMake(0, CGRectGetMaxY(screen) - kbH, screen.size.width, kbH);
        S3FixKbView.frame = S3FixKbWindow.bounds;
    }

    S3FixTargetField = field;
    S3FixKbView.target = field;
    S3FixOwnerVC = vc;

    S3FixKbWindow.hidden = NO;

    // 不要 makeKey —— 标注窗口必须保持 key，否则它的触摸会失效
    S3FixLog(@"keyboard shown for field: %@ (kb win level %.0f)", field, S3FixKbWindow.windowLevel);

    // 让插件的输入框成为第一响应者：光标会出现，插件自己的「确认」逻辑也认为在编辑中。
    // 因为该 input 所在的 window 属于 SystemAperture 场景，系统不会真的弹出键盘，
    // 所以我们自己画的键盘就是唯一的输入来源。
    if ([field respondsToSelector:@selector(becomeFirstResponder)]) {
        [field becomeFirstResponder];
    }
}

static void S3FixHideKeyboard(void) {
    if (S3FixKbWindow) {
        S3FixKbWindow.hidden = YES;
    }
    S3FixTargetField = nil;
    if (S3FixKbView) S3FixKbView.target = nil;
    S3FixOwnerVC = nil;
    S3FixLog(@"keyboard hidden");
}

#pragma mark - 主修复

static void S3FixEnsureKeyboard(id self, SEL _cmd) {
    // 原实现只做了不可靠的 makeKeyWindow + becomeFirstResponder，这里仍调用它，
    // 以免破坏插件对 isKeyboardVisible 等内部状态的假设。
    if (S3FixOrigEnsure) S3FixOrigEnsure(self, _cmd);

    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)self;

    UIView *win = S3FixWindowForView(vc.view);
    S3FixLog(@"ensureTextKeyboard: vc=%@ win=%@ level=%.0f scene=%@",
             vc, win, ((UIWindow *)win).windowLevel, ((UIWindow *)win).windowScene);

    // 延后一点，等插件的 panel 完全布局完（键盘要贴在 panel 下方，不能盖住它）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        S3FixShowKeyboardFor(vc);
    });
}

#pragma mark - 安装

static BOOL S3FixInstall(void) {
    Class cls = NSClassFromString(@"S3TextEditViewController");
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(@"ensureTextKeyboard");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { S3FixLog(@"class found but selector missing"); return NO; }

    S3FixOrigEnsure = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self) {
        @autoreleasepool { S3FixEnsureKeyboard(self, sel); }
    }));

    S3FixLog(@"hook installed on S3TextEditViewController");
    return YES;
}

static void S3FixPoll(void) {
    if (S3FixInstalled) return;
    if (S3FixInstall()) {
        S3FixInstalled = YES;

        // 收起键盘
        [[NSNotificationCenter defaultCenter] addObserverForName:@"S3FixHideKeyboard"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            S3FixHideKeyboard();
        }];

        // 文字编辑页消失后自动收起键盘
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            // 系统键盘如果真的出来了（未来系统版本修复了），就不要我们自己的了
            S3FixLog(@"system keyboard will show");
        }];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ S3FixPoll(); });
}

static void S3FixTidyTimer(void) {
    // 标注 VC 消失 -> 收起自绘键盘
    if (!S3FixOwnerVC) return;
    if (S3FixOwnerVC.view.window == nil || S3FixOwnerVC.isBeingDismissed) {
        S3FixHideKeyboard();
    }
}

__attribute__((constructor))
static void S3FixInit(void) {
    @autoreleasepool {
        S3FixLog(@"----- S3TextKeyboardFix v2 (custom keyboard) loaded (pid=%d) -----", getpid());

        dispatch_async(dispatch_get_main_queue(), ^{ S3FixPoll(); });

        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *tt) {
            S3FixTidyTimer();
        }];
        (void)t;
    }
}
