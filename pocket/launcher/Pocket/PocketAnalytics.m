// Anonymous usage counts (PocketAnalytics.h): one JSON event to Umami Cloud's collector per count.
//
// The request is what Umami's own tracker script sends from a web page ({"type": "event",
// "payload": {...}}, POST /api/send), with the page fields a page would give filled in for the
// app: its hostname, a fixed title and path, the language and the screen. Umami turns away a
// request whose User-Agent reads as a bot, and reads the OS and the device from it, so the app
// sends one shaped as an iOS web view's (the real device family and iOS version), ending with
// its own name and version.
#import "PocketAnalytics.h"
#import "PocketGameUpdates.h"
#import <UIKit/UIKit.h>
#include <os/lock.h>

NSString *const PocketAnalyticsEnabledKey = @"PocketAnonymousUsageCounts";

static NSString *const CollectorURL = @"https://gateway.umami.is/api/send";
static NSString *const WebsiteID = @"ed0c3362-b0f0-4045-85ef-66e465141ddb";   // brighteratlas.com's website in Umami
static NSString *const Hostname = @"app.brighteratlas.com";
static const NSUInteger LongestValue = 40;   // a field's string longer than this is left out
static const NSTimeInterval RequestTimeout = 10;

__attribute__((visibility("default"), used)) BOOL PocketAnalyticsEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:PocketAnalyticsEnabledKey] ? [defaults boolForKey:PocketAnalyticsEnabledKey] : YES;
}
__attribute__((visibility("default"), used)) void PocketAnalyticsSetEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:PocketAnalyticsEnabledKey];
    NSLog(@"[analytics] anonymous usage counts %@", enabled ? @"on" : @"off");
}

// Whether this run may send at all, the player's choice aside: never from the simulator (runs
// on the Mac would count as players), with POCKET_NO_ANALYTICS=1, or under a test runner.
static BOOL RunMaySend(void) {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    static BOOL may;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        BOOL optedOut = [environment[@"POCKET_NO_ANALYTICS"] isEqualToString:@"1"];
        BOOL tested = environment[@"XCTestConfigurationFilePath"] != nil || environment[@"XCTestBundlePath"] != nil ||
                      NSClassFromString(@"XCTestCase") != nil;
        may = !optedOut && !tested;
    });
    return may;
#endif
}

// What every event carries: the page fields, the app's version and the device's family and iOS
// version, and the User-Agent. UIKit's answers, so made on the main thread, once (at launch);
// an event may come from any thread.
static os_unfair_lock contextLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *madeContext;
static NSDictionary *MakeContext(void) {
    UIDevice *device = UIDevice.currentDevice;
    NSString *family = device.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version isKindOfClass:NSString.class] || !version.length) version = @"unknown";
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *osVersion = os.patchVersion ? [NSString stringWithFormat:@"%ld_%ld_%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion]
                                          : [NSString stringWithFormat:@"%ld_%ld", (long)os.majorVersion, (long)os.minorVersion];
    // Safari's own words for the device: "iPhone OS" on an iPhone, "OS" on an iPad.
    NSString *agent = [NSString stringWithFormat:@"Mozilla/5.0 (%@; CPU %@ %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                                                 @"Mobile/15E148 BrighterPocket/%@",
                                                 family, [family isEqualToString:@"iPad"] ? @"OS" : @"iPhone OS", osVersion, version];
    // The screen as a web page reads it: in points, held upright (narrow side first).
    CGSize size = UIScreen.mainScreen.bounds.size;
    NSString *screen = [NSString stringWithFormat:@"%.0fx%.0f", MIN(size.width, size.height), MAX(size.width, size.height)];
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"en";
    return @{@"agent": agent, @"family": family, @"version": version, @"ios": @(os.majorVersion),
             @"page": @{@"website": WebsiteID, @"hostname": Hostname, @"language": language, @"screen": screen,
                        @"title": @"Brighter Pocket", @"url": @"/app"}};
}
static NSDictionary *Context(void) {
    os_unfair_lock_lock(&contextLock);
    NSDictionary *context = madeContext;
    os_unfair_lock_unlock(&contextLock);
    return context;
}
// Main thread.
static NSDictionary *MadeContext(void) {
    NSDictionary *context = Context();
    if (context) return context;
    context = MakeContext();
    os_unfair_lock_lock(&contextLock);
    madeContext = context;
    os_unfair_lock_unlock(&contextLock);
    return context;
}

// Short strings, numbers and Booleans only; anything else is left out, so no caller can send
// more than a word by mistake.
static NSDictionary *Clean(NSDictionary<NSString *, id> *data) {
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    [data enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, __unused BOOL *stop) {
        if (![key isKindOfClass:NSString.class] || key.length > LongestValue) return;
        if ([value isKindOfClass:NSString.class] && [value length] <= LongestValue) clean[key] = value;
        else if ([value isKindOfClass:NSNumber.class]) clean[key] = value;
    }];
    return clean;
}

static NSURLSession *Session(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Ephemeral: no cookies, no cache, nothing kept on the device between events.
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCache = nil;
        configuration.URLCredentialStorage = nil;
        configuration.timeoutIntervalForRequest = RequestTimeout;
        configuration.timeoutIntervalForResource = RequestTimeout;
        configuration.waitsForConnectivity = NO;   // offline: the count is dropped, not queued
        configuration.HTTPMaximumConnectionsPerHost = 1;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static void Send(NSDictionary *context, NSString *name, NSDictionary *data) {
    NSMutableDictionary *payload = [context[@"page"] mutableCopy];
    payload[@"name"] = name;
    if (data.count) payload[@"data"] = data;
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"type": @"event", @"payload": payload} options:0 error:NULL];
    if (!body) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:CollectorURL]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:context[@"agent"] forHTTPHeaderField:@"User-Agent"];
    // The answer does not matter: a failure is the count lost, never the app's problem.
    [[Session() dataTaskWithRequest:request completionHandler:^(__unused NSData *answer, __unused NSURLResponse *response, __unused NSError *error) {}] resume];
}

void PocketAnalyticsEvent(NSString *name, NSDictionary<NSString *, id> *data) {
    if (!name.length || !PocketAnalyticsEnabled()) return;
    if (!RunMaySend()) {
        NSLog(@"[analytics] %@ (not sent from this run)", name);
        return;
    }
    NSDictionary *clean = Clean(data ?: @{}), *context = Context();
    if (context) { Send(context, name, clean); return; }
    // Before launch has made the context (it needs UIKit's main thread): made there first.
    dispatch_async(dispatch_get_main_queue(), ^{ Send(MadeContext(), name, clean); });
}

// The counts that are no one caller's: the app opening (once a launch) and the game's window
// coming up (the in-game settings post PocketGameStartedNotification as it does).
@interface PocketAnalyticsCounts : NSObject
@end
@implementation PocketAnalyticsCounts
+ (void)load {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        NSDictionary *context = MadeContext();
        PocketAnalyticsEvent(@"app-open", @{@"version": context[@"version"], @"device": context[@"family"], @"ios": context[@"ios"]});
    }];
    [center addObserverForName:PocketGameStartedNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        static BOOL counted;   // once a run, however often the window comes up
        if (counted) return;
        counted = YES;
        PocketAnalyticsEvent(@"app-game-start", nil);
    }];
}
@end
