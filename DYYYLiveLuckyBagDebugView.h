#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYLiveLuckyBagDebugView : UIView

@property(nonatomic, copy, nullable) void (^copyHandler)(void);
@property(nonatomic, copy, nullable) void (^clearHandler)(void);
@property(nonatomic, copy, nullable) void (^closeHandler)(void);

- (void)showInWindow:(UIWindow *)window;
- (void)updateLogText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
