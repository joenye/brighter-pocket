// The screen the app shows while Brighter Shores starts (pocket/patches/0027 makes it the
// launcher's status screen): the app's lockup, what is happening in plain words, and a progress
// bar from the runtime log. The launcher's own technical status (its text, the elapsed time,
// the startup activity, Diagnostics) stays, folded away under Details; a failure is always
// shown in full.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PocketLoadingView : UIView
// details: the launcher's technical views, shown under Details below the status text, then
// diagnostics (its Diagnostics and logs button).
- (instancetype)initWithDetails:(NSArray<UIView *> *)details diagnostics:(UIButton *)diagnostics NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
// The launcher's status text: what it sets here is shown in Details, and in plain words above.
@property(nonatomic, readonly) UILabel *status;
// The runtime log the game's start writes (opened anew): from now on the bar follows its lines
// from a background queue, as the game holds the main thread, until the game's window is up.
- (void)watchLog:(NSString *)path;
// The start ended (stopped, refused, or the game closed): the status text becomes the message.
- (void)showStopped;
@end

NS_ASSUME_NONNULL_END
