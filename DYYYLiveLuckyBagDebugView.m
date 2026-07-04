#import "DYYYLiveLuckyBagDebugView.h"

@interface DYYYLiveLuckyBagDebugView ()
@property(nonatomic, strong) UIView *titleBar;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UIButton *copyButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, assign) CGPoint panStartCenter;
@end

@implementation DYYYLiveLuckyBagDebugView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.88];
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        self.clipsToBounds = YES;

        _titleBar = [[UIView alloc] initWithFrame:CGRectZero];
        _titleBar.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
        [self addSubview:_titleBar];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.text = @"福袋调试";
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
        [_titleBar addSubview:_titleLabel];

        _copyButton = [self dyyy_debugButtonWithTitle:@"复制"];
        [_copyButton addTarget:self action:@selector(copyButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [_titleBar addSubview:_copyButton];

        _clearButton = [self dyyy_debugButtonWithTitle:@"清空"];
        [_clearButton addTarget:self action:@selector(clearButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [_titleBar addSubview:_clearButton];

        _closeButton = [self dyyy_debugButtonWithTitle:@"隐藏"];
        [_closeButton addTarget:self action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [_titleBar addSubview:_closeButton];

        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.backgroundColor = UIColor.clearColor;
        _textView.textColor = [UIColor colorWithRed:0.83 green:0.96 blue:0.86 alpha:1.0];
        _textView.editable = NO;
        _textView.selectable = YES;
        _textView.alwaysBounceVertical = YES;
        _textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
        if (@available(iOS 13.0, *)) {
            _textView.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
        } else {
            _textView.font = [UIFont fontWithName:@"Menlo" size:11.0] ?: [UIFont systemFontOfSize:11.0];
        }
        [self addSubview:_textView];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [_titleBar addGestureRecognizer:pan];
    }
    return self;
}

- (UIButton *)dyyy_debugButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    button.layer.cornerRadius = 4.0;
    return button;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat titleHeight = 36.0;
    self.titleBar.frame = CGRectMake(0, 0, width, titleHeight);

    CGFloat buttonWidth = 44.0;
    CGFloat buttonHeight = 24.0;
    CGFloat gap = 6.0;
    CGFloat right = width - 8.0;
    self.closeButton.frame = CGRectMake(right - buttonWidth, (titleHeight - buttonHeight) * 0.5, buttonWidth, buttonHeight);
    right = CGRectGetMinX(self.closeButton.frame) - gap;
    self.clearButton.frame = CGRectMake(right - buttonWidth, (titleHeight - buttonHeight) * 0.5, buttonWidth, buttonHeight);
    right = CGRectGetMinX(self.clearButton.frame) - gap;
    self.copyButton.frame = CGRectMake(right - buttonWidth, (titleHeight - buttonHeight) * 0.5, buttonWidth, buttonHeight);
    self.titleLabel.frame = CGRectMake(10.0, 0, MAX(40.0, CGRectGetMinX(self.copyButton.frame) - 16.0), titleHeight);

    self.textView.frame = CGRectMake(0, titleHeight, width, CGRectGetHeight(self.bounds) - titleHeight);
}

- (void)showInWindow:(UIWindow *)window {
    if (!window) {
        return;
    }

    CGSize windowSize = window.bounds.size;
    if (CGRectIsEmpty(self.frame) || CGRectGetWidth(self.frame) < 100.0 || CGRectGetHeight(self.frame) < 100.0) {
        CGFloat width = MIN(340.0, MAX(260.0, windowSize.width - 24.0));
        CGFloat height = MIN(360.0, MAX(220.0, windowSize.height * 0.45));
        CGFloat x = MAX(12.0, windowSize.width - width - 12.0);
        CGFloat y = 92.0;
        self.frame = CGRectMake(x, y, width, height);
    }

    if (self.superview != window) {
        [self removeFromSuperview];
        [window addSubview:self];
    }
    self.hidden = NO;
    [window bringSubviewToFront:self];
}

- (void)updateLogText:(NSString *)text {
    self.textView.text = text ?: @"";
    if (self.textView.text.length > 0) {
        NSRange bottom = NSMakeRange(self.textView.text.length - 1, 1);
        [self.textView scrollRangeToVisible:bottom];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *host = self.superview;
    if (!host) {
        return;
    }

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.panStartCenter = self.center;
    }

    CGPoint translation = [gesture translationInView:host];
    CGPoint targetCenter = CGPointMake(self.panStartCenter.x + translation.x, self.panStartCenter.y + translation.y);
    CGFloat halfWidth = CGRectGetWidth(self.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(self.bounds) * 0.5;
    targetCenter.x = MIN(MAX(halfWidth + 6.0, targetCenter.x), CGRectGetWidth(host.bounds) - halfWidth - 6.0);
    targetCenter.y = MIN(MAX(halfHeight + 24.0, targetCenter.y), CGRectGetHeight(host.bounds) - halfHeight - 6.0);
    self.center = targetCenter;
}

- (void)copyButtonTapped {
    if (self.copyHandler) {
        self.copyHandler();
    }
}

- (void)clearButtonTapped {
    if (self.clearHandler) {
        self.clearHandler();
    }
}

- (void)closeButtonTapped {
    if (self.closeHandler) {
        self.closeHandler();
    }
}

@end
