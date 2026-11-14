// Keeping Brighter Shores at Steam's build: the builds service, its screens and timing
// (PocketGameUpdates.h); the build on the device and the files are PocketInstalledGame.m's.
#import "PocketGameUpdates.h"
#import "PocketAnalytics.h"
#import "PocketInstalledGame.h"
#import "PocketSignInViewController.h"
#import "PocketSteamLaunch.h"

NSString *const PocketLaunchProgressNotification = @"PocketLaunchProgress";
NSString *const PocketGameStartedNotification = @"PocketGameStarted";
NSString *const PocketNoticeNotification = @"PocketNotice";
NSString *const PocketBuildsDidChangeNotification = @"PocketBuildsDidChange";
NSString *const PocketSteamBranchKey = @"PocketSteamBranch";
NSString *const PocketSteamBranchesKey = @"PocketSteamBranches";

static const NSTimeInterval WatchInterval = 10 * 60;
static const NSTimeInterval LaunchCheckBudget = 6;   // before the game starts: Steam answers by then, or the check goes on behind the game

typedef NS_ENUM(NSInteger, BuildsState) {
    BuildsUnchecked,     // not asked yet this run (no session yet)
    BuildsChecking,
    BuildsUpToDate,
    BuildsAvailable,     // Steam has another build; not downloaded
    BuildsDownloading,
    BuildsReady,         // downloaded: in place the next time the app opens
    BuildsFailed,        // the check or the download did not finish (message)
};

static NSString *Branch(void) {
    NSString *branch = [NSUserDefaults.standardUserDefaults stringForKey:PocketSteamBranchKey];
    return branch.length ? branch : @"public";
}
static void Progress(NSString *text, NSNumber *_Nullable fraction) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:text forKey:@"text"];
        if (fraction) info[@"fraction"] = fraction;
        [NSNotificationCenter.defaultCenter postNotificationName:PocketLaunchProgressNotification object:nil userInfo:info];
    });
}
static NSString *FailureText(NSError *error) {
    BOOL ours = [error.domain isEqualToString:PocketDepotErrorDomain];
    if (ours && error.code == PocketDepotErrorNoSpace)
        return [NSString stringWithFormat:@"There isn't enough free space on this device (%@). Free some space, then try again.", error.localizedDescription];
    if (ours && error.code == PocketDepotErrorNetwork) return @"Steam's servers didn't answer. Check that this device is online, then try again. What came so far is kept.";
    if (ours && error.code == PocketDepotErrorNotOwned) return @"Steam didn't let this account download Brighter Shores.";
    if (ours && error.code == PocketDepotErrorCorrupt) return @"Part of the download didn't check out. Try again: it is fetched again.";
    return [NSString stringWithFormat:@"The update couldn't finish (%@). What came so far is kept.", error.localizedDescription ?: @"an unknown error"];
}

// --- the service ----------------------------------------------------------------------------------
// State on the main thread; Steam and the files on a serial queue of its own.
@interface PocketBuilds : NSObject
@property(nonatomic, readonly) PocketInstalledGame *installed;
@property BuildsState state;
@property(copy, nullable) NSString *installedLabel, *latestLabel, *message;   // atomic: the queue reads them too
@property(nullable) NSDate *checked;
@property int64_t done, total;
@property BOOL gameRunning;
@property(atomic) BOOL cancel;
@end

@implementation PocketBuilds {
    dispatch_queue_t _queue;
    dispatch_source_t _watch;
}

+ (PocketBuilds *)shared {
    static PocketBuilds *builds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ builds = [PocketBuilds new]; });
    return builds;
}
// From the app's start: a game started offline still tells the builds it works.
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:PocketGameStartedNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) { [PocketBuilds.shared gameStarted]; }];
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        _installed = [[PocketInstalledGame alloc] initWithDocuments:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                                                            updates:[support stringByAppendingPathComponent:@"Updates"]];
        _queue = dispatch_queue_create("pocket.builds", DISPATCH_QUEUE_SERIAL);
        [self refreshInstalledLabel];
    }
    return self;
}

- (void)changed {
    void (^post)(void) = ^{ [NSNotificationCenter.defaultCenter postNotificationName:PocketBuildsDidChangeNotification object:nil]; };
    NSThread.isMainThread ? post() : dispatch_async(dispatch_get_main_queue(), post);
}
- (void)onMain:(dispatch_block_t)block { dispatch_async(dispatch_get_main_queue(), block); }
- (void)refreshInstalledLabel {
    dispatch_async(_queue, ^{
        NSString *label = self.installed.label;
        [self onMain:^{ self.installedLabel = label; [self changed]; }];
    });
}
- (void)notice:(NSString *)text {
    [self onMain:^{ [NSNotificationCenter.defaultCenter postNotificationName:PocketNoticeNotification object:nil userInfo:@{@"text": text}]; }];
}

// The state in words, for the Builds screen and the settings' row.
- (NSString *)stateText {
    switch (self.state) {
        case BuildsUnchecked: return @"Not checked yet";
        case BuildsChecking: return @"Checking…";
        case BuildsUpToDate: return @"Up to date";
        case BuildsAvailable: return @"Update available";
        case BuildsDownloading:
            return self.total ? [NSString stringWithFormat:@"Downloading… %.0f of %.0f MB", self.done / 1e6, self.total / 1e6] : @"Downloading…";
        case BuildsReady: return @"Ready: reopen Brighter Pocket to install";
        case BuildsFailed: return @"Couldn't finish";
    }
    return @"";
}

// Queue: Steam's build on the branch, against the device's. The depot and release for a
// download that follows; nil when Steam could not be asked (message set).
- (PocketDepotRelease *)checkWith:(PocketSteamClient *)client depot:(PocketDepot *_Nullable *_Nonnull)depotOut {
    [self onMain:^{ self.state = BuildsChecking; self.message = nil; [self changed]; }];
    NSString *branch = Branch();
    PocketDepot *depot = [[PocketDepot alloc] initWithClient:client appID:PocketGameAppID depotID:PocketGameDepotID];
    NSError *error = nil;
    NSArray *branches = [depot branchesWithError:&error];
    if (branches.count) [NSUserDefaults.standardUserDefaults setObject:branches forKey:PocketSteamBranchesKey];
    if (branches && ![branches containsObject:branch]) {
        NSLog(@"[update] the branch %@ is gone; using public", branch);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:PocketSteamBranchKey];
        branch = @"public";
    }
    PocketDepotRelease *release = branches ? [depot releaseOnBranch:branch error:&error] : nil;
    if (!release) {
        NSLog(@"[update] no answer about updates (%@ %ld)", error.domain, (long)error.code);
        [self onMain:^{ self.state = BuildsFailed; self.message = @"Steam didn't answer. Check that this device is online."; [self changed]; }];
        return nil;
    }
    BOOL current = [self.installed isCurrent:release depot:depot];
    NSString *installedLabel = self.installed.label;
    NSString *latest = current ? installedLabel : PocketBuildLabel(release.updated, [self.installed versionOfRelease:release depot:depot]);
    BOOL staged = [self.installed.staged[@"manifest"] unsignedLongLongValue] == release.manifestID;
    NSLog(@"[update] Steam's build on %@: %@; the device's: %@", branch, latest, current ? @"the same" : installedLabel);
    [self onMain:^{
        self.checked = NSDate.date;
        self.installedLabel = installedLabel;
        self.latestLabel = latest;
        self.state = current ? BuildsUpToDate : staged ? BuildsReady : BuildsAvailable;
        [self changed];
    }];
    *depotOut = depot;
    return release;
}

// Queue: fetch the release into staging, its progress in the state.
- (BOOL)stage:(PocketDepotRelease *)release depot:(PocketDepot *)depot error:(NSError **)error {
    self.cancel = NO;
    [self onMain:^{ self.state = BuildsDownloading; self.done = 0; self.total = 0; [self changed]; }];
    __block NSTimeInterval shown = 0;
    UIBackgroundTaskIdentifier background = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"update" expirationHandler:nil];
    NSString *label = self.latestLabel;
    BOOL staged = [self.installed stage:release depot:depot progress:^(int64_t done, int64_t total) {
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        @synchronized (self) {
            if (now - shown < 0.25 && done < total) return;
            shown = now;
        }
        [self onMain:^{ self.done = done; self.total = total; [self changed]; }];
        if (!self.gameRunning)
            Progress([NSString stringWithFormat:@"Updating to %@… %.0f of %.0f MB", label ?: @"Steam's build", done / 1e6, total / 1e6],
                     @(total ? (double)done / total : 1));
    } cancelled:^BOOL { return self.cancel; } error:error];
    [UIApplication.sharedApplication endBackgroundTask:background];
    NSError *failure = staged || !error ? nil : *error;
    [self onMain:^{
        self.state = staged ? BuildsReady : BuildsFailed;
        self.message = staged ? nil : self.cancel ? @"Download stopped. What came so far is kept." : FailureText(failure);
        [self changed];
    }];
    return staged;
}

// Queue, while the game runs (or once the launch has gone on without it): check, and fetch a
// newer build in the background; the notice says what came of it.
- (void)checkAndStage:(PocketSteamClient *)client announce:(BOOL)announce {
    PocketDepot *depot = nil;
    PocketDepotRelease *release = [self checkWith:client depot:&depot];
    if (!release) return;
    __block BuildsState state;
    dispatch_sync(dispatch_get_main_queue(), ^{ state = self.state; });
    if (state == BuildsUpToDate) {
        if (announce) [self notice:[NSString stringWithFormat:@"Brighter Shores is up to date: %@.", self.latestLabel]];
        return;
    }
    if (state == BuildsAvailable) {
        [self notice:[NSString stringWithFormat:@"Update available: %@. Downloading it now.", self.latestLabel]];
        NSError *error = nil;
        if (![self stage:release depot:depot error:&error]) {
            [self notice:@"The update couldn't download. Settings › Builds has more."];
            return;
        }
    }
    [self notice:[NSString stringWithFormat:@"Update ready: %@. Close Brighter Pocket and open it again to install it.", self.latestLabel]];
}

- (void)checkNow {
    if (self.state == BuildsChecking || self.state == BuildsDownloading) return;
    dispatch_async(_queue, ^{
        PocketSteamClient *client = PocketSteamOnlineSession();
        if (client) { [self checkAndStage:client announce:NO]; return; }
        [self onMain:^{
            self.state = BuildsFailed;
            self.message = @"Sign in to Steam to check for updates.";
            [self changed];
        }];
    });
}
- (void)watch {
    if (_watch) return;
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_watch, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WatchInterval * NSEC_PER_SEC)),
                              (uint64_t)(WatchInterval * NSEC_PER_SEC), 60 * NSEC_PER_SEC);
    __weak PocketBuilds *weakSelf = self;
    dispatch_source_set_event_handler(_watch, ^{
        PocketBuilds *builds = weakSelf;
        if (!builds || builds.state == BuildsChecking || builds.state == BuildsDownloading || builds.state == BuildsReady) return;
        dispatch_async(builds->_queue, ^{
            PocketSteamClient *client = PocketSteamOnlineSession();
            if (client) [builds checkAndStage:client announce:NO];
        });
    });
    dispatch_resume(_watch);
}

// The game's window came up: the build works, what older builds left goes, and the player hears
// what the check before the start found.
- (void)gameStarted {
    self.gameRunning = YES;
    dispatch_async(_queue, ^{
        [self.installed started];
        [self refreshInstalledLabel];
    });
    [self watch];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.state == BuildsUpToDate) [self notice:[NSString stringWithFormat:@"Brighter Shores is up to date: %@.", self.latestLabel]];
        else if (self.state == BuildsReady) [self notice:[NSString stringWithFormat:@"Update ready: %@. Close Brighter Pocket and open it again to install it.", self.latestLabel]];
        else if (self.state == BuildsDownloading) [self notice:[NSString stringWithFormat:@"Update available: %@. Downloading it now.", self.latestLabel]];
    });
}
@end

// --- before the game starts --------------------------------------------------------------------------
@interface PocketGameUpdate : NSObject
@property(nonatomic, nullable) PocketSteamClient *client;
@property(nonatomic) UIViewController *presenter;
@property(nonatomic, copy, nullable) dispatch_block_t done;
@property(nonatomic, nullable) PocketSignInViewController *screen;
@property(atomic) BOOL launched;   // the game went on without waiting for the check
@end

@implementation PocketGameUpdate
- (void)inBackground:(dispatch_block_t)block { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), block); }
- (void)onMain:(dispatch_block_t)block { dispatch_async(dispatch_get_main_queue(), block); }

// Main thread: the game on the device is the one to start.
- (void)finish {
    PocketSignInViewController *screen = self.screen;
    self.screen = nil;
    // At once, as the game holds the main thread next, which an animation's end waits for.
    [screen.presentingViewController dismissViewControllerAnimated:NO completion:nil];
    dispatch_block_t done = self.done;
    self.done = nil;
    if (done) done();
}

// Main thread: a question in the sign-in's sheet, presented over whatever is on screen.
- (void)ask:(NSString *)title message:(NSString *)message detail:(nullable NSString *)detail action:(NSString *)action
    handler:(dispatch_block_t)handler cancelTitle:(NSString *)cancelTitle {
    PocketSignInViewController *screen = self.screen;
    if (!screen) {
        __weak PocketGameUpdate *weakSelf = self;
        screen = [[PocketSignInViewController alloc] initWithCancelTitle:cancelTitle cancel:^{ [weakSelf finish]; }];
        self.screen = screen;
        UIViewController *top = self.presenter;
        while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
        [top presentViewController:screen animated:YES completion:nil];
    }
    [screen showProblem:title message:message detail:detail action:action handler:handler];
}

- (void)run {
    PocketBuilds *builds = PocketBuilds.shared;
    PocketInstalledGame *installed = builds.installed;
    [self inBackground:^{
        // A build put in place that failed to start: offer the one before.
        if ([installed updateFailedToStart]) {
            [self onMain:^{
                [self ask:@"Update Didn’t Start"
                  message:@"The latest version of Brighter Shores didn't start last time. Go back to the version you had before, or try it again."
                   detail:installed.label action:@"Go Back" handler:^{
                    [self.screen setBusy:YES];
                    [self inBackground:^{
                        BOOL back = [installed rollBack];
                        NSLog(@"[update] %@", back ? @"went back to the build before" : @"could not go back to the build before");
                        [builds refreshInstalledLabel];
                        [self onMain:^{ [self finish]; }];
                    }];
                } cancelTitle:@"Try Again"];
            }];
            return;
        }
        // A build downloaded while the game ran last time: in place now, before it starts.
        if (installed.staged) {
            Progress(@"Installing the update…", nil);
            NSError *error = nil;
            BOOL placed = [installed putStagedInPlace:&error];
            NSLog(@"[update] the downloaded build %@", placed ? @"is in place" : [NSString stringWithFormat:@"could not go in place: %@", error]);
            [builds refreshInstalledLabel];
        }
        if (!self.client) { [self onMain:^{ [self finish]; }]; return; }
        Progress(@"Checking for updates…", nil);
        // Steam slow to answer: the game starts as it is, and the check goes on behind it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LaunchCheckBudget * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.done && builds.state == BuildsChecking) {
                NSLog(@"[update] Steam is slow to answer; the game starts and the check goes on");
                self.launched = YES;
                builds.gameRunning = YES;
                [self finish];
            }
        });
        [self check];
    }];
}

// Background: Steam's build against the device's; a newer one fetched and put in place.
- (void)check {
    PocketBuilds *builds = PocketBuilds.shared;
    PocketDepot *depot = nil;
    PocketDepotRelease *release = [builds checkWith:self.client depot:&depot];
    __block BuildsState state = BuildsFailed;
    dispatch_sync(dispatch_get_main_queue(), ^{ state = builds.state; });
    // Usage counts (PocketAnalytics.h): what the check before the start came to. Steam not
    // answering counts as failed; a newer build is counted once it is in place, or not.
    if (!release) PocketAnalyticsEvent(@"app-game-update", @{@"result": @"failed"});
    else if (state == BuildsUpToDate) PocketAnalyticsEvent(@"app-game-update", @{@"result": @"none"});
    if (self.launched) {   // the game went on: what remains happens behind it
        if (release && state == BuildsAvailable) [builds checkAndStage:self.client announce:NO];
        return;
    }
    if (!release || state == BuildsUpToDate) {
        if (release) Progress([NSString stringWithFormat:@"Up to date: %@", builds.latestLabel], nil);
        [self onMain:^{ [self finish]; }];
        return;
    }
    NSLog(@"[update] fetching build %llu (manifest %llu) on %@", release.buildID, release.manifestID, release.branch);
    NSError *error = nil;
    BOOL ok = [builds stage:release depot:depot error:&error] && [builds.installed putStagedInPlace:&error];
    PocketAnalyticsEvent(@"app-game-update", @{@"result": ok ? @"ok" : @"failed"});
    if (ok) {
        NSLog(@"[update] build %llu is in place", release.buildID);
        [builds refreshInstalledLabel];
        [self onMain:^{ builds.state = BuildsUpToDate; [builds changed]; }];
        Progress([NSString stringWithFormat:@"Updated to %@", builds.latestLabel], @1);
        [self onMain:^{ [self finish]; }];
        return;
    }
    NSLog(@"[update] build %llu not fetched: %@ %ld %@", release.buildID, error.domain, (long)error.code, error.localizedDescription);
    NSString *message = FailureText(error), *detail = builds.latestLabel;
    [self onMain:^{
        [self ask:@"Couldn’t Update" message:message detail:detail action:@"Try Again" handler:^{
            [self inBackground:^{ [self check]; }];
        } cancelTitle:@"Play This Version"];
    }];
}
@end

void PocketGameUpdateBeforeLaunch(PocketSteamClient *client, UIViewController *presenter, dispatch_block_t done) {
    static PocketGameUpdate *running;
    if (running) return;
    running = [PocketGameUpdate new];
    running.client = client;
    running.presenter = presenter;
    running.done = ^{
        running = nil;
        done();
    };
    [running run];
}

void PocketBuildsSessionReady(void) {
    PocketBuilds *builds = PocketBuilds.shared;
    [builds watch];
    [builds checkNow];
}

// --- the Builds screen ----------------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, BuildsSection) { SectionDevice, SectionSteam, SectionActions, BuildsSectionCount };

@interface PocketBuildsScreen : UITableViewController
@end

@implementation PocketBuildsScreen
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Builds";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    [NSNotificationCenter.defaultCenter addObserver:self.tableView selector:@selector(reloadData) name:PocketBuildsDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self.tableView]; }
// As the sign-in's lists: edge to edge when a camera takes one side only.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    UIEdgeInsets safe = self.view.window.safeAreaInsets;
    BOOL oneSide = (safe.left > 0) != (safe.right > 0);
    self.tableView.insetsLayoutMarginsFromSafeArea = !oneSide;
    self.tableView.insetsContentViewsToSafeArea = !oneSide;
}

- (NSArray<NSString *> *)branches { return [NSUserDefaults.standardUserDefaults stringArrayForKey:PocketSteamBranchesKey]; }
- (BOOL)canDownload {
    BuildsState state = PocketBuilds.shared.state;
    return state == BuildsAvailable || (state == BuildsFailed && PocketBuilds.shared.latestLabel);
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)table { return BuildsSectionCount; }
- (NSInteger)tableView:(__unused UITableView *)table numberOfRowsInSection:(NSInteger)section {
    switch ((BuildsSection)section) {
        case SectionDevice: return self.branches.count > 1 ? 2 : 1;
        case SectionSteam: return 2;
        case SectionActions: return PocketBuilds.shared.state == BuildsDownloading ? 2 : [self canDownload] ? 2 : 1;
        default: return 0;
    }
}
- (NSString *)tableView:(__unused UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return @[@"This Device", @"Steam", @""][(NSUInteger)section];
}
- (NSString *)tableView:(__unused UITableView *)table titleForFooterInSection:(NSInteger)section {
    PocketBuilds *builds = PocketBuilds.shared;
    if (section == SectionSteam) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        if (builds.message) [lines addObject:builds.message];
        if (builds.checked) {
            NSRelativeDateTimeFormatter *relative = [NSRelativeDateTimeFormatter new];
            [lines addObject:[NSString stringWithFormat:@"Checked %@.", [relative localizedStringForDate:builds.checked relativeToDate:NSDate.date]]];
        }
        return lines.count ? [lines componentsJoinedByString:@" "] : nil;
    }
    if (section == SectionActions)
        return @"Brighter Pocket checks each time it opens and every 10 minutes while you play. An update downloads in the background "
               @"and installs the next time Brighter Pocket opens; the build before stays until the new one has started.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"row" forIndexPath:path];
    cell.insetsLayoutMarginsFromSafeArea = table.insetsLayoutMarginsFromSafeArea;   // edge to edge with the list
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityTraits = UIAccessibilityTraitNone;
    PocketBuilds *builds = PocketBuilds.shared;
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.prefersSideBySideTextAndSecondaryText = NO;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    switch ((BuildsSection)path.section) {
        case SectionDevice:
            if (path.row == 0) {
                content = [UIListContentConfiguration subtitleCellConfiguration];
                content.text = @"Installed";
                content.secondaryText = builds.installedLabel ?: (builds.installed.installed ? @"…" : @"Not on this device");
                content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            } else {
                content.text = @"Branch";
                cell.accessoryView = [self branchMenu];
            }
            break;
        case SectionSteam:
            content = [UIListContentConfiguration subtitleCellConfiguration];
            content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            if (path.row == 0) {
                content.text = @"Latest";
                content.secondaryText = builds.latestLabel ?: @"Not checked yet";
            } else {
                content.text = builds.stateText;
                NSString *symbol = @"questionmark.circle";
                UIColor *color = UIColor.secondaryLabelColor;
                switch (builds.state) {
                    case BuildsUpToDate: symbol = @"checkmark.circle.fill"; color = UIColor.systemGreenColor; break;
                    case BuildsAvailable: symbol = @"arrow.down.circle.fill"; color = UIColor.systemBlueColor; break;
                    case BuildsReady: symbol = @"arrow.clockwise.circle.fill"; color = UIColor.systemBlueColor; break;
                    case BuildsFailed: symbol = @"exclamationmark.triangle.fill"; color = UIColor.systemOrangeColor; break;
                    case BuildsChecking: case BuildsDownloading: {
                        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                        [spinner startAnimating];
                        cell.accessoryView = spinner;
                        symbol = builds.state == BuildsChecking ? @"magnifyingglass.circle" : @"arrow.down.circle";
                        break;
                    }
                    case BuildsUnchecked: break;
                }
                content.image = [UIImage systemImageNamed:symbol];
                content.imageProperties.tintColor = color;
                if (builds.state == BuildsDownloading && builds.total) {
                    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                    bar.progress = (float)builds.done / builds.total;
                    bar.frame = CGRectMake(0, 0, 120, 4);
                    cell.accessoryView = bar;
                }
            }
            break;
        case SectionActions: {
            content = [UIListContentConfiguration cellConfiguration];
            BOOL busy = builds.state == BuildsChecking || builds.state == BuildsDownloading;
            if (path.row == 0) content.text = @"Check for Updates";
            else content.text = builds.state == BuildsDownloading ? @"Stop Download" : @"Download Update";
            BOOL enabled = path.row == 1 || !busy;
            content.textProperties.color = enabled ? self.view.tintColor : UIColor.tertiaryLabelColor;
            cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
            cell.accessibilityTraits = UIAccessibilityTraitButton | (enabled ? 0 : UIAccessibilityTraitNotEnabled);
            break;
        }
        default: break;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (UIButton *)branchMenu {
    NSArray<NSString *> *branches = self.branches;
    NSString *chosen = Branch();
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSString *branch in branches) {
        UIAction *action = [UIAction actionWithTitle:[branch isEqualToString:@"public"] ? @"Release" : branch image:nil identifier:nil
                                             handler:^(__unused UIAction *taken) {
            if ([branch isEqualToString:@"public"]) [NSUserDefaults.standardUserDefaults removeObjectForKey:PocketSteamBranchKey];
            else [NSUserDefaults.standardUserDefaults setObject:branch forKey:PocketSteamBranchKey];
            NSLog(@"[update] branch %@ chosen", branch);
            [PocketBuilds.shared checkNow];
        }];
        action.state = [branch isEqualToString:chosen] ? UIMenuElementStateOn : UIMenuElementStateOff;
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

- (BOOL)tableView:(__unused UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    if (path.section != SectionActions) return NO;
    BuildsState state = PocketBuilds.shared.state;
    return path.row == 1 || (state != BuildsChecking && state != BuildsDownloading);
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section != SectionActions) return;
    PocketBuilds *builds = PocketBuilds.shared;
    if (path.row == 0) { [builds checkNow]; return; }
    if (builds.state == BuildsDownloading) { builds.cancel = YES; return; }
    [builds checkNow];   // a check fetches what it finds newer
}
@end

__attribute__((visibility("default"), used)) UIViewController *PocketBuildsViewController(void) { return [PocketBuildsScreen new]; }
__attribute__((visibility("default"), used)) NSString *PocketBuildsSummary(void) {
    PocketBuilds *builds = PocketBuilds.shared;
    if (builds.state == BuildsUnchecked || !builds.installedLabel) return builds.installedLabel ?: @"";
    return [NSString stringWithFormat:@"%@ · %@", builds.installedLabel, builds.stateText];
}
