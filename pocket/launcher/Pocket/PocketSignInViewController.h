// The Steam sign-in's screens: a form sheet in iOS's own style (a navigation bar over an inset
// grouped list) whose steps follow one another: the account and password, a Steam Guard code,
// approving the sign-in in the Steam Mobile app (both pushed over the account, so Back returns
// to it), and a problem with its way on. PocketSteamLaunch.m decides what is shown; this only
// shows it and hands back what the player typed or chose. Present it as it is.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PocketSignInViewController : UINavigationController
// The way out at the top left of the first step: "Play Offline" before the game, "Not Now" for
// a sign-in again while it runs; cancel runs when it is tapped.
- (instancetype)initWithCancelTitle:(NSString *)cancelTitle cancel:(dispatch_block_t)cancel NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithRootViewController:(UIViewController *)root NS_UNAVAILABLE;
- (instancetype)initWithNavigationBarClass:(nullable Class)bar toolbarClass:(nullable Class)toolbar NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Account name (prefilled with account) and password; submit once both are filled in. problem:
// why it asks again, shown above the fields; detail: a small line for support (an error's code).
- (void)askForAccount:(nullable NSString *)account problem:(nullable NSString *)problem detail:(nullable NSString *)detail
               submit:(void (^)(NSString *account, NSString *password))submit;
// A Steam Guard code from the Steam Mobile app, or emailed (email: the address hint Steam gave,
// or "" when it gave none); approve: the sign-in may be approved in the app instead. Submits by
// itself when the whole code is typed. back: Back was tapped (to the account and password).
- (void)askForCodeEmailedTo:(nullable NSString *)email approve:(BOOL)approve problem:(nullable NSString *)problem
                     submit:(void (^)(NSString *code))submit back:(dispatch_block_t)back;
// Waiting while the player approves the sign-in in the Steam Mobile app (inApp) or by email.
- (void)waitForApprovalInApp:(BOOL)inApp back:(dispatch_block_t)back;
// Something under way the player waits for (signing in with the kept login): a spinner row.
- (void)showWaiting:(NSString *)title text:(NSString *)text;
// Something went wrong: a title, what happened and what to do, a small line for support (an
// error's code), and one way on (Try Again, Use Another Account) beside the way out.
- (void)showProblem:(NSString *)title message:(NSString *)message detail:(nullable NSString *)detail
             action:(NSString *)action handler:(dispatch_block_t)handler;
// A request runs: a spinner in the navigation bar and everything waits, until the next step.
- (void)setBusy:(BOOL)busy;
@end

NS_ASSUME_NONNULL_END
