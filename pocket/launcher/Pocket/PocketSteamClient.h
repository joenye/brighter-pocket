// A connection to Steam for the app: PocketSteam.c's session over a WebSocket to one of Steam's
// connection managers (*.steamserver.net, from Steam's directory). The waiting methods block
// their caller: call them off the main thread.
#import <Foundation/Foundation.h>
#include "PocketSteam.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PocketSteamErrorDomain;   // codes: EResults, or the ones below
typedef NS_ENUM(NSInteger, PocketSteamError) {
    PocketSteamErrorNoServer = 1000,      // the directory named no connection manager
    PocketSteamErrorConnection = 1001,    // the WebSocket failed or closed
    PocketSteamErrorTimedOut = 1002,
    PocketSteamErrorMalformed = 1003,     // Steam sent a frame that could not be read
};

@interface PocketSteamClient : NSObject
@property(nonatomic, readonly) uint64_t steamID;          // 0 until logged on
@property(nonatomic, readonly, copy) NSString *personaName;
@property(nonatomic, readonly, getter=isOnline) BOOL online;
// Steam's reason when it ended the session (an EResult; 0 while it has not).
@property(nonatomic, readonly) int loggedOffResult;
// YES while a game runs on another session of the account, with its app ID (0 if not named).
- (BOOL)playingElsewhere:(uint32_t *_Nullable)appID;
// Online and answering: a WebSocket ping comes back within seconds. A connection that died
// quietly (the app suspended, a network change) fails here and counts as dropped from then on.
- (BOOL)checkAlive:(NSTimeInterval)seconds;

- (BOOL)connect:(NSError **)error;
// A unified service method's reply body (Steam's result must be OK).
- (nullable NSData *)call:(NSString *)method body:(NSData *)body error:(NSError **)error;
// A message Steam answers with a job (EMsg message): its replies' bodies, until last says a reply
// is the last one (nil: the first is). Steam's result must be OK.
- (nullable NSArray<NSData *> *)request:(uint32_t)message body:(NSData *)body error:(NSError **)error
                                  until:(nullable BOOL (^)(NSData *reply))last;
- (BOOL)logOnAccount:(NSString *)account refreshToken:(NSString *)token error:(NSError **)error;
// Brighter Shores' ownership ticket, and Steam told the game is running.
- (BOOL)startGame:(uint32_t)appID error:(NSError **)error;
// A web API ticket (POCKET_STEAM_WEB_TICKET_SIZE bytes) Steam acknowledged, or nil (and the
// connection then counts as dropped).
- (nullable NSData *)webTicketForIdentity:(NSString *)identity crc:(uint32_t *)crc;
- (void)cancelTicket:(uint32_t)crc;
- (void)disconnect;
@end

NS_ASSUME_NONNULL_END
