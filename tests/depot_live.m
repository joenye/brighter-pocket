// By hand, against Steam itself, as the account in the environment (POCKET_STEAM_ACCOUNT and
// POCKET_STEAM_REFRESH_TOKEN; tests/depot_live.py fills them from DepotDownloader's remembered
// login, never printing the token): the app's depot code (launcher/Pocket/PocketDepot.m) finds
// the public build of Brighter Shores' macOS depot, lists the open branches, and fetches the
// build into a folder, reusing an existing build's files, or only its small files (--small),
// which downloads and decodes real chunks. It signs in on a session of its own (a random login
// ID): a game played elsewhere on the account is left alone.
//
// With --installed WORK APP, the app's updates (launcher/Pocket/PocketInstalledGame.m) go
// through their steps on a copy of APP (a Brighter Shores.app at Steam's public build) in WORK:
// the build told from its executable, an update put in place (fetching the file the copy lacks),
// a failed start offered back, going back, and an update that starts, clearing what the builds
// before it left; the label as brighter-atlas shows builds.
//
// usage: depot_live [--small] [OUT [EXISTING]] | depot_live --installed WORK APP
#import "PocketInstalledGame.h"

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "depot_live: failed: %s (line %d)\n", #condition, __LINE__); return 1; } } while (0)

static int Installed(PocketDepot *depot, PocketDepotRelease *release, NSString *work, NSString *source) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *documents = [work stringByAppendingPathComponent:@"Documents"], *updates = [work stringByAppendingPathComponent:@"Updates"];
    NSString *app = [documents stringByAppendingPathComponent:@"Brighter Shores/Brighter Shores.app"];
    NSString *lacking = [app stringByAppendingPathComponent:@"Contents/PkgInfo"];
    [files removeItemAtPath:work error:NULL];
    [files createDirectoryAtPath:app.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    CHECK([files copyItemAtPath:source toPath:app error:NULL]);   // APFS clones it
    [files removeItemAtPath:[app stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"] error:NULL];
    CHECK([files removeItemAtPath:lacking error:NULL]);

    PocketInstalledGame *installed = [[PocketInstalledGame alloc] initWithDocuments:documents updates:updates];
    CHECK(installed.build == 0);
    CHECK([installed isCurrent:release depot:depot]);   // told from the executable, and recorded
    CHECK(installed.build == release.buildID && installed.manifest == release.manifestID);
    NSString *label = installed.label;
    CHECK([label isEqualToString:PocketBuildLabel(release.updated, installed.version)] && [label containsString:@" UTC (v"]);
    CHECK([[installed versionOfRelease:release depot:depot] isEqualToString:installed.version]);
    printf("installed: the build told from its executable: %s\n", label.UTF8String);

    // Recorded as an older build: the update fetches what differs (the file the copy lacks).
    NSString *recordPath = [updates stringByAppendingPathComponent:@"installed.json"];
    NSMutableDictionary *record = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:recordPath] options:NSJSONReadingMutableContainers error:NULL];
    record[@"manifest"] = @1;
    record[@"build"] = @1;
    [[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL] writeToFile:recordPath atomically:YES];
    CHECK(![installed isCurrent:release depot:depot]);
    NSError *error = nil;
    CHECK([installed stage:release depot:depot progress:nil cancelled:nil error:&error]);
    CHECK(![files fileExistsAtPath:lacking] && [installed.staged[@"manifest"] unsignedLongLongValue] == release.manifestID);
    CHECK([installed putStagedInPlace:&error] && !installed.staged);
    CHECK([files fileExistsAtPath:lacking] && installed.manifest == release.manifestID);
    CHECK([files fileExistsAtPath:[updates stringByAppendingPathComponent:@"previous/Brighter Shores.app"]]);
    CHECK(![files fileExistsAtPath:[updates stringByAppendingPathComponent:@"current"]]);
    printf("installed: an update put in place, the build before kept\n");

    // Not started: the first try is the update's own, the second offers the build before.
    CHECK(![installed updateFailedToStart]);
    CHECK([installed updateFailedToStart]);
    CHECK([installed rollBack]);
    CHECK(![files fileExistsAtPath:lacking] && installed.build == 1);
    CHECK([installed isCurrent:release depot:depot]);   // the build gone back from is not offered again
    CHECK(![installed updateFailedToStart]);
    printf("installed: a failed start offered back, gone back, not fetched again\n");

    // An update that starts: the build before goes.
    record = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:recordPath] options:NSJSONReadingMutableContainers error:NULL];
    [record removeObjectForKey:@"skip"];
    [[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL] writeToFile:recordPath atomically:YES];
    CHECK([installed stage:release depot:depot progress:nil cancelled:nil error:&error] && [installed putStagedInPlace:&error]);
    // A page container of an executable no longer on the device goes once the new build starts.
    NSString *containers = [documents stringByAppendingPathComponent:@"LocalSigning"];
    NSString *stale = [containers stringByAppendingPathComponent:[@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]];
    [files createDirectoryAtPath:containers withIntermediateDirectories:YES attributes:nil error:NULL];
    CHECK([files createFileAtPath:[stale stringByAppendingPathExtension:@"dylib"] contents:NSData.data attributes:nil]);
    [installed started];
    CHECK(![files fileExistsAtPath:[stale stringByAppendingPathExtension:@"dylib"]]);
    CHECK(![installed updateFailedToStart]);
    CHECK(![files fileExistsAtPath:[updates stringByAppendingPathComponent:@"previous"]]);
    CHECK([installed isCurrent:release depot:depot] && [files fileExistsAtPath:lacking]);
    printf("installed: an update started, the build before removed\n");
    [files removeItemAtPath:work error:NULL];
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *account = environment[@"POCKET_STEAM_ACCOUNT"], *token = environment[@"POCKET_STEAM_REFRESH_TOKEN"];
        if (!account.length || !token.length) { fprintf(stderr, "depot_live: run it through tests/depot_live.py\n"); return 2; }
        BOOL small = argc > 1 && !strcmp(argv[1], "--small"), installed = argc > 3 && !strcmp(argv[1], "--installed");
        int arg = small ? 2 : 1;
        NSString *out = argc > arg ? @(argv[arg]) : nil, *existing = argc > arg + 1 ? @(argv[arg + 1]) : nil;

        PocketSteamClient *client = [PocketSteamClient new];
        NSError *error = nil;
        if (![client connect:&error] || ![client logOnAccount:account refreshToken:token error:&error]) {
            fprintf(stderr, "depot_live: sign-in failed: %s %ld\n", error.domain.UTF8String, (long)error.code);
            return 1;
        }
        PocketDepot *depot = [[PocketDepot alloc] initWithClient:client appID:2791440 depotID:2791442];
        NSArray *branches = [depot branchesWithError:&error];
        PocketDepotRelease *release = branches ? [depot releaseOnBranch:@"public" error:&error] : nil;
        if (!release) { fprintf(stderr, "depot_live: %s\n", error.localizedDescription.UTF8String); [client disconnect]; return 1; }
        uint32_t playing = 0;
        [NSThread sleepForTimeInterval:1];   // the account's playing state comes just after the logon
        printf("playing elsewhere: %s\n", [client playingElsewhere:&playing] ? [NSString stringWithFormat:@"app %u", playing].UTF8String : "no");
        printf("branches: %s\n", [branches componentsJoinedByString:@", "].UTF8String);
        printf("public: build %llu, manifest %llu, updated %s, download %llu bytes, disk %llu bytes\n", release.buildID,
               release.manifestID, release.updated.description.UTF8String ?: "?", release.downloadSize, release.diskSize);
        if (installed) {
            int failed = Installed(depot, release, @(argv[2]), @(argv[3]));
            [client disconnect];
            return failed;
        }
        if (out) {
            __block int64_t shown = -1;
            NSDate *start = NSDate.date;
            BOOL fetched = [depot fetchRelease:release into:out reusing:existing
                include:small ? ^BOOL(NSString *path) { return ![path containsString:@"/MacOS/"] && ![path containsString:@"assetBundle"]; } : nil
                progress:^(int64_t done, int64_t total) {
                    int64_t percent = total ? done * 100 / total : 100;
                    @synchronized (client) { if (percent / 10 != shown / 10) { shown = percent; printf("  %lld%% of %lld bytes\n", percent, total); } }
                } cancelled:nil error:&error];
            printf("fetch: %s in %.0f s%s%s\n", fetched ? "complete, every file verified" : "failed", -start.timeIntervalSinceNow,
                   fetched ? "" : ": ", fetched ? "" : error.localizedDescription.UTF8String);
            [client disconnect];
            return fetched ? 0 : 1;
        }
        [client disconnect];
        return 0;
    }
}
