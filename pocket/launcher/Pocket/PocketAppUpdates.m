// Brighter Pocket's own updates (PocketAppUpdates.h): the newest version, read from the appcast the companion
// reads, against the app's own; said in the in-game settings and once a version at the main menu.
#import "PocketAppUpdates.h"
#include <stdatomic.h>

NSString *const PocketAppUpdateDidChangeNotification = @"PocketAppUpdateDidChange";

static NSString *const AppcastURL = @"https://github.com/joenye/brighter-pocket/releases/latest/download/appcast.xml";
static NSString *const WhatsNewURL = @"https://brighteratlas.com/whats-new?for=pocket";
static NSString *const LatestKey = @"PocketAppLatestVersion", *const HeadlineKey = @"PocketAppLatestHeadline",
                *const CheckedKey = @"PocketAppLatestChecked", *const ToldKey = @"PocketAppUpdateTold";
static const NSTimeInterval CheckEvery = 6 * 3600, RequestTimeout = 20;

// This app's version (the simulator's run may name another, to see an update offered).
static NSString *CurrentVersion(void) {
#if TARGET_OS_SIMULATOR
    NSString *named = NSProcessInfo.processInfo.environment[@"POCKET_APP_VERSION"];
    if (named.length) return named;
#endif
    id version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : @"0";
}
// x.y.z, compared part by part as numbers.
static NSComparisonResult CompareVersions(NSString *a, NSString *b) {
    NSArray<NSString *> *left = [a componentsSeparatedByString:@"."], *right = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(left.count, right.count); i++) {
        NSInteger l = i < left.count ? left[i].integerValue : 0, r = i < right.count ? right[i].integerValue : 0;
        if (l != r) return l < r ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

__attribute__((visibility("default"), used)) NSString *PocketAppUpdateAvailable(NSString **headline) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *latest = [defaults stringForKey:LatestKey];
    if (!latest.length || CompareVersions(CurrentVersion(), latest) != NSOrderedAscending) return nil;
    if (headline) *headline = [defaults stringForKey:HeadlineKey];
    return latest;
}

// The appcast's newest item: its version and its headline (the first paragraph of its notes).
static NSString *FirstMatch(NSString *text, NSString *pattern) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || [match rangeAtIndex:1].location == NSNotFound) return nil;
    NSString *found = [[text substringWithRange:[match rangeAtIndex:1]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSArray<NSString *> *entity in @[@[@"&lt;", @"<"], @[@"&gt;", @">"], @[@"&quot;", @"\""], @[@"&#39;", @"'"], @[@"&amp;", @"&"]])
        found = [found stringByReplacingOccurrencesOfString:entity[0] withString:entity[1]];
    return found;
}

static __weak UIViewController *menuPresenter;   // main thread: the game's, once it is at its main menu
static void TellIfNew(void);
static void CheckNow(void);

void PocketAppUpdatesCheck(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Again as the app comes back to the front, when the last check is old.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                                                    usingBlock:^(__unused NSNotification *note) { PocketAppUpdatesCheck(); }];
    });
    NSDate *checked = [NSUserDefaults.standardUserDefaults objectForKey:CheckedKey];
    if ([checked isKindOfClass:NSDate.class] && -checked.timeIntervalSinceNow < CheckEvery) return;
    CheckNow();
}

static _Atomic bool checking;
static void Changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:PocketAppUpdateDidChangeNotification object:nil];
    });
}
// The appcast read now, whenever it was last; one check at a time. Says each change (checking, then the answer).
static void CheckNow(void) {
    if (atomic_exchange(&checking, true)) return;
    Changed();
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = RequestTimeout;
    configuration.timeoutIntervalForResource = RequestTimeout;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [[session dataTaskWithURL:[NSURL URLWithString:AppcastURL] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *text = !error && status == 200 && data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *version = text ? FirstMatch(text, @"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>") : nil;
        NSString *headline = text ? FirstMatch(text, @"<description><!\\[CDATA\\[\\s*<p>([^<]+)</p>") : nil;
        [session finishTasksAndInvalidate];
        if (!version.length) {
            NSLog(@"[app-update] could not read the latest version (%@ %ld)", error.domain ?: @"HTTP", (long)(error ? error.code : status));
            atomic_store(&checking, false);
            Changed();
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            [defaults setObject:version forKey:LatestKey];
            if (headline.length) [defaults setObject:headline forKey:HeadlineKey];
            else [defaults removeObjectForKey:HeadlineKey];
            [defaults setObject:[NSDate date] forKey:CheckedKey];
            NSString *now = PocketAppUpdateAvailable(NULL);
            NSLog(@"[app-update] latest %@, this %@: %@", version, CurrentVersion(), now ? @"an update is available" : @"up to date");
            atomic_store(&checking, false);
            [NSNotificationCenter.defaultCenter postNotificationName:PocketAppUpdateDidChangeNotification object:nil];
            TellIfNew();
        });
    }] resume];
}

// Once a version, at the main menu, over whatever is not already up (a sign-in sheet first: tried again).
static void TellIfNew(void) {
    NSString *latest = PocketAppUpdateAvailable(NULL);
    UIViewController *presenter = menuPresenter;
    if (!latest || !presenter || [[NSUserDefaults.standardUserDefaults stringForKey:ToldKey] isEqualToString:latest]) return;
    if (presenter.presentedViewController) {
        static int tries;
        if (++tries <= 40) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ TellIfNew(); });
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:latest forKey:ToldKey];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Brighter Pocket %@ Is Available", latest]
                         message:@"To update, open Brighter Pocket Companion on your Mac and choose Install Pocket."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"What's New" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:WhatsNewURL] options:@{} completionHandler:nil];
    }]];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:ok];
    alert.preferredAction = ok;
    NSLog(@"[app-update] telling of %@", latest);
    [presenter presentViewController:alert animated:YES completion:nil];
}

void PocketAppUpdatesGameReady(UIViewController *presenter) {
    menuPresenter = presenter;
    TellIfNew();
}

// The in-game settings' Brighter Pocket section (found with dlsym): the app's version, whether a check is under
// way, when the last one answered, and Check for Updates.
__attribute__((visibility("default"), used)) NSString *PocketAppVersion(void) { return CurrentVersion(); }
__attribute__((visibility("default"), used)) BOOL PocketAppUpdatesChecking(void) { return atomic_load(&checking); }
__attribute__((visibility("default"), used)) NSDate *PocketAppUpdatesLastChecked(void) {
    NSDate *checked = [NSUserDefaults.standardUserDefaults objectForKey:CheckedKey];
    return [checked isKindOfClass:NSDate.class] ? checked : nil;
}
__attribute__((visibility("default"), used)) void PocketAppUpdatesCheckNow(void) { CheckNow(); }
