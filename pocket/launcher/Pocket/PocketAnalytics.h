// Anonymous usage counts (docs/architecture.md, "Usage counts"): how many players open the app,
// sign in to Steam, start the game and keep it up to date, so Brighter Atlas can see what works
// and what fails on players' devices. Each count is one small event sent to Umami Cloud, to
// Brighter Atlas's own website there, under the app's own hostname (app.brighteratlas.com).
//
// What goes: the event's name and the few short fields its caller gives (a result, a Steam
// Guard way, an EResult number, a count of days), with the app's version, the device family
// (iPhone or iPad), the iOS version, the preferred language and the screen's size in points.
// What never goes: the Steam account, its ID, a token or password, an email address, the
// device's name, a file path, or anything of the game. Umami sees the connection's address, as
// any web server does; the app adds nothing of its own about it.
//
// On unless the player turns it off (the in-game settings' Anonymous Usage Counts, defaults
// key PocketAnonymousUsageCounts). Never sent from the iOS Simulator, with POCKET_NO_ANALYTICS=1
// in the environment, or under a test runner. Fire and forget: nothing waits for an answer,
// and a failure is dropped silently, so the app and the game never notice.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The player's choice, kept in NSUserDefaults: YES until turned off. The in-game settings (in
// the AppKit adapter, another image) find these two with dlsym.
FOUNDATION_EXPORT NSString *const PocketAnalyticsEnabledKey;
FOUNDATION_EXPORT BOOL PocketAnalyticsEnabled(void);
FOUNDATION_EXPORT void PocketAnalyticsSetEnabled(BOOL enabled);

// Counts the event name with data: short strings, numbers and Booleans only (anything else,
// and longer strings, is left out). Any thread; returns at once.
FOUNDATION_EXPORT void PocketAnalyticsEvent(NSString *name, NSDictionary<NSString *, id> *_Nullable data);

NS_ASSUME_NONNULL_END
