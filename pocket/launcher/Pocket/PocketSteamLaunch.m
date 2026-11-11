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
#import <Security/Security.h>
#include "../../translation/libsteam_api/PocketSteamBridge.h"
#include <os/lock.h>
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
static os_unfair_lock sessionLock = OS_UNFAIR_LOCK_INIT;
static PocketSteamClient *gameSession;
static BOOL launchSettled;   // main thread: signed in, or chose to play offline, this run

static PocketSteamClient *CurrentSession(void) {
    os_unfair_lock_lock(&sessionLock);
    PocketSteamClient *client = gameSession;
    os_unfair_lock_unlock(&sessionLock);
    return client.online ? client : nil;
}
static int BridgeAccount(uint64_t *steamID, char *name, size_t size) {
    PocketSteamClient *client = CurrentSession();
    if (!client) return 0;
    if (steamID) *steamID = client.steamID;
    if (name && size) strlcpy(name, client.personaName.UTF8String ?: "", size);
    return 1;
}
static void BridgeWebTicket(const char *identity, PocketSteamTicketDone done, void *context) {
    NSString *service = @(identity ?: "");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PocketSteamClient *client = CurrentSession();
        uint32_t crc = 0;
        NSData *ticket = [client webTicketForIdentity:service crc:&crc];
        NSLog(@"[steam] web API ticket for \"%@\": %@", service, ticket ? @"made and registered with Steam" : @"none (no session)");
        done(context, ticket ? 1 : 3, ticket.bytes, (uint32_t)ticket.length, crc);   // OK, or NoConnection
    });
}
static void BridgeCancelTicket(uint32_t crc) { [CurrentSession() cancelTicket:crc]; }

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
static void ForgetLogin(void) { SecItemDelete((__bridge CFDictionaryRef)LoginQuery()); }

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
@property(nonatomic, strong, nullable) UIAlertController *alert;
@property(nonatomic, strong, nullable) PocketSteamClient *client;
// The sign-in under way (Authentication.BeginAuthSessionViaCredentials's answer).
@property(nonatomic, copy, nullable) NSString *account;
@property(nonatomic, copy, nullable) NSString *guardData;
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

// Over whatever the launcher has on screen (the presenter may itself be presenting).
- (void)presentNow:(UIAlertController *)alert {
    UIViewController *top = self.presenter;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    [top presentViewController:alert animated:YES completion:nil];
}
- (void)show:(UIAlertController *)alert {
    UIAlertController *previous = self.alert;
    self.alert = alert;
    if (previous.presentingViewController) [previous dismissViewControllerAnimated:NO completion:^{ [self presentNow:alert]; }];
    else [self presentNow:alert];
}
- (void)dismissAlert {
    UIAlertController *alert = self.alert;
    self.alert = nil;
    if (alert.presentingViewController) [alert dismissViewControllerAnimated:YES completion:nil];
}

- (void)start {
    [self.client disconnect];
    self.client = nil;
    NSDictionary *login = LoadLogin();
    if (login) [self logOnWithLogin:login];
    else [self askForCredentials:nil];
}

- (void)finishWithClient:(nullable PocketSteamClient *)client {
    self.finished = YES;
    [self dismissAlert];
    if (client) {
        os_unfair_lock_lock(&sessionLock);
        gameSession = client;
        os_unfair_lock_unlock(&sessionLock);
        NSLog(@"[steam] signed in; the game's session is ready");
    } else {
        [self.client disconnect];
        NSLog(@"[steam] playing offline");
    }
    launchSettled = YES;
    self.resume();
}

- (void)offerRetry:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't reach Steam"
        message:[NSString stringWithFormat:@"Brighter Shores signs in through Steam. (%@ %ld)", error.domain, (long)error.code]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Try again" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self start]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Play offline" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { [self finishWithClient:nil]; }]];
    [self show:alert];
}

// The remembered login: log on, then start the game's session. A login Steam no longer
// accepts is forgotten and the player asked again.
- (void)logOnWithLogin:(NSDictionary *)login {
    [self say:@"Signing in to Steam…"];
    self.account = login[@"account"];
    [self inBackground:^{
        PocketSteamClient *client = [PocketSteamClient new];
        NSError *error = nil;
        BOOL online = [client connect:&error] && [client logOnAccount:login[@"account"] refreshToken:login[@"refreshToken"] error:&error];
        [self onMain:^{
            self.client = client;
            if (online) { [self startGameSession]; return; }
            NSSet *rejected = [NSSet setWithArray:@[@(ResultInvalidPassword), @(ResultAccessDenied), @(ResultRevoked), @(ResultExpired)]];
            if ([error.domain isEqualToString:PocketSteamErrorDomain] && [rejected containsObject:@(error.code)]) {
                ForgetLogin();
                self.guardData = login[@"guardData"];
                [self askForCredentials:@"Steam asked you to sign in again."];
            } else {
                [self offerRetry:error];
            }
        }];
    }];
}

- (void)startGameSession {
    [self say:@"Starting Brighter Shores' Steam session…"];
    PocketSteamClient *client = self.client;
    [self inBackground:^{
        NSError *error = nil;
        BOOL started = [client startGame:BrighterShoresAppID error:&error];
        [self onMain:^{
            if (started) { [self finishWithClient:client]; return; }
            if (![error.domain isEqualToString:PocketSteamErrorDomain] || error.code >= PocketSteamErrorNoServer) {
                [self offerRetry:error];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Brighter Shores isn't on this account"
                message:[NSString stringWithFormat:@"Steam would not give %@ a ticket for Brighter Shores (error %ld).",
                         client.personaName.length ? client.personaName : @"this account", (long)error.code]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Use another account" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                [client disconnect];
                ForgetLogin();
                [self askForCredentials:nil];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Play offline" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { [self finishWithClient:nil]; }]];
            [self show:alert];
        }];
    }];
}

- (void)askForCredentials:(nullable NSString *)problem {
    [self say:@"Waiting for Steam sign-in…"];
    NSString *message = @"Brighter Shores signs in with your Steam account. Your password goes only to Steam; "
                        @"this device keeps Steam's sign-in token in its keychain.";
    if (problem) message = [problem stringByAppendingFormat:@"\n\n%@", message];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Sign in to Steam" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSString *lastAccount = self.account;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Steam account name";
        field.text = lastAccount;
        field.textContentType = UITextContentTypeUsername;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Password";
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypePassword;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Sign in" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *account = [weakAlert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *password = weakAlert.textFields[1].text;
        if (!account.length || !password.length) { [self askForCredentials:@"Enter your Steam account name and password."]; return; }
        [self signInAccount:account password:password];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Play offline" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { [self finishWithClient:nil]; }]];
    [self show:alert];
}

- (void)signInAccount:(NSString *)account password:(NSString *)password {
    self.account = account;
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
        NSString *encrypted = key ? EncryptedPassword(password, ProtoString(key, 1), ProtoString(key, 2)) : nil;
        if (!encrypted) {
            [self onMain:^{ key ? [self askForCredentials:@"Steam's sign-in key could not be used."] : [self offerRetry:error]; }];
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
    if (error.code == ResultInvalidPassword) [self askForCredentials:@"Steam didn't accept that account name and password."];
    else if (error.code == ResultRateLimitExceeded) [self askForCredentials:@"Steam has seen too many sign-in attempts from here. Wait a while, then try again."];
    else [self askForCredentials:[NSString stringWithFormat:@"Steam refused the sign-in (error %ld).", (long)error.code]];
}

// Steam Guard: a code typed here, or the sign-in approved in the Steam Mobile app (or by email),
// whichever Steam allows; approval is polled for while a code may still be typed.
- (void)confirmWith:(NSSet<NSNumber *> *)allowed hint:(nullable NSString *)hint {
    BOOL approve = [allowed containsObject:@(GuardDeviceConfirmation)] || [allowed containsObject:@(GuardEmailConfirmation)];
    GuardType code = [allowed containsObject:@(GuardDeviceCode)] ? GuardDeviceCode
                   : [allowed containsObject:@(GuardEmailCode)] ? GuardEmailCode : 0;
    if (approve || [allowed containsObject:@(GuardNone)] || !allowed.count) [self pollForApproval];
    if (code) { [self askForCode:code hint:hint approve:approve problem:nil]; return; }
    if ([allowed containsObject:@(GuardNone)] || !allowed.count) { [self say:@"Signing in to Steam…"]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Approve the sign-in"
        message:[allowed containsObject:@(GuardDeviceConfirmation)]
                    ? @"Open the Steam Mobile app and approve this sign-in." : @"Approve this sign-in from the email Steam sent you."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
        self.polling = NO;
        [self askForCredentials:nil];
    }]];
    [self show:alert];
}

- (void)askForCode:(GuardType)type hint:(nullable NSString *)hint approve:(BOOL)approve problem:(nullable NSString *)problem {
    NSString *message = type == GuardDeviceCode ? @"Enter the code shown in the Steam Mobile app."
        : [NSString stringWithFormat:@"Enter the code Steam emailed to %@.", hint.length ? hint : @"you"];
    if (approve) message = [message stringByAppendingString:@" Or approve the sign-in in the app."];
    if (problem) message = [problem stringByAppendingFormat:@"\n\n%@", message];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Steam Guard" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Code";
        field.textContentType = UITextContentTypeOneTimeCode;
        field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Submit" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self submitCode:[weakAlert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                    type:type hint:hint approve:approve];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
        self.polling = NO;
        [self askForCredentials:nil];
    }]];
    [self show:alert];
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
            if (wrong) [self askForCode:type hint:hint approve:approve problem:@"That code didn't work."];
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
                    [self askForCredentials:@"The sign-in was not completed. Try again."];
                }];
                return;
            }
            if (ProtoNumber(status, 1)) clientID = ProtoNumber(status, 1);   // new_client_id
            NSString *refreshToken = ProtoString(status, 3);
            if (refreshToken.length) {
                NSString *account = ProtoString(status, 6) ?: self.account;
                NSString *guardData = ProtoString(status, 7) ?: self.guardData;
                [self onMain:^{
                    if (!current()) return;
                    self.polling = NO;
                    NSMutableDictionary *login = [@{@"account": account, @"refreshToken": refreshToken} mutableCopy];
                    if (guardData.length) login[@"guardData"] = guardData;
                    SaveLogin(login);
                    [self dismissAlert];
                    [self logOnSignedIn:login];
                }];
                return;
            }
            [NSThread sleepForTimeInterval:interval];
        }
        [self onMain:^{
            if (!current()) return;
            self.polling = NO;
            [self askForCredentials:@"The sign-in timed out. Try again."];
        }];
    }];
}

// Freshly signed in: log on with the new token on the connection already open.
- (void)logOnSignedIn:(NSDictionary *)login {
    [self say:@"Signing in to Steam…"];
    PocketSteamClient *client = self.client;
    [self inBackground:^{
        NSError *error = nil;
        BOOL online = [client logOnAccount:login[@"account"] refreshToken:login[@"refreshToken"] error:&error];
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
    running.resume = ^{
        running = nil;
        resume();
    };
    [running start];
    return YES;
}

NSString *PocketSteamSignOut(void) {
    BOOL kept = LoadLogin() != nil;
    ForgetLogin();
    return kept ? @"Signed out of Steam. The next launch of Brighter Shores asks for a sign-in."
                : @"No Steam sign-in is kept on this device.";
}
