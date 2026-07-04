#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYLiveLuckyBagManager : NSObject

+ (instancetype)sharedManager;
+ (BOOL)isDebugEnabled;

- (void)handleLiveRoomEntered:(id)roomModel audienceViewController:(nullable UIViewController *)viewController;
- (void)handleLiveRoomClosed:(id)roomModel;
- (void)handleLuckyBagViewAppeared:(UIView *)view;
- (void)handleControlAction:(SEL)action target:(nullable id)target sender:(UIControl *)sender event:(nullable UIEvent *)event;
- (void)handleGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer;
- (void)handleTextInputView:(UIView *)textInputView text:(nullable NSString *)text;
- (void)showDebugWindow;
- (void)hideDebugWindow;

@end

NS_ASSUME_NONNULL_END
