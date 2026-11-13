// A game's files from Steam's content system, on the device: which build Steam has on a branch
// (the app's product info), and that build's depot files, verified, with only what changed
// downloaded (unchanged files and chunks are taken from the build already there). It uses a
// signed-in PocketSteamClient (a session of its own: Steam keeps the game's session as it is)
// and Steam's content servers over HTTPS. The waiting methods block: call them off the main thread.
#import <Foundation/Foundation.h>
#import "PocketSteamClient.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PocketDepotErrorDomain;
typedef NS_ENUM(NSInteger, PocketDepotError) {
    PocketDepotErrorNotOwned = 1,      // Steam gave no key or token for the depot: the account lacks the game
    PocketDepotErrorNoRelease = 2,     // the branch or the depot's manifest is not in the product info
    PocketDepotErrorNoServers = 3,     // no content server to download from
    PocketDepotErrorNetwork = 4,       // the content servers did not answer, after retries
    PocketDepotErrorCorrupt = 5,       // what came did not verify (a chunk's or file's SHA-1, its format)
    PocketDepotErrorNoSpace = 6,       // not enough free space for the files that change
    PocketDepotErrorCancelled = 7,
    PocketDepotErrorFiles = 8,         // the files could not be written
};

// One build of the depot on one branch.
@interface PocketDepotRelease : NSObject
@property(nonatomic, readonly, copy) NSString *branch;
@property(nonatomic, readonly) uint64_t buildID, manifestID;
@property(nonatomic, readonly, nullable) NSDate *updated;          // when the branch got this build
@property(nonatomic, readonly) uint64_t downloadSize, diskSize;    // the whole build's, from the product info (0 if not given)
@end

@interface PocketDepot : NSObject
- (instancetype)initWithClient:(PocketSteamClient *)client appID:(uint32_t)appID depotID:(uint32_t)depotID;
- (instancetype)init NS_UNAVAILABLE;

// The branches a player may choose (no password), "public" first.
- (nullable NSArray<NSString *> *)branchesWithError:(NSError **)error;
// Steam's current build on a branch.
- (nullable PocketDepotRelease *)releaseOnBranch:(NSString *)branch error:(NSError **)error;

// One file's SHA-1 in the release (its manifest), to tell whether a file on the device is that build's.
- (nullable NSData *)contentSHA1OfPath:(NSString *)depotPath inRelease:(PocketDepotRelease *)release error:(NSError **)error;

// The release's files under staging (a folder of its own, kept between attempts: a fetch cut
// short resumes there), each verified against the manifest. Files and chunks already present in
// existing (an earlier build's folder, same layout) are cloned or copied instead of downloaded.
// include: which depot paths to take (nil: all). progress: bytes in place so far of all bytes,
// from any thread. cancelled: polled between chunks. A depot path's "/" separates folders.
- (BOOL)fetchRelease:(PocketDepotRelease *)release
                into:(NSString *)staging
             reusing:(nullable NSString *)existing
             include:(nullable BOOL (^)(NSString *depotPath))include
            progress:(nullable void (^)(int64_t done, int64_t total))progress
           cancelled:(nullable BOOL (^)(void))cancelled
               error:(NSError **)error;
@end

// Steam's text KeyValues (the product info's format) as nested dictionaries; nil if malformed.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable PocketKeyValues(NSData *text);

NS_ASSUME_NONNULL_END
