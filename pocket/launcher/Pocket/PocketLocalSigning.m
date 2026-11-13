// Local signing on the device (PocketLocalSigning.h). The container is the one
// tools/build_signed_container.py makes on a Mac, byte for byte (tests/run.sh compares them),
// and Tolkara's own signer, tools/sign_guest_local.m (Security and CommonCrypto only, written
// to run on the device), signs it: compiled in here, its failures throw (pocket/patches/0014).
#import "PocketLocalSigning.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <TargetConditionals.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#define SGL_NO_MAIN 1
#define SGL_THROW_ON_FAILURE 1
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "../../tools/sign_guest_local.m"
#pragma clang diagnostic pop

static const uint32_t Page = 0x4000;
static const uint64_t TextLimit = 1ull << 31;   // the runtime's per-segment budget (runtime/GuestImage.c)
static const uint16_t ChainedStartNone = 0xFFFF;

// --- reading the executable ---------------------------------------------------------------
static uint32_t U32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return OSSwapLittleToHostInt32(v); }
static BOOL Within(uint64_t offset, uint64_t size, uint64_t total) { return offset <= total && size <= total - offset; }
static uint32_t B32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return OSSwapBigToHostInt32(v); }
static uint64_t B64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return OSSwapBigToHostInt64(v); }
static id Refuse(NSString **reason, NSString *text) { if (reason) *reason = text; return nil; }

// The thin arm64 (not arm64e) Mach-O inside a thin or fat file.
static NSData *Arm64Slice(NSData *file, NSString **reason) {
    const uint8_t *p = file.bytes;
    uint64_t length = file.length;
    if (length < 8) return Refuse(reason, @"the game's executable is too small to be a Mac program");
    uint32_t magic = B32(p);
    if (magic != FAT_MAGIC && magic != FAT_MAGIC_64) return file;
    uint32_t count = B32(p + 4);
    BOOL wide = magic == FAT_MAGIC_64;
    uint64_t entry = wide ? 32 : 20;
    if (count > 64 || !Within(8, count * entry, length)) return Refuse(reason, @"the game's executable has a malformed fat header");
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *at = p + 8 + i * entry;
        uint32_t cpu = B32(at), subtype = B32(at + 4);
        uint64_t offset = wide ? B64(at + 8) : B32(at + 8), size = wide ? B64(at + 16) : B32(at + 12);
        if (cpu == CPU_TYPE_ARM64 && (subtype & 0xFF) != CPU_SUBTYPE_ARM64E) {
            if (!Within(offset, size, length)) return Refuse(reason, @"the game's arm64 code lies outside its executable");
            return [file subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)size)];
        }
    }
    return Refuse(reason, @"the game's executable has no arm64 code");
}

// The container maps __TEXT read and execute: an executable with a fixup chain in it is refused.
static BOOL NoFixupsInText(const uint8_t *data, uint64_t length, uint32_t dataoff, uint32_t datasize, uint32_t text, NSString **reason) {
    if (!Within(dataoff, datasize, length) || datasize < 28) { Refuse(reason, @"the game's chained fixups lie outside its executable"); return NO; }
    uint64_t end = (uint64_t)dataoff + datasize, starts = dataoff + (uint64_t)U32(data + dataoff + 4);
    if (!Within(starts, 4, end)) { Refuse(reason, @"the game's chained fixups are malformed"); return NO; }
    uint32_t count = U32(data + starts);
    if (text >= count) return YES;
    if (!Within(starts + 4, 4ull * count, end)) { Refuse(reason, @"the game's chained fixups are malformed"); return NO; }
    uint32_t info = U32(data + starts + 4 + 4ull * text);
    if (!info) return YES;
    uint64_t segment = starts + info;
    if (!Within(segment, 22, end)) { Refuse(reason, @"the game's chained fixups are malformed"); return NO; }
    uint16_t pages;
    memcpy(&pages, data + segment + 20, 2);
    if (!Within(segment + 22, 2ull * pages, end)) { Refuse(reason, @"the game's chained fixups are malformed"); return NO; }
    for (uint16_t i = 0; i < pages; i++) {
        uint16_t start;
        memcpy(&start, data + segment + 22 + 2ull * i, 2);
        if (start != ChainedStartNone) { Refuse(reason, @"the game changes its own code when it loads, which Local signing cannot run"); return NO; }
    }
    return YES;
}

// The executable's __TEXT as it runs: its on-disk bytes, zero-filled to the segment's size.
static NSData *TextImage(NSData *slice, NSString **reason) {
    const uint8_t *data = slice.bytes;
    uint64_t length = slice.length;
    if (length < sizeof(struct mach_header_64)) return Refuse(reason, @"the game's executable is truncated");
    struct mach_header_64 header;
    memcpy(&header, data, sizeof header);
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64) return Refuse(reason, @"the game's executable is not arm64");
    if (header.filetype != MH_EXECUTE) return Refuse(reason, @"the game's file is not an executable");
    uint64_t cursor = sizeof header, end = cursor + header.sizeofcmds;
    if (!Within(cursor, header.sizeofcmds, length)) return Refuse(reason, @"the game's load commands run past its executable");
    uint64_t textVMSize = 0, textFileSize = 0, textVMAddr = 0, textFileOff = 0;
    uint32_t executableSegments = 0, segmentIndex = 0, textIndex = UINT32_MAX, fixupsOffset = 0, fixupsSize = 0;
    BOOL chained = NO, textNamed = NO;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (!Within(cursor, 8, end)) return Refuse(reason, @"the game's load commands are malformed");
        uint32_t cmd = U32(data + cursor), size = U32(data + cursor + 4);
        if (size < 8 || size % 8 || !Within(cursor, size, end)) return Refuse(reason, @"the game's load commands are malformed");
        if (cmd == LC_DYLD_CHAINED_FIXUPS) {
            if (size < 16) return Refuse(reason, @"the game's chained fixups are malformed");
            chained = YES;
            fixupsOffset = U32(data + cursor + 8);
            fixupsSize = U32(data + cursor + 12);
        } else if (cmd == LC_SEGMENT_64) {
            if (size < sizeof(struct segment_command_64)) return Refuse(reason, @"the game's segments are malformed");
            struct segment_command_64 segment;
            memcpy(&segment, data + cursor, sizeof segment);
            if (!Within(segment.fileoff, segment.filesize, length)) return Refuse(reason, @"a segment lies outside the game's executable");
            if (segment.initprot & VM_PROT_EXECUTE) {
                executableSegments++;
                textNamed = !strncmp(segment.segname, SEG_TEXT, sizeof segment.segname);
                textVMAddr = segment.vmaddr;
                textVMSize = segment.vmsize;
                textFileOff = segment.fileoff;
                textFileSize = segment.filesize;
                textIndex = segmentIndex;
            }
            segmentIndex++;
        }
        cursor += size;
    }
    if (cursor != end) return Refuse(reason, @"the game's load commands are malformed");
    if (executableSegments != 1 || !textNamed) return Refuse(reason, @"Local signing runs executables whose only code is __TEXT");
    if (textFileOff || !textVMSize || textVMSize % Page || textVMAddr % Page || textFileSize > textVMSize)
        return Refuse(reason, @"the game's __TEXT does not start the file in whole 16 KiB pages");
    if (textVMSize > TextLimit) return Refuse(reason, @"the game's __TEXT is larger than the runtime accepts");
    if (end > MIN((uint64_t)Page, textFileSize)) return Refuse(reason, @"the game's header is larger than its first page");
    if (chained && !NoFixupsInText(data, length, fixupsOffset, fixupsSize, textIndex, reason)) return nil;
    NSMutableData *image = [NSMutableData dataWithBytes:data length:(NSUInteger)textFileSize];
    image.length = (NSUInteger)textVMSize;
    return image;
}

// --- the container (build_signed_container.py's container(), without a probe) ---------------
static void Append(NSMutableData *out, const void *bytes, size_t size) { [out appendBytes:bytes length:size]; }

static NSData *Container(NSData *image) {
    static const char *const names[] = {"_tolkara_container_final", "_tolkara_container_v1"};   // sorted by name
    const uint32_t symbols = 2;
    const char idName[] = "/tolkara/page-container.dylib";
    uint64_t size = image.length, textEnd = Page + size;
    uint32_t idSize = (uint32_t)((sizeof(struct dylib_command) + sizeof idName + 7) & ~7ull);
    uint32_t sizeofcmds = (uint32_t)(sizeof(struct segment_command_64) + sizeof(struct section_64) + sizeof(struct segment_command_64) +
        idSize + sizeof(struct build_version_command) + sizeof(struct symtab_command) + sizeof(struct dysymtab_command) +
        sizeof(struct uuid_command));
    NSMutableData *strings = [NSMutableData dataWithLength:1];
    for (uint32_t i = 0; i < symbols; i++) Append(strings, names[i], strlen(names[i]) + 1);
    uint64_t symoff = textEnd, stroff = symoff + sizeof(struct nlist_64) * symbols;
    uint32_t strsize = (uint32_t)((strings.length + 7) & ~7ull);
    uint64_t end = (stroff + strsize + 15) & ~15ull, linkeditSize = end - textEnd;
#if TARGET_OS_SIMULATOR
    const uint32_t platform = PLATFORM_IOSSIMULATOR;
#else
    const uint32_t platform = PLATFORM_IOS;
#endif
    const uint32_t minos = 0x110000;

    NSMutableData *out = [NSMutableData data];
    struct mach_header_64 header = {MH_MAGIC_64, CPU_TYPE_ARM64, 0, MH_DYLIB, 7, sizeofcmds, 0x00100085, 0};
    Append(out, &header, sizeof header);
    struct segment_command_64 text = {LC_SEGMENT_64, sizeof(struct segment_command_64) + sizeof(struct section_64), SEG_TEXT,
                                      0, textEnd, 0, textEnd, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_READ | VM_PROT_EXECUTE, 1, 0};
    Append(out, &text, sizeof text);
    struct section_64 section = {SECT_TEXT, SEG_TEXT, Page, size, Page, 14, 0, 0, 0x80000400, 0, 0, 0};
    Append(out, &section, sizeof section);
    struct segment_command_64 linkedit = {LC_SEGMENT_64, sizeof(struct segment_command_64), SEG_LINKEDIT, textEnd,
                                          (linkeditSize + Page - 1) & ~(uint64_t)(Page - 1), textEnd, linkeditSize, VM_PROT_READ, VM_PROT_READ, 0, 0};
    Append(out, &linkedit, sizeof linkedit);
    struct dylib_command dylib = {LC_ID_DYLIB, idSize, {{sizeof(struct dylib_command)}, 0, 0x10000, 0x10000}};
    Append(out, &dylib, sizeof dylib);
    NSMutableData *paddedName = [NSMutableData dataWithBytes:idName length:sizeof idName];
    paddedName.length = idSize - sizeof(struct dylib_command);
    [out appendData:paddedName];
    struct build_version_command build = {LC_BUILD_VERSION, sizeof(struct build_version_command), platform, minos, minos, 0};
    Append(out, &build, sizeof build);
    struct symtab_command symtab = {LC_SYMTAB, sizeof(struct symtab_command), (uint32_t)symoff, symbols, (uint32_t)stroff, strsize};
    Append(out, &symtab, sizeof symtab);
    struct dysymtab_command dysymtab = {0};
    dysymtab.cmd = LC_DYSYMTAB;
    dysymtab.cmdsize = sizeof dysymtab;
    dysymtab.nextdefsym = symbols;
    dysymtab.iundefsym = symbols;
    Append(out, &dysymtab, sizeof dysymtab);
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(image.bytes, (CC_LONG)image.length, digest);
    struct uuid_command uuid = {LC_UUID, sizeof(struct uuid_command), {0}};
    memcpy(uuid.uuid, digest, sizeof uuid.uuid);
    Append(out, &uuid, sizeof uuid);
    out.length = Page;
    [out appendData:image];
    uint32_t index = 1;
    for (uint32_t i = 0; i < symbols; i++) {
        struct nlist_64 symbol = {{index}, N_SECT | N_EXT, 1, 0, Page};
        Append(out, &symbol, sizeof symbol);
        index += (uint32_t)strlen(names[i]) + 1;
    }
    strings.length = strsize;
    [out appendData:strings];
    out.length = (NSUInteger)end;
    return out;
}

// --- building and signing ---------------------------------------------------------------------
static BOOL BuildContainer(NSString *executable, NSString *output, NSString **reason) {
    NSError *error = nil;
    NSData *file = [NSData dataWithContentsOfFile:executable options:NSDataReadingMappedIfSafe error:&error];
    if (!file) { Refuse(reason, [NSString stringWithFormat:@"the game's executable could not be read (%@)", error.localizedDescription]); return NO; }
    NSData *slice = Arm64Slice(file, reason);
    NSData *image = slice ? TextImage(slice, reason) : nil;
    if (!image) return NO;
    NSString *folder = output.stringByDeletingLastPathComponent;
    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *unsignedPath = [folder stringByAppendingPathComponent:[@".unsigned-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![Container(image) writeToFile:unsignedPath options:NSDataWritingAtomic error:&error]) {
        Refuse(reason, [NSString stringWithFormat:@"the page container could not be written (%@)", error.localizedDescription]);
        return NO;
    }
    BOOL signedAndVerified = NO;
    @try {
#if TARGET_OS_SIMULATOR
        sgl_sign(unsignedPath, output, @"tolkara.page-container", nil, nil, SGL_MODE_ADHOC, NO);
#else
        sgl_sign(unsignedPath, output, @"tolkara.page-container", @"Apple Development", nil, SGL_MODE_KEYCHAIN, NO);
#endif
        signedAndVerified = sgl_verify(output) == 0;
        if (!signedAndVerified) Refuse(reason, @"the signed page container failed its own check");
    } @catch (NSException *failure) {
        BOOL none = [failure.reason containsString:@"no code-signing identities"];
        BOOL stale = [failure.reason containsString:@"no valid code-signing identity"] || [failure.reason containsString:@"expired"];
        Refuse(reason, none ? @"this device has no developer identity to sign with yet: run Brighter Pocket Companion's Install once with the device connected"
                     : stale ? @"the developer identity on this device has expired: run Brighter Pocket Companion's Install again with the device connected"
                             : failure.reason);
    }
    [files removeItemAtPath:unsignedPath error:NULL];
    if (!signedAndVerified) [files removeItemAtPath:output error:NULL];
    else NSLog(@"[signing] page container for %@ built and signed on the device: %llu __TEXT pages",
               executable.lastPathComponent, (unsigned long long)(image.length / Page));
    return signedAndVerified;
}

BOOL PocketLocalSigningBuildContainer(NSString *executable, NSString *output, NSString **reason) {
    // The reason outlives the pool that frees the build's 50 MB of temporaries.
    NSString *problem = nil;
    BOOL built;
    @autoreleasepool {
        NSString *inner = nil;
        built = BuildContainer(executable, output, &inner);
        problem = inner;
    }
    if (reason) *reason = problem;
    return built;
}

// --- the identity -----------------------------------------------------------------------------
static NSString *const PassphraseArgument = @"--signing-identity-passphrase=";

// Each certificate in a PEM file.
static NSArray *PEMCertificates(NSString *pem) {
    NSMutableArray *certificates = [NSMutableArray array];
    for (NSString *block in [pem componentsSeparatedByString:@"-----BEGIN CERTIFICATE-----"]) {
        NSRange end = [block rangeOfString:@"-----END CERTIFICATE-----"];
        if (end.location == NSNotFound) continue;
        NSData *der = [[NSData alloc] initWithBase64EncodedString:[block substringToIndex:end.location]
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        id certificate = der ? CFBridgingRelease(SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der)) : nil;
        if (certificate) [certificates addObject:certificate];
    }
    return certificates;
}

void PocketLocalSigningImportOffered(void) {
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/LocalSigning"];
    NSString *path = [folder stringByAppendingPathComponent:@"identity.p12"], *chainPath = [folder stringByAppendingPathComponent:@"identity-chain.pem"];
    NSData *bundle = [NSData dataWithContentsOfFile:path];
    NSString *pem = [NSString stringWithContentsOfFile:chainPath encoding:NSASCIIStringEncoding error:NULL];
    if (!bundle) return;
    // Never left in Files, imported or not.
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:chainPath error:NULL];
    NSString *passphrase = nil;
    for (NSString *argument in NSProcessInfo.processInfo.arguments)
        if ([argument hasPrefix:PassphraseArgument]) passphrase = [argument substringFromIndex:PassphraseArgument.length];
    if (!passphrase.length) { NSLog(@"[signing] a developer identity was offered without its passphrase; deleted"); return; }
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)bundle,
                                      (__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase: passphrase}, &items);
    NSArray *imported = items ? CFBridgingRelease(items) : nil;
    id identity = imported.count ? imported[0][(__bridge id)kSecImportItemIdentity] : nil;
    if (status != errSecSuccess || !identity) { NSLog(@"[signing] the offered developer identity could not be opened (%d)", (int)status); return; }
    // One identity: the one given last.
    SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassIdentity});
    status = SecItemAdd((__bridge CFDictionaryRef)@{(__bridge id)kSecValueRef: identity,
                                                    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly}, NULL);
    if (status != errSecSuccess && status != errSecDuplicateItem) { NSLog(@"[signing] the developer identity could not be kept (%d)", (int)status); return; }
    // The intermediate and root certificates complete the signature's chain (iOS does not look them up).
    NSArray *chain = PEMCertificates(pem ?: @"");
    NSUInteger kept = 0;
    for (id certificate in chain) {
        OSStatus added = SecItemAdd((__bridge CFDictionaryRef)@{(__bridge id)kSecValueRef: certificate}, NULL);
        if (added == errSecSuccess || added == errSecDuplicateItem) kept++;
    }
    // A note for the Mac (tools/give_signing_identity.sh): the certificate's name, its SHA-1 (the
    // Mac gives the identity again when its own differs: renewed, another team) and how many
    // chain certificates came with it (none: given again). Nothing secret.
    SecCertificateRef leaf = NULL;
    NSString *name = @"a developer identity", *fingerprint = @"";
    if (SecIdentityCopyCertificate((__bridge SecIdentityRef)identity, &leaf) == errSecSuccess && leaf) {
        name = CFBridgingRelease(SecCertificateCopySubjectSummary(leaf));
        NSData *der = CFBridgingRelease(SecCertificateCopyData(leaf));
        uint8_t digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(der.bytes, (CC_LONG)der.length, digest);
        NSMutableString *hex = [NSMutableString string];
        for (size_t i = 0; i < sizeof digest; i++) [hex appendFormat:@"%02X", digest[i]];
        fingerprint = hex;
        CFRelease(leaf);
    }
    [[NSString stringWithFormat:@"%@\n%@\n%lu\n", name, fingerprint, (unsigned long)kept]
        writeToFile:[folder stringByAppendingPathComponent:@"identity.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[signing] developer identity kept in the keychain, with %lu of %lu chain certificate(s)",
          (unsigned long)kept, (unsigned long)chain.count);
}
