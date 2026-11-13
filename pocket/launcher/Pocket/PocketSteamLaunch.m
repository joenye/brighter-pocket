// Signing in to Steam on the device, and lending the session to the game.
//
// The account's password goes to Steam's authentication service only (RSA-encrypted with the
// key Steam hands out for the account, as the Steam client sends it); Steam Guard is answered
// with a code or by approving the sign-in in the Steam Mobile app. What is kept is Steam's
// refresh token, in this device's keychain, and with it each launch logs on without asking.
// At launch the session gets Brighter Shores' ownership ticket and tells Steam the game is
// running; the game's Steam library then gets the account and its tickets from it.
#import "PocketSteamLaunch.h"
#import "PocketSteamClient.h"
#import "PocketGameUpdates.h"
#import "PocketSignInViewController.h"
#import <Security/Security.h>
#include "../../translation/libsteam_api/PocketSteamBridge.h"
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>

static const uint32_t BrighterShoresAppID = 2791440;
static NSString *const SteamProfile = @"brighter-shores";
static NSString *const DeviceName = @"Brighter Pocket";
static const NSTimeInterval ApprovalTimeout = 300;

typedef NS_ENUM(uint64_t, GuardType) {   // EAuthSessionGuardType
    GuardNone = 1,
    GuardEmailCode = 2,
    GuardDeviceCode = 3,
    GuardDeviceConfirmation = 4,
    GuardEmailConfirmation = 5,
    GuardMachineToken = 6,   // this device's earlier sign-in (guardData) stands for the code
};
typedef NS_ENUM(NSInteger, SteamResult) {   // the EResults the sign-in tells apart
    ResultInvalidPassword = 5,
    ResultAccessDenied = 15,
    ResultRevoked = 26,
    ResultExpired = 27,
    ResultInvalidLoginAuthCode = 65,
    ResultRateLimitExceeded = 84,
    ResultTwoFactorCodeMismatch = 88,
};

// --- the session lent to the game -------------------------------------------------------------
// The account stays lent for the whole run once signed in. Its connection may drop or die
// quietly (iOS closes the app's sockets while it is in the background, and a network change
// strands them): a ping every KeepaliveInterval, and one as the app comes back, finds that out,
// and the connection is made again with the kept login, before the game next asks for a ticket.
// A ticket Steam does not acknowledge counts as such a drop too.
static const NSTimeInterval KeepaliveInterval = 30, KeepaliveWait = 5;
static os_unfair_lock sessionLock = OS_UNFAIR_LOCK_INIT;
static PocketSteamClient *gameSession;
static uint64_t lentSteamID;
static NSString *lentPersona;
static NSDictionary *lentLogin;   // the login the lent session signed in with: its reconnects use it
static BOOL launchSettled;   // main thread: signed in, or chose to play offline, this run
static NSString *menuProblem;   // main thread: why the sign-in offered at the main menu asks (an expired login)
static NSDictionary *LoadLogin(void);
static NSDictionary *SimulatorLogin(void);

static PocketSteamClient *CurrentSession(void) {
    os_unfair_lock_lock(&sessionLock);
    PocketSteamClient *client = gameSession;
    os_unfair_lock_unlock(&sessionLock);
    return client;
}

// --- what the player sees of it (the in-game settings show it; PocketSteamLaunch.h) -----------
NSString *const PocketSteamStatusDidChangeNotification = @"PocketSteamStatusDidChange";
static os_unfair_lock statusLock = OS_UNFAIR_LOCK_INIT;
static PocketSteamState sessionState = PocketSteamStateOff;
static NSString *sessionText = @"Not signed in to Steam.";

static NSString *ResultReason(int result) {
    switch (result) {
    case 6: return @"the account signed in on another device";   // LoggedInElsewhere
    case 34: return @"another sign-in of the account replaced this one";   // LogonSessionReplaced
    case 48: return @"Steam is down for maintenance";   // TryAnotherCM
    default: return [NSString stringWithFormat:@"Steam ended the session (error %d)", result];
    }
}
static void SetState(PocketSteamState state, NSString *text) {
    os_unfair_lock_lock(&statusLock);
    BOOL changed = state != sessionState || ![text isEqualToString:sessionText];
    sessionState = state;
    sessionText = [text copy];
    os_unfair_lock_unlock(&statusLock);
    if (!changed) return;
    NSLog(@"[steam] status: %@", text);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:PocketSteamStatusDidChangeNotification object:nil];
    });
}
// Signed in: who, and whether Brighter Shores (or another game) runs on another of the
// account's sessions, which the game's servers may refuse or end.
static void SetSignedIn(PocketSteamClient *client) {
    NSString *persona = client.personaName.length ? client.personaName : @"your account";
    uint32_t app = 0;
    if ([client playingElsewhere:&app])
        SetState(PocketSteamStateWarning, [NSString stringWithFormat:@"Signed in to Steam as %@, but %@ is running on another device.",
                                           persona, app == BrighterShoresAppID ? @"Brighter Shores" : @"a game"]);
    else
        SetState(PocketSteamStateSignedIn, [NSString stringWithFormat:@"Signed in to Steam as %@.", persona]);
}

__attribute__((visibility("default"), used)) PocketSteamState PocketSteamCurrentState(NSString **text) {
    os_unfair_lock_lock(&statusLock);
    PocketSteamState state = sessionState;
    if (text) *text = sessionText;
    os_unfair_lock_unlock(&statusLock);
    return state;
}

// Steam said no to the kept login itself (not to the connection): signing in again is the way on.
static BOOL LoginRefused(NSError *error) {
    NSSet *rejected = [NSSet setWithArray:@[@(ResultInvalidPassword), @(ResultAccessDenied), @(ResultRevoked), @(ResultExpired)]];
    return [error.domain isEqualToString:PocketSteamErrorDomain] && [rejected containsObject:@(error.code)];
}

// The lent session, signed in again first if its connection dropped; nil if it cannot be. A
// kept login Steam refuses is not tried again: the player signs in again (the settings offer it).
static PocketSteamClient *OnlineSession(void) {
    static NSLock *reconnecting;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ reconnecting = [NSLock new]; });
    [reconnecting lock];
    PocketSteamClient *client = CurrentSession();
    if (client && !client.online && PocketSteamCurrentState(NULL) != PocketSteamStateSignInNeeded) {
        int ended = client.loggedOffResult;
        SetState(PocketSteamStateConnecting, ended ? [NSString stringWithFormat:@"Signing in to Steam again: %@.", ResultReason(ended)]
                                                   : @"Reconnecting to Steam…");
        os_unfair_lock_lock(&sessionLock);
        NSDictionary *login = lentLogin;
        os_unfair_lock_unlock(&sessionLock);
        PocketSteamClient *fresh = login ? [PocketSteamClient new] : nil;
        NSError *error = nil;
        if (fresh && [fresh connect:&error] &&
            [fresh logOnAccount:login[@"account"] refreshToken:login[@"refreshToken"] error:&error] &&
            [fresh startGame:BrighterShoresAppID error:&error]) {
            // Only if nothing replaced the session meanwhile (a sign-in again from the settings).
            os_unfair_lock_lock(&sessionLock);
            BOOL current = gameSession == client, first = !lentSteamID;
            if (current) { gameSession = fresh; lentSteamID = fresh.steamID; lentPersona = fresh.personaName; }
            PocketSteamClient *lent = gameSession;
            os_unfair_lock_unlock(&sessionLock);
            [client disconnect];
            if (!current) [fresh disconnect];
            client = lent;
            NSLog(@"[steam] %@", first ? @"signed in with the kept login, Steam reachable again" : @"the session's connection dropped; signed in again");
            SetSignedIn(client);
            if (first && current) dispatch_async(dispatch_get_main_queue(), ^{ PocketBuildsSessionReady(); });
        } else {
            NSLog(@"[steam] the session's connection dropped and could not be made again (%@ %ld)",
                  error.domain ?: @"no kept login", (long)error.code);
            [fresh disconnect];
            BOOL refused = !login || LoginRefused(error);
            if (refused) SetState(PocketSteamStateSignInNeeded, @"Steam needs you to sign in again. Open Settings and choose Sign In to Steam.");
            else SetState(PocketSteamStateUnreachable, @"Can't reach Steam right now. Brighter Pocket keeps trying; check the connection.");
        }
    }
    [reconnecting unlock];
    return client.online ? client : nil;
}

PocketSteamClient *PocketSteamOnlineSession(void) { return OnlineSession(); }

// Every KeepaliveInterval, and as the app comes back to the front: is the lent session still
// answering? If not, it is made again now, not when the player next signs in to the game.
static void CheckSession(void) {
    static _Atomic bool checking;
    if (atomic_exchange(&checking, true)) return;
    PocketSteamClient *client = CurrentSession();
    if (client) {
        if ([client checkAlive:KeepaliveWait]) SetSignedIn(client);
        else OnlineSession();
    }
    atomic_store(&checking, false);
}
static void KeepSessionAlive(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KeepaliveInterval * NSEC_PER_SEC)),
                                  (uint64_t)(KeepaliveInterval * NSEC_PER_SEC), NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ CheckSession(); });
        dispatch_resume(timer);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                                                    usingBlock:^(__unused NSNotification *note) { dispatch_async(queue, ^{ CheckSession(); }); }];
    });
}
static int BridgeAccount(uint64_t *steamID, char *name, size_t size) {
    os_unfair_lock_lock(&sessionLock);
    uint64_t account = gameSession ? lentSteamID : 0;
    NSString *persona = lentPersona;
    os_unfair_lock_unlock(&sessionLock);
    if (!account) return 0;
    if (steamID) *steamID = account;
    if (name && size) strlcpy(name, persona.UTF8String ?: "", size);
    return 1;
}
static void BridgeWebTicket(const char *identity, PocketSteamTicketDone done, void *context) {
    NSString *service = @(identity ?: "");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Twice at most: a ticket Steam does not acknowledge means the connection had died, and
        // OnlineSession makes it again for the second.
        uint32_t crc = 0;
        NSData *ticket = nil;
        for (int attempt = 0; attempt < 2 && !ticket; attempt++) ticket = [OnlineSession() webTicketForIdentity:service crc:&crc];
        NSLog(@"[steam] web API ticket for \"%@\": %@", service, ticket ? @"made and registered with Steam" : @"none (no session)");
        done(context, ticket ? 1 : 3, ticket.bytes, (uint32_t)ticket.length, crc);   // OK, or NoConnection
    });
}
static void BridgeCancelTicket(uint32_t crc) {
    PocketSteamClient *client = CurrentSession();
    if (client.online) [client cancelTicket:crc];
}

__attribute__((visibility("default"), used)) const PocketSteamBridge *PocketSteamBridgeGet(void) {
    static const PocketSteamBridge bridge = {POCKET_STEAM_BRIDGE_VERSION, BridgeAccount, BridgeWebTicket, BridgeCancelTicket};
    return &bridge;
}

// --- the remembered login (keychain) --------------------------------------------------------------
static NSDictionary *LoginQuery(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"brighter-pocket.steam", (__bridge id)kSecAttrAccount: @"login"};
}
static NSDictionary *LoadLogin(void) {
    NSMutableDictionary *query = [LoginQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
    NSData *data = CFBridgingRelease(result);
    NSDictionary *login = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [login isKindOfClass:NSDictionary.class] && [login[@"account"] isKindOfClass:NSString.class] &&
           [login[@"refreshToken"] isKindOfClass:NSString.class] ? login : nil;
}
// In the iOS Simulator, tools/run_simulator.py may name the login in the app's environment
// (POCKET_STEAM_ACCOUNT and POCKET_STEAM_REFRESH_TOKEN, a token Steam issued for the account),
// so a run on the Mac signs in without the sign-in screens. It is used for this run only, never
// kept, and dropped with the kept login (ForgetLogin) when Steam rejects it or the player signs
// out; a device build has no such route.
static _Atomic bool simulatorLoginForgotten;
static NSDictionary *SimulatorLogin(void) {
#if TARGET_OS_SIMULATOR
    static dispatch_once_t once;
    static NSDictionary *login;
    dispatch_once(&once, ^{
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *account = environment[@"POCKET_STEAM_ACCOUNT"], *token = environment[@"POCKET_STEAM_REFRESH_TOKEN"];
        if (account.length && token.length) {
            login = @{@"account": account, @"refreshToken": token};
            NSLog(@"[steam] simulator: signing in with the login named in the environment");
        }
    });
    return simulatorLoginForgotten ? nil : login;
#else
    return nil;
#endif
}
static void SaveLogin(NSDictionary *login) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:login options:0 error:nil];
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data,
                                 (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)LoginQuery(), (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *add = [LoginQuery() mutableCopy];
        [add addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    if (status != errSecSuccess) NSLog(@"[steam] the login could not be kept in the keychain (%d)", (int)status);
}
static void ForgetLogin(void) {
    SecItemDelete((__bridge CFDictionaryRef)LoginQuery());
    simulatorLoginForgotten = true;
}

// --- the authentication service's messages --------------------------------------------------------
static NSData *ProtoData(PocketProto *proto) {
    NSData *data = proto->failed ? nil : [NSData dataWithBytes:proto->data length:proto->size];
    pocket_proto_free(proto);
    return data;
}
static BOOL ProtoField(NSData *message, unsigned number, PocketField *field) {
    return message && pocket_proto_find(message.bytes, message.length, number, field);
}
static NSString *ProtoString(NSData *message, unsigned number) {
    PocketField field;
    if (!ProtoField(message, number, &field) || field.wire != 2) return nil;
    return [[NSString alloc] initWithBytes:field.data length:field.size encoding:NSUTF8StringEncoding];
}
static uint64_t ProtoNumber(NSData *message, unsigned number) {
    PocketField field;
    return ProtoField(message, number, &field) && field.wire != 2 ? field.value : 0;
}

// A refresh token lasts months, not for ever: on each sign-in Steam is asked for a fresh one, as
// the Steam client asks (Authentication.GenerateAccessTokenForApp with renewal allowed); it
// replaces the kept one when Steam gives one, so a kept login does not go stale unseen. The
// environment's login (the simulator) is never kept.
static void RenewKeptLogin(PocketSteamClient *client) {
    os_unfair_lock_lock(&sessionLock);
    NSDictionary *login = gameSession == client ? lentLogin : nil;
    os_unfair_lock_unlock(&sessionLock);
    if (!login || login == SimulatorLogin() || !client.steamID) return;
    PocketProto request = {0};
    pocket_proto_string(&request, 1, [login[@"refreshToken"] UTF8String]);
    pocket_proto_fixed64(&request, 2, client.steamID);
    pocket_proto_uint(&request, 3, 1);   // renewal_type: allow
    NSError *error = nil;
    NSData *reply = [client call:@"Authentication.GenerateAccessTokenForApp#1" body:ProtoData(&request) error:&error];
    NSString *renewed = ProtoString(reply, 2);
    if (renewed.length && ![renewed isEqualToString:login[@"refreshToken"]]) {
        NSMutableDictionary *kept = [login mutableCopy];
        kept[@"refreshToken"] = renewed;
        SaveLogin(kept);
        os_unfair_lock_lock(&sessionLock);
        if (lentLogin == login) lentLogin = [kept copy];
        os_unfair_lock_unlock(&sessionLock);
        NSLog(@"[steam] the kept login was renewed");
    } else if (!reply) {
        NSLog(@"[steam] the kept login was not renewed (%@ %ld)", error.domain, (long)error.code);
    }
}

// The password, encrypted with the account's RSA key as the Steam client encrypts it (PKCS #1 v1.5).
static NSData *HexData(NSString *hex) {
    if (hex.length % 2) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:hex.length / 2];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned value;
        if (sscanf([hex substringWithRange:NSMakeRange(i * 2, 2)].UTF8String, "%2x", &value) != 1) return nil;
        bytes[i] = (uint8_t)value;
    }
    return data;
}
static NSData *DER(uint8_t tag, NSData *content) {
    NSMutableData *der = [NSMutableData dataWithBytes:&tag length:1];
    NSUInteger length = content.length;
    if (length < 128) {
        uint8_t small = (uint8_t)length;
        [der appendBytes:&small length:1];
    } else {
        uint8_t bytes[sizeof(NSUInteger)], count = 0;
        for (NSUInteger rest = length; rest; rest >>= 8) bytes[count++] = (uint8_t)rest;
        uint8_t prefix = 0x80 | count;
        [der appendBytes:&prefix length:1];
        for (int i = count - 1; i >= 0; i--) [der appendBytes:&bytes[i] length:1];
    }
    [der appendData:content];
    return der;
}
static NSData *DERInteger(NSData *magnitude) {
    NSMutableData *value = [NSMutableData data];
    if (magnitude.length && ((const uint8_t *)magnitude.bytes)[0] & 0x80) [value appendBytes:"\0" length:1];
    [value appendData:magnitude];
    return DER(0x02, value);
}
// Steam's own sign-in fields take at most 64 characters, so a longer password (a password
// manager's) is set and checked as its first 64: Steam refuses the whole of it as a wrong
// password (EResult 5; Joe's 100-character password, 2026-11-13). Cut at a whole character.
static const NSUInteger SteamPasswordLength = 64;
static NSString *SteamPassword(NSString *password) {
    if (password.length <= SteamPasswordLength) return password;
    // (the last character that fits, whole: one that crosses the 64th place is left out)
    NSRange last = [password rangeOfComposedCharacterSequenceAtIndex:SteamPasswordLength - 1];
    return [password substringToIndex:NSMaxRange(last) > SteamPasswordLength ? last.location : SteamPasswordLength];
}
static NSString *EncryptedPassword(NSString *password, NSString *modulusHex, NSString *exponentHex) {
    NSData *modulus = HexData(modulusHex), *exponent = HexData(exponentHex);
    if (!modulus.length || !exponent.length) return nil;
    NSMutableData *pair = [DERInteger(modulus) mutableCopy];
    [pair appendData:DERInteger(exponent)];
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
                                 (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic};
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)DER(0x30, pair), (__bridge CFDictionaryRef)attributes, NULL);
    if (!key) return nil;
    NSData *encrypted = CFBridgingRelease(SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionPKCS1,
        (__bridge CFDataRef)[password dataUsingEncoding:NSUTF8StringEncoding], NULL));
    CFRelease(key);
    return [encrypted base64EncodedStringWithOptions:0];
}

// --- the launch -------------------------------------------------------------------------------------
@interface PocketSteamLaunch : NSObject
@property(nonatomic, strong) UIViewController *presenter;
@property(nonatomic, strong, nullable) UILabel *status;
@property(nonatomic, copy) dispatch_block_t resume;
// "Not Now" before the game (the menus without Steam) and for a sign-in again while it runs.
@property(nonatomic, copy) NSString *cancelTitle;
// The login this sign-in uses: kept (in the keychain) once its session is lent, not before.
@property(nonatomic, copy, nullable) NSDictionary *login;
// A sign-in again from the settings asks for the account first, rather than reusing the kept login.
@property(nonatomic) BOOL askFirst;
@property(nonatomic) BOOL playHere;   // the player chose to play here while the account plays elsewhere
@property(nonatomic, strong, nullable) PocketSignInViewController *screen;   // the sign-in's sheet, while it is up
@property(nonatomic, strong, nullable) PocketSteamClient *client;
// The sign-in under way (Authentication.BeginAuthSessionViaCredentials's answer).
@property(nonatomic, copy, nullable) NSString *account;
@property(nonatomic, copy, nullable) NSString *guardData;
// The account guardData was Steam's for: sent only with that account, never another's (a sign-in
// with another account after one Steam refused would carry it, and Steam turned it down as a
// wrong password).
@property(nonatomic, copy, nullable) NSString *guardAccount;
@property(nonatomic) uint64_t clientID, steamID;
@property(nonatomic, copy, nullable) NSData *requestID;
@property(nonatomic) NSTimeInterval interval;
@property(atomic) BOOL polling, finished;
@property(atomic) NSUInteger attempt;   // which sign-in a poll belongs to
@end

@implementation PocketSteamLaunch

- (void)onMain:(dispatch_block_t)block { dispatch_async(dispatch_get_main_queue(), block); }
- (void)inBackground:(dispatch_block_t)block { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), block); }
- (void)say:(NSString *)text { if (self.status) self.status.text = text; }

// The sign-in's sheet, presented over whatever the launcher has on screen (the presenter may
// itself be presenting) the first time a step is shown; each step then changes it in place.
- (PocketSignInViewController *)shown {
    if (self.screen) return self.screen;
    __weak PocketSteamLaunch *weakSelf = self;
    PocketSignInViewController *screen = [[PocketSignInViewController alloc] initWithCancelTitle:self.cancelTitle cancel:^{
        [weakSelf finishWithClient:nil];
    }];
    self.screen = screen;
    UIViewController *top = self.presenter;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    [top presentViewController:screen animated:YES completion:nil];
    return screen;
}
- (void)dismissScreen {
    PocketSignInViewController *screen = self.screen;
    self.screen = nil;
    // Before the game (the launcher's status shows): at once, as the game holds the main thread
    // next, which an animation's end waits for. Over the game: animated.
    if (screen.presentingViewController) [screen dismissViewControllerAnimated:self.status == nil completion:nil];
}
// An error's code, small, for support.
static NSString *ErrorDetail(NSError *error) {
    if ([error.domain isEqualToString:PocketSteamErrorDomain])
        return [NSString stringWithFormat:error.code >= PocketSteamErrorNoServer ? @"Code for support: PocketSteam %ld" : @"Code for support: Steam error %ld",
                                          (long)error.code];
    return error ? [NSString stringWithFormat:@"Code for support: %@ %ld", error.domain, (long)error.code] : nil;
}

- (void)start {
    [self.client disconnect];
    self.client = nil;
    if (self.askFirst) {
        self.askFirst = NO;
        self.account = LoadLogin()[@"account"];
        NSString *problem = menuProblem;
        menuProblem = nil;
        [self askForCredentials:problem];
        return;
    }
#if TARGET_OS_SIMULATOR
    // tools/run_simulator.py --offline: straight into the game, as Not Now would.
    if (self.resume && NSProcessInfo.processInfo.environment[@"POCKET_STEAM_OFFLINE"].length) {
        [self startOffline:nil];
        return;
    }
#endif
    NSDictionary *login = self.login ?: SimulatorLogin() ?: LoadLogin();
    // Before the game, with nothing to sign in with: the game first, the sign-in at its main menu.
    if (!login && self.resume) { [self startOffline:nil]; return; }
    SetState(PocketSteamStateConnecting, @"Signing in to Steam…");
    if (login) [self logOnWithLogin:login];
    else [self askForCredentials:nil];
}

// Before the game: it starts offline now (a build downloaded earlier still goes in place first),
// and the sign-in is offered at its main menu, with problem saying why if there is one.
- (void)startOffline:(nullable NSString *)problem {
    menuProblem = problem;
    SetState(problem ? PocketSteamStateSignInNeeded : PocketSteamStateOff,
             problem ? @"Steam needs you to sign in again. Open Settings and choose Sign In to Steam." : @"Not signed in to Steam.");
    NSLog(@"[steam] starting the game offline; the sign-in is offered at its main menu");
    PocketGameUpdateBeforeLaunch(nil, self.presenter, ^{ [self finishWithClient:nil]; });
}

// Before the game, Steam out of reach with a kept login: the game starts offline now, and the
// keepalive signs in with the login as soon as Steam answers (OnlineSession), the account then
// lent to the game as it plays.
- (void)startKeepingLogin:(NSDictionary *)login client:(PocketSteamClient *)client {
    [client disconnect];
    os_unfair_lock_lock(&sessionLock);
    gameSession = client;
    lentSteamID = 0;
    lentPersona = nil;
    lentLogin = login;
    os_unfair_lock_unlock(&sessionLock);
    SetState(PocketSteamStateUnreachable, @"Can't reach Steam right now. Brighter Pocket keeps trying; check the connection.");
    KeepSessionAlive();
    NSLog(@"[steam] Steam out of reach; the game starts offline and the kept login is tried again");
    PocketGameUpdateBeforeLaunch(nil, self.presenter, ^{
        launchSettled = YES;
        self.finished = YES;
        dispatch_block_t resume = self.resume;
        if (resume) [NSTimer scheduledTimerWithTimeInterval:0 repeats:NO block:^(__unused NSTimer *timer) { resume(); }];
    });
}

- (void)finishWithClient:(nullable PocketSteamClient *)client {
    self.finished = YES;
    [self dismissScreen];
    if (client) {
        uint64_t steamID = client.steamID;
        NSString *persona = client.personaName;
        NSDictionary *login = self.login;
        if (login && login != SimulatorLogin()) SaveLogin(login);   // kept only now it works
        os_unfair_lock_lock(&sessionLock);
        PocketSteamClient *previous = gameSession == client ? nil : gameSession;
        gameSession = client;
        lentSteamID = steamID;
        lentPersona = persona;
        lentLogin = login;
        os_unfair_lock_unlock(&sessionLock);
        [previous disconnect];   // a sign-in again from the game's settings replaces the session
        NSLog(@"[steam] signed in; the game's session is ready");
        SetSignedIn(client);
        KeepSessionAlive();
        if (!self.resume) PocketBuildsSessionReady();   // while the game runs; before it, the launch checked
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RenewKeptLogin(client); });
    } else {
        [self.client disconnect];
        PocketSteamClient *current = CurrentSession();
        NSLog(@"[steam] %@", current ? @"the sign-in again was left; the session stays as it was" : @"playing offline");
        if (!current && PocketSteamCurrentState(NULL) != PocketSteamStateSignInNeeded) SetState(PocketSteamStateOff, @"Playing offline: not signed in to Steam.");
        else dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ CheckSession(); });
    }
    launchSettled = YES;
    // Back to the launcher from a run-loop timer callout, never from a main-queue block (this
    // runs in one): the launcher enters the game there, and Developer service's memory
    // preparation waits on the main thread for replies the main queue delivers, which a
    // main-queue block would hold back for good (the platform's launcher enters guest code
    // from timer callouts for the same reason). A sign-in again from the game has no resume.
    dispatch_block_t resume = self.resume;
    if (resume) [NSTimer scheduledTimerWithTimeInterval:0 repeats:NO block:^(__unused NSTimer *timer) { resume(); }];
}

- (void)offerRetry:(NSError *)error {
    BOOL ours = [error.domain isEqualToString:PocketSteamErrorDomain];
    NSString *message = ours && error.code == PocketSteamErrorTimedOut
        ? @"Steam took too long to answer. Check that this device is online (Wi-Fi or mobile data), then try again."
        : ours && error.code == PocketSteamErrorMalformed
        ? @"Steam sent an answer Brighter Pocket couldn't read. Wait a moment, then try again."
        : ours && error.code < PocketSteamErrorNoServer
        ? @"Steam couldn't finish the sign-in just now. Wait a moment, then try again."
        : @"Brighter Pocket couldn't connect to Steam. Check that this device is online (Wi-Fi or mobile data), then try again.";
    [[self shown] showProblem:@"Can’t Reach Steam" message:message detail:ErrorDetail(error) action:@"Try Again" handler:^{ [self start]; }];
}

// The remembered login: log on, then start the game's session. A login Steam no longer
// accepts is forgotten and the player asked again.
- (void)logOnWithLogin:(NSDictionary *)login {
    [self say:@"Signing in to Steam…"];
    self.account = login[@"account"];
    self.login = login;
    // Over the game (no status line): the sheet at once, so the tap shows that it works.
    if (!self.status) [[self shown] showWaiting:@"Steam" text:@"Signing in with your kept sign-in…"];
    [self inBackground:^{
        PocketSteamClient *client = [PocketSteamClient new];
        NSError *error = nil;
        BOOL online = [client connect:&error] && [client logOnAccount:login[@"account"] refreshToken:login[@"refreshToken"] error:&error];
        [self onMain:^{
            self.client = client;
            if (online) { [self startGameSession]; return; }
            if (LoginRefused(error)) {
                ForgetLogin();
                self.login = nil;
                self.guardData = login[@"guardData"];
                self.guardAccount = login[@"account"];
                NSString *expired = @"Your Steam sign-in has expired. Sign in again to keep playing online.";
                if (self.resume) [self startOffline:expired];
                else [self askForCredentials:expired];
            } else if (self.resume) {
                [self startKeepingLogin:login client:client];
            } else {
                [self offerRetry:error];
            }
        }];
    }];
}

- (void)startGameSession {
    PocketSteamClient *client = self.client;
    // Another device plays on this account: starting here ends that game there, so ask first.
    uint32_t elsewhere = 0;
    if (!self.playHere && [client playingElsewhere:&elsewhere]) {
        [self say:@"Waiting for you: the account is playing on another device…"];
        NSString *what = elsewhere == BrighterShoresAppID ? @"Brighter Shores" : @"A game";
        [[self shown] showProblem:@"Playing Elsewhere"
                          message:[NSString stringWithFormat:@"%@ is running on another device signed in to this Steam account. "
                                                             @"Playing here closes it there.", what]
                           detail:nil action:@"Play Here" handler:^{
            self.playHere = YES;
            [self startGameSession];
        }];
        return;
    }
    [self say:@"Checking your Steam account…"];
    [self inBackground:^{
        NSError *error = nil;
        BOOL started = [client startGame:BrighterShoresAppID error:&error];
        [self onMain:^{
            if (started && self.resume) {
                // Before the game starts: bring it to Steam's build first.
                [self dismissScreen];
                PocketGameUpdateBeforeLaunch(client, self.presenter, ^{ [self finishWithClient:client]; });
                return;
            }
            if (started) { [self finishWithClient:client]; return; }
            if (![error.domain isEqualToString:PocketSteamErrorDomain] || error.code >= PocketSteamErrorNoServer) {
                [self offerRetry:error];
                return;
            }
            NSString *who = client.personaName.length ? client.personaName : @"This Steam account";
            [[self shown] showProblem:@"Not on This Account"
                              message:[NSString stringWithFormat:@"%@ doesn't own Brighter Shores. Sign in with the Steam account that has "
                                                                 @"the game, or play offline.", who]
                               detail:ErrorDetail(error) action:@"Use Another Account" handler:^{
                [client disconnect];
                ForgetLogin();
                [self askForCredentials:nil];
            }];
        }];
    }];
}

- (void)askForCredentials:(nullable NSString *)problem { [self askForCredentials:problem detail:nil]; }
- (void)askForCredentials:(nullable NSString *)problem detail:(nullable NSString *)detail {
    [self say:@"Waiting for you to sign in to Steam…"];
    [[self shown] askForAccount:self.account problem:problem detail:detail submit:^(NSString *account, NSString *password) {
        [self signInAccount:account password:password];
    }];
}

- (void)signInAccount:(NSString *)account password:(NSString *)password {
    self.account = account;
    if (self.guardAccount && [self.guardAccount caseInsensitiveCompare:account] != NSOrderedSame) {
        self.guardData = nil;   // another account's: this one gets its own
        self.guardAccount = nil;
    }
    [self say:@"Signing in to Steam…"];
    NSString *guardData = self.guardData;
    [self.client disconnect];
    self.client = nil;
    self.attempt++;   // a poll from an earlier sign-in stops
    self.polling = NO;
    [self inBackground:^{
        PocketSteamClient *client = [PocketSteamClient new];
        NSError *error = nil;
        if (![client connect:&error]) { [self onMain:^{ [self offerRetry:error]; }]; return; }
        PocketProto request = {0};
        pocket_proto_string(&request, 1, account.UTF8String);
        NSData *key = [client call:@"Authentication.GetPasswordRSAPublicKey#1" body:ProtoData(&request) error:&error];
        NSString *encrypted = key ? EncryptedPassword(SteamPassword(password), ProtoString(key, 1), ProtoString(key, 2)) : nil;
        if (!encrypted) {
            [self onMain:^{ key ? [self askForCredentials:@"Steam's answer couldn't be used. Wait a moment, then try again." detail:ErrorDetail(error)]
                                : [self offerRetry:error]; }];
            return;
        }
        PocketProto details = {0}, begin = {0};
        pocket_proto_string(&details, 1, DeviceName.UTF8String);
        pocket_proto_uint(&details, 2, 1);                       // platform_type: SteamClient
        pocket_proto_uint(&details, 3, (uint64_t)(int64_t)-600);   // os_type: iOS
        pocket_proto_string(&begin, 1, DeviceName.UTF8String);
        pocket_proto_string(&begin, 2, account.UTF8String);
        pocket_proto_string(&begin, 3, encrypted.UTF8String);
        pocket_proto_uint(&begin, 4, ProtoNumber(key, 3));       // encryption_timestamp
        pocket_proto_uint(&begin, 5, 1);                         // remember_login
        pocket_proto_uint(&begin, 7, 1);                         // persistence: persistent
        pocket_proto_string(&begin, 8, "Client");                // website_id
        pocket_proto_message(&begin, 9, &details);
        if (guardData.length) pocket_proto_string(&begin, 10, guardData.UTF8String);
        pocket_proto_free(&details);
        NSData *session = [client call:@"Authentication.BeginAuthSessionViaCredentials#1" body:ProtoData(&begin) error:&error];
        [self onMain:^{
            self.client = client;
            if (!session) { [self signInRefused:error]; return; }
            self.clientID = ProtoNumber(session, 1);
            PocketField field;
            self.requestID = ProtoField(session, 2, &field) && field.wire == 2 ? [NSData dataWithBytes:field.data length:field.size] : nil;
            float interval = 5;
            if (ProtoField(session, 3, &field) && field.wire == 5) { uint32_t bits = (uint32_t)field.value; memcpy(&interval, &bits, 4); }
            self.interval = MIN(MAX(interval, 1), 10);
            self.steamID = ProtoNumber(session, 5);
            NSMutableSet<NSNumber *> *allowed = [NSMutableSet set];
            NSString *hint = nil;
            const uint8_t *position = session.bytes, *end = position + session.length;
            while (pocket_proto_next(&position, end, &field) == 1) {
                if (field.field != 4 || field.wire != 2) continue;
                NSData *confirmation = [NSData dataWithBytes:field.data length:field.size];
                [allowed addObject:@(ProtoNumber(confirmation, 1))];
                hint = hint ?: ProtoString(confirmation, 2);
            }
            [self confirmWith:allowed hint:hint];
        }];
    }];
}

- (void)signInRefused:(NSError *)error {
    if (![error.domain isEqualToString:PocketSteamErrorDomain] || error.code >= PocketSteamErrorNoServer) { [self offerRetry:error]; return; }
    if (error.code == ResultInvalidPassword)
        [self askForCredentials:@"That account name or password isn't right. Use your Steam account name, not your email address, "
                                @"then check the password and try again." detail:ErrorDetail(error)];
    else if (error.code == ResultRateLimitExceeded)
        [self askForCredentials:@"Too many sign-in attempts. Wait about 30 minutes, then try again." detail:ErrorDetail(error)];
    else if (error.code == ResultAccessDenied)
        [self askForCredentials:@"Steam turned this sign-in down. Check the account name, then try again." detail:ErrorDetail(error)];
    else [self askForCredentials:@"Steam didn't accept the sign-in. Try again in a moment." detail:ErrorDetail(error)];
}

// Steam Guard: a code typed here, or the sign-in approved in the Steam Mobile app (or by email),
// whichever Steam allows; approval is polled for while a code may still be typed.
- (void)confirmWith:(NSSet<NSNumber *> *)allowed hint:(nullable NSString *)hint {
    BOOL approve = [allowed containsObject:@(GuardDeviceConfirmation)] || [allowed containsObject:@(GuardEmailConfirmation)];
    GuardType code = [allowed containsObject:@(GuardDeviceCode)] ? GuardDeviceCode
                   : [allowed containsObject:@(GuardEmailCode)] ? GuardEmailCode : 0;
    BOOL nothingToAsk = [allowed containsObject:@(GuardNone)] || [allowed containsObject:@(GuardMachineToken)] || !allowed.count;
    if (approve || nothingToAsk) [self pollForApproval];
    if (code) { [self askForCode:code hint:hint approve:approve problem:nil]; return; }
    if (nothingToAsk) { [self say:@"Signing in to Steam…"]; [self.screen setBusy:YES]; return; }
    [[self shown] waitForApprovalInApp:[allowed containsObject:@(GuardDeviceConfirmation)] back:^{
        self.polling = NO;
        [self askForCredentials:nil];
    }];
}

- (void)askForCode:(GuardType)type hint:(nullable NSString *)hint approve:(BOOL)approve problem:(nullable NSString *)problem {
    [self say:@"Waiting for your Steam Guard code…"];
    [[self shown] askForCodeEmailedTo:type == GuardEmailCode ? (hint ?: @"") : nil approve:approve problem:problem submit:^(NSString *code) {
        [self submitCode:code type:type hint:hint approve:approve];
    } back:^{
        self.polling = NO;
        [self askForCredentials:nil];
    }];
}

- (void)submitCode:(NSString *)code type:(GuardType)type hint:(nullable NSString *)hint approve:(BOOL)approve {
    [self say:@"Checking the code…"];
    PocketSteamClient *client = self.client;
    uint64_t clientID = self.clientID, steamID = self.steamID;
    [self inBackground:^{
        PocketProto update = {0};
        pocket_proto_uint(&update, 1, clientID);
        pocket_proto_fixed64(&update, 2, steamID);
        pocket_proto_string(&update, 3, code.UTF8String);
        pocket_proto_uint(&update, 4, type);
        NSError *error = nil;
        NSData *accepted = [client call:@"Authentication.UpdateAuthSessionWithSteamGuardCode#1" body:ProtoData(&update) error:&error];
        [self onMain:^{
            if (self.finished) return;
            if (accepted) { [self say:@"Signing in to Steam…"]; [self pollForApproval]; return; }
            BOOL wrong = [error.domain isEqualToString:PocketSteamErrorDomain] &&
                         (error.code == ResultInvalidLoginAuthCode || error.code == ResultTwoFactorCodeMismatch);
            if (wrong) [self askForCode:type hint:hint approve:approve problem:type == GuardDeviceCode
                ? @"That code isn't right. Type the code the Steam Mobile app shows now; it changes every 30 seconds."
                : @"That code isn't right. Check the latest email from Steam and type its code."];
            else [self signInRefused:error];
        }];
    }];
}

// Ask Steam whether the sign-in is done, every interval it named, until it hands out the tokens.
- (void)pollForApproval {
    if (self.polling) return;
    self.polling = YES;
    PocketSteamClient *client = self.client;
    NSData *requestID = self.requestID;
    NSTimeInterval interval = self.interval;
    NSUInteger attempt = self.attempt;
    BOOL (^current)(void) = ^BOOL { return self.attempt == attempt && self.polling && !self.finished; };
    [self inBackground:^{
        uint64_t clientID = self.clientID;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:ApprovalTimeout];
        while (current() && deadline.timeIntervalSinceNow > 0) {
            PocketProto poll = {0};
            pocket_proto_uint(&poll, 1, clientID);
            pocket_proto_bytes(&poll, 2, requestID.bytes, requestID.length);
            NSError *error = nil;
            NSData *status = [client call:@"Authentication.PollAuthSessionStatus#1" body:ProtoData(&poll) error:&error];
            if (!status) {
                [self onMain:^{
                    if (!current()) return;
                    self.polling = NO;
                    [self askForCredentials:@"The sign-in didn't finish. Sign in again." detail:ErrorDetail(error)];
                }];
                return;
            }
            if (ProtoNumber(status, 1)) clientID = ProtoNumber(status, 1);   // new_client_id
            NSString *refreshToken = ProtoString(status, 3);
            if (refreshToken.length) {
                NSString *account = ProtoString(status, 6) ?: self.account;
                NSString *guardData = ProtoString(status, 7) ?: self.guardData;   // (only ever this account's: signInAccount)
                [self onMain:^{
                    if (!current()) return;
                    self.polling = NO;
                    NSMutableDictionary *login = [@{@"account": account, @"refreshToken": refreshToken} mutableCopy];
                    if (guardData.length) login[@"guardData"] = guardData;
                    self.login = login;   // kept once its session is lent (finishWithClient:)
                    [self.screen setBusy:YES];
                    [self logOnSignedIn:login];
                }];
                return;
            }
            [NSThread sleepForTimeInterval:interval];
        }
        [self onMain:^{
            if (!current()) return;
            self.polling = NO;
            [self askForCredentials:@"The sign-in waited too long for your approval. Sign in again, then approve it within 5 minutes."];
        }];
    }];
}

// Freshly signed in: log on with the new token on the connection already open, or on a new
// one if that one dropped (iOS closes it while the app is in the background, as when the
// player fetched the Steam Guard code from another app).
- (void)logOnSignedIn:(NSDictionary *)login {
    [self say:@"Signing in to Steam…"];
    PocketSteamClient *client = self.client;
    [self inBackground:^{
        NSError *error = nil;
        BOOL online = [client logOnAccount:login[@"account"] refreshToken:login[@"refreshToken"] error:&error];
        if (!online && [error.domain isEqualToString:PocketSteamErrorDomain] &&
            (error.code == PocketSteamErrorConnection || error.code == PocketSteamErrorTimedOut))
            online = [client connect:&error] && [client logOnAccount:login[@"account"] refreshToken:login[@"refreshToken"] error:&error];
        [self onMain:^{
            if (online) [self startGameSession];
            else [self offerRetry:error];
        }];
    }];
}
@end

BOOL PocketSteamPrepareLaunch(NSString *profile, UIViewController *presenter, UILabel *status, dispatch_block_t resume) {
    static PocketSteamLaunch *running;
    if (![profile isEqualToString:SteamProfile] || launchSettled) return NO;
    if (running) return YES;   // a sign-in is already on screen
    running = [PocketSteamLaunch new];
    running.presenter = presenter;
    running.status = status;
    running.cancelTitle = @"Not Now";
    running.resume = ^{
        running = nil;
        resume();
    };
    [running start];
    return YES;
}

__attribute__((visibility("default"), used)) void PocketSteamGameReady(UIViewController *presenter) {
    static BOOL offered;
    PocketSteamState state = PocketSteamCurrentState(NULL);
    // Signed in, signing in, or a kept login waiting for Steam to answer: nothing to offer.
    if (offered || BridgeAccount(NULL, NULL, 0) || state == PocketSteamStateConnecting || state == PocketSteamStateUnreachable) return;
    offered = YES;
    NSLog(@"[steam] the game is at its main menu without Steam: offering the sign-in");
    PocketSteamSignInAgain(presenter);
}

__attribute__((visibility("default"), used)) void PocketSteamSignInAgain(UIViewController *presenter) {
    static PocketSteamLaunch *again;
    if (again) return;   // already on screen
    again = [PocketSteamLaunch new];
    again.presenter = presenter;
    again.cancelTitle = @"Not Now";
    // Unreachable: the kept login again (Try again); otherwise the account is asked for, so
    // another one can be chosen.
    again.askFirst = PocketSteamCurrentState(NULL) != PocketSteamStateUnreachable;
    again.resume = ^{ again = nil; };
    [again start];
}

// Signs out now (the in-game settings' Sign Out of Steam): the kept login is forgotten and the
// lent session ends, so the next sign-in starts clean, with any account. The game keeps running;
// what it already holds from its servers stays until it next asks Steam. Main thread.
__attribute__((visibility("default"), used)) void PocketSteamEndSession(void) {
    ForgetLogin();
    os_unfair_lock_lock(&sessionLock);
    PocketSteamClient *client = gameSession;
    gameSession = nil;
    lentSteamID = 0;
    lentPersona = nil;
    lentLogin = nil;
    os_unfair_lock_unlock(&sessionLock);
    [client disconnect];
    NSLog(@"[steam] signed out by the player; the kept login is forgotten");
    SetState(PocketSteamStateOff, @"Signed out of Steam.");
}

NSString *PocketSteamSignOut(void) {
    BOOL kept = LoadLogin() != nil;
    ForgetLogin();
    return kept ? @"Signed out of Steam. The next launch of Brighter Shores asks for a sign-in."
                : @"No Steam sign-in is kept on this device.";
}
