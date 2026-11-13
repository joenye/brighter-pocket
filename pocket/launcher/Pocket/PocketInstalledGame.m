// The build of Brighter Shores on the device and its updates (PocketInstalledGame.h).
#import "PocketInstalledGame.h"
#import <CommonCrypto/CommonDigest.h>

const uint32_t PocketGameAppID = 2791440, PocketGameDepotID = 2791442;
static NSString *const DepotApp = @"x64arm64/Brighter Shores.app";
static NSString *const DepotExecutable = @"x64arm64/Brighter Shores.app/Contents/MacOS/Brighter Shores";
static NSString *const DepotInfo = @"x64arm64/Brighter Shores.app/Contents/Info.plist";
static NSString *const LeftOut = @"x64arm64/Brighter Shores.app/Contents/MacOS/libsteam_api.dylib";   // as install.py leaves it out
static NSString *const GameFolder = @"Brighter Shores", *const AppName = @"Brighter Shores.app";

NSString *PocketBuildLabel(NSDate *published, NSString *version) {
    NSString *date = nil;
    if (published) {
        NSDateFormatter *format = [NSDateFormatter new];
        format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        format.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        format.dateFormat = @"dd-MMM-yyyy HH:mm 'UTC'";
        date = [format stringFromDate:published];
    }
    if (date && version.length) return [NSString stringWithFormat:@"%@ (v%@)", date, version];
    return date ?: (version.length ? [@"v" stringByAppendingString:version] : nil);
}

static NSString *Hex(const uint8_t *bytes, size_t length) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}
// A file's SHA-1 or SHA-256, in hex.
static NSString *FileDigest(NSString *path, BOOL sha256) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    if (stream.streamStatus != NSStreamStatusOpen) return nil;
    CC_SHA1_CTX one;
    CC_SHA256_CTX two;
    sha256 ? CC_SHA256_Init(&two) : CC_SHA1_Init(&one);
    uint8_t buffer[1 << 16];
    NSInteger got;
    while ((got = [stream read:buffer maxLength:sizeof buffer]) > 0)
        sha256 ? CC_SHA256_Update(&two, buffer, (CC_LONG)got) : CC_SHA1_Update(&one, buffer, (CC_LONG)got);
    [stream close];
    if (got < 0) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    sha256 ? CC_SHA256_Final(digest, &two) : CC_SHA1_Final(digest, &one);
    return Hex(digest, sha256 ? CC_SHA256_DIGEST_LENGTH : CC_SHA1_DIGEST_LENGTH);
}
static NSString *VersionOfApp(NSString *app) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *version = info[@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && version.length ? version : nil;
}

@implementation PocketInstalledGame {
    NSString *_documents, *_updates;
}

- (instancetype)initWithDocuments:(NSString *)documents updates:(NSString *)updates {
    if ((self = [super init])) {
        _documents = [documents copy];
        _updates = [updates copy];
        if (![NSFileManager.defaultManager fileExistsAtPath:updates]) {
            [NSFileManager.defaultManager createDirectoryAtPath:updates withIntermediateDirectories:YES attributes:nil error:NULL];
            [[NSURL fileURLWithPath:updates] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
        }
    }
    return self;
}

- (NSString *)app { return [[_documents stringByAppendingPathComponent:GameFolder] stringByAppendingPathComponent:AppName]; }
- (NSString *)executable { return [self.app stringByAppendingPathComponent:@"Contents/MacOS/Brighter Shores"]; }
- (NSString *)previous { return [_updates stringByAppendingPathComponent:@"previous"]; }
- (NSString *)stagingFor:(uint64_t)manifest { return [_updates stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu", manifest]]; }
static NSMutableDictionary *ReadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id record = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] : nil;
    return [record isKindOfClass:NSDictionary.class] ? record : [NSMutableDictionary dictionary];
}
static void WriteJSON(NSString *path, NSDictionary *record) {
    [[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL] writeToFile:path atomically:YES];
}
static NSString *RecordPath(NSString *folder) { return [folder stringByAppendingPathComponent:@"installed.json"]; }
static NSMutableDictionary *ReadRecord(NSString *folder) { return ReadJSON(RecordPath(folder)); }
static void WriteRecord(NSString *folder, NSDictionary *record) { WriteJSON(RecordPath(folder), record); }

- (uint64_t)build { return [ReadRecord(_updates)[@"build"] unsignedLongLongValue]; }
- (uint64_t)manifest { return [ReadRecord(_updates)[@"manifest"] unsignedLongLongValue]; }
- (BOOL)installed { return [NSFileManager.defaultManager fileExistsAtPath:self.executable]; }
- (NSString *)version { return VersionOfApp(self.app); }
- (NSString *)label {
    NSDictionary *record = ReadRecord(_updates);
    NSNumber *published = record[@"published"];
    // The record's date belongs to the build it names: only while the executable is that one.
    BOOL same = [record[@"executable"] isEqual:FileDigest(self.executable, NO)];
    return PocketBuildLabel(same && published ? [NSDate dateWithTimeIntervalSince1970:published.doubleValue] : nil, self.version);
}

static NSDictionary *RecordOf(PocketDepotRelease *release, NSString *executable, NSString *version, BOOL started) {
    NSMutableDictionary *record = [@{@"branch": release.branch, @"build": @(release.buildID), @"manifest": @(release.manifestID),
                                     @"executable": executable ?: @"", @"started": @(started), @"attempts": @0} mutableCopy];
    if (release.updated) record[@"published"] = @(release.updated.timeIntervalSince1970);
    if (version) record[@"version"] = version;
    return record;
}

- (BOOL)updateFailedToStart {
    NSMutableDictionary *record = ReadRecord(_updates);
    if (!record.count || [record[@"started"] boolValue] ||
        ![NSFileManager.defaultManager fileExistsAtPath:[self.previous stringByAppendingPathComponent:AppName]]) return NO;
    NSInteger attempts = [record[@"attempts"] integerValue];
    record[@"attempts"] = @(attempts + 1);
    WriteRecord(_updates, record);
    return attempts >= 1;
}

- (BOOL)isCurrent:(PocketDepotRelease *)release depot:(PocketDepot *)depot {
    NSString *executable = FileDigest(self.executable, NO);
    if (!executable) return NO;
    NSDictionary *record = ReadRecord(_updates);
    // The build the player went back from: kept from until Steam has another.
    if ([record[@"skip"] unsignedLongLongValue] == release.manifestID) return YES;
    // Recorded, and the executable still the one recorded: the record says which build it is
    // (its date and version filled in if an earlier record lacked them, for its label).
    if ([record[@"executable"] isEqual:executable]) {
        BOOL same = [record[@"manifest"] unsignedLongLongValue] == release.manifestID;
        if (same && (!record[@"published"] || !record[@"version"])) {
            NSMutableDictionary *filled = [record mutableCopy];
            if (release.updated) filled[@"published"] = @(release.updated.timeIntervalSince1970);
            if (self.version) filled[@"version"] = self.version;
            WriteRecord(_updates, filled);
        }
        return same;
    }
    // Copied from the Mac, or the record lost: the release's manifest says whether it is that build.
    NSData *wanted = [depot contentSHA1OfPath:DepotExecutable inRelease:release error:NULL];
    if (!wanted || ![Hex(wanted.bytes, wanted.length) isEqualToString:executable]) return NO;
    WriteRecord(_updates, RecordOf(release, executable, self.version, YES));
    return YES;
}

- (NSString *)versionOfRelease:(PocketDepotRelease *)release depot:(PocketDepot *)depot {
    NSDictionary *staged = self.staged;
    if ([staged[@"manifest"] unsignedLongLongValue] == release.manifestID) return staged[@"version"];
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"release-%llu", release.manifestID]];
    BOOL fetched = [depot fetchRelease:release into:scratch reusing:nil include:^BOOL(NSString *path) { return [path isEqualToString:DepotInfo]; }
                              progress:nil cancelled:nil error:NULL];
    NSString *version = fetched ? VersionOfApp([scratch stringByAppendingPathComponent:DepotApp]) : nil;
    [NSFileManager.defaultManager removeItemAtPath:scratch error:NULL];
    return version;
}

- (BOOL)stage:(PocketDepotRelease *)release depot:(PocketDepot *)depot progress:(void (^)(int64_t, int64_t))progress
    cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *staging = [self stagingFor:release.manifestID];
    if ([ReadJSON([staging stringByAppendingPathComponent:@"staged.json"])[@"manifest"] unsignedLongLongValue] == release.manifestID) return YES;
    // Other builds' fetches go; this one's stays, to resume.
    for (NSString *name in [files contentsOfDirectoryAtPath:_updates error:NULL])
        if (name.longLongValue && ![name isEqualToString:staging.lastPathComponent])
            [files removeItemAtPath:[_updates stringByAppendingPathComponent:name] error:NULL];
    NSString *current = [_updates stringByAppendingPathComponent:@"current"];
    [files removeItemAtPath:current error:NULL];
    [files createDirectoryAtPath:current withIntermediateDirectories:YES attributes:nil error:NULL];
    [files createSymbolicLinkAtPath:[current stringByAppendingPathComponent:@"x64arm64"]
                withDestinationPath:[_documents stringByAppendingPathComponent:GameFolder] error:NULL];
    BOOL fetched = [depot fetchRelease:release into:staging reusing:current
                               include:^BOOL(NSString *path) { return [path hasPrefix:DepotApp] && ![path isEqualToString:LeftOut]; }
                              progress:progress cancelled:cancelled error:error];
    [files removeItemAtPath:current error:NULL];
    if (!fetched) return NO;
    NSString *app = [staging stringByAppendingPathComponent:DepotApp];
    NSMutableDictionary *staged = [RecordOf(release, FileDigest([app stringByAppendingPathComponent:@"Contents/MacOS/Brighter Shores"], NO),
                                            VersionOfApp(app), NO) mutableCopy];
    WriteJSON([staging stringByAppendingPathComponent:@"staged.json"], staged);
    return YES;
}

- (NSDictionary *)staged {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:_updates error:NULL]) {
        if (!name.longLongValue) continue;
        NSDictionary *staged = ReadJSON([[_updates stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"staged.json"]);
        if (staged.count) return staged;
    }
    return nil;
}

- (BOOL)putStagedInPlace:(NSError **)error {
    NSDictionary *staged = self.staged;
    if (!staged) return NO;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *staging = [self stagingFor:[staged[@"manifest"] unsignedLongLongValue]];
    NSString *previous = self.previous, *app = self.app, *kept = [previous stringByAppendingPathComponent:AppName];
    [files removeItemAtPath:previous error:NULL];
    [files createDirectoryAtPath:previous withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *record = ReadRecord(_updates);
    if (record.count) WriteRecord(previous, record);
    BOOL had = [files fileExistsAtPath:app];
    if (had && ![files moveItemAtPath:app toPath:kept error:error]) return NO;
    [files createDirectoryAtPath:app.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![files moveItemAtPath:[staging stringByAppendingPathComponent:DepotApp] toPath:app error:error]) {
        if (had) [files moveItemAtPath:kept toPath:app error:NULL];
        return NO;
    }
    [files removeItemAtPath:staging error:NULL];
    if (!had) [files removeItemAtPath:previous error:NULL];
    NSMutableDictionary *now = [staged mutableCopy];
    now[@"started"] = @(!had);
    WriteRecord(_updates, now);
    return YES;
}

// What older builds left: the build before (once this one has started), a build gone back
// from, staged builds that are not newer than this one, and page containers of executables no
// longer on the device.
- (void)clearOldBuilds {
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtPath:self.previous error:NULL];
    [files removeItemAtPath:[_updates stringByAppendingPathComponent:@"failed.app"] error:NULL];
    uint64_t manifest = self.manifest;
    for (NSString *name in [files contentsOfDirectoryAtPath:_updates error:NULL])
        if (name.longLongValue && strtoull(name.UTF8String, NULL, 10) == manifest)
            [files removeItemAtPath:[_updates stringByAppendingPathComponent:name] error:NULL];
    NSString *containers = [_documents stringByAppendingPathComponent:@"LocalSigning"], *keep = FileDigest(self.executable, YES);
    if (!keep) return;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet;
    for (NSString *name in [files contentsOfDirectoryAtPath:containers error:NULL]) {
        NSString *sha = name.stringByDeletingPathExtension;
        if (![name.pathExtension isEqualToString:@"dylib"] || sha.length != 64 || [sha rangeOfCharacterFromSet:hex].location != NSNotFound) continue;
        if (![sha isEqualToString:keep]) [files removeItemAtPath:[containers stringByAppendingPathComponent:name] error:NULL];
    }
}

- (void)started {
    NSMutableDictionary *record = ReadRecord(_updates);
    if (record.count && ![record[@"started"] boolValue]) {
        record[@"started"] = @YES;
        [record removeObjectForKey:@"attempts"];
        WriteRecord(_updates, record);
    }
    [self clearOldBuilds];
}

- (BOOL)rollBack {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *previous = self.previous, *app = self.app, *aside = [_updates stringByAppendingPathComponent:@"failed.app"];
    [files removeItemAtPath:aside error:NULL];
    if (![files moveItemAtPath:app toPath:aside error:NULL]) return NO;
    if (![files moveItemAtPath:[previous stringByAppendingPathComponent:AppName] toPath:app error:NULL]) {
        [files moveItemAtPath:aside toPath:app error:NULL];
        return NO;
    }
    NSNumber *failed = ReadRecord(_updates)[@"manifest"];
    NSMutableDictionary *record = ReadRecord(previous);   // empty if it had none: told from the executable next time
    record[@"started"] = @YES;
    [record removeObjectForKey:@"attempts"];
    if (failed) record[@"skip"] = failed;
    WriteRecord(_updates, record);
    [files removeItemAtPath:previous error:NULL];
    [files removeItemAtPath:aside error:NULL];
    return YES;
}
@end
