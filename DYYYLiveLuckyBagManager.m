#import "DYYYLiveLuckyBagManager.h"
#import "AwemeHeaders.h"
#import "DYYYLiveLuckyBagDebugView.h"
#import "DYYYUtils.h"
#import <objc/runtime.h>
#import <stddef.h>
#import <stdint.h>

static NSString *const kDYYYLiveLuckyBagDebugKey = @"DYYYLiveLuckyBagDebug";
static NSUInteger const kDYYYLiveLuckyBagMaxLogItems = 160;

@interface DYYYLiveLuckyBagManager ()
@property(nonatomic, strong) NSMutableArray<NSString *> *logItems;
@property(nonatomic, strong) NSMutableSet<NSString *> *loggedViewKeys;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *recentEventDates;
@property(nonatomic, strong) NSDateFormatter *dateFormatter;
@property(nonatomic, strong) DYYYLiveLuckyBagDebugView *debugView;
@property(nonatomic, weak) UIViewController *currentAudienceViewController;
@property(nonatomic, strong) id currentRoomModel;
@property(nonatomic, assign) BOOL inLiveRoom;
@property(nonatomic, assign) NSUInteger eventSequence;
@end

@implementation DYYYLiveLuckyBagManager

+ (instancetype)sharedManager {
    static DYYYLiveLuckyBagManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      manager = [[DYYYLiveLuckyBagManager alloc] init];
    });
    return manager;
}

+ (BOOL)isDebugEnabled {
    return DYYYGetBool(kDYYYLiveLuckyBagDebugKey);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logItems = [NSMutableArray array];
        _loggedViewKeys = [NSMutableSet set];
        _recentEventDates = [NSMutableDictionary dictionary];
        _dateFormatter = [[NSDateFormatter alloc] init];
        _dateFormatter.dateFormat = @"HH:mm:ss.SSS";
    }
    return self;
}

#pragma mark - Public

- (void)showDebugWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
      UIWindow *window = [DYYYUtils getActiveWindow] ?: UIApplication.sharedApplication.keyWindow;
      if (!window) {
          return;
      }

      if (!self.debugView) {
          self.debugView = [[DYYYLiveLuckyBagDebugView alloc] initWithFrame:CGRectZero];
          __weak typeof(self) weakSelf = self;
          self.debugView.copyHandler = ^{
            [weakSelf copyLogsToPasteboard];
          };
          self.debugView.clearHandler = ^{
            [weakSelf clearLogs];
          };
          self.debugView.closeHandler = ^{
            [weakSelf hideDebugWindow];
          };
      }

      [self.debugView showInWindow:window];
      [self refreshDebugWindow];
    });
}

- (void)hideDebugWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
      self.debugView.hidden = YES;
    });
}

- (void)handleLiveRoomEntered:(id)roomModel audienceViewController:(UIViewController *)viewController {
    if (![DYYYLiveLuckyBagManager isDebugEnabled]) {
        self.currentRoomModel = roomModel;
        self.currentAudienceViewController = viewController;
        self.inLiveRoom = YES;
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      self.currentRoomModel = roomModel;
      self.currentAudienceViewController = viewController;
      self.inLiveRoom = YES;
      [self.loggedViewKeys removeAllObjects];
      [self showDebugWindow];

      NSMutableString *log = [NSMutableString string];
      [log appendString:@"Hook: IESLiveAudienceViewController didEnterRoom:\n"];
      [self appendObjectDump:roomModel name:@"roomModel" toLog:log depth:0];
      [self appendObjectDump:viewController name:@"audienceVC" toLog:log depth:0];
      [self appendLikelyIdentifiersFromObject:roomModel title:@"roomModel identifiers" toLog:log];
      [self appendEventWithTitle:@"进入直播间" body:log];
    });
}

- (void)handleLiveRoomClosed:(id)roomModel {
    if (![DYYYLiveLuckyBagManager isDebugEnabled]) {
        self.currentRoomModel = nil;
        self.currentAudienceViewController = nil;
        self.inLiveRoom = NO;
        [self.loggedViewKeys removeAllObjects];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      NSMutableString *log = [NSMutableString string];
      [log appendString:@"Hook: IESLiveAudienceViewController didCloseRoom:/dealloc\n"];
      [self appendObjectDump:roomModel name:@"roomModelOrVC" toLog:log depth:0];
      [self appendEventWithTitle:@"离开直播间" body:log];

      self.currentRoomModel = nil;
      self.currentAudienceViewController = nil;
      self.inLiveRoom = NO;
      [self.loggedViewKeys removeAllObjects];
    });
}

- (void)handleLuckyBagViewAppeared:(UIView *)view {
    if (![DYYYLiveLuckyBagManager isDebugEnabled] || !view) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self viewLooksRelevant:view]) {
          return;
      }

      NSString *viewKey = [NSString stringWithFormat:@"%p-%@", view, NSStringFromClass(view.class)];
      if ([self.loggedViewKeys containsObject:viewKey]) {
          return;
      }
      [self.loggedViewKeys addObject:viewKey];

      [self showDebugWindow];
      NSMutableString *log = [NSMutableString string];
      [log appendString:@"Hook: live lucky bag candidate layoutSubviews\n"];
      [self appendObjectDump:view name:@"candidateView" toLog:log depth:0];
      [self appendLuckyBagHeuristicsForText:[self visibleTextInView:view maxDepth:5] object:view toLog:log];
      [self appendLikelyIdentifiersFromObject:view title:@"candidate values" toLog:log];
      [self appendEventWithTitle:@"候选福袋视图出现" body:log];
    });
}

- (void)handleControlAction:(SEL)action target:(id)target sender:(UIControl *)sender event:(UIEvent *)event {
    if (![DYYYLiveLuckyBagManager isDebugEnabled] || !sender || [self viewIsInsideDebugWindow:sender]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self shouldCaptureInteractionFromView:sender target:target action:action]) {
          return;
      }
      NSString *fingerprint = [NSString stringWithFormat:@"control-%p-%@-%@", sender, target ? NSStringFromClass([target class]) : @"nil", NSStringFromSelector(action)];
      if (![self shouldLogFingerprint:fingerprint interval:0.45]) {
          return;
      }

      [self showDebugWindow];
      NSMutableString *log = [NSMutableString string];
      [log appendFormat:@"UIControl sendAction: %@\n", NSStringFromSelector(action)];
      [self appendObjectDump:sender name:@"sender" toLog:log depth:0];
      [self appendObjectDump:target name:@"target" toLog:log depth:0];
      if (event) {
          [log appendFormat:@"event.class = %@, touches = %lu\n", NSStringFromClass([event class]), (unsigned long)event.allTouches.count];
      }
      [self appendLuckyBagHeuristicsForText:[self textForInteractionView:sender target:target action:action] object:sender toLog:log];
      [self appendLikelyIdentifiersFromObject:sender title:@"sender values" toLog:log];
      [self appendLikelyIdentifiersFromObject:target title:@"target values" toLog:log];
      [self appendEventWithTitle:@"点击控件" body:log];
    });
}

- (void)handleGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer {
    if (![DYYYLiveLuckyBagManager isDebugEnabled] || !gestureRecognizer || [self viewIsInsideDebugWindow:gestureRecognizer.view]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      UIView *view = gestureRecognizer.view;
      if (![self shouldCaptureGesture:gestureRecognizer]) {
          return;
      }
      NSString *fingerprint = [NSString stringWithFormat:@"gesture-%p-%@-%p", gestureRecognizer, NSStringFromClass(gestureRecognizer.class), view];
      if (![self shouldLogFingerprint:fingerprint interval:0.45]) {
          return;
      }

      [self showDebugWindow];
      NSMutableString *log = [NSMutableString string];
      [log appendFormat:@"UIGestureRecognizer state = %ld\n", (long)gestureRecognizer.state];
      [self appendObjectDump:gestureRecognizer name:@"gestureRecognizer" toLog:log depth:0];
      [self appendObjectDump:view name:@"gesture.view" toLog:log depth:0];
      [self appendGestureTargets:gestureRecognizer toLog:log];
      [self appendLuckyBagHeuristicsForText:[self visibleTextAroundView:view] object:view toLog:log];
      [self appendLikelyIdentifiersFromObject:view title:@"gesture view values" toLog:log];
      [self appendEventWithTitle:@"点击手势" body:log];
    });
}

- (void)handleTextInputView:(UIView *)textInputView text:(NSString *)text {
    if (![DYYYLiveLuckyBagManager isDebugEnabled] || !textInputView || [self viewIsInsideDebugWindow:textInputView]) {
        return;
    }

    NSString *safeText = text ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *contextText = [NSString stringWithFormat:@"%@ %@", safeText, [self visibleTextAroundView:textInputView]];
      if (!self.inLiveRoom && ![self viewLooksRelevant:textInputView] && ![self stringLooksRelevant:contextText]) {
          return;
      }
      if (safeText.length == 0 && ![self stringLooksRelevant:contextText]) {
          return;
      }

      NSString *fingerprint = [NSString stringWithFormat:@"text-%p-%@", textInputView, [self truncateString:safeText limit:80]];
      if (![self shouldLogFingerprint:fingerprint interval:0.25]) {
          return;
      }

      [self showDebugWindow];
      NSMutableString *log = [NSMutableString string];
      [log appendFormat:@"textInput.class = <%@: %p>\n", NSStringFromClass(textInputView.class), textInputView];
      [log appendFormat:@"textInput.text = %@\n", [self truncateString:safeText limit:500]];
      [log appendFormat:@"textInput.nearestVC = %@\n", [DYYYUtils firstAvailableViewControllerFromView:textInputView] ? NSStringFromClass([DYYYUtils firstAvailableViewControllerFromView:textInputView].class) : @"nil"];
      [log appendFormat:@"textInput.visibleTextAround = %@\n", [self truncateString:[self visibleTextAroundView:textInputView] limit:700]];
      [log appendFormat:@"textInput.superviewPath = %@\n", [self superviewPathForView:textInputView]];
      [self appendLuckyBagHeuristicsForText:contextText object:textInputView toLog:log];
      [self appendLikelyIdentifiersFromObject:textInputView title:@"textInput values" toLog:log];
      [self appendEventWithTitle:@"文本输入变化" body:log];
    });
}

#pragma mark - Log Window

- (void)copyLogsToPasteboard {
    NSString *text = [self fullLogText];
    UIPasteboard.generalPasteboard.string = text.length > 0 ? text : @"";
    [DYYYUtils showToast:@"福袋调试日志已复制"];
}

- (void)clearLogs {
    [self.logItems removeAllObjects];
    [self.loggedViewKeys removeAllObjects];
    [self.recentEventDates removeAllObjects];
    self.eventSequence = 0;
    [self appendEventWithTitle:@"日志已清空" body:@"继续按完整流程操作：进入直播间 -> 点福袋 -> 点参与/去发表评论 -> 手动发送官方要求弹幕。\n"];
}

- (void)appendEventWithTitle:(NSString *)title body:(NSString *)body {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self appendEventWithTitle:title body:body];
        });
        return;
    }

    self.eventSequence += 1;
    NSString *time = [self.dateFormatter stringFromDate:[NSDate date]];
    NSMutableString *entry = [NSMutableString stringWithFormat:@"\n#%03lu %@ %@\n", (unsigned long)self.eventSequence, time, title ?: @"事件"];
    [entry appendString:@"----------------------------------------\n"];
    if (body.length > 0) {
        [entry appendString:body];
        if (![body hasSuffix:@"\n"]) {
            [entry appendString:@"\n"];
        }
    }

    [self.logItems addObject:entry];
    while (self.logItems.count > kDYYYLiveLuckyBagMaxLogItems) {
        [self.logItems removeObjectAtIndex:0];
    }
    [self refreshDebugWindow];
}

- (NSString *)fullLogText {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"DYYY 福袋调试采集日志\n"];
    [text appendString:@"说明：当前版本只采集手动流程数据，不自动点击、不发送弹幕、不加入粉丝团。\n"];
    [text appendFormat:@"liveRoom = %@, currentVC = %@, roomModel = %@\n",
                       self.inLiveRoom ? @"YES" : @"NO",
                       self.currentAudienceViewController ? NSStringFromClass(self.currentAudienceViewController.class) : @"nil",
                       self.currentRoomModel ? NSStringFromClass([self.currentRoomModel class]) : @"nil"];
    [text appendString:@"========================================\n"];
    for (NSString *item in self.logItems) {
        [text appendString:item];
    }
    return text;
}

- (void)refreshDebugWindow {
    if (!self.debugView) {
        return;
    }
    [self.debugView updateLogText:[self fullLogText]];
}

#pragma mark - Filters

- (BOOL)shouldCaptureInteractionFromView:(UIView *)view target:(id)target action:(SEL)action {
    if (!view) {
        return NO;
    }
    if (self.inLiveRoom) {
        return YES;
    }

    NSString *combined = [self textForInteractionView:view target:target action:action];
    return [self stringLooksRelevant:combined] || [self viewLooksRelevant:view] || [self objectLooksRelevant:target];
}

- (BOOL)shouldCaptureGesture:(UIGestureRecognizer *)gestureRecognizer {
    UIView *view = gestureRecognizer.view;
    if (!view || gestureRecognizer.state != UIGestureRecognizerStateEnded) {
        return NO;
    }
    if (self.inLiveRoom && [gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]]) {
        return YES;
    }
    return [self viewLooksRelevant:view] || [self objectLooksRelevant:gestureRecognizer];
}

- (BOOL)viewLooksRelevant:(UIView *)view {
    if (!view) {
        return NO;
    }

    NSString *className = NSStringFromClass(view.class);
    NSString *text = [self visibleTextAroundView:view];
    NSString *combined = [NSString stringWithFormat:@"%@ %@", className ?: @"", text ?: @""];
    if ([self stringLooksRelevant:combined]) {
        return YES;
    }

    UIView *parent = view.superview;
    for (NSUInteger i = 0; parent && i < 4; i++, parent = parent.superview) {
        NSString *parentClass = NSStringFromClass(parent.class);
        if ([self stringLooksRelevant:parentClass]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)objectLooksRelevant:(id)object {
    if (!object) {
        return NO;
    }
    NSString *className = NSStringFromClass([object class]);
    if ([self stringLooksRelevant:className]) {
        return YES;
    }
    NSString *description = [self safeShortDescription:object limit:240];
    return [self stringLooksRelevant:description];
}

- (BOOL)stringLooksRelevant:(NSString *)string {
    if (string.length == 0) {
        return NO;
    }

    NSString *lower = string.lowercaseString;
    NSArray<NSString *> *tokens = @[
        @"福袋", @"超级福袋", @"红包", @"开奖", @"抽奖", @"参与", @"去发表评论", @"发表评论", @"评论", @"弹幕", @"口令", @"粉丝团", @"加团", @"关注",
        @"lucky", @"luckybag", @"lottery", @"redenvelope", @"red_envelope", @"treasure", @"shorttouch", @"lynx", @"comment", @"danmu", @"barrage",
        @"fans", @"follow", @"join", @"participate", @"award", @"gift", @"task"
    ];
    for (NSString *token in tokens) {
        if ([lower rangeOfString:token.lowercaseString options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)shouldLogFingerprint:(NSString *)fingerprint interval:(NSTimeInterval)interval {
    if (fingerprint.length == 0) {
        return YES;
    }
    NSDate *now = [NSDate date];
    NSDate *lastDate = self.recentEventDates[fingerprint];
    if (lastDate && [now timeIntervalSinceDate:lastDate] < interval) {
        return NO;
    }
    self.recentEventDates[fingerprint] = now;
    if (self.recentEventDates.count > 240) {
        [self.recentEventDates removeAllObjects];
    }
    return YES;
}

- (BOOL)viewIsInsideDebugWindow:(UIView *)view {
    return view && self.debugView && (view == self.debugView || [view isDescendantOfView:self.debugView]);
}

#pragma mark - Dumps

- (void)appendObjectDump:(id)object name:(NSString *)name toLog:(NSMutableString *)log depth:(NSUInteger)depth {
    if (!object || depth > 2) {
        [log appendFormat:@"%@ = nil\n", name ?: @"object"];
        return;
    }

    [log appendFormat:@"%@ = <%@: %p>\n", name ?: @"object", NSStringFromClass([object class]), object];

    NSString *description = [self safeShortDescription:object limit:500];
    if (description.length > 0) {
        [log appendFormat:@"%@.description = %@\n", name ?: @"object", description];
    }

    if ([object isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)object;
        [log appendFormat:@"%@.frame = %@, bounds = %@, hidden = %@, alpha = %.3f, userInteraction = %@\n",
                          name ?: @"view",
                          NSStringFromCGRect(view.frame),
                          NSStringFromCGRect(view.bounds),
                          view.hidden ? @"YES" : @"NO",
                          view.alpha,
                          view.userInteractionEnabled ? @"YES" : @"NO"];
        if (view.accessibilityLabel.length > 0 || view.accessibilityIdentifier.length > 0) {
            [log appendFormat:@"%@.accessibility = label:%@ identifier:%@\n", name ?: @"view", view.accessibilityLabel ?: @"", view.accessibilityIdentifier ?: @""];
        }
        NSString *visibleText = [self visibleTextInView:view maxDepth:4];
        if (visibleText.length > 0) {
            [log appendFormat:@"%@.visibleText = %@\n", name ?: @"view", visibleText];
        }
        UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:view];
        if (vc) {
            [log appendFormat:@"%@.nearestVC = <%@: %p>\n", name ?: @"view", NSStringFromClass(vc.class), vc];
        }
        [log appendFormat:@"%@.superviewPath = %@\n", name ?: @"view", [self superviewPathForView:view]];
        [log appendFormat:@"%@.subviews = %@\n", name ?: @"view", [self immediateSubviewsForView:view]];
    } else if ([object isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer *gesture = (UIGestureRecognizer *)object;
        [log appendFormat:@"%@.state = %ld, enabled = %@, view = <%@: %p>\n",
                          name ?: @"gesture",
                          (long)gesture.state,
                          gesture.enabled ? @"YES" : @"NO",
                          gesture.view ? NSStringFromClass(gesture.view.class) : @"nil",
                          gesture.view];
    }

    [self appendLikelyIdentifiersFromObject:object title:[NSString stringWithFormat:@"%@ likelyValues", name ?: @"object"] toLog:log];
    [self appendIvarSummaryForObject:object title:[NSString stringWithFormat:@"%@ ivars", name ?: @"object"] toLog:log];
    [self appendMethodSummaryForObject:object title:[NSString stringWithFormat:@"%@ methods", name ?: @"object"] toLog:log];
}

- (void)appendLikelyIdentifiersFromObject:(id)object title:(NSString *)title toLog:(NSMutableString *)log {
    if (!object) {
        return;
    }

    NSArray<NSString *> *keys = @[
        @"roomID", @"roomId", @"room_id", @"idStr", @"id_str", @"ID", @"id", @"anchorID", @"anchorId", @"ownerUserID", @"ownerUserId",
        @"lotteryID", @"lotteryId", @"lottery_id", @"luckyBagID", @"luckyBagId", @"lucky_bag_id", @"redEnvelopeID", @"redEnvelopeId", @"activityID", @"activityId",
        @"taskType", @"task_type", @"condition", @"joinCondition", @"participateCondition", @"requirement", @"requirementText", @"taskText", @"schema", @"url",
        @"text", @"title", @"subTitle", @"subtitle", @"desc", @"descriptionString", @"buttonText", @"content", @"commentText", @"prompt", @"hint", @"placeholder",
        @"data", @"model", @"viewModel", @"itemModel", @"roomModel", @"room", @"rawRoom", @"lotteryInfo", @"lotteryModel", @"luckyBagInfo", @"luckyBagModel",
        @"redEnvelopeInfo", @"redEnvelopeModel", @"delegate", @"actionHandler", @"handler", @"presenter", @"service", @"component", @"context", @"containerContext"
    ];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in keys) {
        id value = [self safeValueForKey:key object:object];
        NSString *valueText = [self valueTextForLog:value limit:260];
        if (valueText.length > 0) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, valueText]];
        }
    }

    if (parts.count > 0) {
        [log appendFormat:@"%@:\n", title ?: @"likely values"];
        for (NSString *part in parts) {
            [log appendFormat:@"  %@\n", part];
        }
    }
}

- (void)appendIvarSummaryForObject:(id)object title:(NSString *)title toLog:(NSMutableString *)log {
    if (!object) {
        return;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    Class cls = [object class];
    NSUInteger classDepth = 0;
    while (cls && cls != NSObject.class && classDepth < 4 && parts.count < 60) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count && parts.count < 60; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            NSString *ivarName = name ? [NSString stringWithUTF8String:name] : @"?";
            NSString *typeText = type ? [NSString stringWithUTF8String:type] : @"?";
            NSString *line = [NSString stringWithFormat:@"%@.%@ <%@>", NSStringFromClass(cls), ivarName, typeText];
            if (type && type[0] == '@') {
                @try {
                    id value = object_getIvar(object, ivar);
                    NSString *valueText = [self valueTextForLog:value limit:180];
                    if (valueText.length > 0) {
                        line = [line stringByAppendingFormat:@" = %@", valueText];
                    }
                } @catch (__unused NSException *exception) {
                }
            } else {
                NSString *primitiveValue = [self primitiveIvarValueForObject:object ivar:ivar type:type];
                if (primitiveValue.length > 0) {
                    line = [line stringByAppendingFormat:@" = %@", primitiveValue];
                }
            }
            [parts addObject:line];
        }
        if (ivars) {
            free(ivars);
        }
        cls = class_getSuperclass(cls);
        classDepth += 1;
    }

    if (parts.count > 0) {
        [log appendFormat:@"%@:\n", title ?: @"ivars"];
        for (NSString *part in parts) {
            [log appendFormat:@"  %@\n", part];
        }
    }
}

- (void)appendMethodSummaryForObject:(id)object title:(NSString *)title toLog:(NSMutableString *)log {
    if (!object) {
        return;
    }

    NSMutableArray<NSString *> *methods = [NSMutableArray array];
    Class cls = [object class];
    NSUInteger classDepth = 0;
    while (cls && cls != NSObject.class && classDepth < 5 && methods.count < 90) {
        unsigned int count = 0;
        Method *methodList = class_copyMethodList(cls, &count);
        NSMutableArray<NSString *> *classMethods = [NSMutableArray array];
        for (unsigned int i = 0; i < count && methods.count + classMethods.count < 90; i++) {
            SEL selector = method_getName(methodList[i]);
            if (selector) {
                [classMethods addObject:NSStringFromSelector(selector)];
            }
        }
        if (methodList) {
            free(methodList);
        }
        if (classMethods.count > 0) {
            [methods addObject:[NSString stringWithFormat:@"%@: %@", NSStringFromClass(cls), [classMethods componentsJoinedByString:@", "]]];
        }
        cls = class_getSuperclass(cls);
        classDepth += 1;
    }

    if (methods.count > 0) {
        [log appendFormat:@"%@:\n", title ?: @"methods"];
        for (NSString *line in methods) {
            [log appendFormat:@"  %@\n", [self truncateString:line limit:1100]];
        }
    }
}

- (void)appendGestureTargets:(UIGestureRecognizer *)gestureRecognizer toLog:(NSMutableString *)log {
    id targets = [self safeValueForKey:@"targets" object:gestureRecognizer] ?: [self safeValueForKey:@"_targets" object:gestureRecognizer];
    NSString *targetText = [self valueTextForLog:targets limit:900];
    if (targetText.length > 0) {
        [log appendFormat:@"gesture.targets = %@\n", targetText];
    }

    if ([targets isKindOfClass:[NSArray class]] || [targets isKindOfClass:[NSSet class]]) {
        NSArray *targetArray = [targets isKindOfClass:[NSSet class]] ? [(NSSet *)targets allObjects] : (NSArray *)targets;
        NSUInteger index = 0;
        for (id targetAction in targetArray) {
            if (index >= 8) {
                break;
            }
            [self appendObjectDump:targetAction name:[NSString stringWithFormat:@"gesture.targetAction[%lu]", (unsigned long)index] toLog:log depth:1];
            index += 1;
        }
    }
}

- (void)appendLuckyBagHeuristicsForText:(NSString *)text object:(id)object toLog:(NSMutableString *)log {
    NSMutableString *combined = [NSMutableString stringWithString:text ?: @""];
    if (object) {
        [combined appendFormat:@" %@", NSStringFromClass([object class])];
        [combined appendFormat:@" %@", [self safeShortDescription:object limit:300] ?: @""];
    }
    NSString *lower = combined.lowercaseString;

    NSString *bagType = @"未知";
    if ([combined containsString:@"超级福袋"] || [lower containsString:@"super"] || [lower containsString:@"mega"]) {
        bagType = @"可能是超级福袋";
    } else if ([combined containsString:@"福袋"] || [lower containsString:@"lucky"] || [lower containsString:@"lottery"]) {
        bagType = @"可能是普通福袋";
    } else if ([combined containsString:@"红包"] || [lower containsString:@"redenvelope"]) {
        bagType = @"可能是红包/福袋入口";
    }

    NSMutableArray<NSString *> *conditions = [NSMutableArray array];
    if ([combined containsString:@"发送"] || [combined containsString:@"评论"] || [combined containsString:@"弹幕"] || [combined containsString:@"口令"] || [lower containsString:@"comment"] || [lower containsString:@"danmu"] || [lower containsString:@"barrage"]) {
        [conditions addObject:@"评论/弹幕/口令"];
    }
    if ([combined containsString:@"粉丝团"] || [combined containsString:@"加团"] || [lower containsString:@"fans"]) {
        [conditions addObject:@"加入粉丝团"];
    }
    if ([combined containsString:@"关注"] || [lower containsString:@"follow"]) {
        [conditions addObject:@"关注主播"];
    }
    if ([combined containsString:@"下单"] || [combined containsString:@"购买"] || [lower containsString:@"order"] || [lower containsString:@"buy"]) {
        [conditions addObject:@"交易/下单"];
    }

    NSString *conditionText = conditions.count > 0 ? [conditions componentsJoinedByString:@", "] : @"未知";
    [log appendFormat:@"heuristic.bagType = %@\n", bagType];
    [log appendFormat:@"heuristic.condition = %@\n", conditionText];
    NSString *commentCandidate = [self commentCandidateFromText:combined];
    if (commentCandidate.length > 0) {
        [log appendFormat:@"heuristic.commentCandidate = %@\n", commentCandidate];
    }
    if (text.length > 0) {
        [log appendFormat:@"heuristic.visibleText = %@\n", [self truncateString:text limit:800]];
    }
}

#pragma mark - Text Helpers

- (NSString *)textForInteractionView:(UIView *)view target:(id)target action:(SEL)action {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (action) {
        [parts addObject:NSStringFromSelector(action)];
    }
    if (target) {
        [parts addObject:NSStringFromClass([target class])];
    }
    if (view) {
        [parts addObject:NSStringFromClass(view.class)];
        NSString *text = [self visibleTextAroundView:view];
        if (text.length > 0) {
            [parts addObject:text];
        }
        if (view.accessibilityLabel.length > 0) {
            [parts addObject:view.accessibilityLabel];
        }
        if (view.accessibilityIdentifier.length > 0) {
            [parts addObject:view.accessibilityIdentifier];
        }
    }
    return [parts componentsJoinedByString:@" "];
}

- (NSString *)visibleTextAroundView:(UIView *)view {
    if (!view) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *ownText = [self visibleTextInView:view maxDepth:4];
    if (ownText.length > 0) {
        [parts addObject:ownText];
    }

    UIView *parent = view.superview;
    for (NSUInteger i = 0; parent && i < 3; i++, parent = parent.superview) {
        NSString *parentText = [self visibleTextInView:parent maxDepth:2];
        if (parentText.length > 0) {
            [parts addObject:parentText];
        }
    }
    return [self deduplicatedTextFromParts:parts];
}

- (NSString *)visibleTextInView:(UIView *)view maxDepth:(NSUInteger)maxDepth {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [self collectVisibleTextInView:view parts:parts depth:0 maxDepth:maxDepth];
    return [self deduplicatedTextFromParts:parts];
}

- (void)collectVisibleTextInView:(UIView *)view parts:(NSMutableArray<NSString *> *)parts depth:(NSUInteger)depth maxDepth:(NSUInteger)maxDepth {
    if (!view || depth > maxDepth || view.hidden || view.alpha < 0.01) {
        return;
    }

    NSString *text = nil;
    if ([view isKindOfClass:[UILabel class]]) {
        text = ((UILabel *)view).text;
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        text = [button titleForState:UIControlStateNormal] ?: [button attributedTitleForState:UIControlStateNormal].string;
    } else if ([view isKindOfClass:[UITextView class]]) {
        text = ((UITextView *)view).text;
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *textField = (UITextField *)view;
        text = textField.text.length > 0 ? textField.text : textField.placeholder;
    }

    if (text.length > 0) {
        [parts addObject:text];
    }
    if (view.accessibilityLabel.length > 0) {
        [parts addObject:view.accessibilityLabel];
    }
    if (view.accessibilityIdentifier.length > 0) {
        [parts addObject:view.accessibilityIdentifier];
    }

    for (UIView *subview in view.subviews) {
        [self collectVisibleTextInView:subview parts:parts depth:depth + 1 maxDepth:maxDepth];
    }
}

- (NSString *)deduplicatedTextFromParts:(NSArray<NSString *> *)parts {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *part in parts) {
        NSString *trimmed = [[part stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0 || [seen containsObject:trimmed]) {
            continue;
        }
        [seen addObject:trimmed];
        [clean addObject:trimmed];
    }
    return [self truncateString:[clean componentsJoinedByString:@" | "] limit:1200];
}

- (NSString *)commentCandidateFromText:(NSString *)text {
    if (text.length == 0) {
        return nil;
    }

    NSArray<NSString *> *patterns = @[
        @"(?:发送|发|评论|弹幕|口令|输入|发表)[^\\n\\r:：\"“”'「」]*[:：\"“'「](.{1,60})[\"”'」]?",
        @"[\"“「](.{1,60})[\"”」].{0,12}(?:参与|福袋|评论|弹幕|口令)",
        @"(?:去发表评论|发表评论|发送弹幕)\\s*(.{1,40})"
    ];

    for (NSString *pattern in patterns) {
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:&error];
        if (error) {
            continue;
        }
        NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *candidate = [text substringWithRange:[match rangeAtIndex:1]];
            candidate = [[candidate stringByReplacingOccurrencesOfString:@"|" withString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (candidate.length > 0) {
                return [self truncateString:candidate limit:80];
            }
        }
    }
    return nil;
}

- (NSString *)superviewPathForView:(UIView *)view {
    if (!view) {
        return @"";
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *current = view;
    NSUInteger depth = 0;
    while (current && depth < 12) {
        [parts addObject:[NSString stringWithFormat:@"<%@: %p frame=%@>", NSStringFromClass(current.class), current, NSStringFromCGRect(current.frame)]];
        current = current.superview;
        depth += 1;
    }
    return [parts componentsJoinedByString:@" <- "];
}

- (NSString *)immediateSubviewsForView:(UIView *)view {
    if (!view.subviews.count) {
        return @"[]";
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger index = 0;
    for (UIView *subview in view.subviews) {
        if (index >= 30) {
            [parts addObject:@"..."];
            break;
        }
        NSString *text = [self visibleTextInView:subview maxDepth:1];
        [parts addObject:[NSString stringWithFormat:@"%lu:<%@: %p frame=%@ text=%@>", (unsigned long)index, NSStringFromClass(subview.class), subview, NSStringFromCGRect(subview.frame), text ?: @""]];
        index += 1;
    }
    return [parts componentsJoinedByString:@"; "];
}

#pragma mark - Runtime Helpers

- (NSString *)primitiveIvarValueForObject:(id)object ivar:(Ivar)ivar type:(const char *)type {
    if (!object || !ivar || !type) {
        return nil;
    }

    @try {
        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *bytes = (uint8_t *)(__bridge void *)object;
        void *valuePointer = bytes + offset;

        switch (type[0]) {
            case ':': {
                SEL selector = *(SEL *)valuePointer;
                return selector ? NSStringFromSelector(selector) : nil;
            }
            case '#': {
                Class cls = *(Class *)valuePointer;
                return cls ? NSStringFromClass(cls) : nil;
            }
            case 'B': {
                BOOL value = *(BOOL *)valuePointer;
                return value ? @"YES" : @"NO";
            }
            case 'c': {
                char value = *(char *)valuePointer;
                return [NSString stringWithFormat:@"%d", value];
            }
            case 'C': {
                unsigned char value = *(unsigned char *)valuePointer;
                return [NSString stringWithFormat:@"%u", value];
            }
            case 's': {
                short value = *(short *)valuePointer;
                return [NSString stringWithFormat:@"%hd", value];
            }
            case 'S': {
                unsigned short value = *(unsigned short *)valuePointer;
                return [NSString stringWithFormat:@"%hu", value];
            }
            case 'i': {
                int value = *(int *)valuePointer;
                return [NSString stringWithFormat:@"%d", value];
            }
            case 'I': {
                unsigned int value = *(unsigned int *)valuePointer;
                return [NSString stringWithFormat:@"%u", value];
            }
            case 'l': {
                long value = *(long *)valuePointer;
                return [NSString stringWithFormat:@"%ld", value];
            }
            case 'L': {
                unsigned long value = *(unsigned long *)valuePointer;
                return [NSString stringWithFormat:@"%lu", value];
            }
            case 'q': {
                long long value = *(long long *)valuePointer;
                return [NSString stringWithFormat:@"%lld", value];
            }
            case 'Q': {
                unsigned long long value = *(unsigned long long *)valuePointer;
                return [NSString stringWithFormat:@"%llu", value];
            }
            case 'f': {
                float value = *(float *)valuePointer;
                return [NSString stringWithFormat:@"%f", value];
            }
            case 'd': {
                double value = *(double *)valuePointer;
                return [NSString stringWithFormat:@"%f", value];
            }
            case '^': {
                void *pointer = *(void **)valuePointer;
                return pointer ? [NSString stringWithFormat:@"%p", pointer] : nil;
            }
            default:
                return nil;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (id)safeValueForKey:(NSString *)key object:(id)object {
    if (!key.length || !object) {
        return nil;
    }

    @try {
        id value = [object valueForKey:key];
        if (value && value != NSNull.null) {
            return value;
        }
    } @catch (__unused NSException *exception) {
    }

    SEL selector = NSSelectorFromString(key);
    id selectorValue = [self safeInvokeZeroArgumentSelector:selector object:object];
    if (selectorValue) {
        return selectorValue;
    }

    if (![key hasPrefix:@"_"]) {
        NSString *underscoreKey = [@"_" stringByAppendingString:key];
        @try {
            id value = [object valueForKey:underscoreKey];
            if (value && value != NSNull.null) {
                return value;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    NSString *capitalized = key.length > 0 ? [key stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:[[key substringToIndex:1] uppercaseString]] : key;
    SEL getter = NSSelectorFromString([NSString stringWithFormat:@"get%@", capitalized]);
    return [self safeInvokeZeroArgumentSelector:getter object:object];
}

- (id)safeInvokeZeroArgumentSelector:(SEL)selector object:(id)object {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    while (returnType[0] == 'r' || returnType[0] == 'n' || returnType[0] == 'N' || returnType[0] == 'o' || returnType[0] == 'O' || returnType[0] == 'R' || returnType[0] == 'V') {
        returnType++;
    }
    if (returnType[0] == 'v') {
        return nil;
    }

    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = object;
        invocation.selector = selector;
        [invocation invoke];

        switch (returnType[0]) {
            case '@':
            case '#': {
                __unsafe_unretained id value = nil;
                [invocation getReturnValue:&value];
                return value && value != NSNull.null ? value : nil;
            }
            case 'B': {
                BOOL value = NO;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'c': {
                char value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'C': {
                unsigned char value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 's': {
                short value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'S': {
                unsigned short value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'i': {
                int value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'I': {
                unsigned int value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'l': {
                long value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'L': {
                unsigned long value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'q': {
                long long value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'Q': {
                unsigned long long value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'f': {
                float value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'd': {
                double value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case '*': {
                char *value = NULL;
                [invocation getReturnValue:&value];
                return value ? [NSString stringWithUTF8String:value] : nil;
            }
            default:
                return nil;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSString *)valueTextForLog:(id)value limit:(NSUInteger)limit {
    if (!value || value == NSNull.null) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [self truncateString:value limit:limit];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    if ([value isKindOfClass:[NSURL class]]) {
        return [self truncateString:[(NSURL *)value absoluteString] limit:limit];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *items = [NSMutableArray array];
        NSUInteger index = 0;
        for (id item in (NSArray *)value) {
            if (index >= 12) {
                [items addObject:@"..."];
                break;
            }
            [items addObject:[self safeShortDescription:item limit:120] ?: @""];
            index += 1;
        }
        return [self truncateString:[NSString stringWithFormat:@"[%@]", [items componentsJoinedByString:@", "]] limit:limit];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableArray<NSString *> *items = [NSMutableArray array];
        NSUInteger index = 0;
        for (id key in (NSDictionary *)value) {
            if (index >= 16) {
                [items addObject:@"..."];
                break;
            }
            id item = [(NSDictionary *)value objectForKey:key];
            [items addObject:[NSString stringWithFormat:@"%@:%@", [self safeShortDescription:key limit:80], [self safeShortDescription:item limit:120]]];
            index += 1;
        }
        return [self truncateString:[NSString stringWithFormat:@"{%@}", [items componentsJoinedByString:@", "]] limit:limit];
    }
    return [NSString stringWithFormat:@"<%@: %p> %@", NSStringFromClass([value class]), value, [self safeShortDescription:value limit:limit]];
}

- (NSString *)safeShortDescription:(id)object limit:(NSUInteger)limit {
    if (!object || object == NSNull.null) {
        return nil;
    }
    @try {
        NSString *description = [object description];
        if (![description isKindOfClass:NSString.class]) {
            return nil;
        }
        description = [description stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        return [self truncateString:description limit:limit];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSString *)truncateString:(NSString *)string limit:(NSUInteger)limit {
    if (string.length <= limit || limit == 0) {
        return string ?: @"";
    }
    return [[string substringToIndex:limit] stringByAppendingString:@"..."];
}

@end
