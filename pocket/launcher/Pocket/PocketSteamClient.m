#import "PocketSteamClient.h"
#include <stdlib.h>
#include <zlib.h>

NSString *const PocketSteamErrorDomain = @"PocketSteam";
static const NSTimeInterval PocketSteamWait = 30;
static const NSTimeInterval PocketSteamServerWait = 10;   // for one server's WebSocket to answer
static const NSUInteger PocketSteamServersTried = 5;
static const NSTimeInterval PocketSteamTicketWait = 10;   // for Steam to acknowledge a new ticket

static NSError *PocketError(NSInteger code) { return [NSError errorWithDomain:PocketSteamErrorDomain code:code userInfo:nil]; }
static void PocketRandom(void *buffer, size_t size) { arc4random_buf(buffer, size); }
static int PocketGunzip(const uint8_t *data, size_t size, uint8_t *output, size_t output_size) {
    z_stream stream = {0};
    stream.next_in = (Bytef *)data;
    stream.avail_in = (uInt)size;
    stream.next_out = output;
    stream.avail_out = (uInt)output_size;
    int status = inflateInit2(&stream, 15 + 16);
    if (status == Z_OK) { status = inflate(&stream, Z_FINISH); inflateEnd(&stream); }
    return status == Z_STREAM_END && stream.total_out == output_size ? 0 : -1;
}

@interface PocketSteamClient ()
- (void)sendFrame:(NSData *)frame;
@end

static void PocketSend(void *context, const uint8_t *frame, size_t size) {
    [(__bridge PocketSteamClient *)context sendFrame:[NSData dataWithBytes:frame length:size]];
}

@implementation PocketSteamClient {
    NSCondition *_condition;   // guards _session and _failure; broadcast after every frame
    PocketSteamSession *_session;
    NSURLSession *_urlSession;
    NSURLSessionWebSocketTask *_socket;
    NSError *_failure;
    dispatch_source_t _heartbeat;
    uint32_t _appID;   // the game startGame: started
}

- (instancetype)init {
    if ((self = [super init])) {
        _condition = [NSCondition new];
        _session = pocket_steam_create(PocketSend, (__bridge void *)self, PocketRandom, PocketGunzip);
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
    pocket_steam_destroy(_session);
}

- (void)sendFrame:(NSData *)frame {
    NSURLSessionWebSocketTask *socket = _socket;
    __weak PocketSteamClient *weakSelf = self;
    [socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:frame] completionHandler:^(NSError *error) {
        if (error) [weakSelf fail:PocketError(PocketSteamErrorConnection) socket:socket];
    }];
}

- (void)fail:(NSError *)error socket:(NSURLSessionWebSocketTask *)socket {
    [_condition lock];
    if (socket == _socket && !_failure) _failure = error;
    [_condition broadcast];
    [_condition unlock];
}

- (void)readFrom:(NSURLSessionWebSocketTask *)socket {
    __weak PocketSteamClient *weakSelf = self;
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        PocketSteamClient *self = weakSelf;
        if (!self) return;
        if (error || message.type != NSURLSessionWebSocketMessageTypeData) {
            [self fail:PocketError(PocketSteamErrorConnection) socket:socket];
            return;
        }
        [self->_condition lock];
        BOOL current = socket == self->_socket;
        if (current && pocket_steam_receive(self->_session, message.data.bytes, message.data.length) != 0 && !self->_failure)
            self->_failure = PocketError(PocketSteamErrorMalformed);
        BOOL again = current && !self->_failure;
        [self->_condition broadcast];
        [self->_condition unlock];
        if (again) [self readFrom:socket];
    }];
}

// Wait, holding the lock between checks, until done() says so (it runs under the lock).
- (BOOL)waitUntil:(BOOL (^)(void))done seconds:(NSTimeInterval)seconds error:(NSError **)error {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    [_condition lock];
    for (;;) {
        if (done()) { [_condition unlock]; return YES; }
        NSError *failure = _failure;
        if (failure || ![_condition waitUntilDate:deadline]) {
            [_condition unlock];
            if (error) *error = failure ?: PocketError(PocketSteamErrorTimedOut);
            return NO;
        }
    }
}

- (BOOL)connect:(NSError **)error {
    [self disconnect];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = PocketSteamWait;
    _urlSession = [NSURLSession sessionWithConfiguration:configuration];
    NSURL *directory = [NSURL URLWithString:@"https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets"];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *listing;
    [[_urlSession dataTaskWithURL:directory completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
        if (!failure && [(NSHTTPURLResponse *)response statusCode] == 200) listing = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PocketSteamWait * NSEC_PER_SEC)));
    NSDictionary *parsed = listing ? [NSJSONSerialization JSONObjectWithData:listing options:0 error:nil] : nil;
    NSMutableArray<NSURL *> *servers = [NSMutableArray array];
    if ([parsed isKindOfClass:NSDictionary.class])
        for (NSDictionary *server in parsed[@"response"][@"serverlist"]) {
            // Only Valve's TLS hosts get the account's token.
            NSString *endpoint = [server isKindOfClass:NSDictionary.class] ? server[@"endpoint"] : nil;
            NSURL *candidate = [endpoint isKindOfClass:NSString.class]
                ? [NSURL URLWithString:[NSString stringWithFormat:@"wss://%@/cmsocket/", endpoint]] : nil;
            if ([candidate.host hasSuffix:@".steamserver.net"] && !candidate.user && !candidate.password) [servers addObject:candidate];
            if (servers.count == PocketSteamServersTried) break;
        }
    if (!servers.count) { if (error) *error = PocketError(PocketSteamErrorNoServer); return NO; }
    // A server the network will not reach (its TLS handshake reset, say) costs one try: each in
    // the directory's order until one answers a WebSocket ping.
    for (NSURL *url in servers) {
        NSURLSessionWebSocketTask *socket = [_urlSession webSocketTaskWithURL:url];
        socket.maximumMessageSize = 16 << 20;
        [socket resume];
        dispatch_semaphore_t answered = dispatch_semaphore_create(0);
        __block NSError *pingFailure = nil;
        [socket sendPingWithPongReceiveHandler:^(NSError *failure) {
            pingFailure = failure;
            dispatch_semaphore_signal(answered);
        }];
        if (!dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PocketSteamServerWait * NSEC_PER_SEC))) && !pingFailure) {
            [_condition lock];
            _failure = nil;
            _socket = socket;
            [self readFrom:_socket];
            pocket_steam_hello(_session);
            [_condition unlock];
            return YES;
        }
        NSLog(@"[steam] %@ did not answer (%@); trying the next server", url.host, pingFailure.localizedDescription ?: @"timed out");
        [socket cancel];
    }
    if (error) *error = PocketError(PocketSteamErrorConnection);
    return NO;
}

// A service call. Before logon (the sign-in's calls), a connection that dropped is made again
// once and the call sent again: iOS closes the app's sockets while it is in the background,
// as it is while the player fetches a Steam Guard code from another app, and the sign-in
// lives on Steam's side (its client ID), not on the connection.
- (NSData *)call:(NSString *)method body:(NSData *)body error:(NSError **)error {
    [_condition lock];
    NSURLSessionWebSocketTask *used = _socket;
    [_condition unlock];
    NSError *failure = nil;
    NSData *reply = [self callOnce:method body:body error:&failure];
    [_condition lock];
    BOOL dropped = !reply && [failure.domain isEqualToString:PocketSteamErrorDomain] &&
                   (failure.code == PocketSteamErrorConnection || failure.code == PocketSteamErrorTimedOut) &&
                   pocket_steam_status(_session, NULL) != POCKET_STEAM_ONLINE;
    [_condition unlock];
    if (dropped) {
        // The sign-in's poll and its code may both find the connection gone: one makes it again.
        @synchronized (self) {
            [_condition lock];
            BOOL replaced = _socket != used;
            [_condition unlock];
            if (replaced || [self connect:&failure]) reply = [self callOnce:method body:body error:&failure];
        }
    }
    if (!reply && error) *error = failure;
    return reply;
}

- (NSData *)callOnce:(NSString *)method body:(NSData *)body error:(NSError **)error {
    [_condition lock];
    uint64_t job = pocket_steam_call(_session, method.UTF8String, body.bytes, body.length);
    [_condition unlock];
    __block int result = 0;
    __block NSData *reply;
    PocketSteamSession *session = _session;
    if (![self waitUntil:^BOOL {
            const uint8_t *bytes;
            size_t size;
            if (!pocket_steam_reply(session, job, &result, &bytes, &size)) return NO;
            reply = [NSData dataWithBytes:bytes length:size];
            return YES;
        } seconds:PocketSteamWait error:error]) return nil;
    if (result != POCKET_STEAM_RESULT_OK) { if (error) *error = PocketError(result); return nil; }
    return reply;
}

- (NSArray<NSData *> *)request:(uint32_t)message body:(NSData *)body error:(NSError **)error
                         until:(BOOL (^)(NSData *reply))last {
    [_condition lock];
    uint64_t job = pocket_steam_request(_session, message, body.bytes, body.length);
    [_condition unlock];
    PocketSteamSession *session = _session;
    NSMutableArray<NSData *> *replies = [NSMutableArray array];
    for (;;) {
        __block int result = 0;
        __block NSData *reply;
        if (![self waitUntil:^BOOL {
                const uint8_t *bytes;
                size_t size;
                if (!pocket_steam_reply(session, job, &result, &bytes, &size)) return NO;
                reply = [NSData dataWithBytes:bytes length:size];
                return YES;
            } seconds:PocketSteamWait error:error]) return nil;
        if (result != POCKET_STEAM_RESULT_OK) { if (error) *error = PocketError(result); return nil; }
        [replies addObject:reply];
        if (!last || last(reply)) return replies;
    }
}

- (BOOL)logOnAccount:(NSString *)account refreshToken:(NSString *)token error:(NSError **)error {
    [_condition lock];
    pocket_steam_logon(_session, account.UTF8String, token.UTF8String, "Brighter Pocket");
    [_condition unlock];
    PocketSteamSession *session = _session;
    if (![self waitUntil:^BOOL { return pocket_steam_status(session, NULL) != POCKET_STEAM_LOGGING_ON; }
                 seconds:PocketSteamWait error:error]) return NO;
    [_condition lock];
    int result = 0;
    BOOL online = pocket_steam_status(_session, &result) == POCKET_STEAM_ONLINE;
    int seconds = pocket_steam_heartbeat_seconds(_session);
    [_condition unlock];
    if (!online) { if (error) *error = PocketError(result); return NO; }
    _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_heartbeat, dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC),
                              (uint64_t)seconds * NSEC_PER_SEC, NSEC_PER_SEC);
    __weak PocketSteamClient *weakSelf = self;
    dispatch_source_set_event_handler(_heartbeat, ^{
        PocketSteamClient *client = weakSelf;
        if (!client) return;
        [client->_condition lock];
        if (pocket_steam_status(client->_session, NULL) == POCKET_STEAM_ONLINE) pocket_steam_heartbeat(client->_session);
        [client->_condition unlock];
    });
    dispatch_resume(_heartbeat);
    return YES;
}

- (BOOL)startGame:(uint32_t)appID error:(NSError **)error {
    [_condition lock];
    pocket_steam_request_ownership(_session, appID);
    [_condition unlock];
    PocketSteamSession *session = _session;
    __block int result = 0;
    if (![self waitUntil:^BOOL { return pocket_steam_ownership(session, appID, &result); } seconds:PocketSteamWait error:error])
        return NO;
    if (result != POCKET_STEAM_RESULT_OK) { if (error) *error = PocketError(result); return NO; }
    [_condition lock];
    pocket_steam_games_played(_session, appID);
    _appID = appID;
    [_condition unlock];
    // Steam sends the game connect tokens tickets are made from soon after logon.
    return [self waitUntil:^BOOL { return pocket_steam_connect_tokens(session) > 0; } seconds:PocketSteamWait error:error];
}

// A ticket counts once Steam acknowledged it (the auth list's ack): a ticket made on a
// connection that died quietly (the app suspended, a network change) would reach Steam never,
// and the game's servers would refuse it every time.
- (NSData *)webTicketForIdentity:(NSString *)identity crc:(uint32_t *)crc {
    NSMutableData *ticket = [NSMutableData dataWithLength:POCKET_STEAM_WEB_TICKET_SIZE];
    uint32_t made_crc = 0;
    [_condition lock];
    int made = _appID ? pocket_steam_web_ticket(_session, _appID, identity.UTF8String, ticket.mutableBytes, &made_crc) : -1;
    [_condition unlock];
    if (made != 0) return nil;
    PocketSteamSession *session = _session;
    if (![self waitUntil:^BOOL { return pocket_steam_ticket_acknowledged(session, made_crc) != 0; }
                 seconds:PocketSteamTicketWait error:NULL]) {
        [self cancelTicket:made_crc];
        [self fail:PocketError(PocketSteamErrorTimedOut) socket:_socket];   // the connection is stale: make it again
        return nil;
    }
    if (crc) *crc = made_crc;
    return ticket;
}

- (void)cancelTicket:(uint32_t)crc {
    [_condition lock];
    pocket_steam_cancel_ticket(_session, crc);
    [_condition unlock];
}

- (uint64_t)steamID {
    [_condition lock];
    uint64_t steamID = pocket_steam_steam_id(_session);
    [_condition unlock];
    return steamID;
}

- (NSString *)personaName {
    [_condition lock];
    NSString *name = @(pocket_steam_persona_name(_session));
    [_condition unlock];
    return name;
}

- (int)loggedOffResult {
    [_condition lock];
    int result = 0;
    BOOL ended = pocket_steam_status(_session, &result) == POCKET_STEAM_LOGGED_OFF;
    [_condition unlock];
    return ended ? result : 0;
}

- (BOOL)playingElsewhere:(uint32_t *)appID {
    [_condition lock];
    BOOL playing = pocket_steam_playing_elsewhere(_session, appID) != 0;
    [_condition unlock];
    return playing;
}

- (BOOL)checkAlive:(NSTimeInterval)seconds {
    [_condition lock];
    NSURLSessionWebSocketTask *socket = _socket;
    [_condition unlock];
    if (!socket || !self.online) return NO;
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    [socket sendPingWithPongReceiveHandler:^(NSError *error) {
        failure = error;
        dispatch_semaphore_signal(answered);
    }];
    BOOL alive = !dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) && !failure;
    if (!alive) [self fail:PocketError(PocketSteamErrorTimedOut) socket:socket];
    return alive;
}

- (BOOL)isOnline {
    [_condition lock];
    BOOL online = pocket_steam_status(_session, NULL) == POCKET_STEAM_ONLINE && !_failure;
    [_condition unlock];
    return online;
}

- (void)disconnect {
    if (_heartbeat) { dispatch_source_cancel(_heartbeat); _heartbeat = nil; }
    [_condition lock];
    if (_socket && pocket_steam_status(_session, NULL) == POCKET_STEAM_ONLINE && !_failure) {
        pocket_steam_games_played(_session, 0);
        pocket_steam_logoff(_session);
    }
    NSURLSessionWebSocketTask *socket = _socket;
    _socket = nil;
    [_condition broadcast];
    [_condition unlock];
    [socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [_urlSession finishTasksAndInvalidate];
    _urlSession = nil;
}
@end
