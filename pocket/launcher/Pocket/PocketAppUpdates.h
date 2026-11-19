// Brighter Pocket's own updates: whether a newer version of the app is out. The app cannot update itself (it is
// built and installed from the player's Mac), so it says so: in the in-game settings, and once for each new
// version in a popup at the game's main menu, with the way to update (Brighter Pocket Companion, then Install
// Pocket).
//
// It reads the appcast the companion reads, from GitHub's latest release
// (releases/latest/download/appcast.xml): the newest version and its headline. Nothing is sent but the request
// itself. At most every few hours; the last answer is kept (NSUserDefaults) for the next launch.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when a check starts or ends (and so what PocketAppUpdateAvailable says may change).
FOUNDATION_EXPORT NSString *const PocketAppUpdateDidChangeNotification;
// Starts the check (at launch; again later only when the last is old). Any thread.
FOUNDATION_EXPORT void PocketAppUpdatesCheck(void);
// The newer version, with its headline, or nil when this one is the newest (or none is known yet). The
// in-game settings (in the AppKit adapter, another image) find this with dlsym.
FOUNDATION_EXPORT NSString *_Nullable PocketAppUpdateAvailable(NSString *_Nullable *_Nullable headline);
// The in-game settings' Brighter Pocket section (found with dlsym): this app's version, a check under way, when
// the last check answered (nil: never), and a check now whenever the last was (its answer is notified).
FOUNDATION_EXPORT NSString *PocketAppVersion(void);
FOUNDATION_EXPORT BOOL PocketAppUpdatesChecking(void);
FOUNDATION_EXPORT NSDate *_Nullable PocketAppUpdatesLastChecked(void);
FOUNDATION_EXPORT void PocketAppUpdatesCheckNow(void);
// The game is at its main menu, over presenter: a new version not yet told of is told now. Main thread.
FOUNDATION_EXPORT void PocketAppUpdatesGameReady(UIViewController *presenter);

NS_ASSUME_NONNULL_END
