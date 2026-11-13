// Brighter Pocket's Steam sign-in, before a game that needs Steam starts (pocket/patches/0005
// calls it from the launcher). The session it starts is lent to the game's Steam library through
// PocketSteamBridgeGet (translation/libsteam_api/PocketSteamBridge.h).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PocketSteamClient;

// For a profile that needs Steam (Brighter Shores), before the game starts: with a kept login,
// signs in to Steam, gets the game's ownership ticket, tells Steam the game is running and brings
// the game to Steam's build (PocketGameUpdates.h), then calls resume on the main thread. Without
// one, or with Steam out of reach, resume comes at once: the game starts offline, the sign-in is
// offered at its main menu (PocketSteamGameReady), and a kept login is tried again in the
// background. Returns YES if it took the launch over, NO when there is nothing to do (another
// profile, or already done this run).
FOUNDATION_EXPORT BOOL PocketSteamPrepareLaunch(NSString *profile, UIViewController *presenter,
                                                UILabel *_Nullable status, dispatch_block_t resume);

// Forgets the kept Steam sign-in (the launcher's Diagnostics menu); says what it did.
FOUNDATION_EXPORT NSString *PocketSteamSignOut(void);
// Signs out now, from the in-game settings: forgets the kept sign-in and ends the lent session,
// so the next sign-in starts clean with any account. Main thread.
FOUNDATION_EXPORT void PocketSteamEndSession(void);

// The lent session as the player should see it. The in-game settings (in the AppKit adapter,
// another image) find these two with dlsym and listen for the notification, posted on the main
// thread whenever the state or its text changes.
typedef NS_ENUM(NSInteger, PocketSteamState) {
    PocketSteamStateOff,           // not signed in (playing offline, or not yet)
    PocketSteamStateConnecting,    // signing in, or again after the connection dropped
    PocketSteamStateSignedIn,
    PocketSteamStateWarning,       // signed in, with something to know (a game running on another device)
    PocketSteamStateUnreachable,   // the connection could not be made again; it is tried again
    PocketSteamStateSignInNeeded,  // Steam refused the kept login: the player signs in again
};
FOUNDATION_EXPORT NSString *const PocketSteamStatusDidChangeNotification;
FOUNDATION_EXPORT PocketSteamState PocketSteamCurrentState(NSString *_Nullable *_Nullable text);
// Signs in again while the game runs (Steam refused the kept login, or another account), over
// presenter; the new session replaces the lent one. Main thread.
FOUNDATION_EXPORT void PocketSteamSignInAgain(UIViewController *presenter);

// The game's session, online: signed in again first if its connection dropped; nil if there is
// none or it cannot be. Blocks while it signs in again: not on the main thread.
FOUNDATION_EXPORT PocketSteamClient *_Nullable PocketSteamOnlineSession(void);

// The game is at its main menu, over presenter (the in-game settings say so, a few seconds after
// its window comes up). Not signed in and not asked yet this run: the sign-in is offered now.
FOUNDATION_EXPORT void PocketSteamGameReady(UIViewController *presenter);

NS_ASSUME_NONNULL_END
