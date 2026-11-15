// The app's own Local signing (pocket/launcher/Pocket/PocketLocalSigning.m), on the host: the
// page container it makes for the client is the one tools/build_signed_container.py makes on a
// Mac, byte for byte; signed (ad hoc here: the device uses its developer identity) it passes the
// signer's own check; what Local signing cannot run is refused with a reason; and the question
// the app puts to iOS about a container (does the system take its signature?) finds the
// signature where the signer put it, and takes no file it cannot read for a refusal.
//
// usage: local_signing_test EXECUTABLE MAC_CONTAINER WORK_DIR
// Built by tests/run.sh with -iquote <prepared tree>/launcher/Pocket.
#include "PocketLocalSigning.m"

static int check(BOOL ok, const char *what) {
    if (!ok) fprintf(stderr, "local signing: FAILED: %s\n", what);
    return ok ? 0 : 1;
}

// The client with a fixup chain in __TEXT: __TEXT's entry in the chained fixups' starts is
// pointed at another segment's, which has fixups.
static BOOL MarkTextFixup(NSMutableData *slice) {
    uint8_t *data = slice.mutableBytes;
    struct mach_header_64 header;
    memcpy(&header, data, sizeof header);
    uint64_t cursor = sizeof header;
    uint32_t segment = 0, text = UINT32_MAX, starts = 0;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        uint32_t cmd = U32(data + cursor), size = U32(data + cursor + 4);
        if (cmd == LC_DYLD_CHAINED_FIXUPS) { uint32_t dataoff = U32(data + cursor + 8); starts = dataoff + U32(data + dataoff + 4); }
        if (cmd == LC_SEGMENT_64) {
            struct segment_command_64 command;
            memcpy(&command, data + cursor, sizeof command);
            if (command.initprot & VM_PROT_EXECUTE) text = segment;
            segment++;
        }
        cursor += size;
    }
    if (!starts || text == UINT32_MAX) return NO;
    uint32_t count = U32(data + starts);
    for (uint32_t j = 0; j < count; j++) {
        uint32_t info = U32(data + starts + 4 + 4 * j);
        if (j != text && info) { memcpy(data + starts + 4 + 4 * text, &info, 4); return YES; }
    }
    return NO;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4) { fprintf(stderr, "usage: local_signing_test EXECUTABLE MAC_CONTAINER WORK_DIR\n"); return 2; }
        NSString *executable = @(argv[1]), *work = @(argv[3]);
        NSString *reason = nil;
        NSData *slice = Arm64Slice([NSData dataWithContentsOfFile:executable], &reason);
        NSData *image = slice ? TextImage(slice, &reason) : nil;
        if (!image) { fprintf(stderr, "local signing: the client was refused: %s\n", reason.UTF8String); return 1; }
        NSData *container = Container(image);
        int failures = check([container isEqualToData:[NSData dataWithContentsOfFile:@(argv[2])]],
                             "the container differs from build_signed_container.py's");

        NSString *unsignedPath = [work stringByAppendingPathComponent:@"unsigned.dylib"];
        NSString *signedPath = [work stringByAppendingPathComponent:@"signed.dylib"];
        [container writeToFile:unsignedPath atomically:YES];
        @try {
            sgl_sign(unsignedPath, signedPath, ContainerIdentifier(), nil, nil, SGL_MODE_ADHOC, NO);
            failures += check(sgl_verify(signedPath) == 0, "the signed container fails the signer's check");
        } @catch (NSException *failure) {
            fprintf(stderr, "local signing: signing threw: %s\n", failure.reason.UTF8String);
            failures++;
        }

        // What the app asks the system about a container. The signature is found where the signer
        // put it: after the container's own bytes, to the end of the file.
        uint32_t signatureOffset = 0, signatureSize = 0;
        int signedFile = open(signedPath.fileSystemRepresentation, O_RDONLY);
        NSUInteger signedLength = [NSData dataWithContentsOfFile:signedPath].length;
        failures += check(signedFile >= 0 && SignatureRange(signedFile, &signatureOffset, &signatureSize) &&
                          signatureOffset == container.length && (NSUInteger)signatureOffset + signatureSize == signedLength,
                          "the signed container's signature is not found where it is");
        if (signedFile >= 0) close(signedFile);
        int unsignedFile = open(unsignedPath.fileSystemRepresentation, O_RDONLY);
        failures += check(unsignedFile >= 0 && !SignatureRange(unsignedFile, &signatureOffset, &signatureSize),
                          "an unsigned container is said to have a signature");
        if (unsignedFile >= 0) close(unsignedFile);
        // Only the system's own "no" is a refusal: not a missing file, nor one that is no Mach-O.
        // Such files stay where they are, whatever their names.
        NSString *folder = [work stringByAppendingPathComponent:@"refused"];
        NSString *garbage = [folder stringByAppendingPathComponent:[[@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0] stringByAppendingString:@".dylib"]];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSData dataWithBytes:"not a Mach-O file" length:17] writeToFile:garbage atomically:YES];
        [container writeToFile:[folder stringByAppendingPathComponent:@"page-container.dylib"] atomically:YES];
        failures += check(!RefusedByIOS([work stringByAppendingPathComponent:@"missing"]) && !RefusedByIOS(garbage) && !RefusedByIOS(unsignedPath),
                          "a file the system was never asked about counts as refused");
        failures += check(DropRefusedContainers(folder) == 0 && [NSFileManager.defaultManager fileExistsAtPath:garbage] &&
                          [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:NULL].count == 2,
                          "a container the system did not refuse was removed");

        // What the app refuses, with a reason a player can read, instead of a container.
        uint8_t notMachO[64] = {0};
        reason = nil;
        failures += check(!TextImage([NSData dataWithBytes:notMachO length:sizeof notMachO], &reason) && reason.length,
                          "a file that is not an executable is not refused");
        NSMutableData *fixupInText = [slice mutableCopy];
        failures += check(MarkTextFixup(fixupInText) && !TextImage(fixupInText, &reason) && [reason containsString:@"changes its own code"],
                          "an executable with a fixup in __TEXT is not refused");
        reason = nil;
        failures += check(!PocketLocalSigningBuildContainer([work stringByAppendingPathComponent:@"missing"],
                                                            [work stringByAppendingPathComponent:@"none.dylib"], &reason) && reason.length,
                          "a missing executable is not refused");
        if (failures) return 1;
        printf("local signing: the container matches the Mac's (%lu bytes, %lu __TEXT pages), signs and verifies; refusals hold\n",
               (unsigned long)container.length, (unsigned long)(image.length / Page));
        return 0;
    }
}
