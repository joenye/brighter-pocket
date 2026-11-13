// export_signing_identity: writes the Apple Development identity of one team as a PKCS#12
// file protected by the passphrase in SIGNING_PASSPHRASE, and the certificates that complete
// its chain (the intermediate and the root) as PEM: the keychain will not export an identity
// and certificates together. tools/give_signing_identity.sh hands both to Brighter Pocket on
// the device, which keeps them in its keychain and signs a new build's page container itself
// (launcher/Pocket/PocketLocalSigning.m). macOS may ask to allow the export of the key.
//
// usage: SIGNING_PASSPHRASE=... export_signing_identity TEAMID IDENTITY.p12 CHAIN.pem
//        export_signing_identity --fingerprint TEAMID   (the SHA-1 it would export, nothing else)
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>

static int fail(NSString *message) {
    fprintf(stderr, "export_signing_identity: %s\n", message.UTF8String);
    return 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL fingerprintOnly = argc == 3 && !strcmp(argv[1], "--fingerprint");
        if (argc != 4 && !fingerprintOnly)
            return fail(@"usage: SIGNING_PASSPHRASE=... export_signing_identity TEAMID IDENTITY.p12 CHAIN.pem\n"
                        @"       export_signing_identity --fingerprint TEAMID");
        NSString *team = @(argv[fingerprintOnly ? 2 : 1]);
        NSString *output = fingerprintOnly ? nil : @(argv[2]), *chainOutput = fingerprintOnly ? nil : @(argv[3]);
        NSString *passphrase = NSProcessInfo.processInfo.environment[@"SIGNING_PASSPHRASE"];
        if (!fingerprintOnly && passphrase.length < 16) return fail(@"SIGNING_PASSPHRASE must hold at least 16 characters");

        // The team's valid Apple Development identity that expires last.
        CFTypeRef found = NULL;
        NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassIdentity,
                                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                                (__bridge id)kSecReturnRef: @YES};
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &found) != errSecSuccess || !found)
            return fail(@"no signing identities in the keychain (sign in to Xcode with your Apple account once)");
        NSArray *identities = CFBridgingRelease(found);
        id chosen = nil;
        SecCertificateRef chosenCertificate = NULL;
        NSDate *chosenExpiry = nil;
        for (id identity in identities) {
            SecCertificateRef certificate = NULL;
            if (SecIdentityCopyCertificate((__bridge SecIdentityRef)identity, &certificate) != errSecSuccess || !certificate) continue;
            NSString *name = CFBridgingRelease(SecCertificateCopySubjectSummary(certificate));
            NSDictionary *values = CFBridgingRelease(SecCertificateCopyValues(certificate,
                (__bridge CFArrayRef)@[(__bridge id)kSecOIDX509V1ValidityNotAfter, (__bridge id)kSecOIDX509V1SubjectName], NULL));
            NSMutableArray *units = [NSMutableArray array];   // the subject's OU: the team
            for (NSDictionary *part in values[(__bridge id)kSecOIDX509V1SubjectName][(__bridge id)kSecPropertyKeyValue])
                if ([part isKindOfClass:NSDictionary.class] && [part[(__bridge id)kSecPropertyKeyLabel] isEqual:(__bridge id)kSecOIDOrganizationalUnitName] &&
                    part[(__bridge id)kSecPropertyKeyValue]) [units addObject:part[(__bridge id)kSecPropertyKeyValue]];
            NSNumber *notAfter = values[(__bridge id)kSecOIDX509V1ValidityNotAfter][(__bridge id)kSecPropertyKeyValue];
            NSDate *expiry = [notAfter isKindOfClass:NSNumber.class] ? [NSDate dateWithTimeIntervalSinceReferenceDate:notAfter.doubleValue] : nil;
            if ([name hasPrefix:@"Apple Development"] && [units containsObject:team] && expiry.timeIntervalSinceNow > 0 &&
                (!chosenExpiry || [expiry compare:chosenExpiry] == NSOrderedDescending)) {
                if (chosenCertificate) CFRelease(chosenCertificate);
                chosen = identity;
                chosenCertificate = certificate;
                chosenExpiry = expiry;
            } else {
                CFRelease(certificate);
            }
        }
        if (!chosen) return fail([NSString stringWithFormat:@"no valid Apple Development identity of team %@ in the keychain", team]);
        if (fingerprintOnly) {
            NSData *der = CFBridgingRelease(SecCertificateCopyData(chosenCertificate));
            uint8_t digest[CC_SHA1_DIGEST_LENGTH];
            CC_SHA1(der.bytes, (CC_LONG)der.length, digest);
            for (size_t i = 0; i < sizeof digest; i++) printf("%02X", digest[i]);
            printf("\n");
            CFRelease(chosenCertificate);
            return 0;
        }

        // The intermediate and root certificates: the device does not look them up.
        NSMutableString *pem = [NSMutableString string];
        NSUInteger chainCount = 0;
        SecPolicyRef policy = SecPolicyCreateBasicX509();
        SecTrustRef trust = NULL;
        if (SecTrustCreateWithCertificates(chosenCertificate, policy, &trust) == errSecSuccess && trust) {
            (void)SecTrustEvaluateWithError(trust, NULL);   // builds the chain, trusted or not
            NSArray *chain = CFBridgingRelease(SecTrustCopyCertificateChain(trust));
            for (NSUInteger i = 1; i < chain.count; i++, chainCount++) {
                NSData *der = CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)chain[i]));
                [pem appendFormat:@"-----BEGIN CERTIFICATE-----\n%@\n-----END CERTIFICATE-----\n",
                                  [der base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed]];
            }
            CFRelease(trust);
        }
        CFRelease(policy);
        NSString *name = CFBridgingRelease(SecCertificateCopySubjectSummary(chosenCertificate));
        CFRelease(chosenCertificate);

        SecItemImportExportKeyParameters parameters = {.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION,
                                                       .passphrase = (__bridge CFTypeRef)passphrase};
        CFDataRef exported = NULL;
        OSStatus status = SecItemExport((__bridge CFTypeRef)chosen, kSecFormatPKCS12, 0, &parameters, &exported);
        if (status != errSecSuccess || !exported)
            return fail([NSString stringWithFormat:@"the keychain did not export the identity (%d%@)", (int)status,
                         status == errSecAuthFailed || status == errSecUserCanceled ? @": the export was not allowed" : @""]);
        NSData *bundle = CFBridgingRelease(exported);
        int fd = open(output.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0 || write(fd, bundle.bytes, bundle.length) != (ssize_t)bundle.length || close(fd) != 0)
            return fail([NSString stringWithFormat:@"could not write %@", output]);
        if (![pem writeToFile:chainOutput atomically:YES encoding:NSASCIIStringEncoding error:NULL])
            return fail([NSString stringWithFormat:@"could not write %@", chainOutput]);
        printf("exported %s and %lu chain certificate(s)\n", name.UTF8String, (unsigned long)chainCount);
        return 0;
    }
}
