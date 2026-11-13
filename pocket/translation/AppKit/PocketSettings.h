// The in-game settings: a button beside Tolkara's on-screen controls opens a settings sheet
// (docs/architecture.md, "In-game settings"). AKHostViewController calls these
// (pocket/patches/0010); the choices are kept in NSUserDefaults.
#import <UIKit/UIKit.h>

// What the settings ask of the game's view (AKHostView, pocket/patches/0010).
@protocol PocketGameHost <NSObject>
// Tolkara's on-screen controls, while they are shown.
@property (nonatomic, readonly) UIView *pocketTouchControls;
// Shows or removes them now; a held button or the keyboard is released first.
- (void)pocketShowTouchControls:(BOOL)shown;
// The input settings changed (the trackpad, pinch scrolling): touches in progress end, and the
// view takes multiple touches as they now need.
- (void)pocketInputChanged;
@end

// The controller's view is a black root; the game's view goes in it, inside the safe area
// or over the whole screen, with the settings button and the performance overlay above.
void PocketSettingsAttach(UIViewController *controller, UIView<PocketGameHost> *host);

// The orientations the game's window takes, as the player chose.
UIInterfaceOrientationMask PocketSettingsOrientations(void);
