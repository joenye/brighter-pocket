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

- (BOOL)connect:(NSError **)error;
// A unified service method's reply body (Steam's result must be OK).
- (nullable NSData *)call:(NSString *)method body:(NSData *)body error:(NSError **)error;
- (BOOL)logOnAccount:(NSString *)account refreshToken:(NSString *)token error:(NSError **)error;
// Brighter Shores' ownership ticket, and Steam told the game is running.
- (BOOL)startGame:(uint32_t)appID error:(NSError **)error;
// A web API ticket (POCKET_STEAM_WEB_TICKET_SIZE bytes) registered with Steam, or nil.
- (nullable NSData *)webTicketForIdentity:(NSString *)identity crc:(uint32_t *)crc;
- (void)cancelTicket:(uint32_t)crc;
- (void)disconnect;
@end

NS_ASSUME_NONNULL_END
