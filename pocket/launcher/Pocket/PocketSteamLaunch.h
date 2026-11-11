// Brighter Pocket's Steam sign-in, before a game that needs Steam starts (pocket/patches/0005
// calls it from the launcher). The session it starts is lent to the game's Steam library through
// PocketSteamBridgeGet (translation/libsteam_api/PocketSteamBridge.h).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// For a profile that needs Steam (Brighter Shores): signs in to Steam, with the remembered login
// or by asking (name and password, then Steam Guard), gets the game's ownership ticket and tells
// Steam the game is running, then calls resume on the main thread. The player may choose to play
// offline instead; resume is called then too. Returns YES if it took the launch over, NO when
// there is nothing to do (another profile, or already done this run).
FOUNDATION_EXPORT BOOL PocketSteamPrepareLaunch(NSString *profile, UIViewController *presenter,
                                                UILabel *_Nullable status, dispatch_block_t resume);

// Forgets the kept Steam sign-in (the launcher's Diagnostics menu); says what it did.
FOUNDATION_EXPORT NSString *PocketSteamSignOut(void);

NS_ASSUME_NONNULL_END
