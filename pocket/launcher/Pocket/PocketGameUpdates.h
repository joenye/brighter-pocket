// Keeping Brighter Shores on the device at Steam's build, without the Mac (PocketDepot.h does
// the downloading, PocketInstalledGame.h keeps the files): the builds service and its screen.
//
// Each time the app opens, signed in, it asks Steam for the build on the chosen branch, briefly:
// a newer one is fetched with its progress on the loading screen and put in place before the
// game starts; Steam slow to answer, the game starts as it is and the check goes on behind it.
// While the game runs, Steam is asked again every few minutes, and at once after a sign-in; a
// newer build then downloads in the background and goes in place the next time the app opens.
// The in-game notice says which: up to date, downloading, or ready. Builds (the settings' sub-
// menu, PocketBuildsViewController) shows the build on the device and Steam's, the branch, and
// checks or downloads on request.
#import <UIKit/UIKit.h>
#import "PocketSteamClient.h"

NS_ASSUME_NONNULL_BEGIN

// The loading screen follows these (PocketLoadingView.m): userInfo "text" (what is happening,
// plain words) and "fraction" (0 to 1; absent: no bar). Posted on the main thread.
FOUNDATION_EXPORT NSString *const PocketLaunchProgressNotification;
// The game's window came up (the AppKit adapter's settings post it): the build works.
FOUNDATION_EXPORT NSString *const PocketGameStartedNotification;
// A short notice for the player over the game (the settings show it): userInfo "text".
FOUNDATION_EXPORT NSString *const PocketNoticeNotification;
// The builds' state changed (main thread).
FOUNDATION_EXPORT NSString *const PocketBuildsDidChangeNotification;

// The defaults key of the chosen Steam branch ("public" unless chosen), and of the branches
// Steam listed last.
FOUNDATION_EXPORT NSString *const PocketSteamBranchKey;
FOUNDATION_EXPORT NSString *const PocketSteamBranchesKey;

// Main thread, before the game starts. client: signed in, or nil (the game starts offline: a
// build downloaded earlier still goes in place). done runs on the main thread once the game on
// the device is the one to start.
FOUNDATION_EXPORT void PocketGameUpdateBeforeLaunch(PocketSteamClient *_Nullable client, UIViewController *presenter, dispatch_block_t done);

// The game's session is signed in (late, or again): check now, and every few minutes from here.
FOUNDATION_EXPORT void PocketBuildsSessionReady(void);

// The Builds screen, for a navigation controller (the in-game settings push it); found by
// name from the AppKit adapter. Summary: the build on the device and its state, for a row.
FOUNDATION_EXPORT UIViewController *PocketBuildsViewController(void);
FOUNDATION_EXPORT NSString *PocketBuildsSummary(void);

NS_ASSUME_NONNULL_END
