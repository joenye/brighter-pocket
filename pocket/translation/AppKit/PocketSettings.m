// The in-game settings (docs/architecture.md, "In-game settings"): a gear button beside
// Tolkara's on-screen controls opens a sheet in iOS's own style (an inset grouped list, as the
// Settings app shows). Every choice is kept in NSUserDefaults and takes effect at once:
//
// - Performance overlay: presented frames per second and the frame time, from the
//   drawables' presentation times (translation/Metal/Presentation.m, pocket/patches/0011),
//   with the target, in the top left corner inside the safe area.
// - Frame rate: as fast as the screen allows, or a cap among the rates the screen divides
//   into. The cap lengthens the minimum duration the game's presents ask for
//   (presentDrawable:afterMinimumDuration:, patch 0011); the game itself is not changed.
//   Above 60 Hz an iPhone needs CADisableMinimumFrameDurationOnPhone (patch 0013), and a
//   display link asking for the rate: Core Animation runs a ProMotion screen at the rate the
//   app's display links ask, and the game's presents alone left it at 60 Hz (the overlay
//   showed 13 ms waits for a drawable against 0.7 ms of GPU time).
// - Orientation: landscape, portrait, or as the device is held. The game's window takes the
//   view's size, so portrait gives the game a portrait window. The launcher keeps Info.plist's
//   orientations (patch 0012).
// - Safe-area border: the game's view inside the safe area (notch, Dynamic Island, rounded
//   corners, home indicator), black around it; UIKit gives each screen's own insets. Off by
//   default: the game uses the whole screen.
// - Input: touch (a finger is the mouse, where it touches) or cursor (Tolkara's touch
//   trackpad: slide to move the cursor, tap to click, double-tap or tap with two fingers to
//   right-click, two fingers to scroll); and pinch to zoom, two fingers pinching as the
//   scroll wheel in either mode (translation/AppKit, pocket/patches/0025).
// - The on-screen buttons (this one, Tolkara's trackpad and keyboard buttons) fold away
//   behind a small handle and come back with it; the choice is kept. They sit in the corner
//   the player chooses (bottom right unless chosen), in a row or a column (pocket/patches/0032),
//   the keyboard's button at the corner and the handle furthest from it. With them at the top,
//   a notice shows at the bottom instead, and with them at the top left the performance
//   overlay moves to the top right.
// - Privacy: Anonymous Usage Counts, on unless turned off (launcher/Pocket/PocketAnalytics.h
//   says what is sent and what never is).
// - About: the app's icon, name and version, links to Brighter Atlas and to Tolkara, and the
//   credit to Tolkara, which the app runs on.
//
// Development: --open-settings opens the sheet when the game's window appears (--open-builds,
// its Builds screen; --open-about, scrolled to About);
// --settings-demo then closes it and changes the settings one by one over the game, three seconds apart.
#import "PocketSettings.h"
#import "AKSupport.h"
#import "TouchControls.h"
#import <objc/runtime.h>
#include <dlfcn.h>

static NSString *const OverlayKey = @"PocketPerformanceOverlay";   // Boolean, default off
static NSString *const FrameRateKey = @"PocketFrameRate";          // frames a second; 0: as fast as the screen allows
static NSString *const OrientationKey = @"PocketOrientation";      // "landscape", "portrait" or "device"
static NSString *const SafeAreaKey = @"PocketSafeArea";            // Boolean, default off
static NSString *const ButtonsHiddenKey = @"PocketButtonsHidden";  // Boolean, default off on iPhone, on on iPad
static NSString *const ButtonsCornerKey = @"PocketButtonsCorner";  // one of Corners below, default "bottomRight"
static NSString *const ButtonsVerticalKey = @"PocketButtonsVertical";   // Boolean, default off (a row)
typedef NS_ENUM(NSUInteger, ButtonsCorner) { CornerBottomRight, CornerBottomLeft, CornerTopRight, CornerTopLeft, CornerCount };
static NSString *const Corners[] = {@"bottomRight", @"bottomLeft", @"topRight", @"topLeft"};
static NSString *const Orientations[] = {@"landscape", @"portrait", @"device"};

// The app's Steam session (launcher/Pocket/PocketSteamLaunch.h), in the app's own image: found
// by name, as the game's Steam library finds its bridge. Without them (another app) nothing shows.
typedef NS_ENUM(NSInteger, SteamState) { SteamOff, SteamConnecting, SteamSignedIn, SteamWarning, SteamUnreachable, SteamSignInNeeded };
static SteamState steamState(NSString **text) {
    static SteamState (*current)(NSString **);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ current = (SteamState (*)(NSString **))dlsym(RTLD_DEFAULT, "PocketSteamCurrentState"); });
    if (!current) { if (text) *text = nil; return SteamOff; }
    return current(text);
}
static void steamSignInAgain(UIViewController *presenter) {
    void (*again)(UIViewController *) = (void (*)(UIViewController *))dlsym(RTLD_DEFAULT, "PocketSteamSignInAgain");
    if (again) again(presenter);
}
static void steamSignOut(void) {
    void (*end)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "PocketSteamEndSession");
    if (end) end();
}
static NSString *const SteamStatusNotification = @"PocketSteamStatusDidChange";
// The launcher's builds (pocket/launcher/Pocket/PocketGameUpdates.h), found by name as the Steam
// session is: their screen, a summary for the row, their changes, a notice for the player, and
// the game's window being up; and the game at its main menu (PocketSteamLaunch.h).
static NSString *const BuildsNotification = @"PocketBuildsDidChange", *const NoticeNotification = @"PocketNotice";
static NSString *const GameStartedNotification = @"PocketGameStarted";
static UIViewController *buildsScreen(void) {
    UIViewController *(*screen)(void) = (UIViewController *(*)(void))dlsym(RTLD_DEFAULT, "PocketBuildsViewController");
    return screen ? screen() : nil;
}
static NSString *buildsSummary(void) {
    NSString *(*summary)(void) = (NSString *(*)(void))dlsym(RTLD_DEFAULT, "PocketBuildsSummary");
    return summary ? summary() : nil;
}
static void gameReady(UIViewController *presenter) {
    void (*ready)(UIViewController *) = (void (*)(UIViewController *))dlsym(RTLD_DEFAULT, "PocketSteamGameReady");
    if (ready) ready(presenter);
}
static const NSTimeInterval MainMenuDelay = 6;   // from the game's window to its main menu, about
// The launcher's anonymous usage counts (pocket/launcher/Pocket/PocketAnalytics.h), found by name
// too: the player's choice, which the launcher keeps. Without them (another app) no row shows.
static BOOL hasUsageCounts(void) { return dlsym(RTLD_DEFAULT, "PocketAnalyticsEnabled") != NULL; }
static BOOL usageCountsOn(void) {
    BOOL (*enabled)(void) = (BOOL (*)(void))dlsym(RTLD_DEFAULT, "PocketAnalyticsEnabled");
    return enabled && enabled();
}
static void setUsageCounts(BOOL on) {
    void (*set)(BOOL) = (void (*)(BOOL))dlsym(RTLD_DEFAULT, "PocketAnalyticsSetEnabled");
    if (set) set(on);
}

// translation/Metal/Presentation.m (pocket/patches/0011), in the Metal adapter.
@protocol PocketPresentationPacing <NSObject>
+ (void)setMinimumInterval:(double)seconds;
+ (NSDictionary<NSString *, NSNumber *> *)sample;
@end
static Class<PocketPresentationPacing> pacing(void) {
    return (Class<PocketPresentationPacing>)NSClassFromString(@"AKPresentationPacing");
}

static BOOL isPhone(void) { return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone; }
static BOOL boolSetting(NSString *key, BOOL fallback) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key] ? [defaults boolForKey:key] : fallback;
}
static NSString *orientationSetting(void) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:OrientationKey];
    for (NSUInteger i = 0; i < 3; i++) if ([value isEqualToString:Orientations[i]]) return value;
    return @"device";   // as the device is held, as the launcher's screens turn
}
static ButtonsCorner cornerSetting(void) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:ButtonsCornerKey];
    for (NSUInteger i = 0; i < CornerCount; i++) if ([value isEqualToString:Corners[i]]) return (ButtonsCorner)i;
    return CornerBottomRight;
}
static BOOL cornerIsLeft(ButtonsCorner corner) { return corner == CornerBottomLeft || corner == CornerTopLeft; }
static BOOL cornerIsTop(ButtonsCorner corner) { return corner == CornerTopRight || corner == CornerTopLeft; }
static NSInteger frameRateSetting(void) { return MAX(0, [NSUserDefaults.standardUserDefaults integerForKey:FrameRateKey]); }

UIInterfaceOrientationMask PocketSettingsOrientations(void) {
    NSString *orientation = orientationSetting();
    if ([orientation isEqualToString:@"portrait"])
        return isPhone() ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
    if ([orientation isEqualToString:@"device"])
        return isPhone() ? UIInterfaceOrientationMaskAllButUpsideDown : UIInterfaceOrientationMaskAll;
    return UIInterfaceOrientationMaskLandscape;
}

// 0 (as fast as the screen allows), then the steady rates below the screen's maximum: its
// whole fractions, and 80 on a 120 Hz screen (ProMotion's 240 Hz base), down to 30.
static NSArray<NSNumber *> *frameRates(NSInteger maximum) {
    NSMutableOrderedSet<NSNumber *> *rates = [NSMutableOrderedSet orderedSetWithObject:@0];
    if (maximum >= 120) [rates addObject:@80];
    for (NSInteger divisor = 2; maximum / divisor >= 30; divisor++)
        if (maximum % divisor == 0) [rates addObject:@(maximum / divisor)];
    return [rates.array sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        if (!a.integerValue || !b.integerValue) return a.integerValue ? NSOrderedDescending : NSOrderedAscending;
        return [b compare:a];
    }];
}

// The settings sheet's navigation: no status bar, as the game has none (full screen on a
// phone, the sheet would otherwise bring it back, and on the iPhone Duo's outer screen held
// upright it takes a column at the side).
@interface PocketSheetNavigation : UINavigationController
@end
@implementation PocketSheetNavigation
- (BOOL)prefersStatusBarHidden { return YES; }
@end

// The display link's target: it only asks Core Animation for the rate (a link retains its target).
@interface PocketDisplayRate : NSObject
@end
@implementation PocketDisplayRate
- (void)tick:(CADisplayLink *)link { (void)link; }
@end

@class PocketSettingsPanel;
@interface PocketSettings : NSObject <UIAdaptivePresentationControllerDelegate>
- (void)setOverlay:(BOOL)on;
- (void)setFrameRate:(NSInteger)rate;
- (void)setOrientation:(NSString *)orientation;
- (void)setSafeArea:(BOOL)on;
- (void)setCursor:(BOOL)cursor;
- (void)setCursorSpeed:(double)speed;
- (void)setPinch:(BOOL)on;
- (void)setButtonsCorner:(ButtonsCorner)corner;
- (void)setButtonsVertical:(BOOL)vertical;
- (void)signInToSteam;
- (void)closePanel;
- (NSInteger)screenMaximum;
- (BOOL)cursor;
@end

// When Apple's signature for this build runs out: embedded.mobileprovision's ExpirationDate
// (the plist inside its signed envelope), or nil without one (the simulator, an unsigned build).
static NSDate *SignatureExpiry(void) {
    static NSDate *expiry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"embedded" withExtension:@"mobileprovision"];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        if (!data.length) return;
        NSRange start = [data rangeOfData:[@"<?xml" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, data.length)];
        if (start.location == NSNotFound) return;
        NSRange end = [data rangeOfData:[@"</plist>" dataUsingEncoding:NSASCIIStringEncoding] options:0
                                  range:NSMakeRange(start.location, data.length - start.location)];
        if (end.location == NSNotFound) return;
        NSData *plist = [data subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
        NSDictionary *profile = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
        NSDate *date = [profile isKindOfClass:NSDictionary.class] ? profile[@"ExpirationDate"] : nil;
        if ([date isKindOfClass:NSDate.class]) expiry = date;
    });
    return expiry;
}

// The sheet: an inset grouped list, as the Settings app shows. Each row reads the setting it
// shows, so a reload shows what is kept; each change goes through PocketSettings.
typedef NS_ENUM(NSInteger, PanelSection) { PanelSteam, PanelGame, PanelDisplay, PanelControls, PanelPrivacy, PanelAbout, PanelSectionCount };
typedef NS_ENUM(NSInteger, PanelRow) {
    RowSteamStatus, RowSignIn, RowSignOut, RowBuilds,
    RowOverlay, RowFrameRate, RowOrientation, RowSafeArea,
    RowInput, RowCursorSpeed, RowPinch, RowButtonsCorner, RowButtonsDirection,
    RowUsageCounts,
    RowAboutApp, RowAboutSource, RowAboutAtlas, RowAboutTolkara,
};
// The About section's links.
static NSString *const SourceURL = @"https://github.com/joenye/brighter-pocket";
static NSString *const AtlasURL = @"https://brighteratlas.com";
static NSString *const TolkaraURL = @"https://github.com/tolkara/tolkara";

@interface PocketSettingsPanel : UITableViewController
- (instancetype)initWithSettings:(PocketSettings *)settings;
- (void)steamStatusChanged;
- (void)push:(UIViewController *)screen;
@end

@implementation PocketSettingsPanel {
    __weak PocketSettings *_settings;
}

- (instancetype)initWithSettings:(PocketSettings *)settings {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _settings = settings;
        self.title = @"Settings";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"pocket.settings.done";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(buildsChanged) name:BuildsNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)done { [_settings closePanel]; }
// A screen with a camera at one side only (the iPhone Duo's outer screen held upright, its
// camera at a corner) gives that side a safe-area inset all the way down, which left a band of
// the list empty: the list goes edge to edge then, the navigation bar still clear of it. With
// insets on both sides (an iPhone's notch in landscape), the list keeps to the safe area.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    UIEdgeInsets safe = self.view.window.safeAreaInsets;
    BOOL oneSide = (safe.left > 0) != (safe.right > 0);
    self.tableView.insetsLayoutMarginsFromSafeArea = !oneSide;
    self.tableView.insetsContentViewsToSafeArea = !oneSide;
}

- (BOOL)hasSteam { return dlsym(RTLD_DEFAULT, "PocketSteamCurrentState") != NULL; }
- (NSArray<NSNumber *> *)rowsIn:(NSInteger)section {
    switch ((PanelSection)section) {
        case PanelSteam:
            if (![self hasSteam]) return @[];
            // Sign Out of Steam whenever there is a sign-in to end (not while signed out already).
            return steamState(NULL) == SteamOff || steamState(NULL) == SteamSignInNeeded
                ? @[@(RowSteamStatus), @(RowSignIn)] : @[@(RowSteamStatus), @(RowSignIn), @(RowSignOut)];
        case PanelGame: return dlsym(RTLD_DEFAULT, "PocketBuildsViewController") ? @[@(RowBuilds)] : @[];
        case PanelDisplay: return @[@(RowOverlay), @(RowFrameRate), @(RowOrientation), @(RowSafeArea)];
        case PanelControls:
            return [_settings cursor] ? @[@(RowInput), @(RowCursorSpeed), @(RowPinch), @(RowButtonsCorner), @(RowButtonsDirection)]
                                      : @[@(RowInput), @(RowPinch), @(RowButtonsCorner), @(RowButtonsDirection)];
        case PanelPrivacy: return hasUsageCounts() ? @[@(RowUsageCounts)] : @[];
        case PanelAbout: return @[@(RowAboutApp), @(RowAboutSource), @(RowAboutAtlas), @(RowAboutTolkara)];
        default: return @[];
    }
}
- (PanelRow)rowAt:(NSIndexPath *)path { return (PanelRow)[self rowsIn:path.section][(NSUInteger)path.row].integerValue; }

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)table { return PanelSectionCount; }
- (NSInteger)tableView:(__unused UITableView *)table numberOfRowsInSection:(NSInteger)section { return (NSInteger)[self rowsIn:section].count; }
- (NSString *)tableView:(__unused UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (![self rowsIn:section].count) return nil;
    return @[@"Steam", @"Brighter Shores", @"Display", @"Controls", @"Privacy", @"About"][(NSUInteger)section];
}
- (NSString *)tableView:(__unused UITableView *)table titleForFooterInSection:(NSInteger)section {
    switch ((PanelSection)section) {
        case PanelDisplay: return @"Max is the screen's own rate; a lower cap saves battery. Rotate follows the way the device is held.";
        case PanelControls:
            return [_settings cursor] ? @"Slide to move the cursor, tap to click, double-tap or tap with two fingers to right-click, and drag two fingers to scroll."
                                      : @"Tap where you click. Pinch to zoom works in either mode.";
        case PanelPrivacy:
            return [self rowsIn:section].count ? @"Counts such as app opens, sign-ins and game starts, sent to Umami without your Steam account, "
                                                 @"device name or game data. Turn off to send nothing." : nil;
        case PanelAbout:
            return @"Brighter Pocket runs on Tolkara, a compatibility layer: like Wine or Proton, but for iOS. "
                   @"A Brighter Atlas project; not affiliated with Fen Research.";
        default: return nil;
    }
}

// Steam's state, as a symbol in its colour and the words PocketSteamCurrentState gives.
static UIListContentConfiguration *steamContent(void) {
    NSString *text = nil;
    SteamState state = steamState(&text);
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = text ?: @"Not signed in to Steam.";
    NSString *symbol = @"person.crop.circle.badge.xmark";
    UIColor *color = UIColor.secondaryLabelColor;
    switch (state) {
        case SteamSignedIn: symbol = @"checkmark.circle.fill"; color = UIColor.systemGreenColor; break;
        case SteamConnecting: symbol = @"arrow.triangle.2.circlepath"; color = UIColor.systemYellowColor; break;
        case SteamWarning: symbol = @"exclamationmark.triangle.fill"; color = UIColor.systemOrangeColor; break;
        case SteamUnreachable: symbol = @"wifi.exclamationmark"; color = UIColor.systemRedColor; break;
        case SteamSignInNeeded: symbol = @"exclamationmark.circle.fill"; color = UIColor.systemRedColor; break;
        case SteamOff: break;
    }
    content.image = [UIImage systemImageNamed:symbol];
    content.imageProperties.tintColor = color;
    return content;
}
- (void)steamStatusChanged {
    if (![self hasSteam] || !self.isViewLoaded) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:PanelSteam] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)buildsChanged {
    if (!self.isViewLoaded || ![self rowsIn:PanelGame].count) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:PanelGame] withRowAnimation:UITableViewRowAnimationNone];
}

// A pop-up button as a row's accessory: the choice shown, the others in its menu.
- (UIButton *)popUp:(NSArray<NSString *> *)titles selected:(NSUInteger)selected choose:(void (^)(NSUInteger index))choose {
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIAction *action = [UIAction actionWithTitle:titles[i] image:nil identifier:nil handler:^(__unused UIAction *taken) { choose(i); }];
        action.state = i == selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.indicator = UIButtonConfigurationIndicatorPopup;
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    configuration.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    button.menu = [UIMenu menuWithChildren:actions];
    button.showsMenuAsPrimaryAction = YES;
    button.changesSelectionAsPrimaryAction = YES;
    [button sizeToFit];
    return button;
}
- (UISwitch *)toggle:(BOOL)on change:(void (^)(BOOL on))change {
    UISwitch *control = [UISwitch new];
    control.on = on;
    [control addAction:[UIAction actionWithHandler:^(UIAction *action) { change(((UISwitch *)action.sender).on); }]
      forControlEvents:UIControlEventValueChanged];
    return control;
}
// A row that opens a web page: its title in the tint colour, an arrow out of the app.
- (void)link:(NSString *)title content:(UIListContentConfiguration *)content cell:(UITableViewCell *)cell {
    content.text = title;
    content.textProperties.color = self.view.tintColor;
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.right"]];
    arrow.tintColor = UIColor.tertiaryLabelColor;
    cell.accessoryView = arrow;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityTraits = UIAccessibilityTraitLink;
}
// The app's icon from its asset catalog, as the home screen shows it.
static UIImage *appIcon(void) { return [UIImage imageNamed:@"AppIcon"] ?: [UIImage imageNamed:@"AppIcon60x60"]; }

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"row" forIndexPath:path];
    cell.insetsLayoutMarginsFromSafeArea = table.insetsLayoutMarginsFromSafeArea;   // edge to edge with the list
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityTraits = UIAccessibilityTraitNone;
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    PocketSettings *settings = _settings;
    __weak PocketSettingsPanel *weakSelf = self;
    switch ([self rowAt:path]) {
        case RowSteamStatus: content = steamContent(); break;
        case RowSignIn: {
            SteamState state = steamState(NULL);
            content.text = state == SteamSignInNeeded || state == SteamOff ? @"Sign In to Steam" : @"Sign In Again";
            content.textProperties.color = self.view.tintColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessibilityTraits = UIAccessibilityTraitButton;
            break;
        }
        case RowSignOut:
            content.text = @"Sign Out of Steam";
            content.textProperties.color = UIColor.systemRedColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessibilityTraits = UIAccessibilityTraitButton;
            break;
        case RowBuilds: {
            content = [UIListContentConfiguration subtitleCellConfiguration];
            content.text = @"Builds";
            content.secondaryText = buildsSummary();
            content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
        case RowOverlay: {
            content.text = @"Performance Overlay";
            cell.accessoryView = [self toggle:boolSetting(OverlayKey, NO) change:^(BOOL on) { [settings setOverlay:on]; }];
            break;
        }
        case RowFrameRate: {
            content.text = @"Frame Rate";
            NSInteger maximum = [settings screenMaximum], cap = frameRateSetting();
            NSArray<NSNumber *> *rates = frameRates(maximum);
            NSMutableArray<NSString *> *titles = [NSMutableArray array];
            NSUInteger selected = 0;
            for (NSUInteger i = 0; i < rates.count; i++) {
                NSInteger rate = rates[i].integerValue;
                [titles addObject:rate ? [NSString stringWithFormat:@"%ld fps", (long)rate] : [NSString stringWithFormat:@"Max (%ld fps)", (long)maximum]];
                if (rate && rate <= cap && !selected) selected = i;   // the highest at or below the kept cap
            }
            if (cap >= maximum) selected = 0;
            cell.accessoryView = [self popUp:titles selected:selected choose:^(NSUInteger i) { [settings setFrameRate:rates[i].integerValue]; }];
            break;
        }
        case RowOrientation: {
            content.text = @"Orientation";
            NSUInteger selected = 0;
            for (NSUInteger i = 0; i < 3; i++) if ([orientationSetting() isEqualToString:Orientations[i]]) selected = i;
            cell.accessoryView = [self popUp:@[@"Landscape", @"Portrait", @"Rotate"] selected:selected
                                      choose:^(NSUInteger i) { [settings setOrientation:Orientations[i]]; }];
            break;
        }
        case RowSafeArea: {
            content.text = @"Keep Clear of Notch and Corners";
            cell.accessoryView = [self toggle:boolSetting(SafeAreaKey, NO) change:^(BOOL on) { [settings setSafeArea:on]; }];
            break;
        }
        case RowInput: {
            content.text = @"Input";
            UISegmentedControl *input = [[UISegmentedControl alloc] initWithItems:@[@"Touch", @"Cursor"]];
            input.selectedSegmentIndex = [settings cursor] ? 1 : 0;
            [input addAction:[UIAction actionWithHandler:^(UIAction *action) {
                [settings setCursor:((UISegmentedControl *)action.sender).selectedSegmentIndex == 1];
                [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:PanelControls] withRowAnimation:UITableViewRowAnimationAutomatic];
            }] forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = input;
            break;
        }
        case RowCursorSpeed: {
            content.text = @"Cursor Speed";
            UISlider *speed = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 160, 34)];
            speed.minimumValue = 0.5;
            speed.maximumValue = 3;
            speed.value = (float)AKTouchTrackpadSpeed();
            speed.minimumValueImage = [UIImage systemImageNamed:@"tortoise"];
            speed.maximumValueImage = [UIImage systemImageNamed:@"hare"];
            speed.accessibilityLabel = @"Cursor Speed";
            [speed addAction:[UIAction actionWithHandler:^(UIAction *action) { [settings setCursorSpeed:((UISlider *)action.sender).value]; }]
            forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = speed;
            break;
        }
        case RowPinch: {
            content.text = @"Pinch to Zoom";
            cell.accessoryView = [self toggle:AKTouchPinchScrolls() change:^(BOOL on) { [settings setPinch:on]; }];
            break;
        }
        case RowButtonsCorner: {
            content.text = @"Button Position";
            cell.accessoryView = [self popUp:@[@"Bottom Right", @"Bottom Left", @"Top Right", @"Top Left"] selected:cornerSetting()
                                      choose:^(NSUInteger i) { [settings setButtonsCorner:(ButtonsCorner)i]; }];
            break;
        }
        case RowButtonsDirection: {
            content.text = @"Button Layout";
            cell.accessoryView = [self popUp:@[@"Horizontal", @"Vertical"] selected:boolSetting(ButtonsVerticalKey, NO) ? 1 : 0
                                      choose:^(NSUInteger i) { [settings setButtonsVertical:i == 1]; }];
            break;
        }
        case RowUsageCounts: {
            content.text = @"Anonymous Usage Counts";
            cell.accessoryView = [self toggle:usageCountsOn() change:^(BOOL on) { setUsageCounts(on); }];
            break;
        }
        case RowAboutApp: {
            content = [UIListContentConfiguration subtitleCellConfiguration];
            content.text = @"Brighter Pocket";
            NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            if ([version isKindOfClass:NSString.class]) [lines addObject:[@"Version " stringByAppendingString:version]];
            // Until when Apple's signature lets it open: renewed from the Mac (Brighter Pocket Companion).
            NSDate *expiry = SignatureExpiry();
            if (expiry) {
                NSString *date = [NSDateFormatter localizedStringFromDate:expiry dateStyle:NSDateFormatterLongStyle timeStyle:NSDateFormatterNoStyle];
                [lines addObject:expiry.timeIntervalSinceNow < 2 * 86400
                    ? [NSString stringWithFormat:@"Stops opening on %@: renew it from your Mac", date]
                    : [NSString stringWithFormat:@"Works until %@", date]];
            }
            content.secondaryText = lines.count ? [lines componentsJoinedByString:@"\n"] : nil;
            content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            content.image = appIcon();
            content.imageProperties.maximumSize = CGSizeMake(44, 44);
            content.imageProperties.reservedLayoutSize = CGSizeMake(44, 44);
            content.imageProperties.cornerRadius = 10;
            break;
        }
        case RowAboutSource: [self link:@"Brighter Pocket on GitHub" content:content cell:cell]; break;
        case RowAboutAtlas: [self link:@"Brighter Atlas" content:content cell:cell]; break;
        case RowAboutTolkara: [self link:@"Tolkara on GitHub" content:content cell:cell]; break;
    }
    cell.contentConfiguration = content;
    return cell;
}
- (BOOL)tableView:(__unused UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    PanelRow row = [self rowAt:path];
    return row == RowSignIn || row == RowSignOut || row == RowBuilds || row == RowAboutSource || row == RowAboutAtlas || row == RowAboutTolkara;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    PanelRow row = [self rowAt:path];
    if (row == RowSignIn) [_settings signInToSteam];
    if (row == RowSignOut) [self confirmSignOut];
    UIViewController *builds = row == RowBuilds ? buildsScreen() : nil;
    if (builds) [self push:builds];
    NSString *link = row == RowAboutSource ? SourceURL : row == RowAboutAtlas ? AtlasURL : row == RowAboutTolkara ? TolkaraURL : nil;
    if (link) [UIApplication.sharedApplication openURL:[NSURL URLWithString:link] options:@{} completionHandler:nil];
}
// Sign Out of Steam, once the player says so: the kept sign-in goes, and the next sign-in can
// be any account.
- (void)confirmSignOut {
    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"Sign Out of Steam?"
        message:@"Pocket forgets your Steam sign-in on this device. The game keeps running until you close it. "
                @"To play online again, sign in with any Steam account."
        preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak PocketSettingsPanel *weakSelf = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"Sign Out" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        steamSignOut();
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}
// A screen over this one, with a titled way back: iOS 26 drew the icon-only back button out of
// the bar, over the list, in a full-screen sheet beside a camera (the iPhone Duo's outer screen).
- (void)push:(UIViewController *)screen {
    UINavigationController *navigation = self.navigationController;
    screen.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Settings" style:UIBarButtonItemStylePlain target:self
                                                                              action:@selector(back)];
    [navigation pushViewController:screen animated:YES];
}
- (void)back { [self.navigationController popToViewController:self animated:YES]; }
@end

@implementation PocketSettings {
    __weak UIViewController *_controller;
    __weak UIView<PocketGameHost> *_host;
    __weak UIView *_root;
    __weak UIWindowScene *_observedScene;
    UIButton *_button, *_handle;
    NSArray<NSLayoutConstraint *> *_insideSafeArea, *_wholeScreen, *_buttonPlace, *_aroundPlace;
    CADisplayLink *_displayLink;
    UIView *_overlay;
    UILabel *_overlayText;
    NSTimer *_overlayTimer;
    uint64_t _sampledFrames;
    double _sampledTime;
    PocketSettingsPanel *_panel;
    UILabel *_notice;
    UIView *_badge, *_noticePill;
    SteamState _shownSteamState;
}
static char settingsKey;

- (instancetype)initWithController:(UIViewController *)controller host:(UIView<PocketGameHost> *)host {
    if (!(self = [super init])) return nil;
    _controller = controller; _host = host;
    UIView *root = controller.view;
    _root = root;
    host.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:host];
    _wholeScreen = @[[host.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
                     [host.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
                     [host.topAnchor constraintEqualToAnchor:root.topAnchor],
                     [host.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]];
    [self applySafeArea];
    // The trackpad (cursor input) lives in Tolkara's on-screen controls: they are always there,
    // folded away with the other buttons when the player hides them.
    [host pocketShowTouchControls:YES];

    // As Tolkara's on-screen buttons look (translation/AppKit/TouchControls.m).
    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    [_button setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    _button.tintColor = UIColor.whiteColor;
    _button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.45];
    _button.layer.cornerRadius = 22;
    _button.layer.borderWidth = 0.5;
    _button.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.4].CGColor;
    _button.accessibilityLabel = @"Settings";
    _button.accessibilityIdentifier = @"pocket.settings";
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    [_button addTarget:self action:@selector(openPanel) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_button];
    _handle = [UIButton buttonWithType:UIButtonTypeSystem];
    _handle.tintColor = UIColor.whiteColor;
    _handle.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.35];
    _handle.layer.cornerRadius = 10;
    _handle.accessibilityIdentifier = @"pocket.buttons";
    _handle.translatesAutoresizingMaskIntoConstraints = NO;
    [_handle addTarget:self action:@selector(toggleButtons) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_handle];
    [self placeButton];

    _overlay = [UIView new];
    _overlay.userInteractionEnabled = NO;
    _overlay.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.5];
    _overlay.layer.cornerRadius = 6;
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    _overlayText = [UILabel new];
    _overlayText.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    _overlayText.textColor = UIColor.whiteColor;
    _overlayText.numberOfLines = 3;
    _overlayText.translatesAutoresizingMaskIntoConstraints = NO;
    _overlay.accessibilityIdentifier = @"pocket.performance";
    [_overlay addSubview:_overlayText];
    [root addSubview:_overlay];
    [NSLayoutConstraint activateConstraints:@[
        [_overlayText.leadingAnchor constraintEqualToAnchor:_overlay.leadingAnchor constant:6],
        [_overlayText.trailingAnchor constraintEqualToAnchor:_overlay.trailingAnchor constant:-6],
        [_overlayText.topAnchor constraintEqualToAnchor:_overlay.topAnchor constant:3],
        [_overlayText.bottomAnchor constraintEqualToAnchor:_overlay.bottomAnchor constant:-3],
    ]];
    [self applyOverlay];
    [self applyFrameRate];
    [self makeSteamStatus];
    [self placeAround];
    AKLog(@"settings: overlay=%d frame rate=%ld orientation=%@ safe area=%d input=%@ pinch=%d buttons %@ at %@%@",
          boolSetting(OverlayKey, NO), (long)frameRateSetting(), orientationSetting(), boolSetting(SafeAreaKey, NO),
          [self trackpad].trackpadEnabled ? @"cursor" : @"touch", AKTouchPinchScrolls(), [self buttonsHidden] ? @"hidden" : @"shown",
          Corners[cornerSetting()], boolSetting(ButtonsVerticalKey, NO) ? @", vertical" : @"");

    // The window is shown once the controller is its root: then turn it as chosen.
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    BOOL demo = [arguments containsObject:@"--settings-demo"], builds = [arguments containsObject:@"--open-builds"];
    BOOL about = [arguments containsObject:@"--open-about"];
    BOOL open = demo || builds || about || [arguments containsObject:@"--open-settings"];
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyOrientation]; });
    // The sheet once the window has turned and settled, as a tap on the gear would open it.
    if (open) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self openPanel];
        UIViewController *screen = builds ? buildsScreen() : nil;
        if (screen) [self->_panel push:screen];
        if (about) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            UITableView *table = self->_panel.tableView;
            [table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:PanelAbout] atScrollPosition:UITableViewScrollPositionTop animated:NO];
        });
    });
    if (demo) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self demoStep:0]; });
    return self;
}

// --- the Steam session, as the player should see it ---------------------------------------------
// A dot on the gear while it needs attention (yellow: reconnecting or a warning; red: Steam
// cannot be reached, or wants a sign-in), a short notice at the top when that changes, and the
// whole story, with Sign In to Steam, in the sheet.
- (void)makeSteamStatus {
    UIView *root = _root;
    _badge = [UIView new];
    _badge.userInteractionEnabled = NO;
    _badge.layer.cornerRadius = 5;
    _badge.layer.borderWidth = 1;
    _badge.layer.borderColor = UIColor.blackColor.CGColor;
    _badge.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_badge];
    // The notice: a capsule of the system's material at the top, as iOS's own banners (at the
    // bottom while the buttons are at the top: placeAround).
    UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    pill.layer.cornerRadius = 18;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    _noticePill = pill;
    _noticePill.alpha = 0;
    _noticePill.userInteractionEnabled = NO;
    _noticePill.translatesAutoresizingMaskIntoConstraints = NO;
    _notice = [UILabel new];
    _notice.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _notice.textColor = UIColor.labelColor;
    _notice.textAlignment = NSTextAlignmentCenter;
    _notice.numberOfLines = 2;
    _notice.translatesAutoresizingMaskIntoConstraints = NO;
    [pill.contentView addSubview:_notice];
    [root addSubview:_noticePill];
    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_badge.widthAnchor constraintEqualToConstant:10], [_badge.heightAnchor constraintEqualToConstant:10],
        [_badge.topAnchor constraintEqualToAnchor:_button.topAnchor constant:1],
        [_badge.trailingAnchor constraintEqualToAnchor:_button.trailingAnchor constant:-1],
        [_noticePill.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_noticePill.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-40],
        [_noticePill.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [_notice.leadingAnchor constraintEqualToAnchor:_noticePill.leadingAnchor constant:18],
        [_notice.trailingAnchor constraintEqualToAnchor:_noticePill.trailingAnchor constant:-18],
        [_notice.topAnchor constraintEqualToAnchor:_noticePill.topAnchor constant:8],
        [_notice.bottomAnchor constraintEqualToAnchor:_noticePill.bottomAnchor constant:-8],
    ]];
    _shownSteamState = steamState(NULL);
    [self steamStatusChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(steamStatusChanged) name:SteamStatusNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(noticeArrived:) name:NoticeNotification object:nil];
}
- (void)noticeArrived:(NSNotification *)notification {
    NSString *text = notification.userInfo[@"text"];
    if (text) [self showNotice:text];
}

- (void)steamStatusChanged {
    NSString *text = nil;
    SteamState state = steamState(&text);
    BOOL problem = state == SteamUnreachable || state == SteamSignInNeeded;
    _badge.hidden = !(problem || state == SteamConnecting || state == SteamWarning) || _button.hidden;
    _badge.backgroundColor = problem ? UIColor.systemRedColor : UIColor.systemYellowColor;
    [_panel steamStatusChanged];
    // A notice when it goes wrong, or right again after going wrong; not for every check.
    BOOL wasProblem = _shownSteamState == SteamUnreachable || _shownSteamState == SteamSignInNeeded;
    if (text && state != _shownSteamState && (problem || state == SteamWarning || (wasProblem && state == SteamSignedIn)))
        [self showNotice:state == SteamSignedIn ? @"Connected to Steam again." : text];
    _shownSteamState = state;
}

- (void)showNotice:(NSString *)text {
    _notice.text = text;
    [UIView animateWithDuration:0.25 animations:^{ self->_noticePill.alpha = 1; }];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideNotice) object:nil];
    [self performSelector:@selector(hideNotice) withObject:nil afterDelay:5];
}
- (void)hideNotice { [UIView animateWithDuration:0.4 animations:^{ self->_noticePill.alpha = 0; }]; }

- (void)signInToSteam {
    // Over the game once the sheet has gone: the sign-in is a sheet of its own.
    UIViewController *controller = _controller;
    if (_panel.presentingViewController) [_panel dismissViewControllerAnimated:YES completion:^{ steamSignInAgain(controller); }];
    else steamSignInAgain(controller);
    [self panelClosed];
}

// --- applying each setting ----------------------------------------------------------------
// The screen's corner radius (UIKit's own, read defensively: 0 if it has none). Inset by
// r(1 - 1/√2) on each side, the game's view keeps its corners inside the rounded screen, which
// the safe area alone does not do on a screen without a notch.
static CGFloat cornerInset(UIScreen *screen) {
    CGFloat radius = 0;
    @try { radius = [[screen valueForKey:@"_displayCornerRadius"] doubleValue]; } @catch (NSException *missing) { (void)missing; }
    return isfinite(radius) && radius > 0 ? ceil(radius * (1 - M_SQRT1_2)) : 0;
}

// Inside the safe area and clear of the corners: each edge at whichever is further in, the
// safe area's or the corner inset.
- (NSArray<NSLayoutConstraint *> *)insideConstraints {
    UIView *root = _root, *host = _host;
    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    CGFloat c = cornerInset(root.window.windowScene.screen ?: UIScreen.mainScreen);
    NSArray<NSLayoutConstraint *> *preferred = @[[host.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:c],
                                                 [host.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-c],
                                                 [host.topAnchor constraintEqualToAnchor:root.topAnchor constant:c],
                                                 [host.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-c]];
    for (NSLayoutConstraint *constraint in preferred) constraint.priority = UILayoutPriorityDefaultLow;
    return [preferred arrayByAddingObjectsFromArray:@[
        [host.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor],
        [host.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.leadingAnchor constant:c],
        [host.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor],
        [host.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-c],
        [host.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor],
        [host.topAnchor constraintGreaterThanOrEqualToAnchor:root.topAnchor constant:c],
        [host.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor],
        [host.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor constant:-c]]];
}

- (void)applySafeArea {
    BOOL inside = boolSetting(SafeAreaKey, NO);
    if (_insideSafeArea) [NSLayoutConstraint deactivateConstraints:_insideSafeArea];
    [NSLayoutConstraint deactivateConstraints:_wholeScreen];
    _insideSafeArea = [self insideConstraints];
    [NSLayoutConstraint activateConstraints:inside ? _insideSafeArea : _wholeScreen];
    if (_handle) [self placeButton];
    [_root setNeedsLayout];
    [_root layoutIfNeeded];
}

// The scene's geometry (a turn, or the game moving to the other screen of an iPhone Duo, with
// its own corners): the border again.
- (void)observeScene {
    UIWindowScene *scene = _root.window.windowScene;
    if (!scene || scene == _observedScene) return;
    [_observedScene removeObserver:self forKeyPath:@"effectiveGeometry"];
    _observedScene = scene;
    [scene addObserver:self forKeyPath:@"effectiveGeometry" options:0 context:NULL];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)keyPath; (void)object; (void)change; (void)context;
    __weak PocketSettings *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applySafeArea]; });
}

- (AKTouchControls *)trackpad {
    UIView *controls = _host.pocketTouchControls;
    return [controls isKindOfClass:AKTouchControls.class] ? (AKTouchControls *)controls : nil;
}
- (BOOL)buttonsHidden { return boolSetting(ButtonsHiddenKey, !isPhone()); }

// Shown: [handle][gear][trackpad][keyboard] from the chosen corner (bottom right unless chosen)
// outward, in a row or a column, the keyboard's button at the corner. Hidden: the handle alone,
// half see-through, at the corner. Over the whole screen they sit in its corner, clear of the
// rounded edge but not of the safe area's side: on a screen whose camera is at a side (an iPhone
// in landscape, the iPhone Duo's outer screen in portrait), the safe area's side inset runs the
// whole height, and the buttons stopped where the border would end. Inside the safe-area border,
// at its edge. At the bottom they keep above the keyboard; at the top, below the safe area's top
// (a notch, a Dynamic Island) and clear of the rounded corner.
- (CGFloat)edgeInset {
    if (boolSetting(SafeAreaKey, NO)) return 12;
    return MAX(8, cornerInset(_root.window.windowScene.screen ?: UIScreen.mainScreen));
}
- (void)placeButton {
    UIView<PocketGameHost> *host = _host;
    if (_buttonPlace) [NSLayoutConstraint deactivateConstraints:_buttonPlace];
    UIView *controls = host.pocketTouchControls;
    // Tolkara places its controls itself (translation/AppKit/AppKit.m: 96 x 44 at the safe area's
    // bottom right); they go with the rest here instead.
    for (NSLayoutConstraint *constraint in host.constraints)
        if (controls && (constraint.firstItem == controls || constraint.secondItem == controls)) constraint.active = NO;
    for (NSLayoutConstraint *constraint in controls.constraints)
        if (constraint.firstItem == controls && !constraint.secondItem) constraint.active = NO;
    BOOL hidden = [self buttonsHidden];
    controls.hidden = hidden;
    _button.hidden = hidden;
    if (_badge) [self steamStatusChanged];
    if (hidden && [controls isKindOfClass:AKTouchControls.class]) [(AKTouchControls *)controls dismissKeyboard];

    ButtonsCorner corner = cornerSetting();
    BOOL left = cornerIsLeft(corner), top = cornerIsTop(corner), vertical = boolSetting(ButtonsVerticalKey, NO);
    if ([controls isKindOfClass:AKTouchControls.class]) {
        AKTouchControls *touch = (AKTouchControls *)controls;
        touch.vertical = vertical;
        touch.keyboardFirst = vertical ? top : left;   // the keyboard's button at the corner
    }
    // The handle's chevron points the way the buttons go: into the corner to fold them away,
    // out of it to bring them back.
    NSString *into = vertical ? (top ? @"up" : @"down") : (left ? @"left" : @"right");
    NSString *outOf = vertical ? (top ? @"down" : @"up") : (left ? @"right" : @"left");
    [_handle setImage:[UIImage systemImageNamed:[@"chevron." stringByAppendingString:hidden ? outOf : into]] forState:UIControlStateNormal];
    _handle.alpha = hidden ? 0.6 : 1;
    _handle.accessibilityLabel = hidden ? @"Show the on-screen buttons" : @"Hide the on-screen buttons";

    CGFloat edge = [self edgeInset];
    NSMutableArray<NSLayoutConstraint *> *place = [NSMutableArray arrayWithArray:@[
        [_button.widthAnchor constraintEqualToConstant:44],
        [_button.heightAnchor constraintEqualToConstant:44],
        [_handle.widthAnchor constraintEqualToConstant:vertical ? 44 : 24],
        [_handle.heightAnchor constraintEqualToConstant:vertical ? 24 : 44]]];
    if (controls) [place addObjectsFromArray:@[[controls.widthAnchor constraintEqualToConstant:vertical ? 44 : 96],
                                               [controls.heightAnchor constraintEqualToConstant:vertical ? 96 : 44]]];
    // Against the corner's side (left or right) and its end (top or bottom).
    void (^side)(UIView *) = ^(UIView *view) {
        [place addObject:left ? [view.leftAnchor constraintEqualToAnchor:host.leftAnchor constant:edge]
                              : [view.rightAnchor constraintEqualToAnchor:host.rightAnchor constant:-edge]];
    };
    void (^end)(UIView *) = ^(UIView *view) {
        if (!top) { [place addObject:[view.bottomAnchor constraintEqualToAnchor:host.keyboardLayoutGuide.topAnchor constant:-8]]; return; }
        NSLayoutConstraint *up = [view.topAnchor constraintEqualToAnchor:host.topAnchor];
        up.priority = UILayoutPriorityDefaultLow;
        [place addObjectsFromArray:@[[view.topAnchor constraintGreaterThanOrEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:8],
                                     [view.topAnchor constraintGreaterThanOrEqualToAnchor:host.topAnchor constant:edge], up]];
    };
    // Each in turn from the corner: the first against it, the next beyond the one before.
    void (^next)(UIView *, UIView *) = ^(UIView *view, UIView *previous) {
        if (!previous) { side(view); end(view); return; }
        if (vertical) {
            side(view);
            [place addObject:top ? [view.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:8]
                                 : [view.bottomAnchor constraintEqualToAnchor:previous.topAnchor constant:-8]];
        } else {
            end(view);
            [place addObject:left ? [view.leftAnchor constraintEqualToAnchor:previous.rightAnchor constant:8]
                                  : [view.rightAnchor constraintEqualToAnchor:previous.leftAnchor constant:-8]];
        }
    };
    if (controls) next(controls, nil);
    next(_button, controls);
    next(_handle, hidden ? nil : _button);
    _buttonPlace = place;
    [NSLayoutConstraint activateConstraints:_buttonPlace];
    [self placeAround];
}

// What shares the screen's edges with the buttons: the notice at the top, or at the bottom
// while the buttons are at the top; the performance overlay at the top left, or the top right
// while the buttons are there.
- (void)placeAround {
    UIView<PocketGameHost> *host = _host;
    if (!_overlay || !_noticePill || !host) return;
    if (_aroundPlace) [NSLayoutConstraint deactivateConstraints:_aroundPlace];
    ButtonsCorner corner = cornerSetting();
    UILayoutGuide *safe = host.safeAreaLayoutGuide, *rootSafe = _root.safeAreaLayoutGuide;
    _aroundPlace = @[
        corner == CornerTopLeft ? [_overlay.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-6]
                                : [_overlay.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:6],
        [_overlay.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        cornerIsTop(corner) ? [_noticePill.bottomAnchor constraintEqualToAnchor:rootSafe.bottomAnchor constant:-8]
                            : [_noticePill.topAnchor constraintEqualToAnchor:rootSafe.topAnchor constant:8],
    ];
    [NSLayoutConstraint activateConstraints:_aroundPlace];
}

- (void)toggleButtons {
    [NSUserDefaults.standardUserDefaults setBool:![self buttonsHidden] forKey:ButtonsHiddenKey];
    [UIView animateWithDuration:0.2 animations:^{
        [self placeButton];
        [self->_root layoutIfNeeded];
    }];
    AKLog(@"settings: on-screen buttons %@", [self buttonsHidden] ? @"hidden" : @"shown");
}

- (void)applyOverlay {
    BOOL shown = boolSetting(OverlayKey, NO);
    _overlay.hidden = !shown;
    [_overlayTimer invalidate];
    _overlayTimer = nil;
    if (!shown) return;
    _sampledFrames = 0; _sampledTime = 0;
    [self updateOverlay];
    __weak PocketSettings *weakSelf = self;
    _overlayTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf updateOverlay];
    }];
    [NSRunLoop.mainRunLoop addTimer:_overlayTimer forMode:NSRunLoopCommonModes];
}

- (NSInteger)screenMaximum {
    UIScreen *screen = _root.window.windowScene.screen ?: UIScreen.mainScreen;
    return MAX(1, screen.maximumFramesPerSecond);
}

// Frames presented since the last look, over the time between their presentations.
- (void)updateOverlay {
    NSDictionary<NSString *, NSNumber *> *sample = [pacing() sample];
    uint64_t frames = sample[@"frames"].unsignedLongLongValue;
    double last = sample[@"lastPresented"].doubleValue, longest = sample[@"longestGap"].doubleValue;
    double asked = sample[@"gameInterval"].doubleValue;
    NSString *rate = @"-- fps", *time = @"--";
    if (_sampledTime > 0 && frames > _sampledFrames && last > _sampledTime) {
        double fps = (frames - _sampledFrames) / (last - _sampledTime);
        rate = [NSString stringWithFormat:@"%.0f fps", fps];
        time = [NSString stringWithFormat:@"%.1f", 1000 / fps];
    } else if (_sampledTime > 0 && CACurrentMediaTime() - _sampledTime > 1) {
        rate = @"0 fps";
    }
    if (frames != _sampledFrames) { _sampledFrames = frames; _sampledTime = last; }
    if (!_sampledTime && last > 0) _sampledTime = last;
    NSInteger cap = frameRateSetting(), maximum = [self screenMaximum], target = cap && cap < maximum ? cap : maximum;
    // The game's own rate, when it differs: below the target, the game holds the rate there.
    long game = asked > 0 ? lround(1 / asked) : 0;
    // What holds a frame back: the GPU's time for a frame, and the wait for a drawable (the
    // display, or the GPU still on earlier frames).
    _overlayText.text = [NSString stringWithFormat:@"%@  %@ ms\ntarget %@%ld%@  worst %.0f ms\ngpu %.1f ms  wait %.1f ms", rate, time,
                         target == maximum ? @"max " : @"", (long)target,
                         game && game != target ? [NSString stringWithFormat:@" (game %ld)", game] : @"", longest * 1000,
                         sample[@"gpuTime"].doubleValue * 1000, sample[@"drawableWait"].doubleValue * 1000];
}

- (void)applyFrameRate {
    NSInteger rate = frameRateSetting();
    Class<PocketPresentationPacing> presentation = pacing();
    if (!presentation) { AKLog(@"settings: no presentation pacing in the Metal adapter; frame rate unchanged"); return; }
    [presentation setMinimumInterval:rate ? 1.0 / rate : 0];
    // The screen at the target rate: a ProMotion screen runs at what the app's display links ask.
    NSInteger maximum = [self screenMaximum];
    float target = rate && rate < maximum ? (float)rate : (float)maximum;
    if (!_displayLink) {
        _displayLink = [CADisplayLink displayLinkWithTarget:[PocketDisplayRate new] selector:@selector(tick:)];
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(target > 60 ? 60 : target, target, target);
    AKLog(@"settings: frame rate %@", rate ? [NSString stringWithFormat:@"capped at %ld", (long)rate] : @"as fast as the screen allows");
    if (!_overlay.hidden) [self updateOverlay];
}

- (void)applyOrientation {
    [self observeScene];
    [self applySafeArea];
    UIViewController *controller = _controller;
    [controller setNeedsUpdateOfSupportedInterfaceOrientations];
    UIWindowScene *scene = controller.viewIfLoaded.window.windowScene;
    if (!scene) return;
    UIWindowSceneGeometryPreferencesIOS *preferences =
        [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:PocketSettingsOrientations()];
    [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
        AKLog(@"settings: orientation %@ not taken: %@", orientationSetting(), error.localizedDescription);
    }];
}

// --- the settings, as the sheet and the demo change them ----------------------------------------
- (BOOL)cursor { return [self trackpad].trackpadEnabled; }
- (void)setOverlay:(BOOL)on {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:OverlayKey];
    [self applyOverlay];
    AKLog(@"settings: performance overlay %@", on ? @"on" : @"off");
}
- (void)setFrameRate:(NSInteger)rate {
    [NSUserDefaults.standardUserDefaults setInteger:rate forKey:FrameRateKey];
    [self applyFrameRate];
}
- (void)setOrientation:(NSString *)orientation {
    [NSUserDefaults.standardUserDefaults setObject:orientation forKey:OrientationKey];
    AKLog(@"settings: orientation %@", orientation);
    [self applyOrientation];
}
- (void)setSafeArea:(BOOL)on {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:SafeAreaKey];
    AKLog(@"settings: safe-area border %@", on ? @"on" : @"off");
    [self applySafeArea];
}
- (void)setCursor:(BOOL)cursor {
    [self trackpad].trackpadEnabled = cursor;
    [NSUserDefaults.standardUserDefaults setBool:cursor forKey:AKTouchTrackpadDefaultsKey];
    [_host pocketInputChanged];
    AKLog(@"settings: input %@", cursor ? @"cursor" : @"touch");
}
- (void)setCursorSpeed:(double)speed { [NSUserDefaults.standardUserDefaults setDouble:speed forKey:AKTouchSpeedDefaultsKey]; }
- (void)setPinch:(BOOL)on {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:AKTouchPinchDefaultsKey];
    [_host pocketInputChanged];
    AKLog(@"settings: pinch to zoom %@", on ? @"on" : @"off");
}

- (void)setButtonsCorner:(ButtonsCorner)corner {
    [NSUserDefaults.standardUserDefaults setObject:Corners[corner] forKey:ButtonsCornerKey];
    AKLog(@"settings: on-screen buttons at %@", Corners[corner]);
    [self movedButtons];
}
- (void)setButtonsVertical:(BOOL)vertical {
    [NSUserDefaults.standardUserDefaults setBool:vertical forKey:ButtonsVerticalKey];
    AKLog(@"settings: on-screen buttons %@", vertical ? @"in a column" : @"in a row");
    [self movedButtons];
}
- (void)movedButtons {
    [UIView animateWithDuration:0.2 animations:^{
        [self placeButton];
        [self->_root layoutIfNeeded];
    }];
}

- (void)openPanel {
    UIViewController *controller = _controller;
    if (_panel || !controller || controller.presentedViewController) return;
    UIView *controls = _host.pocketTouchControls;
    if ([controls isKindOfClass:AKTouchControls.class]) [(AKTouchControls *)controls dismissKeyboard];
    _noticePill.hidden = YES;   // the sheet says it all; the notice comes back with the game
    _panel = [[PocketSettingsPanel alloc] initWithSettings:self];
    UINavigationController *sheet = [[PocketSheetNavigation alloc] initWithRootViewController:_panel];
    sheet.modalPresentationStyle = UIModalPresentationFormSheet;
    sheet.presentationController.delegate = self;
    sheet.view.accessibilityIdentifier = @"pocket.settings.panel";
    [controller presentViewController:sheet animated:YES completion:nil];
    AKLog(@"settings: sheet open");
}
- (void)closePanel {
    if (!_panel) return;
    [_panel dismissViewControllerAnimated:YES completion:nil];
    [self panelClosed];
}
// Done, or the sheet swiped away.
- (void)presentationControllerDidDismiss:(__unused UIPresentationController *)presentation { [self panelClosed]; }
- (void)panelClosed {
    if (!_panel) return;
    _panel = nil;
    _noticePill.hidden = NO;
    [_host becomeFirstResponder];   // the keyboard's keys go to the game again
    AKLog(@"settings: sheet closed");
}

// --settings-demo: the sheet closes, then each setting changes in turn over the game, where its
// effect shows (the sheet covers the whole game on a phone), three seconds apart.
- (void)demoStep:(NSUInteger)step {
    NSArray<NSNumber *> *rates = frameRates([self screenMaximum]);
    switch (step) {
        case 0: {   // from the defaults, so each step below shows its change
            [self closePanel];
            [self setOverlay:NO];
            [self setFrameRate:0];
            [self setSafeArea:NO];
            [self setCursor:NO];
            [self setOrientation:@"device"];
            if ([self buttonsHidden]) [self toggleButtons];
            break;
        }
        case 1: [self setOverlay:YES]; break;
        case 2: if ([rates containsObject:@30]) [self setFrameRate:30]; break;
        case 3: [self setFrameRate:0]; break;
        case 4: [self setSafeArea:!boolSetting(SafeAreaKey, NO)]; break;
        case 5: [self setSafeArea:!boolSetting(SafeAreaKey, NO)]; break;
        case 6: [self setCursor:![self cursor]]; break;
        case 7: [self setCursor:![self cursor]]; break;
        case 8: [self toggleButtons]; break;
        case 9: [self toggleButtons]; break;
        case 10: [self setOverlay:NO]; break;
        case 11: [self setOrientation:@"portrait"]; break;
        case 12: [self setOrientation:@"device"]; break;
        default: return;
    }
    AKLog(@"settings demo: step %lu done", (unsigned long)step);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self demoStep:step + 1]; });
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_observedScene removeObserver:self forKeyPath:@"effectiveGeometry"];
    [_overlayTimer invalidate];
    [_displayLink invalidate];
}
@end

void PocketSettingsAttach(UIViewController *controller, UIView<PocketGameHost> *host) {
    PocketSettings *settings = [[PocketSettings alloc] initWithController:controller host:host];
    objc_setAssociatedObject(controller, &settingsKey, settings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [NSNotificationCenter.defaultCenter postNotificationName:GameStartedNotification object:nil];
    // At the main menu, about: the sign-in is offered there if the game started without Steam;
    // not in a development run that opens the settings itself.
    for (NSString *argument in NSProcessInfo.processInfo.arguments)
        if ([@[@"--open-settings", @"--open-builds", @"--open-about", @"--settings-demo"] containsObject:argument]) return;
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MainMenuDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *presenter = weakController;
        if (presenter && !presenter.presentedViewController) gameReady(presenter);
    });
}
