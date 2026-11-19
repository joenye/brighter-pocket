// By hand (tests/steam_sessions_live.py): one of the account's Steam sessions, as another device would hold
// it, to see what Steam does when two sessions play: the playing session states each is sent, when Steam ends
// one, and what the takeover (PocketSteamClient's takeOverPlaying) does. The account and its refresh token
// come from the environment, never printed.
//
// usage: steam_sessions_live [--play] [--take-over] [--ticket IDENTITY] [--seconds N] [--name NAME]
//   --play        tell Steam this session plays Brighter Shores (its ownership ticket, then games played)
//   --take-over   first, if another session plays, end its game as the app's Play Here does
//   --ticket ID   then ask for a web API ticket for ID, as the game does at its login
//   --seconds N   then stay connected N seconds (default 30), reporting what Steam sends
#import <Foundation/Foundation.h>
#import "PocketSteamClient.h"

static const uint32_t BrighterShores = 2791440;

static void Say(NSString *name, NSString *text) {
    static NSDateFormatter *clock;
    if (!clock) { clock = [NSDateFormatter new]; clock.dateFormat = @"HH:mm:ss.SSS"; }
    printf("%s [%s] %s\n", [clock stringFromDate:[NSDate date]].UTF8String, name.UTF8String, text.UTF8String);
    fflush(stdout);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL play = NO, takeOver = NO;
        NSString *ticket = nil, *name = @"other";
        double seconds = 30;
        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--play"]) play = YES;
            else if ([arg isEqualToString:@"--take-over"]) takeOver = YES;
            else if ([arg isEqualToString:@"--ticket"] && i + 1 < argc) ticket = @(argv[++i]);
            else if ([arg isEqualToString:@"--seconds"] && i + 1 < argc) seconds = atof(argv[++i]);
            else if ([arg isEqualToString:@"--name"] && i + 1 < argc) name = @(argv[++i]);
            else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
        }
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *account = environment[@"POCKET_STEAM_ACCOUNT"], *token = environment[@"POCKET_STEAM_REFRESH_TOKEN"];
        if (!account.length || !token.length) { fprintf(stderr, "no account in the environment\n"); return 2; }

        PocketSteamClient *client = [PocketSteamClient new];
        NSError *error = nil;
        if (![client connect:&error] || ![client logOnAccount:account refreshToken:token error:&error]) {
            Say(name, [NSString stringWithFormat:@"logon failed: %@ %ld", error.domain, (long)error.code]);
            return 1;
        }
        Say(name, @"logged on");
        BOOL heard = [client awaitPlayingState:3];
        uint32_t app = 0;
        BOOL elsewhere = [client playingElsewhere:&app];
        Say(name, [NSString stringWithFormat:@"after 3 s: playing state %@, playing elsewhere %@ (app %u)",
                                             heard ? @"heard" : @"none", elsewhere ? @"yes" : @"no", app]);
        if (takeOver && elsewhere) {
            BOOL free = [client takeOverPlaying:&error];
            Say(name, free ? @"took over: the account is free"
                           : [NSString stringWithFormat:@"take-over failed: %@ %ld", error.domain, (long)error.code]);
        }
        if (play) {
            BOOL started = [client startGame:BrighterShores error:&error];
            Say(name, started ? @"playing Brighter Shores" : [NSString stringWithFormat:@"start failed: %@ %ld", error.domain, (long)error.code]);
        }
        if (ticket) {
            uint32_t crc = 0;
            NSData *made = [client webTicketForIdentity:ticket crc:&crc];
            Say(name, made ? @"web API ticket made" : @"no web API ticket");
        }
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
        BOOL wasOnline = YES;
        while ([end timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.5];
            BOOL online = client.online;
            if (online != wasOnline)
                Say(name, online ? @"online again" : [NSString stringWithFormat:@"offline (Steam's result %d)", client.loggedOffResult]);
            wasOnline = online;
        }
        elsewhere = [client playingElsewhere:&app];
        Say(name, [NSString stringWithFormat:@"done: %@, playing elsewhere %@ (app %u)", client.online ? @"online" : @"offline",
                                             elsewhere ? @"yes" : @"no", app]);
        [client disconnect];
    }
    return 0;
}
