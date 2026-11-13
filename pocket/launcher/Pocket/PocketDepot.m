// A game's depot from Steam's content system (PocketDepot.h), as the Steam client and
// DepotDownloader fetch it:
//
//   product info (PICS, with the app's access token) -> the branch's build ID and the depot's
//   manifest ID; the depot key (ClientGetDepotDecryptionKey); a manifest request code
//   (ContentServerDirectory.GetManifestRequestCode); the content servers
//   (ContentServerDirectory.GetServersForSteamPipe); then over HTTPS the manifest (a zip holding
//   the file list, its file names AES-encrypted with the depot key) and each chunk the build
//   needs (AES with the depot key, then zstd or LZMA in Valve's framings), each chunk's SHA-1
//   checked, and each file's.
//
// zstd is the zstd project's reference decoder (PocketZstd.c); LZMA the system's liblzma (in iOS
// and macOS, without a public header), opened by name; zip's deflate the Compression framework.
#import "PocketDepot.h"
#include "PocketZstd.h"
#import <CommonCrypto/CommonCrypto.h>
#import <compression.h>
#include <copyfile.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const PocketDepotErrorDomain = @"PocketDepot";

enum {   // EMsg
    MsgPICSProductInfoRequest = 8903,
    MsgPICSAccessTokenRequest = 8905,
    MsgGetDepotDecryptionKey = 5438,
};
enum { FileFlagExecutable = 32, FileFlagDirectory = 64, FileFlagSymlink = 512 };
static const int Parallel = 8;              // chunks in flight at once
static const NSTimeInterval ChunkWait = 60; // for one chunk from one server
static const int Attempts = 4;              // servers tried for one request

static NSError *DepotError(PocketDepotError code, NSString *what) {
    return [NSError errorWithDomain:PocketDepotErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: what}];
}
static NSData *Proto(PocketProto *proto) {
    NSData *data = proto->failed ? nil : [NSData dataWithBytes:proto->data length:proto->size];
    pocket_proto_free(proto);
    return data ?: [NSData data];
}
static uint64_t Number(NSData *message, unsigned field) {
    PocketField found;
    return message && pocket_proto_find(message.bytes, message.length, field, &found) && found.wire != 2 ? found.value : 0;
}
static NSData *Bytes(NSData *message, unsigned field) {
    PocketField found;
    return message && pocket_proto_find(message.bytes, message.length, field, &found) && found.wire == 2
        ? [NSData dataWithBytes:found.data length:found.size] : nil;
}
static NSString *String(NSData *message, unsigned field) {
    NSData *bytes = Bytes(message, field);
    return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
}
// Every field with this number, as messages.
static NSArray<NSData *> *Repeated(NSData *message, unsigned number) {
    NSMutableArray *found = [NSMutableArray array];
    const uint8_t *position = message.bytes, *end = position + message.length;
    PocketField field;
    while (pocket_proto_next(&position, end, &field) == 1)
        if (field.field == number && field.wire == 2) [found addObject:[NSData dataWithBytes:field.data length:field.size]];
    return found;
}
static NSString *Hex(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}
static NSData *SHA1(const void *bytes, size_t size) {
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(bytes, (CC_LONG)size, digest);
    return [NSData dataWithBytes:digest length:sizeof digest];
}
static NSData *FileSHA1(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    uint8_t buffer[1 << 16];
    ssize_t read_size;
    while ((read_size = read(fd, buffer, sizeof buffer)) > 0) CC_SHA1_Update(&context, buffer, (CC_LONG)read_size);
    close(fd);
    if (read_size < 0) return nil;
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

// --- KeyValues ------------------------------------------------------------------------------
typedef struct { const uint8_t *at, *end; } Cursor;
static void SkipSpace(Cursor *c) {
    for (;;) {
        while (c->at < c->end && (*c->at == ' ' || *c->at == '\t' || *c->at == '\r' || *c->at == '\n')) c->at++;
        if (c->end - c->at >= 2 && c->at[0] == '/' && c->at[1] == '/') { while (c->at < c->end && *c->at != '\n') c->at++; continue; }
        return;
    }
}
static NSString *Token(Cursor *c) {
    SkipSpace(c);
    if (c->at >= c->end || *c->at == '{' || *c->at == '}' || *c->at == 0) return nil;
    NSMutableData *text = [NSMutableData data];
    if (*c->at == '"') {
        c->at++;
        while (c->at < c->end && *c->at != '"') {
            uint8_t ch = *c->at++;
            if (ch == '\\' && c->at < c->end) {
                uint8_t escaped = *c->at++;
                ch = escaped == 'n' ? '\n' : escaped == 't' ? '\t' : escaped;
            }
            [text appendBytes:&ch length:1];
        }
        if (c->at >= c->end) return nil;
        c->at++;
    } else {
        while (c->at < c->end && !strchr(" \t\r\n{}\"", *c->at) && *c->at) [text appendBytes:c->at++ length:1];
    }
    return [[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding] ?: @"";
}
static NSDictionary *Block(Cursor *c, int depth) {
    if (depth > 32) return nil;
    NSMutableDictionary *block = [NSMutableDictionary dictionary];
    for (;;) {
        SkipSpace(c);
        if (c->at >= c->end || *c->at == 0) return depth ? nil : block;
        if (*c->at == '}') { c->at++; return depth ? block : nil; }
        NSString *key = Token(c);
        if (!key) return nil;
        SkipSpace(c);
        if (c->at < c->end && *c->at == '{') {
            c->at++;
            NSDictionary *child = Block(c, depth + 1);
            if (!child) return nil;
            block[key] = child;
        } else {
            NSString *value = Token(c);
            if (!value) return nil;
            block[key] = value;
        }
    }
}
NSDictionary *PocketKeyValues(NSData *text) {
    Cursor c = {text.bytes, (const uint8_t *)text.bytes + text.length};
    return Block(&c, 0);
}
static id Path(NSDictionary *root, NSArray<NSString *> *keys) {
    id node = root;
    for (NSString *key in keys) node = [node isKindOfClass:NSDictionary.class] ? node[key] : nil;
    return node;
}

// --- AES, LZMA, zip ---------------------------------------------------------------------------------
// Steam's symmetric scheme: the first block is the IV, encrypted (ECB); the rest is CBC, PKCS #7.
static NSData *Decrypt(NSData *input, NSData *key) {
    if (input.length < 32 || input.length % 16 || key.length != 32) return nil;
    uint8_t iv[16];
    size_t moved = 0;
    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionECBMode, key.bytes, key.length, NULL, input.bytes, 16, iv, 16, &moved) != kCCSuccess) return nil;
    NSMutableData *plain = [NSMutableData dataWithLength:input.length];
    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, key.length, iv,
                (const uint8_t *)input.bytes + 16, input.length - 16, plain.mutableBytes, plain.length, &moved) != kCCSuccess) return nil;
    plain.length = moved;
    return plain;
}

// liblzma's stream, as liblzma 5 lays it out.
typedef struct {
    const uint8_t *next_in; size_t avail_in; uint64_t total_in;
    uint8_t *next_out; size_t avail_out; uint64_t total_out;
    const void *allocator; void *internal;
    void *reserved_ptr1, *reserved_ptr2, *reserved_ptr3, *reserved_ptr4;
    uint64_t reserved_int1, reserved_int2;
    size_t reserved_int3, reserved_int4;
    int reserved_enum1, reserved_enum2;
} LZMAStream;
static int (*lzmaAloneDecoder)(LZMAStream *, uint64_t);
static int (*lzmaCode)(LZMAStream *, int);
static void (*lzmaEnd)(LZMAStream *);
static BOOL LoadLZMA(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/usr/lib/liblzma.5.dylib", RTLD_LAZY);
        if (!library) return;
        lzmaAloneDecoder = (int (*)(LZMAStream *, uint64_t))dlsym(library, "lzma_alone_decoder");
        lzmaCode = (int (*)(LZMAStream *, int))dlsym(library, "lzma_code");
        lzmaEnd = (void (*)(LZMAStream *))dlsym(library, "lzma_end");
    });
    return lzmaAloneDecoder && lzmaCode && lzmaEnd;
}
// VZip: "VZ", 'a', a 4-byte stamp, 5 LZMA property bytes, the LZMA data, then a CRC-32, the
// size, and "zv". Decoded as an LZMA "alone" stream: the properties and the size, then the data.
static NSData *UnVZip(NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t length = data.length;
    if (length < 22 || bytes[0] != 'V' || bytes[1] != 'Z' || bytes[2] != 'a' || bytes[length - 2] != 'z' || bytes[length - 1] != 'v' || !LoadLZMA()) return nil;
    uint32_t size = (uint32_t)bytes[length - 6] | (uint32_t)bytes[length - 5] << 8 | (uint32_t)bytes[length - 4] << 16 | (uint32_t)bytes[length - 3] << 24;
    NSMutableData *alone = [NSMutableData dataWithBytes:bytes + 7 length:5];
    uint64_t size64 = size;
    for (int i = 0; i < 8; i++) { uint8_t b = (uint8_t)(size64 >> (8 * i)); [alone appendBytes:&b length:1]; }
    [alone appendBytes:bytes + 12 length:length - 22];
    NSMutableData *out = [NSMutableData dataWithLength:size];
    LZMAStream stream;
    memset(&stream, 0, sizeof stream);
    if (lzmaAloneDecoder(&stream, UINT64_MAX) != 0) return nil;
    stream.next_in = alone.bytes; stream.avail_in = alone.length;
    stream.next_out = out.mutableBytes; stream.avail_out = out.length;
    int result = lzmaCode(&stream, 3 /* LZMA_FINISH */);
    BOOL whole = (result == 1 /* LZMA_STREAM_END */ || result == 0) && stream.total_out == size;
    lzmaEnd(&stream);
    return whole ? out : nil;
}
// VZstd: "VSZa", a CRC-32, one zstd frame, then 15 bytes of footer (the CRC-32, the size as
// 8 bytes, "zsv"). zstd: the zstd project's reference decoder (PocketZstd.c).
static NSData *UnVZstd(NSData *data, uint32_t size) {
    const uint8_t *bytes = data.bytes;
    size_t length = data.length;
    if (length < 8 + 15 || memcmp(bytes, "VSZa", 4) || memcmp(bytes + length - 3, "zsv", 3)) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:size];
    return pocket_zstd_decompress(out.mutableBytes, size, bytes + 8, length - 8 - 15) == size ? out : nil;
}
// The one file in a zip (the manifest's, and old depots' chunks): its central directory entry
// gives the sizes, its local header where the data starts.
static NSData *Unzip(NSData *zip) {
    const uint8_t *bytes = zip.bytes;
    size_t length = zip.length;
    if (length < 22) return nil;
    size_t end = length - 22;
    while (end > 0 && !(bytes[end] == 'P' && bytes[end + 1] == 'K' && bytes[end + 2] == 5 && bytes[end + 3] == 6)) end--;
    #define LE16(p) ((uint32_t)(p)[0] | (uint32_t)(p)[1] << 8)
    #define LE32(p) ((uint32_t)(p)[0] | (uint32_t)(p)[1] << 8 | (uint32_t)(p)[2] << 16 | (uint32_t)(p)[3] << 24)
    if (bytes[end] != 'P') return nil;
    uint32_t directory = LE32(bytes + end + 16);
    if ((size_t)directory + 46 > length || LE32(bytes + directory) != 0x02014b50) return nil;
    uint32_t method = LE16(bytes + directory + 10), packed = LE32(bytes + directory + 20), size = LE32(bytes + directory + 24);
    uint32_t local = LE32(bytes + directory + 42);
    if ((size_t)local + 30 > length || LE32(bytes + local) != 0x04034b50) return nil;
    size_t start = (size_t)local + 30 + LE16(bytes + local + 26) + LE16(bytes + local + 28);
    if (start + packed > length) return nil;
    #undef LE16
    #undef LE32
    if (method == 0) return packed == size ? [NSData dataWithBytes:bytes + start length:size] : nil;
    if (method != 8) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:size ? size : 1];
    size_t made = compression_decode_buffer(out.mutableBytes, out.length, bytes + start, packed, NULL, COMPRESSION_ZLIB);
    if (made != size) return nil;
    out.length = size;
    return out;
}

// --- the manifest -----------------------------------------------------------------------------------
@interface DepotChunk : NSObject
@property(nonatomic) NSData *sha;
@property(nonatomic) uint64_t offset;
@property(nonatomic) uint32_t size;
@end
@implementation DepotChunk
@end
@interface DepotFile : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) uint64_t size;
@property(nonatomic) uint32_t flags;
@property(nonatomic) NSData *sha;
@property(nonatomic) NSArray<DepotChunk *> *chunks;
@property(nonatomic, copy, nullable) NSString *link;
@end
@implementation DepotFile
@end

@implementation PocketDepotRelease
- (instancetype)initWithBranch:(NSString *)branch build:(uint64_t)build manifest:(uint64_t)manifest updated:(NSDate *)updated
                      download:(uint64_t)download disk:(uint64_t)disk {
    if ((self = [super init])) {
        _branch = [branch copy]; _buildID = build; _manifestID = manifest; _updated = updated;
        _downloadSize = download; _diskSize = disk;
    }
    return self;
}
@end

@implementation PocketDepot {
    PocketSteamClient *_client;
    uint32_t _app, _depot;
    NSDictionary *_appInfo;
    NSData *_key;
    NSArray<NSString *> *_servers;
    NSURLSession *_http;
    NSMutableDictionary<NSNumber *, NSArray<DepotFile *> *> *_manifests;   // by manifest ID
}

- (instancetype)initWithClient:(PocketSteamClient *)client appID:(uint32_t)appID depotID:(uint32_t)depotID {
    if ((self = [super init])) {
        _client = client; _app = appID; _depot = depotID;
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = ChunkWait;
        configuration.HTTPMaximumConnectionsPerHost = Parallel;
        _http = [NSURLSession sessionWithConfiguration:configuration];
        _manifests = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)dealloc { [_http finishTasksAndInvalidate]; }

// The app's product info (PICS), with the access token Steam gives an owner.
- (NSDictionary *)appInfo:(NSError **)error {
    if (_appInfo) return _appInfo;
    PocketProto tokenRequest = {0};
    pocket_proto_uint(&tokenRequest, 2, _app);
    NSArray *tokenReplies = [_client request:MsgPICSAccessTokenRequest body:Proto(&tokenRequest) error:error until:nil];
    if (!tokenReplies) return nil;
    uint64_t token = 0;
    for (NSData *entry in Repeated(tokenReplies.firstObject, 3)) if (Number(entry, 1) == _app) token = Number(entry, 2);
    PocketProto app = {0}, request = {0};
    pocket_proto_uint(&app, 1, _app);
    if (token) pocket_proto_uint(&app, 2, token);
    pocket_proto_message(&request, 2, &app);
    pocket_proto_free(&app);
    NSArray<NSData *> *replies = [_client request:MsgPICSProductInfoRequest body:Proto(&request) error:error
                                            until:^BOOL(NSData *reply) { return Number(reply, 6) == 0; }];   // response_pending
    if (!replies) return nil;
    for (NSData *reply in replies)
        for (NSData *entry in Repeated(reply, 1)) {
            if (Number(entry, 1) != _app) continue;
            NSData *buffer = Bytes(entry, 5);
            if (!buffer.length) {   // a large app's info comes over HTTP instead
                NSString *host = String(reply, 8);
                NSData *sha = Bytes(entry, 4);
                if (host.length && sha.length) {
                    NSString *url = [NSString stringWithFormat:@"https://%@/appinfo/%u/sha/%@.txt.gz", host, _app, Hex(sha)];
                    NSData *gz = [self get:[NSURL URLWithString:url] error:error];
                    buffer = gz ? [self gunzip:gz] : nil;
                }
            }
            NSDictionary *parsed = buffer ? PocketKeyValues(buffer) : nil;
            _appInfo = parsed[@"appinfo"] ?: parsed;
            if (_appInfo) return _appInfo;
        }
    if (error) *error = DepotError(PocketDepotErrorNotOwned, @"Steam gave no product information for the game");
    return nil;
}
- (NSData *)gunzip:(NSData *)gz {
    const uint8_t *bytes = gz.bytes;
    if (gz.length < 18 || bytes[0] != 0x1f || bytes[1] != 0x8b || bytes[2] != 8) return nil;
    size_t start = 10;
    if (bytes[3] & 4) start += 2 + ((size_t)bytes[10] | (size_t)bytes[11] << 8);
    if (bytes[3] & 8) { while (start < gz.length && bytes[start]) start++; start++; }
    if (bytes[3] & 16) { while (start < gz.length && bytes[start]) start++; start++; }
    if (bytes[3] & 2) start += 2;
    uint32_t size = (uint32_t)bytes[gz.length - 4] | (uint32_t)bytes[gz.length - 3] << 8 | (uint32_t)bytes[gz.length - 2] << 16 | (uint32_t)bytes[gz.length - 1] << 24;
    if (start >= gz.length - 8) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:size ? size : 1];
    size_t made = compression_decode_buffer(out.mutableBytes, out.length, bytes + start, gz.length - 8 - start, NULL, COMPRESSION_ZLIB);
    if (made != size) return nil;
    out.length = size;
    return out;
}

- (NSArray<NSString *> *)branchesWithError:(NSError **)error {
    NSDictionary *info = [self appInfo:error];
    if (!info) return nil;
    NSDictionary *branches = Path(info, @[@"depots", @"branches"]);
    NSMutableArray *open = [NSMutableArray array];
    for (NSString *name in [branches.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *branch = branches[name];
        if (![branch isKindOfClass:NSDictionary.class] || [branch[@"pwdrequired"] intValue]) continue;
        if (Path(info, @[@"depots", [NSString stringWithFormat:@"%u", _depot], @"manifests", name]))
            [open addObject:name];
    }
    [open removeObject:@"public"];
    if (Path(info, @[@"depots", [NSString stringWithFormat:@"%u", _depot], @"manifests", @"public"])) [open insertObject:@"public" atIndex:0];
    return open;
}

- (PocketDepotRelease *)releaseOnBranch:(NSString *)branch error:(NSError **)error {
    NSDictionary *info = [self appInfo:error];
    if (!info) return nil;
    NSDictionary *branchInfo = Path(info, @[@"depots", @"branches", branch]);
    id manifest = Path(info, @[@"depots", [NSString stringWithFormat:@"%u", _depot], @"manifests", branch]);
    // Newer product info names the manifest's sizes beside its ID; older, the ID alone.
    NSString *gid = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"gid"] : manifest;
    if (![gid isKindOfClass:NSString.class] || ![branchInfo isKindOfClass:NSDictionary.class]) {
        if (error) *error = DepotError(PocketDepotErrorNoRelease, [NSString stringWithFormat:@"Steam lists no build of the game on the branch %@", branch]);
        return nil;
    }
    NSString *updated = branchInfo[@"timeupdated"];
    return [[PocketDepotRelease alloc] initWithBranch:branch build:strtoull([branchInfo[@"buildid"] UTF8String] ?: "0", NULL, 10)
        manifest:strtoull(gid.UTF8String, NULL, 10) updated:updated ? [NSDate dateWithTimeIntervalSince1970:updated.doubleValue] : nil
        download:[manifest isKindOfClass:NSDictionary.class] ? strtoull([manifest[@"download"] UTF8String] ?: "0", NULL, 10) : 0
            disk:[manifest isKindOfClass:NSDictionary.class] ? strtoull([manifest[@"size"] UTF8String] ?: "0", NULL, 10) : 0];
}

// --- the content servers -------------------------------------------------------------------------
- (NSData *)depotKey:(NSError **)error {
    if (_key) return _key;
    PocketProto request = {0};
    pocket_proto_uint(&request, 1, _depot);
    pocket_proto_uint(&request, 2, _app);
    NSArray *replies = [_client request:MsgGetDepotDecryptionKey body:Proto(&request) error:error until:nil];
    NSData *reply = replies.firstObject;
    uint64_t result = Number(reply, 1);
    NSData *key = Bytes(reply, 3);
    if (!reply) return nil;
    if (result != 1 || key.length != 32) {
        if (error) *error = DepotError(PocketDepotErrorNotOwned, [NSString stringWithFormat:@"Steam gave no key for the game's files (error %llu)", result]);
        return nil;
    }
    return _key = key;
}
- (NSArray<NSString *> *)servers:(NSError **)error {
    if (_servers.count) return _servers;
    PocketProto request = {0};
    pocket_proto_uint(&request, 1, 0);    // cell_id: Steam picks
    pocket_proto_uint(&request, 2, 20);   // max_servers
    NSData *reply = [_client call:@"ContentServerDirectory.GetServersForSteamPipe#1" body:Proto(&request) error:error];
    if (!reply) return nil;
    NSMutableArray *hosts = [NSMutableArray array];
    for (NSData *server in Repeated(reply, 1)) {
        NSString *type = String(server, 1), *host = String(server, 9) ?: String(server, 8), *https = String(server, 12);
        if (!host.length || ![@[@"SteamCache", @"CDN"] containsObject:type ?: @""] || [https isEqualToString:@"none"]) continue;
        NSArray *allowed = nil;   // a server only for some apps lists them (allowed_app_ids)
        const uint8_t *position = server.bytes, *end = position + server.length;
        PocketField field;
        NSMutableArray *apps = [NSMutableArray array];
        while (pocket_proto_next(&position, end, &field) == 1) if (field.field == 13 && field.wire == 0) [apps addObject:@(field.value)];
        allowed = apps;
        if (allowed.count && ![allowed containsObject:@(_app)]) continue;
        [hosts addObject:host];
    }
    if (!hosts.count) {
        if (error) *error = DepotError(PocketDepotErrorNoServers, @"Steam named no content server to download from");
        return nil;
    }
    return _servers = hosts;
}
- (NSData *)get:(NSURL *)url error:(NSError **)error {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *body;
    __block NSError *failure;
    [[_http dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!taskError && status == 200) body = data;
        else failure = taskError ?: DepotError(PocketDepotErrorNetwork, [NSString stringWithFormat:@"a content server answered %ld", (long)status]);
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);   // the session's own timeout ends it
    if (!body && error) *error = failure;
    return body;
}
// The path from each server in turn (a different first one for each request), until one answers.
- (NSData *)fetch:(NSString *)path error:(NSError **)error {
    NSArray<NSString *> *hosts = [self servers:error];
    if (!hosts) return nil;
    NSUInteger first = arc4random_uniform((uint32_t)hosts.count);
    NSError *last = nil;
    for (int attempt = 0; attempt < Attempts; attempt++) {
        NSString *host = hosts[(first + attempt) % hosts.count];
        NSData *body = [self get:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/%@", host, path]] error:&last];
        if (body) return body;
    }
    if (error) *error = DepotError(PocketDepotErrorNetwork, [NSString stringWithFormat:@"Steam's content servers did not answer (%@)", last.localizedDescription]);
    return nil;
}

- (NSArray<DepotFile *> *)manifest:(PocketDepotRelease *)release error:(NSError **)error {
    NSArray<DepotFile *> *known = _manifests[@(release.manifestID)];
    if (known) return known;
    NSData *key = [self depotKey:error];
    if (!key) return nil;
    PocketProto request = {0};
    pocket_proto_uint(&request, 1, _app);
    pocket_proto_uint(&request, 2, _depot);
    pocket_proto_uint(&request, 3, release.manifestID);
    pocket_proto_string(&request, 4, release.branch.UTF8String);
    NSData *reply = [_client call:@"ContentServerDirectory.GetManifestRequestCode#1" body:Proto(&request) error:error];
    if (!reply) return nil;
    uint64_t code = Number(reply, 1);
    NSString *path = code ? [NSString stringWithFormat:@"depot/%u/manifest/%llu/5/%llu", _depot, release.manifestID, code]
                          : [NSString stringWithFormat:@"depot/%u/manifest/%llu/5", _depot, release.manifestID];
    NSData *zip = [self fetch:path error:error];
    NSData *manifest = zip ? Unzip(zip) : nil;
    if (zip && !manifest) { if (error) *error = DepotError(PocketDepotErrorCorrupt, @"the build's file list could not be read"); return nil; }
    if (!manifest) return nil;
    // Sections: a magic and a length each; the payload (the files) and the metadata matter here.
    NSData *payload = nil, *metadata = nil;
    const uint8_t *bytes = manifest.bytes;
    size_t at = 0;
    while (at + 4 <= manifest.length) {
        uint32_t magic = (uint32_t)bytes[at] | (uint32_t)bytes[at + 1] << 8 | (uint32_t)bytes[at + 2] << 16 | (uint32_t)bytes[at + 3] << 24;
        if (magic == 0x32C415AB || at + 8 > manifest.length) break;   // the end
        uint32_t length = (uint32_t)bytes[at + 4] | (uint32_t)bytes[at + 5] << 8 | (uint32_t)bytes[at + 6] << 16 | (uint32_t)bytes[at + 7] << 24;
        if (at + 8 + length > manifest.length) break;
        NSData *section = [NSData dataWithBytes:bytes + at + 8 length:length];
        if (magic == 0x71F617D0) payload = section;
        else if (magic == 0x1F4812BE) metadata = section;
        at += 8 + length;
    }
    if (!payload) { if (error) *error = DepotError(PocketDepotErrorCorrupt, @"the build's file list has no files"); return nil; }
    BOOL encrypted = Number(metadata, 4) != 0;
    NSMutableArray<DepotFile *> *files = [NSMutableArray array];
    for (NSData *mapping in Repeated(payload, 1)) {
        DepotFile *file = [DepotFile new];
        NSString *name = String(mapping, 1);
        if (encrypted) {
            NSData *sealed = [[NSData alloc] initWithBase64EncodedString:name ?: @"" options:NSDataBase64DecodingIgnoreUnknownCharacters];
            NSData *plain = sealed ? Decrypt(sealed, key) : nil;
            name = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
            name = [name stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
        }
        name = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (!name.length || [name hasPrefix:@"/"] || [name containsString:@"../"] || [name isEqualToString:@".."] || [name hasSuffix:@"/.."]) {
            if (error) *error = DepotError(PocketDepotErrorCorrupt, @"the build's file list names a file outside the game");
            return nil;
        }
        file.path = name;
        file.size = Number(mapping, 2);
        file.flags = (uint32_t)Number(mapping, 3);
        file.sha = Bytes(mapping, 5);
        file.link = String(mapping, 7);
        NSMutableArray *chunks = [NSMutableArray array];
        for (NSData *data in Repeated(mapping, 6)) {
            DepotChunk *chunk = [DepotChunk new];
            chunk.sha = Bytes(data, 1);
            chunk.offset = Number(data, 3);
            chunk.size = (uint32_t)Number(data, 4);
            if (chunk.sha.length != 20 || chunk.offset + chunk.size > file.size) {
                if (error) *error = DepotError(PocketDepotErrorCorrupt, @"the build's file list is malformed");
                return nil;
            }
            [chunks addObject:chunk];
        }
        file.chunks = [chunks sortedArrayUsingComparator:^NSComparisonResult(DepotChunk *a, DepotChunk *b) {
            return a.offset < b.offset ? NSOrderedAscending : a.offset > b.offset ? NSOrderedDescending : NSOrderedSame; }];
        [files addObject:file];
    }
    _manifests[@(release.manifestID)] = files;
    return files;
}

- (NSData *)contentSHA1OfPath:(NSString *)depotPath inRelease:(PocketDepotRelease *)release error:(NSError **)error {
    NSArray<DepotFile *> *files = [self manifest:release error:error];
    for (DepotFile *file in files) if ([file.path isEqualToString:depotPath]) return file.sha;
    if (files && error) *error = DepotError(PocketDepotErrorNoRelease, [NSString stringWithFormat:@"the build has no %@", depotPath]);
    return nil;
}

// One chunk, from the servers: decrypted, decompressed, its SHA-1 checked.
- (NSData *)chunk:(DepotChunk *)chunk error:(NSError **)error {
    NSData *sealed = [self fetch:[NSString stringWithFormat:@"depot/%u/chunk/%@", _depot, Hex(chunk.sha)] error:error];
    if (!sealed) return nil;
    NSData *packed = Decrypt(sealed, _key);
    const uint8_t *head = packed.bytes;
    NSData *plain = packed.length >= 4 && head[0] == 'V' && head[1] == 'Z' ? UnVZip(packed)
                  : packed.length >= 4 && head[0] == 'V' && head[1] == 'S' ? UnVZstd(packed, chunk.size)
                  : packed.length >= 4 && head[0] == 'P' && head[1] == 'K' ? Unzip(packed) : nil;
    if (!plain || plain.length != chunk.size || ![SHA1(plain.bytes, plain.length) isEqualToData:chunk.sha]) {
        if (error) *error = DepotError(PocketDepotErrorCorrupt, @"a downloaded chunk did not verify");
        return nil;
    }
    return plain;
}

// --- fetching a build ------------------------------------------------------------------------------
- (BOOL)fetchRelease:(PocketDepotRelease *)release into:(NSString *)staging reusing:(NSString *)existing
             include:(BOOL (^)(NSString *))include progress:(void (^)(int64_t, int64_t))progress
           cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    NSArray<DepotFile *> *all = [self manifest:release error:error];
    if (!all) return NO;
    NSMutableArray<DepotFile *> *files = [NSMutableArray array];
    for (DepotFile *file in all) if (!include || include(file.path)) [files addObject:file];
    NSFileManager *manager = NSFileManager.defaultManager;
    int64_t total = 0;
    for (DepotFile *file in files) total += (int64_t)file.size;
    __block _Atomic int64_t done = 0;
    void (^advance)(int64_t) = ^(int64_t bytes) {
        int64_t now = atomic_fetch_add(&done, bytes) + bytes;
        if (progress) progress(now, total);
    };
    if (progress) progress(0, total);

    // What needs writing (not already in staging or the existing build), against free space.
    NSMutableArray<DepotFile *> *work = [NSMutableArray array];
    int64_t toWrite = 0;
    for (DepotFile *file in files) {
        if (file.flags & (FileFlagDirectory | FileFlagSymlink)) continue;
        NSString *staged = [staging stringByAppendingPathComponent:file.path];
        NSDictionary *attributes = [manager attributesOfItemAtPath:staged error:NULL];
        if (attributes && attributes.fileSize == file.size && [FileSHA1(staged) isEqualToData:file.sha]) { advance((int64_t)file.size); continue; }
        [work addObject:file];
        toWrite += (int64_t)file.size;
    }
    NSNumber *free = [manager attributesOfFileSystemForPath:NSHomeDirectory() error:NULL][NSFileSystemFreeSize];
    if (free && free.longLongValue < toWrite + (64 << 20)) {
        if (error) *error = DepotError(PocketDepotErrorNoSpace, [NSString stringWithFormat:@"the update needs %.1f GB free on this device",
                                                                  (toWrite + (64 << 20)) / 1e9]);
        return NO;
    }
    for (DepotFile *file in files) {
        NSString *path = [staging stringByAppendingPathComponent:file.path];
        if (file.flags & FileFlagDirectory) [manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
        else if (file.flags & FileFlagSymlink && file.link.length) {
            [manager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            [manager removeItemAtPath:path error:NULL];
            [manager createSymbolicLinkAtPath:path withDestinationPath:file.link error:NULL];
        }
    }
    if (work.count && ![self depotKey:error]) return NO;
    for (DepotFile *file in work) {
        if (cancelled && cancelled()) { if (error) *error = DepotError(PocketDepotErrorCancelled, @"the download was stopped"); return NO; }
        if (![self writeFile:file staging:staging existing:existing advance:advance cancelled:cancelled error:error]) return NO;
    }
    return YES;
}

// One file: cloned whole from the existing build when it is the same; otherwise each chunk from
// the existing file where its bytes match there, else from the servers, several at once.
- (BOOL)writeFile:(DepotFile *)file staging:(NSString *)staging existing:(NSString *)existing
          advance:(void (^)(int64_t))advance cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *target = [staging stringByAppendingPathComponent:file.path];
    NSString *partial = [target stringByAppendingString:@".part"];
    NSString *old = existing ? [existing stringByAppendingPathComponent:file.path] : nil;
    [manager createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [manager removeItemAtPath:partial error:NULL];
    mode_t mode = file.flags & FileFlagExecutable ? 0755 : 0644;
    NSDictionary *oldAttributes = old ? [manager attributesOfItemAtPath:old error:NULL] : nil;
    if (oldAttributes.fileSize == file.size && [FileSHA1(old) isEqualToData:file.sha] &&
        copyfile(old.fileSystemRepresentation, partial.fileSystemRepresentation, NULL, COPYFILE_CLONE) == 0) {
        chmod(partial.fileSystemRepresentation, mode);
        [manager removeItemAtPath:target error:NULL];
        if (rename(partial.fileSystemRepresentation, target.fileSystemRepresentation) == 0) { advance((int64_t)file.size); return YES; }
    }
    int fd = open(partial.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, mode);
    if (fd < 0 || ftruncate(fd, (off_t)file.size) != 0) {
        if (fd >= 0) close(fd);
        if (error) *error = DepotError(PocketDepotErrorFiles, [NSString stringWithFormat:@"%@ could not be written", file.path]);
        return NO;
    }
    int oldFD = oldAttributes ? open(old.fileSystemRepresentation, O_RDONLY) : -1;
    __block NSError *failure = nil;
    __block _Atomic bool failed = false;
    dispatch_semaphore_t slots = dispatch_semaphore_create(Parallel);
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    for (DepotChunk *chunk in file.chunks) {
        if (atomic_load(&failed) || (cancelled && cancelled())) break;
        // The same bytes at the same place in the existing file: no download.
        if (oldFD >= 0 && chunk.offset + chunk.size <= oldAttributes.fileSize) {
            NSMutableData *here = [NSMutableData dataWithLength:chunk.size];
            if (pread(oldFD, here.mutableBytes, chunk.size, (off_t)chunk.offset) == (ssize_t)chunk.size &&
                [SHA1(here.bytes, here.length) isEqualToData:chunk.sha] &&
                pwrite(fd, here.bytes, here.length, (off_t)chunk.offset) == (ssize_t)here.length) {
                advance(chunk.size);
                continue;
            }
        }
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        dispatch_group_async(group, queue, ^{
            NSError *chunkError = nil;
            NSData *plain = atomic_load(&failed) ? nil : [self chunk:chunk error:&chunkError];
            if (plain && pwrite(fd, plain.bytes, plain.length, (off_t)chunk.offset) == (ssize_t)plain.length) advance(chunk.size);
            else if (!atomic_exchange(&failed, true))
                failure = chunkError ?: DepotError(PocketDepotErrorFiles, [NSString stringWithFormat:@"%@ could not be written", file.path]);
            dispatch_semaphore_signal(slots);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    if (oldFD >= 0) close(oldFD);
    BOOL synced = fsync(fd) == 0;
    close(fd);
    if (!failed && cancelled && cancelled()) { failed = true; failure = DepotError(PocketDepotErrorCancelled, @"the download was stopped"); }
    if (!failed && !(synced && [FileSHA1(partial) isEqualToData:file.sha])) {
        failed = true;
        failure = DepotError(PocketDepotErrorCorrupt, [NSString stringWithFormat:@"%@ did not verify", file.path]);
    }
    if (failed) {
        [manager removeItemAtPath:partial error:NULL];
        if (error) *error = failure;
        return NO;
    }
    [manager removeItemAtPath:target error:NULL];
    if (rename(partial.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
        if (error) *error = DepotError(PocketDepotErrorFiles, [NSString stringWithFormat:@"%@ could not be put in place", file.path]);
        return NO;
    }
    return YES;
}
@end
