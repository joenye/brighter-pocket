// The build of Brighter Shores on the device and its updates, without the screens (those are
// PocketGameUpdates.m): whether it is Steam's, fetching Steam's into a staging folder, putting a
// fetched build in place before the game starts, the build before kept until the new one has
// started, going back to it, and clearing what older builds left. Foundation only, so
// tests/depot_live.m runs it on the Mac against Steam itself.
//
// Where things are: the game in <documents>/Brighter Shores/Brighter Shores.app (the profile's
// layout), the depot's copy of it at x64arm64/Brighter Shores.app; the updates' work in
// <updates>: installed.json (the build on the device: branch, build, manifest, when Steam
// published it, its version, the executable's SHA-1, whether it has started since it was put in
// place, how often it was tried, the build gone back from), <manifest>/ (a build being fetched,
// in the depot's layout, kept when cut short so the next attempt resumes; staged.json in it once
// it is complete, waiting for the next start), current/x64arm64 (a link to the game's folder, so
// a fetch finds the build already there in the depot's layout and clones what did not change),
// previous/ (the build before the last update, with its installed.json, until the new one has
// started once). <documents>/LocalSigning/<SHA-256>.dylib: each executable's page container,
// made on the device; those of builds no longer on it go.
#import "PocketDepot.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const uint32_t PocketGameAppID, PocketGameDepotID;

// A build as people read it, as brighter-atlas shows builds: when Steam published it and the
// game's own version, "11-Nov-2026 15:19 UTC (v0.104.2)"; either alone when the other is not
// known; nil when neither is.
FOUNDATION_EXPORT NSString *_Nullable PocketBuildLabel(NSDate *_Nullable published, NSString *_Nullable version);

@interface PocketInstalledGame : NSObject
- (instancetype)initWithDocuments:(NSString *)documents updates:(NSString *)updates NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The build on the device, as last recorded (0 before the first check), its version (from its
// Info.plist), and its label.
@property(nonatomic, readonly) uint64_t build, manifest;
@property(nonatomic, readonly, nullable) NSString *version, *label;
@property(nonatomic, readonly) BOOL installed;

// A build put in place by an update that has been tried and has not started: the one before
// it is there to go back to. Counts this try.
- (BOOL)updateFailedToStart;

// The device has release (or the player went back from it). Asks Steam for the release's
// manifest only when the device's build is not recorded, and records it then.
- (BOOL)isCurrent:(PocketDepotRelease *)release depot:(PocketDepot *)depot;

// The release's version (its Info.plist, fetched alone), for its label.
- (nullable NSString *)versionOfRelease:(PocketDepotRelease *)release depot:(PocketDepot *)depot;

// Fetches the release (what changed only) into its staging folder, complete when this returns
// YES; the game on the device is not touched. Cut short, it resumes the next time.
- (BOOL)stage:(PocketDepotRelease *)release depot:(PocketDepot *)depot progress:(nullable void (^)(int64_t done, int64_t total))progress
    cancelled:(nullable BOOL (^)(void))cancelled error:(NSError **)error;

// A complete staged build waiting for the next start (its manifest, build, published, version),
// or nil.
@property(nonatomic, readonly, nullable) NSDictionary *staged;

// The staged build where the game's is (before the game starts), the one there kept as the
// previous one.
- (BOOL)putStagedInPlace:(NSError **)error;

// The build put in place has started: the previous one goes, with page containers and staged
// builds no longer needed.
- (void)started;

// Back to the previous build (after updateFailedToStart).
- (BOOL)rollBack;
@end

NS_ASSUME_NONNULL_END
