#import "DYYYLiveLuckyBagManager.h"
#import "AwemeHeaders.h"
#import "DYYYBottomAlertView.h"
#import "DYYYLiveLuckyBagDebugView.h"
#import "DYYYUtils.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stddef.h>
#import <stdint.h>

static NSString *const kDYYYAutoJoinLiveLuckyBagKey = @"DYYYAutoJoinLiveLuckyBag";
static NSString *const kDYYYLiveLuckyBagDebugKey = @"DYYYLiveLuckyBagDebug";
static NSUInteger const kDYYYLiveLuckyBagMaxLogItems = 160;
static NSTimeInterval const kDYYYLiveLuckyBagAutoEntryCooldown = 12.0;
static NSTimeInterval const kDYYYLiveLuckyBagCommentSendWindow = 12.0;
static NSTimeInterval const kDYYYLiveLuckyBagSensitivePromptCooldown = 18.0;
static NSUInteger const kDYYYLiveLuckyBagPanelScanMaxAttempts = 24;
static NSUInteger const kDYYYLiveLuckyBagCommentScanMaxAttempts = 20;
static NSTimeInterval const kDYYYLiveLuckyBagPanelScanInterval = 0.5;

typedef struct __IOHIDEvent *DYYYIOHIDEventRef;
typedef uint32_t DYYYIOOptionBits;
typedef unsigned char DYYYBoolean;

@interface DYYYLiveLuckyBagManager ()
@property(nonatomic, strong) NSMutableArray<NSString *> *logItems;
@property(nonatomic, strong) NSMutableSet<NSString *> *loggedViewKeys;
@property(nonatomic, strong) NSMutableSet<NSString *> *autoProcessedViewKeys;
@property(nonatomic, strong) NSMutableSet<NSString *> *autoProcessedWebKeys;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *recentEventDates;
@property(nonatomic, strong) NSDateFormatter *dateFormatter;
@property(nonatomic, strong) DYYYLiveLuckyBagDebugView *debugView;
@property(nonatomic, weak) UIViewController *currentAudienceViewController;
@property(nonatomic, strong) id currentRoomModel;
@property(nonatomic, copy) NSString *currentRoomIdentifier;
@property(nonatomic, copy) NSString *pendingCommentText;
@property(nonatomic, strong) NSDate *lastAutoEntryActionDate;
@property(nonatomic, strong) NSDate *commentSendDeadline;
@property(nonatomic, strong) NSDate *sensitivePromptCooldownDate;
@property(nonatomic, strong) NSDate *sensitiveActionApprovedUntil;
@property(nonatomic, weak) UIView *pendingSensitiveControl;
@property(nonatomic, strong) UIViewController *autoAlertController;
@property(nonatomic, copy) NSDictionary *latestLuckyBagInfo;
@property(nonatomic, copy) NSString *lastParticipationSuccessKey;
@property(nonatomic, strong) NSDate *lastParticipationSuccessDate;
@property(nonatomic, assign) BOOL commentConditionCompleted;
@property(nonatomic, assign) BOOL inLiveRoom;
@property(nonatomic, assign) BOOL autoFlowActive;
@property(nonatomic, assign) BOOL autoSensitivePromptVisible;
@property(nonatomic, assign) NSUInteger eventSequence;
@property(nonatomic, assign) NSUInteger autoFlowGeneration;
@property(nonatomic, copy) NSString *activeLuckyBagKey;
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

+ (BOOL)isAutoJoinEnabled {
    return DYYYGetBool(kDYYYAutoJoinLiveLuckyBagKey);
}

+ (BOOL)isDebugEnabled {
    return DYYYGetBool(kDYYYLiveLuckyBagDebugKey);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logItems = [NSMutableArray array];
        _loggedViewKeys = [NSMutableSet set];
        _autoProcessedViewKeys = [NSMutableSet set];
        _autoProcessedWebKeys = [NSMutableSet set];
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
    BOOL debugEnabled = [DYYYLiveLuckyBagManager isDebugEnabled];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.currentRoomModel = roomModel;
      self.currentAudienceViewController = viewController;
      self.currentRoomIdentifier = [self roomIdentifierFromObject:roomModel] ?: [self roomIdentifierFromObject:viewController];
      self.inLiveRoom = YES;
      self.autoFlowGeneration += 1;
      self.autoFlowActive = NO;
      self.pendingCommentText = nil;
      self.lastAutoEntryActionDate = nil;
      self.commentSendDeadline = nil;
      self.sensitivePromptCooldownDate = nil;
      self.sensitiveActionApprovedUntil = nil;
      self.pendingSensitiveControl = nil;
      [self dismissAutoAlertControllerWithoutCallbacks];
      self.latestLuckyBagInfo = nil;
      self.lastParticipationSuccessKey = nil;
      self.lastParticipationSuccessDate = nil;
      self.commentConditionCompleted = NO;
      self.autoSensitivePromptVisible = NO;
      self.activeLuckyBagKey = nil;
      [self.loggedViewKeys removeAllObjects];
      [self.autoProcessedViewKeys removeAllObjects];
      [self.autoProcessedWebKeys removeAllObjects];

      if (!debugEnabled) {
          return;
      }

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
    BOOL debugEnabled = [DYYYLiveLuckyBagManager isDebugEnabled];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (debugEnabled) {
          NSMutableString *log = [NSMutableString string];
          [log appendString:@"Hook: IESLiveAudienceViewController didCloseRoom:/dealloc\n"];
          [self appendObjectDump:roomModel name:@"roomModelOrVC" toLog:log depth:0];
          [self appendEventWithTitle:@"离开直播间" body:log];
      }

      self.currentRoomModel = nil;
      self.currentAudienceViewController = nil;
      self.currentRoomIdentifier = nil;
      self.inLiveRoom = NO;
      self.autoFlowGeneration += 1;
      self.autoFlowActive = NO;
      self.pendingCommentText = nil;
      self.lastAutoEntryActionDate = nil;
      self.commentSendDeadline = nil;
      self.sensitivePromptCooldownDate = nil;
      self.sensitiveActionApprovedUntil = nil;
      self.pendingSensitiveControl = nil;
      [self dismissAutoAlertControllerWithoutCallbacks];
      self.latestLuckyBagInfo = nil;
      self.lastParticipationSuccessKey = nil;
      self.lastParticipationSuccessDate = nil;
      self.commentConditionCompleted = NO;
      self.autoSensitivePromptVisible = NO;
      self.activeLuckyBagKey = nil;
      [self.loggedViewKeys removeAllObjects];
      [self.autoProcessedViewKeys removeAllObjects];
      [self.autoProcessedWebKeys removeAllObjects];
    });
}

- (void)handleLuckyBagViewAppeared:(UIView *)view {
    if (!view) {
        return;
    }

    BOOL debugEnabled = [DYYYLiveLuckyBagManager isDebugEnabled];
    BOOL autoEnabled = [DYYYLiveLuckyBagManager isAutoJoinEnabled];
    if (!debugEnabled && !autoEnabled) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (autoEnabled) {
          [self tryAutoOpenLuckyBagFromView:view];
      }

      if (!debugEnabled) {
          return;
      }

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

- (void)handleWebContainerViewAppeared:(UIView *)view {
    if (!view || ![DYYYLiveLuckyBagManager isAutoJoinEnabled]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self canRunAutoFlow]) {
          return;
      }
      NSUInteger generation = self.autoFlowGeneration;
      self.autoFlowActive = YES;
      [self scheduleLuckyBagPanelScanWithGeneration:generation attempt:0];
    });
}

- (void)handleNativeAlertViewAppeared:(UIView *)alertView {
    if (!alertView || ![DYYYLiveLuckyBagManager isAutoJoinEnabled]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [self tryAutoHandleNativeAlert:alertView];
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
    if (!textInputView || [self viewIsInsideDebugWindow:textInputView]) {
        return;
    }

    NSString *safeText = text ?: @"";
    BOOL debugEnabled = [DYYYLiveLuckyBagManager isDebugEnabled];
    BOOL autoEnabled = [DYYYLiveLuckyBagManager isAutoJoinEnabled];
    if (!debugEnabled && !autoEnabled) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (autoEnabled) {
          [self tryAutoSendCommentFromTextInputView:textInputView text:safeText];
      }

      if (!debugEnabled) {
          return;
      }

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

#pragma mark - Auto Join

- (BOOL)canRunAutoFlow {
    return self.inLiveRoom && [DYYYLiveLuckyBagManager isAutoJoinEnabled];
}

- (BOOL)isAutoFlowGenerationCurrent:(NSUInteger)generation {
    return generation == self.autoFlowGeneration && [self canRunAutoFlow];
}

- (void)scheduleLuckyBagPanelScanWithGeneration:(NSUInteger)generation attempt:(NSUInteger)attempt {
    if (![self isAutoFlowGenerationCurrent:generation]) {
        return;
    }
    if (attempt > kDYYYLiveLuckyBagPanelScanMaxAttempts) {
        [self appendAutoLog:@"未找到福袋面板" detail:@"入口已点击，但超时未识别到普通福袋弹窗"];
        self.autoFlowActive = NO;
        return;
    }

    NSTimeInterval delay = attempt == 0 ? 0.15 : kDYYYLiveLuckyBagPanelScanInterval;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation]) {
          return;
      }

      NSArray *webViews = [strongSelf visibleJavaScriptWebViewsInActiveWindows];
      if (webViews.count == 0) {
          [strongSelf scheduleLuckyBagPanelScanWithGeneration:generation attempt:attempt + 1];
          return;
      }
      [strongSelf scanLuckyBagWebViews:webViews index:0 generation:generation attempt:attempt];
    });
}

- (void)scanLuckyBagWebViews:(NSArray *)webViews index:(NSUInteger)index generation:(NSUInteger)generation attempt:(NSUInteger)attempt {
    if (![self isAutoFlowGenerationCurrent:generation]) {
        return;
    }
    if (index >= webViews.count) {
        [self scheduleLuckyBagPanelScanWithGeneration:generation attempt:attempt + 1];
        return;
    }

    id webView = webViews[index];
    if (![self webViewIsVisibleForAutoScan:webView]) {
        [self scanLuckyBagWebViews:webViews index:index + 1 generation:generation attempt:attempt];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self evaluateLuckyBagWebInfoInWebView:webView completion:^(NSDictionary *info) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation]) {
          return;
      }

      NSString *combined = [strongSelf webInfoCombinedText:info];
      if (![strongSelf webTextLooksLuckyBagPanel:combined]) {
          [strongSelf scanLuckyBagWebViews:webViews index:index + 1 generation:generation attempt:attempt];
          return;
      }

      [strongSelf processLuckyBagPanelInfo:info webView:webView generation:generation attempt:attempt];
    }];
}

- (void)processLuckyBagPanelInfo:(NSDictionary *)info webView:(id)webView generation:(NSUInteger)generation attempt:(NSUInteger)attempt {
    if (![self isAutoFlowGenerationCurrent:generation]) {
        return;
    }

    NSString *combined = [self webInfoCombinedText:info];
    NSDictionary *luckyBagInfo = [self luckyBagInfoFromWebInfo:info combinedText:combined];
    if (luckyBagInfo.count > 0) {
        self.latestLuckyBagInfo = luckyBagInfo;
    }

    if ([self isSuperLuckyBagText:combined]) {
        self.autoFlowActive = NO;
        [self appendAutoLog:@"跳过超级福袋" detail:[self truncateString:combined limit:180]];
        return;
    }

    if ([self textLooksAlreadyParticipated:combined]) {
        self.autoFlowActive = NO;
        self.pendingCommentText = nil;
        self.commentSendDeadline = nil;
        [self showParticipationSuccessWithInfo:luckyBagInfo.count > 0 ? luckyBagInfo : self.latestLuckyBagInfo fallbackText:combined];
        [self appendAutoLog:@"福袋已参与" detail:[self truncateString:combined limit:180]];
        return;
    }

    NSString *conditionSegment = [luckyBagInfo[@"conditionSegment"] isKindOfClass:NSString.class] ? luckyBagInfo[@"conditionSegment"] : [self conditionSegmentFromText:combined];
    NSString *commentText = [luckyBagInfo[@"commentText"] isKindOfClass:NSString.class] ? luckyBagInfo[@"commentText"] : [self commentCandidateFromText:conditionSegment];
    BOOL hasCommentCondition = commentText.length > 0 || [self textLooksCommentCondition:conditionSegment];
    NSArray<NSString *> *sensitiveConditions = [self sensitiveConditionsFromLuckyBagInfo:luckyBagInfo text:combined];

    if (!self.commentConditionCompleted && hasCommentCondition) {
        NSArray *buttons = [info[@"buttons"] isKindOfClass:NSArray.class] ? info[@"buttons"] : @[];
        NSDictionary *commentButton = [self commentActionButtonFromButtons:buttons];
        if (!commentButton && attempt < kDYYYLiveLuckyBagPanelScanMaxAttempts) {
            [self scheduleLuckyBagPanelScanWithGeneration:generation attempt:attempt + 1];
            return;
        }

        self.pendingCommentText = [self commentTextLooksSafe:commentText] ? commentText : nil;
        self.commentSendDeadline = [NSDate dateWithTimeIntervalSinceNow:kDYYYLiveLuckyBagCommentSendWindow];
        self.autoFlowActive = YES;
        NSString *buttonText = [commentButton[@"text"] isKindOfClass:NSString.class] ? commentButton[@"text"] : @"去发表评论";
        NSString *actionKey = [NSString stringWithFormat:@"%@-comment-%@", self.activeLuckyBagKey ?: self.currentRoomIdentifier ?: @"room", buttonText ?: @""];
        if ([self.autoProcessedWebKeys containsObject:actionKey]) {
            [self scheduleOfficialCommentScanWithGeneration:generation attempt:0];
            return;
        }
        [self.autoProcessedWebKeys addObject:actionKey];
        [self appendAutoLog:@"识别到福袋评论条件" detail:commentText.length > 0 ? commentText : @"官方评论文案将由抖音输入框预填"];

        __weak typeof(self) weakSelf = self;
        [self clickLuckyBagWebButtonWithText:buttonText webView:webView completion:^(BOOL clicked) {
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation]) {
              return;
          }
          if (clicked) {
              [strongSelf appendAutoLog:@"自动点击去发表评论" detail:buttonText ?: @"去发表评论"];
              [strongSelf scheduleOfficialCommentScanWithGeneration:generation attempt:0];
          } else {
              [strongSelf appendAutoLog:@"自动点击去发表评论失败" detail:buttonText ?: @"去发表评论"];
              [strongSelf scheduleLuckyBagPanelScanWithGeneration:generation attempt:attempt + 1];
          }
        }];
        return;
    }

    if (sensitiveConditions.count > 0 && ![self hasRecentSensitiveApproval]) {
        [self showSensitiveConditionPromptWithInfo:luckyBagInfo text:combined control:nil webView:nil];
        return;
    }

    if (sensitiveConditions.count > 0 && [self hasRecentSensitiveApproval]) {
        __weak typeof(self) weakSelf = self;
        [self clickLuckyBagSensitiveWebButtonInWebView:webView completion:^(BOOL clicked) {
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation]) {
              return;
          }
          [strongSelf appendAutoLog:clicked ? @"自动点击已确认的敏感条件按钮" : @"未找到已确认的敏感条件按钮" detail:[sensitiveConditions componentsJoinedByString:@", "]];
          if (clicked) {
              [strongSelf scheduleLuckyBagPanelScanWithGeneration:generation attempt:attempt + 1];
          }
        }];
        return;
    }

    NSArray *buttons = [info[@"buttons"] isKindOfClass:NSArray.class] ? info[@"buttons"] : @[];
    NSDictionary *participateButton = [self participationActionButtonFromButtons:buttons];
    if (participateButton) {
        NSString *buttonText = [participateButton[@"text"] isKindOfClass:NSString.class] ? participateButton[@"text"] : @"参与";
        __weak typeof(self) weakSelf = self;
        [self clickLuckyBagWebButtonWithText:buttonText webView:webView completion:^(BOOL clicked) {
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation]) {
              return;
          }
          [strongSelf appendAutoLog:clicked ? @"自动点击福袋参与按钮" : @"自动点击福袋参与按钮失败" detail:buttonText ?: @"参与"];
          if (clicked) {
              [strongSelf scheduleLuckyBagPanelScanWithGeneration:generation attempt:attempt + 1];
          }
        }];
        return;
    }

    if (attempt < kDYYYLiveLuckyBagPanelScanMaxAttempts) {
        [self scheduleLuckyBagPanelScanWithGeneration:generation attempt:attempt + 1];
    }
}

- (void)scheduleOfficialCommentScanWithGeneration:(NSUInteger)generation attempt:(NSUInteger)attempt {
    if (![self isAutoFlowGenerationCurrent:generation] || !self.commentSendDeadline) {
        return;
    }
    if (attempt > kDYYYLiveLuckyBagCommentScanMaxAttempts || [[NSDate date] compare:self.commentSendDeadline] == NSOrderedDescending) {
        self.commentSendDeadline = nil;
        [self appendAutoLog:@"未找到福袋弹幕输入框" detail:@"已点击去发表评论，但未检测到官方预填弹幕输入框"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation] || !strongSelf.commentSendDeadline) {
          return;
      }

      UIView *inputView = [strongSelf visibleOfficialCommentInputView];
      if (!inputView) {
          [strongSelf scheduleOfficialCommentScanWithGeneration:generation attempt:attempt + 1];
          return;
      }

      NSString *text = [strongSelf textFromInputView:inputView];
      if (text.length == 0 && strongSelf.pendingCommentText.length > 0) {
          text = strongSelf.pendingCommentText;
      }
      [strongSelf tryAutoSendCommentFromTextInputView:inputView text:text];
      if (strongSelf.commentSendDeadline) {
          [strongSelf scheduleOfficialCommentScanWithGeneration:generation attempt:attempt + 1];
      }
    });
}

- (void)tryAutoOpenLuckyBagFromView:(UIView *)view {
    if (![self canRunAutoFlow] || ![self viewIsVisibleAndTouchable:view] || ![self viewRepresentsOrdinaryLuckyBagEntry:view]) {
        return;
    }

    NSDate *now = [NSDate date];
    if (self.lastAutoEntryActionDate && [now timeIntervalSinceDate:self.lastAutoEntryActionDate] < kDYYYLiveLuckyBagAutoEntryCooldown) {
        return;
    }

    NSString *viewKey = [NSString stringWithFormat:@"%@-%@-%p", self.currentRoomIdentifier ?: @"room", NSStringFromClass(view.class), view];
    if ([self.autoProcessedViewKeys containsObject:viewKey]) {
        return;
    }
    [self.autoProcessedViewKeys addObject:viewKey];
    self.lastAutoEntryActionDate = now;
    self.autoFlowGeneration += 1;
    NSUInteger generation = self.autoFlowGeneration;
    self.autoFlowActive = YES;
    self.commentConditionCompleted = NO;
    self.latestLuckyBagInfo = nil;
    self.pendingCommentText = nil;
    self.commentSendDeadline = nil;
    self.activeLuckyBagKey = viewKey;

    __weak typeof(self) weakSelf = self;
    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      UIView *strongView = weakView;
      if (!strongSelf || !strongView || ![strongSelf isAutoFlowGenerationCurrent:generation] || ![strongSelf viewIsVisibleAndTouchable:strongView]) {
          return;
      }

      BOOL tapped = [strongSelf performSyntheticTapForView:strongView];
      if (!tapped) {
          tapped = [strongSelf tapControlOrView:strongView];
      }
      if (tapped) {
          [strongSelf appendAutoLog:@"自动点击普通福袋入口" detail:NSStringFromClass(strongView.class)];
      } else {
          [DYYYUtils showToast:@"自动参与福袋：无法点击福袋入口，已保留调试采集"];
          [strongSelf appendAutoLog:@"自动点击普通福袋入口失败" detail:NSStringFromClass(strongView.class)];
      }
      [strongSelf scheduleLuckyBagPanelScanWithGeneration:generation attempt:0];
    });
}

- (void)tryAutoHandleWebLuckyBagFromView:(UIView *)view retryCount:(NSUInteger)retryCount {
    if (![self canRunAutoFlow] || !view || [self viewIsInsideDebugWindow:view]) {
        return;
    }

    self.autoFlowActive = YES;
    [self scheduleLuckyBagPanelScanWithGeneration:self.autoFlowGeneration attempt:MIN(retryCount, (NSUInteger)2)];
}

- (void)tryAutoHandleNativeAlert:(UIView *)alertView {
    if (![self canRunAutoFlow] || ![self viewAndAncestorsAreVisible:alertView]) {
        return;
    }

    NSString *visibleText = [self visibleTextInView:alertView maxDepth:6];
    NSString *title = [self valueTextForLog:[self safeValueForKey:@"title" object:alertView] limit:120] ?: @"";
    NSString *message = [self valueTextForLog:[self safeValueForKey:@"message" object:alertView] limit:400] ?: @"";
    NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", title, message, visibleText ?: @""];
    if (![combined containsString:@"福袋"] && ![combined containsString:@"粉丝团"] && ![combined containsString:@"钻石"]) {
        return;
    }

    if ([self textLooksAlreadyParticipated:combined]) {
        self.autoFlowActive = NO;
        self.pendingCommentText = nil;
        self.commentSendDeadline = nil;
        [self showParticipationSuccessWithInfo:self.latestLuckyBagInfo fallbackText:combined];
        return;
    }

    UIView *confirmButton = [self positiveButtonInAlertView:alertView];
    if (!confirmButton) {
        return;
    }

    NSDictionary *info = [self luckyBagInfoFromWebInfo:@{ @"text" : combined } combinedText:combined];
    NSArray<NSString *> *sensitiveConditions = [self sensitiveConditionsFromLuckyBagInfo:info text:combined];
    if (sensitiveConditions.count > 0 && ![self hasRecentSensitiveApproval]) {
        self.pendingSensitiveControl = confirmButton;
        if (info.count > 0) {
            self.latestLuckyBagInfo = info;
        }
        [self showSensitiveConditionPromptWithInfo:info text:combined control:confirmButton webView:nil];
        return;
    }

    [self tapApprovedSensitiveControl:confirmButton detail:[self truncateString:combined limit:180]];
}

- (void)tryAutoSendCommentFromTextInputView:(UIView *)textInputView text:(NSString *)text {
    if (![self canRunAutoFlow] || !textInputView || !self.commentSendDeadline || [[NSDate date] compare:self.commentSendDeadline] == NSOrderedDescending) {
        return;
    }

    NSString *className = NSStringFromClass(textInputView.class);
    NSString *aroundText = [self visibleTextAroundView:textInputView];
    NSString *trimmedInput = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *candidate = trimmedInput.length > 0 ? trimmedInput : nil;
    NSString *expected = self.pendingCommentText;
    BOOL matchesExpectedComment = expected.length > 0 && ([candidate isEqualToString:expected] || [aroundText containsString:expected]);
    if ((!matchesExpectedComment && ![self textInputViewLooksLiveCommentInput:textInputView context:aroundText]) || ![self commentTextLooksSafe:candidate]) {
        return;
    }

    if (expected.length > 0 && ![candidate isEqualToString:expected]) {
        if (![aroundText containsString:expected]) {
            return;
        }
    }

    UIView *sendControl = [self sendControlNearTextInputView:textInputView];
    if (!sendControl) {
        __weak typeof(self) weakSelf = self;
        __weak UIView *weakTextInput = textInputView;
        NSUInteger generation = self.autoFlowGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          UIView *strongTextInput = weakTextInput;
          if (!strongSelf || !strongTextInput) {
              return;
          }
          if (![strongSelf isAutoFlowGenerationCurrent:generation]) {
              return;
          }
          UIView *retryControl = [strongSelf sendControlNearTextInputView:strongTextInput];
          if (retryControl) {
              [strongSelf tapCommentSendControl:retryControl commentText:candidate sourceClass:className];
          }
        });
        return;
    }

    [self tapCommentSendControl:sendControl commentText:candidate sourceClass:className];
}

- (void)tapCommentSendControl:(UIView *)sendControl commentText:(NSString *)commentText sourceClass:(NSString *)sourceClass {
    if (!self.commentSendDeadline || [[NSDate date] compare:self.commentSendDeadline] == NSOrderedDescending) {
        return;
    }

    BOOL tapped = [self tapControlOrView:sendControl];
    NSString *detail = [NSString stringWithFormat:@"%@ / %@", [self truncateString:commentText limit:80], sourceClass ?: @""];
    if (tapped) {
        self.commentSendDeadline = nil;
        self.pendingCommentText = nil;
        self.commentConditionCompleted = YES;
        [self appendAutoLog:@"自动发送福袋弹幕" detail:detail];
        [self handlePostCommentConditionResult];
    } else {
        [DYYYUtils showToast:@"自动参与福袋：未能点击发送按钮"];
        [self appendAutoLog:@"自动发送福袋弹幕失败" detail:detail];
    }
}

- (void)tapApprovedSensitiveControl:(UIView *)control detail:(NSString *)detail {
    if (!control || ![self canRunAutoFlow]) {
        return;
    }
    NSString *fingerprint = [NSString stringWithFormat:@"sensitive-confirm-%p", control];
    if (![self shouldLogFingerprint:fingerprint interval:3.0]) {
        return;
    }

    BOOL tapped = [self tapControlOrView:control];
    if (tapped) {
        self.autoFlowActive = YES;
        [self appendAutoLog:@"已确认敏感条件并点击官方按钮" detail:detail ?: @""];
    } else {
        [DYYYUtils showToast:@"自动参与福袋：未能点击官方确认按钮"];
        [self appendAutoLog:@"点击官方敏感条件确认按钮失败" detail:detail ?: @""];
    }
}

- (void)showSensitiveConditionPromptWithInfo:(NSDictionary *)info text:(NSString *)text control:(UIView *)control webView:(UIView *)webView {
    if (self.autoSensitivePromptVisible || self.autoAlertController) {
        return;
    }

    NSDate *now = [NSDate date];
    if (self.sensitivePromptCooldownDate && [now timeIntervalSinceDate:self.sensitivePromptCooldownDate] < kDYYYLiveLuckyBagSensitivePromptCooldown) {
        return;
    }
    self.sensitivePromptCooldownDate = now;
    self.autoSensitivePromptVisible = YES;

    NSDictionary *displayInfo = info.count > 0 ? info : self.latestLuckyBagInfo;
    NSArray<NSString *> *conditions = [self sensitiveConditionsFromLuckyBagInfo:displayInfo text:text];
    NSString *content = [self sensitivePromptContentWithInfo:displayInfo conditions:conditions fallbackText:text];
    NSString *detail = [self compactLuckyBagDetailFromInfo:displayInfo fallbackText:text];
    NSUInteger generation = self.autoFlowGeneration;
    __weak typeof(self) weakSelf = self;
    __weak UIView *weakControl = control;
    UIViewController *alertController = [DYYYBottomAlertView showAlertWithTitle:@"自动参与福袋"
                                                                        message:content
                                                                      avatarURL:nil
                                                               cancelButtonText:@"跳过本次"
                                                              confirmButtonText:@"确认继续"
                                                                   cancelAction:^{
                                                                     __strong typeof(weakSelf) strongSelf = weakSelf;
                                                                     if (!strongSelf) {
                                                                         return;
                                                                     }
                                                                     strongSelf.autoSensitivePromptVisible = NO;
                                                                     strongSelf.autoFlowActive = NO;
                                                                     strongSelf.pendingSensitiveControl = nil;
                                                                     strongSelf.autoAlertController = nil;
                                                                     [strongSelf appendAutoLog:@"用户跳过敏感福袋条件" detail:detail ?: @""];
                                                                   }
                                                                    closeAction:^{
                                                                      __strong typeof(weakSelf) strongSelf = weakSelf;
                                                                      if (!strongSelf) {
                                                                          return;
                                                                      }
                                                                      strongSelf.autoSensitivePromptVisible = NO;
                                                                      strongSelf.autoFlowActive = NO;
                                                                      strongSelf.pendingSensitiveControl = nil;
                                                                      strongSelf.autoAlertController = nil;
                                                                    }
                                                                  confirmAction:^{
                                                                    __strong typeof(weakSelf) strongSelf = weakSelf;
                                                                    if (!strongSelf) {
                                                                        return;
                                                                    }
                                                                    strongSelf.autoSensitivePromptVisible = NO;
                                                                    strongSelf.sensitivePromptCooldownDate = nil;
                                                                    strongSelf.pendingSensitiveControl = nil;
                                                                    strongSelf.autoAlertController = nil;
                                                                    strongSelf.sensitiveActionApprovedUntil = [NSDate dateWithTimeIntervalSinceNow:22.0];
                                                                    UIView *approvedControl = weakControl;
                                                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                      if (![strongSelf isAutoFlowGenerationCurrent:generation]) {
                                                                          return;
                                                                      }
                                                                      if (approvedControl) {
                                                                          [strongSelf tapApprovedSensitiveControl:approvedControl detail:detail ?: @""];
                                                                      } else {
                                                                          [strongSelf appendAutoLog:@"已确认敏感条件，继续扫描当前福袋面板" detail:detail ?: @""];
                                                                          [strongSelf scheduleLuckyBagPanelScanWithGeneration:generation attempt:0];
                                                                      }
                                                                    });
                                                                  }];
    if (!alertController) {
        self.autoSensitivePromptVisible = NO;
        self.autoFlowActive = NO;
        [DYYYUtils showToast:@"自动参与福袋：检测到敏感条件，请手动确认"];
        [self appendAutoLog:@"敏感条件弹窗展示失败，已停止自动处理" detail:detail ?: @""];
    } else {
        self.autoAlertController = alertController;
    }
}

- (BOOL)hasRecentSensitiveApproval {
    return self.sensitiveActionApprovedUntil && [[NSDate date] compare:self.sensitiveActionApprovedUntil] == NSOrderedAscending;
}

- (void)handlePostCommentConditionResult {
    NSDictionary *info = self.latestLuckyBagInfo ?: @{};
    NSArray<NSString *> *remainingConditions = [self sensitiveConditionsFromLuckyBagInfo:info text:info[@"rawText"] ?: @""];
    NSUInteger generation = self.autoFlowGeneration;
    if (remainingConditions.count > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation]) {
              return;
          }
          [strongSelf showSensitiveConditionPromptWithInfo:strongSelf.latestLuckyBagInfo text:strongSelf.latestLuckyBagInfo[@"rawText"] ?: @"" control:nil webView:nil];
        });
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation]) {
          return;
      }
      [strongSelf showParticipationSuccessWithInfo:strongSelf.latestLuckyBagInfo fallbackText:nil];
    });
}

- (void)showParticipationSuccessWithInfo:(NSDictionary *)info fallbackText:(NSString *)fallbackText {
    if (self.autoAlertController) {
        return;
    }
    NSDictionary *displayInfo = info.count > 0 ? info : [self luckyBagInfoFromWebInfo:@{ @"text" : fallbackText ?: @"" } combinedText:fallbackText ?: @""];
    NSString *content = [self displayValueFromInfo:displayInfo key:@"content" fallback:@"未识别"];
    NSString *participants = [self displayValueFromInfo:displayInfo key:@"participants" fallback:@"未识别"];
    NSString *countdown = [self displayValueFromInfo:displayInfo key:@"countdown" fallback:@"未识别"];
    NSString *successKey = [NSString stringWithFormat:@"%@-%@-%@-%@", self.currentRoomIdentifier ?: @"room", content, participants, countdown];
    NSDate *now = [NSDate date];
    if ([self.lastParticipationSuccessKey isEqualToString:successKey] && self.lastParticipationSuccessDate && [now timeIntervalSinceDate:self.lastParticipationSuccessDate] < 12.0) {
        return;
    }
    self.lastParticipationSuccessKey = successKey;
    self.lastParticipationSuccessDate = now;
    self.autoFlowActive = NO;

    NSString *message = [NSString stringWithFormat:@"已成功参与当前福袋。\n福袋内容：%@。\n%@人已参与。\n倒计时：%@。", content, participants, countdown];
    __weak typeof(self) weakSelf = self;
    UIViewController *alertController = [DYYYBottomAlertView showAlertWithTitle:@"自动参与福袋"
                                                                        message:message
                                                                      avatarURL:nil
                                                               cancelButtonText:@"关闭"
                                                              confirmButtonText:@"知道了"
                                                                   cancelAction:^{
                                                                     __strong typeof(weakSelf) strongSelf = weakSelf;
                                                                     strongSelf.autoAlertController = nil;
                                                                   }
                                                                    closeAction:^{
                                                                      __strong typeof(weakSelf) strongSelf = weakSelf;
                                                                      strongSelf.autoAlertController = nil;
                                                                    }
                                                                  confirmAction:^{
                                                                    __strong typeof(weakSelf) strongSelf = weakSelf;
                                                                    strongSelf.autoAlertController = nil;
                                                                  }];
    if (alertController) {
        self.autoAlertController = alertController;
    } else {
        [DYYYUtils showToast:@"已成功参与当前福袋"];
    }
}

- (void)dismissAutoAlertControllerWithoutCallbacks {
    UIViewController *alertController = self.autoAlertController;
    self.autoAlertController = nil;
    self.autoSensitivePromptVisible = NO;
    if (!alertController) {
        return;
    }
    if ([alertController isKindOfClass:NSClassFromString(@"AFDPrivacyHalfScreenViewController")]) {
        AFDPrivacyHalfScreenViewController *privacyController = (AFDPrivacyHalfScreenViewController *)alertController;
        privacyController.closeButtonClickedBlock = nil;
        privacyController.slideDismissBlock = nil;
        privacyController.tapDismissBlock = nil;
        privacyController.leftButtonClickedBlock = nil;
        privacyController.rightBtnClickedBlock = nil;
    }
    if (alertController.presentingViewController || alertController.view.window) {
        [alertController dismissViewControllerAnimated:NO completion:nil];
    }
}

- (void)appendAutoLog:(NSString *)title detail:(NSString *)detail {
    NSString *line = [NSString stringWithFormat:@"autoFlow = %@\nroom = %@\ndetail = %@\n",
                      self.autoFlowActive ? @"YES" : @"NO",
                      self.currentRoomIdentifier ?: @"unknown",
                      detail ?: @""];
    NSLog(@"[DYYY] %@ %@", title ?: @"自动参与福袋", detail ?: @"");
    if ([DYYYLiveLuckyBagManager isDebugEnabled]) {
        [self appendEventWithTitle:title ?: @"自动参与福袋" body:line];
    }
}

#pragma mark - Auto Web Helpers

- (id)webViewFromView:(UIView *)view {
    if (!view) {
        return nil;
    }
    if ([view respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")]) {
        return view;
    }
    id directWebView = [self javaScriptCapableWebViewFromObject:view];
    if (directWebView) {
        return directWebView;
    }

    id webView = [self firstSubviewInView:view matching:^BOOL(UIView *candidate) {
      return [candidate respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")] || [self javaScriptCapableWebViewFromObject:candidate] != nil;
    } maxDepth:6];
    if (webView) {
        id nestedWebView = [self javaScriptCapableWebViewFromObject:webView];
        return nestedWebView ?: webView;
    }

    UIView *current = view.superview;
    NSUInteger depth = 0;
    while (current && depth < 5) {
        if ([current respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")]) {
            return current;
        }
        id currentWebView = [self javaScriptCapableWebViewFromObject:current];
        if (currentWebView) {
            return currentWebView;
        }
        webView = [self firstSubviewInView:current matching:^BOOL(UIView *candidate) {
          return [candidate respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")] || [self javaScriptCapableWebViewFromObject:candidate] != nil;
        } maxDepth:3];
        if (webView) {
            id nestedWebView = [self javaScriptCapableWebViewFromObject:webView];
            return nestedWebView ?: webView;
        }
        current = current.superview;
        depth += 1;
    }
    return nil;
}

- (id)javaScriptCapableWebViewFromObject:(id)object {
    if (!object) {
        return nil;
    }
    if ([object respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")]) {
        return object;
    }

    for (NSString *key in @[ @"webView", @"wkWebView", @"WKWebView", @"innerWebView", @"realWebView", @"_webView", @"_wkWebView" ]) {
        id value = [self safeValueForKey:key object:object];
        if ([value respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")]) {
            return value;
        }
    }
    return nil;
}

- (BOOL)webViewLooksInsideLivePopup:(UIView *)webView {
    NSString *path = [self superviewPathForView:webView];
    return [path containsString:@"BDXPopup"] || [path containsString:@"HTSLivePopup"] || [path containsString:@"Live"];
}

- (void)evaluateLuckyBagWebInfoInWebView:(id)webView completion:(void (^)(NSDictionary *info))completion {
    NSString *script =
        @"(function(){"
         "function norm(s){return (s||'').replace(/\\s+/g,' ').trim();}"
         "function vis(e){if(!e)return false;var r=e.getBoundingClientRect();var st=getComputedStyle(e);return r.width>1&&r.height>1&&st.visibility!=='hidden'&&st.display!=='none'&&parseFloat(st.opacity||'1')>0.01;}"
         "var body=document.body;var bodyText=norm(body?body.innerText:'');"
         "var nodes=Array.prototype.slice.call(document.querySelectorAll('button,a,[role=button],input,div,span,p'));"
         "var buttons=[];var re=/参与|立即参与|去发表评论|发表评论|发送评论|发送弹幕|去完成|完成|加入|开通|支付|领取|报名/;"
         "for(var i=0;i<nodes.length&&buttons.length<80;i++){var e=nodes[i];if(!vis(e))continue;var t=norm(e.innerText||e.value||e.getAttribute('aria-label')||e.textContent||'');if(!t||t.length>40)continue;if(!re.test(t))continue;var r=e.getBoundingClientRect();buttons.push({text:t,tag:e.tagName||'',role:e.getAttribute('role')||'',x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height});}"
         "return JSON.stringify({title:document.title||'',url:location.href||'',text:bodyText.slice(0,2500),buttons:buttons});"
         "})();";
    [self evaluateJavaScript:script inWebView:webView completion:^(id result, NSError *error) {
      NSDictionary *info = nil;
      if ([result isKindOfClass:NSString.class]) {
          NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
          if (data) {
              id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
              if ([json isKindOfClass:NSDictionary.class]) {
                  info = json;
              }
          }
      } else if ([result isKindOfClass:NSDictionary.class]) {
          info = result;
      }
      if (completion) {
          completion(info ?: @{});
      }
    }];
}

- (NSString *)webInfoCombinedText:(NSDictionary *)info {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[ @"title", @"url", @"text" ]) {
        NSString *value = [info[key] isKindOfClass:NSString.class] ? info[key] : nil;
        if (value.length > 0) {
            [parts addObject:value];
        }
    }
    NSArray *buttons = [info[@"buttons"] isKindOfClass:NSArray.class] ? info[@"buttons"] : @[];
    for (NSDictionary *button in buttons) {
        if (![button isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *text = [button[@"text"] isKindOfClass:NSString.class] ? button[@"text"] : nil;
        if (text.length > 0) {
            [parts addObject:text];
        }
    }
    return [[parts componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSDictionary *)luckyBagInfoFromWebInfo:(NSDictionary *)info combinedText:(NSString *)combinedText {
    NSString *bodyText = [info[@"text"] isKindOfClass:NSString.class] ? info[@"text"] : @"";
    NSString *rawText = combinedText.length > 0 ? combinedText : bodyText;
    NSString *text = [self normalizedLuckyBagText:rawText];
    if (text.length == 0) {
        return @{};
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"rawText"] = text;

    NSString *participants = [self firstCapturedGroupInText:text
                                                   patterns:@[
                                                       @"([0-9][0-9,\\.万]*)\\s*人\\s*(?:已参加|已参与|参加|参与)",
                                                       @"参与人数\\s*[:：]?\\s*([0-9][0-9,\\.万]*)",
                                                       @"([0-9][0-9,\\.万]*)\\s*人"
                                                   ]];
    if (participants.length > 0) {
        result[@"participants"] = [self cleanLuckyBagField:participants limit:20];
    }

    NSString *countdown = [self firstCapturedGroupInText:text
                                                patterns:@[
                                                    @"([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\\s*倒计时",
                                                    @"倒计时\\s*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)",
                                                    @"([0-9]+\\s*(?:秒|分钟|分|小时))\\s*(?:后开奖|倒计时)"
                                                ]];
    if (countdown.length > 0) {
        result[@"countdown"] = [self cleanLuckyBagField:countdown limit:30];
    }

    NSString *conditionSegment = [self conditionSegmentFromText:text];
    if (conditionSegment.length > 0) {
        result[@"conditionSegment"] = conditionSegment;
    }

    NSString *commentText = conditionSegment.length > 0 ? [self commentCandidateFromText:conditionSegment] : nil;
    if (commentText.length > 0) {
        result[@"commentText"] = commentText;
    }

    NSString *content = [self luckyBagContentFromText:text];
    if (content.length > 0) {
        result[@"content"] = content;
    }

    NSArray<NSString *> *conditions = conditionSegment.length > 0 ? [self readableConditionsFromConditionSegment:conditionSegment] : @[];
    if (conditions.count > 0) {
        result[@"conditions"] = conditions;
    }
    return [result copy];
}

- (NSString *)conditionSegmentFromText:(NSString *)text {
    NSString *normalized = [self normalizedLuckyBagText:text];
    if (normalized.length == 0) {
        return @"";
    }

    NSRange startRange = [normalized rangeOfString:@"参与条件"];
    if (startRange.location == NSNotFound) {
        startRange = [normalized rangeOfString:@"参与任务"];
    }
    if (startRange.location == NSNotFound) {
        return @"";
    }

    NSUInteger start = NSMaxRange(startRange);
    NSString *segment = [normalized substringFromIndex:start];
    NSArray<NSString *> *endTokens = @[ @"去发表评论", @"立即参与", @"国家反诈", @"抖音提醒", @"活动规则", @"规则", @"开奖后", @"已参与", @"等待开奖" ];
    NSUInteger end = segment.length;
    for (NSString *token in endTokens) {
        NSRange range = [segment rangeOfString:token];
        if (range.location != NSNotFound) {
            end = MIN(end, range.location);
        }
    }
    segment = [segment substringToIndex:end];
    return [self cleanLuckyBagField:segment limit:180];
}

- (NSString *)luckyBagContentFromText:(NSString *)text {
    NSString *normalized = [self normalizedLuckyBagText:text];
    NSString *content = [self firstCapturedGroupInText:normalized
                                             patterns:@[
                                                 @"倒计时\\s*(?:[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)?\\s*(.{1,160}?)(?:\\s*参与条件|\\s*参与任务|\\s*国家反诈|$)",
                                                 @"(?:福袋内容|奖品|奖励)\\s*[:：]?\\s*(.{1,120}?)(?:\\s*参与条件|\\s*参与任务|\\s*倒计时|\\s*国家反诈|$)",
                                                 @"(\\d+个[^\\s]{1,80}(?:\\s*\\d+个福袋)?)\\s*(?:参与条件|参与任务)"
                                             ]];
    content = [self cleanLuckyBagField:content limit:120];
    if ([self string:content containsAny:@[ @"发送评论", @"去发表评论", @"未达成", @"参与条件", @"国家反诈" ]]) {
        content = @"";
    }
    return content;
}

- (NSArray<NSString *> *)readableConditionsFromConditionSegment:(NSString *)segment {
    NSMutableArray<NSString *> *conditions = [NSMutableArray array];
    NSString *commentText = [self commentCandidateFromText:segment];
    if (commentText.length > 0) {
        [conditions addObject:[NSString stringWithFormat:@"发送评论：%@", commentText]];
    } else if ([self textLooksCommentCondition:segment]) {
        [conditions addObject:@"发送评论"];
    }
    for (NSString *condition in [self sensitiveConditionsFromLuckyBagInfo:@{ @"conditionSegment" : segment ?: @"" } text:segment]) {
        if (![conditions containsObject:condition]) {
            [conditions addObject:condition];
        }
    }
    return [conditions copy];
}

- (NSArray<NSString *> *)sensitiveConditionsFromLuckyBagInfo:(NSDictionary *)info text:(NSString *)text {
    NSString *segment = [info[@"conditionSegment"] isKindOfClass:NSString.class] ? info[@"conditionSegment"] : nil;
    if (segment.length == 0) {
        segment = [self conditionSegmentFromText:text ?: @""];
    }
    if (segment.length == 0) {
        NSString *normalizedText = [self normalizedLuckyBagText:text ?: @""];
        if ([normalizedText containsString:@"福袋"] || [normalizedText containsString:@"此福袋额外附赠"]) {
            return @[];
        }
        segment = [self normalizedLuckyBagText:text ?: @""];
    }

    NSMutableArray<NSString *> *conditions = [NSMutableArray array];
    if ([self conditionSegment:segment containsAnyUnfinishedTokens:@[ @"粉丝团", @"加团", @"入团", @"加入粉丝" ]]) {
        [conditions addObject:@"加入主播粉丝团"];
    }
    if ([self conditionSegment:segment containsAnyUnfinishedTokens:@[ @"关注主播", @"关注该主播", @"先关注", @"需关注", @"需要关注", @"关注后", @"完成关注" ]]) {
        [conditions addObject:@"关注主播"];
    }
    if ([self conditionSegment:segment containsAnyUnfinishedTokens:@[ @"确认支付", @"支付", @"抖币", @"购买", @"下单", @"充值" ]] ||
        ([self conditionSegment:segment containsAnyUnfinishedTokens:@[ @"开通" ]] && ![segment containsString:@"去发表评论"])) {
        [conditions addObject:@"支付、购买或开通服务"];
    }
    if ([self conditionSegment:segment containsAnyUnfinishedTokens:@[ @"手机号", @"授权", @"实名", @"认证", @"验证" ]]) {
        [conditions addObject:@"授权或账号验证"];
    }
    if (conditions.count == 0 && segment.length > 0 && [self isSensitiveConditionText:segment] && ![self textLooksCommentCondition:segment]) {
        [conditions addObject:@"额外参与条件"];
    }
    return [conditions copy];
}

- (BOOL)conditionSegment:(NSString *)segment containsAnyUnfinishedTokens:(NSArray<NSString *> *)tokens {
    if (segment.length == 0) {
        return NO;
    }
    for (NSString *token in tokens) {
        NSRange range = [segment rangeOfString:token options:NSCaseInsensitiveSearch];
        if (range.location == NSNotFound) {
            continue;
        }
        NSUInteger location = range.location > 10 ? range.location - 10 : 0;
        NSUInteger end = MIN(segment.length, NSMaxRange(range) + 36);
        NSString *nearby = [segment substringWithRange:NSMakeRange(location, end - location)];
        if ([nearby containsString:@"已达成"] && ![nearby containsString:@"未达成"]) {
            continue;
        }
        return YES;
    }
    return NO;
}

- (NSString *)sensitivePromptContentWithInfo:(NSDictionary *)info conditions:(NSArray<NSString *> *)conditions fallbackText:(NSString *)fallbackText {
    NSMutableString *content = [NSMutableString stringWithString:@"当前福袋还需要完成以下条件：\n"];
    NSArray<NSString *> *displayConditions = conditions.count > 0 ? conditions : @[ @"额外参与条件" ];
    NSUInteger index = 1;
    for (NSString *condition in displayConditions) {
        [content appendFormat:@"%lu. %@\n", (unsigned long)index, condition];
        index += 1;
    }

    NSString *bagContent = [self displayValueFromInfo:info key:@"content" fallback:@"未识别"];
    NSString *participants = [self displayValueFromInfo:info key:@"participants" fallback:@"未识别"];
    NSString *countdown = [self displayValueFromInfo:info key:@"countdown" fallback:@"未识别"];
    [content appendFormat:@"\n福袋内容：%@。\n已参与人数：%@人。\n倒计时：%@。", bagContent, participants, countdown];
    return [self truncateString:content limit:420];
}

- (NSString *)compactLuckyBagDetailFromInfo:(NSDictionary *)info fallbackText:(NSString *)fallbackText {
    NSString *bagContent = [self displayValueFromInfo:info key:@"content" fallback:@"未识别"];
    NSString *participants = [self displayValueFromInfo:info key:@"participants" fallback:@"未识别"];
    NSString *countdown = [self displayValueFromInfo:info key:@"countdown" fallback:@"未识别"];
    NSString *conditions = [[self sensitiveConditionsFromLuckyBagInfo:info text:fallbackText ?: @""] componentsJoinedByString:@", "];
    return [NSString stringWithFormat:@"content=%@ participants=%@ countdown=%@ conditions=%@", bagContent, participants, countdown, conditions.length > 0 ? conditions : @"未识别"];
}

- (NSString *)displayValueFromInfo:(NSDictionary *)info key:(NSString *)key fallback:(NSString *)fallback {
    NSString *value = [info[key] isKindOfClass:NSString.class] ? info[key] : nil;
    value = [self cleanLuckyBagField:value limit:120];
    return value.length > 0 ? value : fallback;
}

- (NSString *)normalizedLuckyBagText:(NSString *)text {
    if (text.length == 0) {
        return @"";
    }
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *cleanParts = [NSMutableArray array];
    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) {
            [cleanParts addObject:trimmed];
        }
    }
    return [cleanParts componentsJoinedByString:@" "];
}

- (NSString *)cleanLuckyBagField:(NSString *)text limit:(NSUInteger)limit {
    NSString *clean = [self normalizedLuckyBagText:text ?: @""];
    clean = [clean stringByReplacingOccurrencesOfString:@"|" withString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([clean containsString:@"  "]) {
        clean = [clean stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return [self truncateString:clean limit:limit > 0 ? limit : 120];
}

- (NSString *)firstCapturedGroupInText:(NSString *)text patterns:(NSArray<NSString *> *)patterns {
    if (text.length == 0) {
        return nil;
    }
    for (NSString *pattern in patterns) {
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:&error];
        if (error) {
            continue;
        }
        NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (!match || match.numberOfRanges <= 1) {
            continue;
        }
        for (NSUInteger index = 1; index < match.numberOfRanges; index++) {
            NSRange range = [match rangeAtIndex:index];
            if (range.location != NSNotFound && range.length > 0) {
                NSString *value = [text substringWithRange:range];
                value = [self cleanLuckyBagField:value limit:160];
                if (value.length > 0) {
                    return value;
                }
            }
        }
    }
    return nil;
}

- (NSDictionary *)bestLuckyBagWebButtonFromButtons:(NSArray *)buttons bodyText:(NSString *)bodyText allowSensitive:(BOOL)allowSensitive {
    NSDictionary *bestButton = nil;
    NSInteger bestScore = NSIntegerMin;
    for (id item in buttons) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *text = [item[@"text"] isKindOfClass:NSString.class] ? item[@"text"] : @"";
        if (![self webButtonTextLooksActionable:text]) {
            continue;
        }
        if (!allowSensitive && [self isSensitiveConditionText:text]) {
            continue;
        }

        NSInteger score = [self webButtonActionScore:text bodyText:bodyText ?: @""];
        if (score > bestScore) {
            bestScore = score;
            bestButton = item;
        }
    }
    return bestScore > 0 ? bestButton : nil;
}

- (BOOL)webButtonTextLooksActionable:(NSString *)text {
    if (text.length == 0) {
        return NO;
    }
    if ([self string:text containsAny:@[ @"取消", @"关闭", @"知道", @"规则", @"查看", @"返回", @"稍后", @"放弃" ]]) {
        return NO;
    }
    return [self string:text containsAny:@[ @"立即参与", @"参与", @"去发表评论", @"发表评论", @"发送评论", @"发送弹幕", @"去完成", @"完成", @"加入", @"开通", @"支付", @"领取", @"报名" ]];
}

- (NSInteger)webButtonActionScore:(NSString *)text bodyText:(NSString *)bodyText {
    NSInteger score = 0;
    if ([text containsString:@"立即参与"]) {
        score += 120;
    }
    if ([text containsString:@"去发表评论"] || [text containsString:@"发表评论"] || [text containsString:@"发送评论"] || [text containsString:@"发送弹幕"]) {
        score += 110;
    }
    if ([text containsString:@"参与"]) {
        score += 90;
    }
    if ([text containsString:@"去完成"] || [text containsString:@"完成"]) {
        score += 70;
    }
    if ([text containsString:@"加入"] || [text containsString:@"开通"] || [text containsString:@"支付"]) {
        score += [self isSensitiveConditionText:bodyText] ? 60 : 30;
    }
    if ([text containsString:@"领取"] || [text containsString:@"报名"]) {
        score += 40;
    }
    return score;
}

- (void)clickLuckyBagWebButtonWithText:(NSString *)buttonText webView:(id)webView completion:(void (^)(BOOL clicked))completion {
    NSString *escapedText = [self javaScriptStringLiteral:buttonText ?: @""];
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
         "function norm(s){return (s||'').replace(/\\s+/g,' ').trim();}"
         "function vis(e){if(!e)return false;var r=e.getBoundingClientRect();var st=getComputedStyle(e);return r.width>1&&r.height>1&&st.visibility!=='hidden'&&st.display!=='none'&&parseFloat(st.opacity||'1')>0.01;}"
         "var wanted=%@;"
         "var nodes=Array.prototype.slice.call(document.querySelectorAll('button,a,[role=button],input,div,span,p'));"
         "var deny=/取消|关闭|知道|规则|查看|返回|稍后|放弃/;"
         "var action=/立即参与|去发表评论|发表评论|发送评论|发送弹幕|参与|去完成|完成|加入|开通|支付|领取|报名/;"
         "var best=null,score=-1,bestText='';"
         "for(var i=0;i<nodes.length;i++){var e=nodes[i];if(!vis(e))continue;var t=norm(e.innerText||e.value||e.getAttribute('aria-label')||e.textContent||'');if(!t||t.length>40||deny.test(t))continue;var s=0;if(wanted&&t.indexOf(wanted)>=0)s+=1000;if(/立即参与/.test(t))s+=120;if(/去发表评论|发表评论|发送评论|发送弹幕/.test(t))s+=110;if(/参与/.test(t))s+=90;if(/去完成|完成/.test(t))s+=70;if(/加入|开通|支付/.test(t))s+=60;if(/领取|报名/.test(t))s+=40;if(action.test(t)&&s>score){best=e;score=s;bestText=t;}}"
         "if(best){best.click();return JSON.stringify({clicked:true,text:bestText});}"
         "return JSON.stringify({clicked:false});"
         "})();",
        escapedText];

    [self evaluateJavaScript:script inWebView:webView completion:^(id result, NSError *error) {
      BOOL clicked = NO;
      if ([result isKindOfClass:NSString.class]) {
          NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
          if (data) {
              NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
              clicked = [json[@"clicked"] boolValue];
          }
      } else if ([result isKindOfClass:NSDictionary.class]) {
          clicked = [result[@"clicked"] boolValue];
      }
      if (completion) {
          completion(clicked && !error);
      }
    }];
}

- (void)clickLuckyBagSensitiveWebButtonInWebView:(id)webView completion:(void (^)(BOOL clicked))completion {
    NSString *script =
        @"(function(){"
         "function norm(s){return (s||'').replace(/\\s+/g,' ').trim();}"
         "function vis(e){if(!e)return false;var r=e.getBoundingClientRect();var st=getComputedStyle(e);return r.width>1&&r.height>1&&st.visibility!=='hidden'&&st.display!=='none'&&parseFloat(st.opacity||'1')>0.01;}"
         "var nodes=Array.prototype.slice.call(document.querySelectorAll('button,a,[role=button],input,div,span,p'));"
         "var deny=/取消|关闭|知道|规则|查看|返回|稍后|放弃|去发表评论|发表评论|发送评论|发送弹幕/;"
         "var action=/加入粉丝团|粉丝团|加团|入团|关注主播|关注该主播|去关注|确认支付|支付|购买|下单|开通|授权|实名|认证|验证/;"
         "var best=null,score=-1,bestText='';"
         "for(var i=0;i<nodes.length;i++){var e=nodes[i];if(!vis(e))continue;var t=norm(e.innerText||e.value||e.getAttribute('aria-label')||e.textContent||'');if(!t||t.length>48||deny.test(t)||!action.test(t))continue;var s=0;if(/加入粉丝团|粉丝团|加团|入团/.test(t))s+=120;if(/关注/.test(t))s+=100;if(/确认支付|支付|购买|下单|开通/.test(t))s+=80;if(/授权|实名|认证|验证/.test(t))s+=70;if(s>score){best=e;score=s;bestText=t;}}"
         "if(best){best.click();return JSON.stringify({clicked:true,text:bestText});}"
         "return JSON.stringify({clicked:false});"
         "})();";
    [self evaluateJavaScript:script inWebView:webView completion:^(id result, NSError *error) {
      BOOL clicked = NO;
      if ([result isKindOfClass:NSString.class]) {
          NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
          if (data) {
              NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
              clicked = [json[@"clicked"] boolValue];
          }
      } else if ([result isKindOfClass:NSDictionary.class]) {
          clicked = [result[@"clicked"] boolValue];
      }
      if (completion) {
          completion(clicked && !error);
      }
    }];
}

- (void)evaluateJavaScript:(NSString *)script inWebView:(id)webView completion:(void (^)(id result, NSError *error))completion {
    if (!webView || ![webView respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")]) {
        if (completion) {
            completion(nil, nil);
        }
        return;
    }

    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    void (*sendMessage)(id, SEL, NSString *, void (^)(id, NSError *)) = (void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend;
    @try {
        sendMessage(webView, selector, script, completion);
    } @catch (__unused NSException *exception) {
        if (completion) {
            completion(nil, nil);
        }
    }
}

- (NSString *)javaScriptStringLiteral:(NSString *)text {
    if (text.length == 0) {
        return @"''";
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[ text ] options:0 error:nil];
    if (!data) {
        return @"''";
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json.length < 2) {
        return @"''";
    }
    return [json substringWithRange:NSMakeRange(1, json.length - 2)];
}

- (NSArray *)visibleJavaScriptWebViewsInActiveWindows {
    NSMutableArray *webViews = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows ?: @[];
    for (UIWindow *window in windows) {
        if (!window || window.hidden || window.alpha < 0.05) {
            continue;
        }
        [self collectJavaScriptWebViewsInView:window into:webViews seen:seen depth:0 maxDepth:14];
    }
    return [webViews copy];
}

- (void)collectJavaScriptWebViewsInView:(UIView *)view into:(NSMutableArray *)webViews seen:(NSMutableSet<NSString *> *)seen depth:(NSUInteger)depth maxDepth:(NSUInteger)maxDepth {
    if (!view || depth > maxDepth || view.hidden || view.alpha < 0.01) {
        return;
    }

    id webView = nil;
    if ([view respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")]) {
        webView = view;
    } else {
        webView = [self javaScriptCapableWebViewFromObject:view];
    }
    if (webView) {
        NSString *key = [NSString stringWithFormat:@"%p", webView];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [webViews addObject:webView];
        }
    }

    for (UIView *subview in view.subviews) {
        [self collectJavaScriptWebViewsInView:subview into:webViews seen:seen depth:depth + 1 maxDepth:maxDepth];
    }
}

- (BOOL)webViewIsVisibleForAutoScan:(id)webView {
    if (![webView isKindOfClass:UIView.class]) {
        return YES;
    }
    UIView *view = (UIView *)webView;
    if (![self viewAndAncestorsAreVisible:view]) {
        return NO;
    }
    CGRect frame = [self frameInWindowForView:view];
    if (CGRectIsEmpty(frame) || frame.size.width < 24 || frame.size.height < 24) {
        return NO;
    }
    return CGRectIntersectsRect(view.window.bounds, frame);
}

- (NSDictionary *)commentActionButtonFromButtons:(NSArray *)buttons {
    NSDictionary *fallback = nil;
    for (id item in buttons) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *button = (NSDictionary *)item;
        NSString *text = [button[@"text"] isKindOfClass:NSString.class] ? button[@"text"] : @"";
        if ([self string:text containsAny:@[ @"去发表评论", @"发表评论", @"发送评论", @"发送弹幕" ]]) {
            return button;
        }
        if (!fallback && [self string:text containsAny:@[ @"去完成", @"完成" ]] && ![self isSensitiveConditionText:text]) {
            fallback = button;
        }
    }
    return fallback;
}

- (NSDictionary *)participationActionButtonFromButtons:(NSArray *)buttons {
    NSDictionary *fallback = nil;
    NSInteger bestScore = NSIntegerMin;
    for (id item in buttons) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *button = (NSDictionary *)item;
        NSString *text = [button[@"text"] isKindOfClass:NSString.class] ? button[@"text"] : @"";
        if (text.length == 0 || [self string:text containsAny:@[ @"取消", @"关闭", @"知道", @"规则", @"查看", @"返回", @"稍后", @"放弃" ]]) {
            continue;
        }
        if ([self isSensitiveConditionText:text] && ![self hasRecentSensitiveApproval]) {
            continue;
        }
        NSInteger score = [self webButtonActionScore:text bodyText:@""];
        if (score > bestScore) {
            bestScore = score;
            fallback = button;
        }
    }
    return bestScore > 0 ? fallback : nil;
}

- (UIView *)visibleOfficialCommentInputView {
    NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows ?: @[];
    for (UIWindow *window in [windows reverseObjectEnumerator]) {
        if (!window || window.hidden || window.alpha < 0.05) {
            continue;
        }
        UIView *match = [self firstSubviewInView:window matching:^BOOL(UIView *candidate) {
          if (![candidate isKindOfClass:UITextView.class] && ![candidate isKindOfClass:UITextField.class]) {
              return NO;
          }
          if (![self viewAndAncestorsAreVisible:candidate]) {
              return NO;
          }
          NSString *text = [self textFromInputView:candidate];
          NSString *context = [self visibleTextAroundView:candidate];
          if (self.pendingCommentText.length > 0 && ([text isEqualToString:self.pendingCommentText] || [context containsString:self.pendingCommentText])) {
              return YES;
          }
          return [self textInputViewLooksLiveCommentInput:candidate context:context] && [self commentTextLooksSafe:text];
        } maxDepth:14];
        if (match) {
            return match;
        }
    }
    return nil;
}

- (NSString *)textFromInputView:(UIView *)inputView {
    NSString *text = nil;
    if ([inputView isKindOfClass:UITextView.class]) {
        text = ((UITextView *)inputView).text;
    } else if ([inputView isKindOfClass:UITextField.class]) {
        text = ((UITextField *)inputView).text;
    } else {
        id value = [self safeValueForKey:@"text" object:inputView];
        if ([value isKindOfClass:NSString.class]) {
            text = value;
        }
    }
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

#pragma mark - Auto View Helpers

- (BOOL)viewRepresentsOrdinaryLuckyBagEntry:(UIView *)view {
    NSString *className = NSStringFromClass(view.class);
    NSString *text = [self visibleTextAroundView:view];
    NSString *combined = [NSString stringWithFormat:@"%@ %@", className ?: @"", text ?: @""];
    if ([self isSuperLuckyBagText:combined]) {
        return NO;
    }
    if ([className containsString:@"LotteryAnimationViewNew"]) {
        return YES;
    }
    if ([className containsString:@"RedEnvelope"] || [className containsString:@"Treasure"]) {
        return NO;
    }
    if ([combined containsString:@"普通福袋"] || ([combined containsString:@"福袋"] && ![combined containsString:@"超级福袋"])) {
        return YES;
    }
    return NO;
}

- (BOOL)viewIsVisibleAndTouchable:(UIView *)view {
    if (![self viewAndAncestorsAreVisible:view]) {
        return NO;
    }
    CGRect frame = [self frameInWindowForView:view];
    if (CGRectIsEmpty(frame) || frame.size.width < 8 || frame.size.height < 8) {
        return NO;
    }
    return CGRectIntersectsRect(view.window.bounds, frame);
}

- (BOOL)viewAndAncestorsAreVisible:(UIView *)view {
    if (!view || !view.window) {
        return NO;
    }
    UIView *current = view;
    while (current) {
        if (current.hidden || current.alpha < 0.05 || !current.userInteractionEnabled) {
            return NO;
        }
        current = current.superview;
    }
    return YES;
}

- (CGRect)frameInWindowForView:(UIView *)view {
    if (!view || !view.superview) {
        return CGRectZero;
    }
    return [view.superview convertRect:view.frame toView:view.window];
}

- (BOOL)tapControlOrView:(UIView *)view {
    if (!view || ![self viewIsVisibleAndTouchable:view]) {
        return NO;
    }

    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        if (control.enabled) {
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }

    if ([view respondsToSelector:@selector(accessibilityActivate)]) {
        NSString *className = NSStringFromClass(view.class);
        if ([className containsString:@"LotteryAnimationViewNew"]) {
            return [self performSyntheticTapForView:view];
        }
        @try {
            if ([view accessibilityActivate]) {
                return YES;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    CGPoint center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    CGPoint windowPoint = [view convertPoint:center toView:view.window];
    return [self performSyntheticTapAtWindowPoint:windowPoint window:view.window];
}

- (BOOL)performSyntheticTapForView:(UIView *)view {
    if (!view || ![self viewIsVisibleAndTouchable:view]) {
        return NO;
    }
    CGPoint center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    CGPoint windowPoint = [view convertPoint:center toView:view.window];
    return [self performSyntheticTapAtWindowPoint:windowPoint window:view.window];
}

- (BOOL)performSyntheticTapAtWindowPoint:(CGPoint)point window:(UIWindow *)window {
    UIApplication *application = UIApplication.sharedApplication;
    if (!window || ![application respondsToSelector:NSSelectorFromString(@"_enqueueHIDEvent:")]) {
        return NO;
    }

    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
    }
    if (!handle) {
        return NO;
    }

    typedef DYYYIOHIDEventRef (*DYYYCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, DYYYBoolean, DYYYBoolean, DYYYIOOptionBits);
    typedef DYYYIOHIDEventRef (*DYYYCreateFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, DYYYBoolean, DYYYBoolean, DYYYIOOptionBits);
    typedef void (*DYYYAppendEvent)(DYYYIOHIDEventRef, DYYYIOHIDEventRef, DYYYIOOptionBits);

    DYYYCreateDigitizerEvent createDigitizerEvent = (DYYYCreateDigitizerEvent)dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    DYYYCreateFingerEvent createFingerEvent = (DYYYCreateFingerEvent)dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    DYYYAppendEvent appendEvent = (DYYYAppendEvent)dlsym(handle, "IOHIDEventAppendEvent");
    if (!createDigitizerEvent || !createFingerEvent || !appendEvent) {
        return NO;
    }

    CGPoint screenPoint = [window convertPoint:point toWindow:nil];
    SEL enqueueSelector = NSSelectorFromString(@"_enqueueHIDEvent:");
    void (*enqueueEvent)(id, SEL, DYYYIOHIDEventRef) = (void (*)(id, SEL, DYYYIOHIDEventRef))objc_msgSend;
    NSUInteger generation = self.autoFlowGeneration;
    BOOL shouldGuardAutoFlow = self.autoFlowActive || self.commentSendDeadline != nil;

    void (^sendTouch)(BOOL) = ^(BOOL touch) {
      uint64_t timestamp = mach_absolute_time();
      uint32_t handMask = touch ? 0x27 : 0x25;
      uint32_t fingerMask = touch ? 0x27 : 0x25;
      DYYYIOHIDEventRef handEvent = createDigitizerEvent(kCFAllocatorDefault, timestamp, 3, 0, 0, handMask, 0, screenPoint.x, screenPoint.y, 0, 0, 0, YES, touch, 0);
      DYYYIOHIDEventRef fingerEvent = createFingerEvent(kCFAllocatorDefault, timestamp, 1, 1, fingerMask, screenPoint.x, screenPoint.y, 0, touch ? 1.0 : 0.0, 0, YES, touch, 0);
      if (handEvent && fingerEvent) {
          appendEvent(handEvent, fingerEvent, 0);
          enqueueEvent(application, enqueueSelector, handEvent);
      }
      if (fingerEvent) {
          CFRelease(fingerEvent);
      }
      if (handEvent) {
          CFRelease(handEvent);
      }
    };

    sendTouch(YES);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (shouldGuardAutoFlow && (!strongSelf || ![strongSelf isAutoFlowGenerationCurrent:generation])) {
          return;
      }
      sendTouch(NO);
    });
    return YES;
}

- (UIView *)positiveButtonInAlertView:(UIView *)alertView {
    id buttonsValue = [self safeValueForKey:@"buttons" object:alertView] ?: [self safeValueForKey:@"_buttons" object:alertView];
    NSArray *buttons = [buttonsValue isKindOfClass:NSArray.class] ? buttonsValue : nil;
    UIView *fallback = nil;
    for (id item in buttons) {
        if (![item isKindOfClass:UIView.class]) {
            continue;
        }
        UIView *button = item;
        NSString *text = [self visibleTextInView:button maxDepth:3];
        if ([self string:text containsAny:@[ @"取消", @"跳过", @"放弃" ]]) {
            continue;
        }
        if ([self string:text containsAny:@[ @"确认", @"支付", @"加入", @"开通", @"继续", @"参与", @"确定" ]]) {
            return button;
        }
        fallback = button;
    }

    if (fallback) {
        return fallback;
    }

    return [self firstSubviewInView:alertView matching:^BOOL(UIView *candidate) {
      if (![candidate isKindOfClass:UIControl.class]) {
          return NO;
      }
      NSString *text = [self visibleTextInView:candidate maxDepth:3];
      return [self string:text containsAny:@[ @"确认", @"支付", @"加入", @"开通", @"继续", @"参与", @"确定" ]] && ![self string:text containsAny:@[ @"取消", @"跳过", @"放弃" ]];
    } maxDepth:8];
}

- (UIView *)sendControlNearTextInputView:(UIView *)textInputView {
    UIView *parent = textInputView.superview;
    for (NSUInteger depth = 0; parent && depth < 6; depth++, parent = parent.superview) {
        UIView *control = [self firstSubviewInView:parent matching:^BOOL(UIView *candidate) {
          if (candidate == textInputView || ![self viewAndAncestorsAreVisible:candidate]) {
              return NO;
          }
          NSString *text = [self visibleTextInView:candidate maxDepth:3];
          if (![text isEqualToString:@"发送"] && ![text containsString:@"发送"]) {
              return NO;
          }
          if ([candidate isKindOfClass:UIControl.class]) {
              return YES;
          }
          NSString *className = NSStringFromClass(candidate.class);
          return candidate.userInteractionEnabled || [className containsString:@"Button"] || [className containsString:@"Send"];
        } maxDepth:5];
        if (control && [self viewIsVisibleAndTouchable:control]) {
            return control;
        }
        if (control) {
            UIView *clickable = [self clickableAncestorForView:control stopAtView:parent];
            if (clickable && [self viewIsVisibleAndTouchable:clickable]) {
                return clickable;
            }
        }
    }
    return nil;
}

- (UIView *)clickableAncestorForView:(UIView *)view stopAtView:(UIView *)stopView {
    UIView *current = view;
    while (current && current != stopView.superview) {
        if ([current isKindOfClass:UIControl.class] || current.gestureRecognizers.count > 0 || [NSStringFromClass(current.class) containsString:@"Button"]) {
            return current;
        }
        if (current == stopView) {
            break;
        }
        current = current.superview;
    }
    return view;
}

- (UIView *)firstSubviewInView:(UIView *)view matching:(BOOL (^)(UIView *candidate))matcher maxDepth:(NSUInteger)maxDepth {
    if (!view || !matcher) {
        return nil;
    }
    return [self firstSubviewInView:view matching:matcher depth:0 maxDepth:maxDepth];
}

- (UIView *)firstSubviewInView:(UIView *)view matching:(BOOL (^)(UIView *candidate))matcher depth:(NSUInteger)depth maxDepth:(NSUInteger)maxDepth {
    if (!view || depth > maxDepth || view.hidden || view.alpha < 0.01) {
        return nil;
    }
    if (matcher(view)) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *match = [self firstSubviewInView:subview matching:matcher depth:depth + 1 maxDepth:maxDepth];
        if (match) {
            return match;
        }
    }
    return nil;
}

#pragma mark - Auto Text Helpers

- (NSString *)roomIdentifierFromObject:(id)object {
    if (!object) {
        return nil;
    }
    for (NSString *key in @[ @"roomID", @"roomId", @"room_id", @"idStr", @"id_str", @"ID", @"id" ]) {
        id value = [self safeValueForKey:key object:object];
        NSString *text = [self valueTextForLog:value limit:80];
        if (text.length > 0) {
            return text;
        }
    }
    id roomModel = [self safeValueForKey:@"roomModel" object:object] ?: [self safeValueForKey:@"_roomModel" object:object];
    if (roomModel && roomModel != object) {
        for (NSString *key in @[ @"idStr", @"id_str", @"roomID", @"roomId", @"room_id", @"ID", @"id" ]) {
            id value = [self safeValueForKey:key object:roomModel];
            NSString *text = [self valueTextForLog:value limit:80];
            if (text.length > 0) {
                return text;
            }
        }
    }
    return nil;
}

- (BOOL)isSuperLuckyBagText:(NSString *)text {
    NSString *lower = text.lowercaseString ?: @"";
    return [text containsString:@"超级福袋"] || [lower containsString:@"super lucky"] || [lower containsString:@"super_lucky"] || [lower containsString:@"mega"];
}

- (BOOL)webTextLooksLuckyBagPanel:(NSString *)text {
    NSString *lower = text.lowercaseString ?: @"";
    if ([text containsString:@"福袋"] || [lower containsString:@"lucky"] || [lower containsString:@"lottery"] || [lower containsString:@"redpacket"] || [lower containsString:@"red_packet"]) {
        return YES;
    }
    BOOL justOpenedEntry = self.lastAutoEntryActionDate && [[NSDate date] timeIntervalSinceDate:self.lastAutoEntryActionDate] < 18.0;
    return self.autoFlowActive && justOpenedEntry && [self string:text containsAny:@[ @"参与条件", @"倒计时", @"钻石", @"开奖" ]] &&
           [self string:text containsAny:@[ @"发表评论", @"发送评论", @"发送弹幕", @"粉丝团", @"已参加", @"已参与" ]];
}

- (BOOL)isSensitiveConditionText:(NSString *)text {
    if ([self string:text containsAny:@[ @"粉丝团", @"加团", @"入团", @"加入粉丝", @"确认支付", @"支付", @"抖币", @"购买", @"下单", @"开通", @"手机号", @"授权", @"实名", @"认证" ]]) {
        return YES;
    }
    return [self string:text containsAny:@[ @"关注主播", @"需要关注", @"需关注", @"关注后", @"先关注", @"完成关注", @"关注并参与", @"关注才可参与", @"关注该主播" ]];
}

- (BOOL)textLooksCommentCondition:(NSString *)text {
    NSString *lower = text.lowercaseString ?: @"";
    return [self string:text containsAny:@[ @"评论", @"弹幕", @"口令", @"发表评论", @"发送评论", @"发送弹幕", @"去发表评论" ]] || [lower containsString:@"comment"] || [lower containsString:@"danmu"] || [lower containsString:@"barrage"];
}

- (BOOL)textLooksAlreadyParticipated:(NSString *)text {
    return [self string:text containsAny:@[ @"已成功参与", @"参与成功", @"成功参与", @"你已参与", @"已参与本次", @"已参与该福袋", @"等待开奖" ]];
}

- (BOOL)textInputViewLooksLiveCommentInput:(UIView *)textInputView context:(NSString *)context {
    NSString *className = NSStringFromClass(textInputView.class);
    NSString *combined = [NSString stringWithFormat:@"%@ %@", className ?: @"", context ?: @""];
    return ([className containsString:@"LiveComment"] || [combined containsString:@"IESLiveComment"] || [combined containsString:@"发送"]) && ![combined containsString:@"AWEUIAlertView"];
}

- (BOOL)commentTextLooksSafe:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || trimmed.length > 80) {
        return NO;
    }
    if ([trimmed isEqualToString:@"说点什么"] || [trimmed isEqualToString:@"发送"] || [trimmed isEqualToString:@"发表评论"]) {
        return NO;
    }
    if ([self string:trimmed containsAny:@[ @"<", @">", @"0x", @"frame =", @"baseClass", @"UITextView", @"UIButton", @"UIView", @"CALayer", @"gestureRecognizer" ]]) {
        return NO;
    }
    return YES;
}

- (BOOL)string:(NSString *)text containsAny:(NSArray<NSString *> *)tokens {
    if (text.length == 0) {
        return NO;
    }
    for (NSString *token in tokens) {
        if (token.length > 0 && [text rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
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
    [self appendEventWithTitle:@"日志已清空" body:@"可继续采集完整流程：进入直播间 -> 点福袋 -> 点参与/去发表评论 -> 发送官方要求弹幕；若开启自动参与，也会记录自动流程。\n"];
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
    [text appendString:@"说明：调试采集用于记录手动/自动流程数据；自动参与由“自动参与福袋”开关独立控制。\n"];
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
            candidate = [self sanitizedCommentCandidate:candidate];
            if ([self commentTextLooksSafe:candidate]) {
                return [self truncateString:candidate limit:80];
            }
        }
    }
    return nil;
}

- (NSString *)sanitizedCommentCandidate:(NSString *)candidate {
    NSString *clean = [self cleanLuckyBagField:candidate limit:120];
    NSArray<NSString *> *endTokens = @[ @"未达成", @"已达成", @"去发表评论", @"发表评论", @"发送评论", @"发送弹幕", @"国家反诈", @"抖音提醒", @"确认继续", @"跳过", @"参与条件", @"活动规则" ];
    NSUInteger end = clean.length;
    for (NSString *token in endTokens) {
        NSRange range = [clean rangeOfString:token];
        if (range.location != NSNotFound) {
            end = MIN(end, range.location);
        }
    }
    clean = [clean substringToIndex:end];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSCharacterSet *trimSet = [NSCharacterSet characterSetWithCharactersInString:@" ：:，,。.;；\"“”'「」[]【】()（）"];
    clean = [clean stringByTrimmingCharactersInSet:trimSet];
    return [self truncateString:clean limit:80];
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
