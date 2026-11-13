// Local signing on the device: the page container for a new build of the game is made and
// signed here, with the developer identity Brighter Pocket Companion gave the app once
// (pocket/tools/give_signing_identity.sh), so a game update needs no Mac to sign it.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The identity the Mac copied to Documents/LocalSigning/identity.p12, opened with the
// passphrase given at launch (--signing-identity-passphrase=), goes into the app's keychain,
// with the certificates of its chain from identity-chain.pem beside it; both files are
// deleted either way. Without the identity file this does nothing.
void PocketLocalSigningImportOffered(void);

// Makes the page container for the executable at `executable` (a Mac executable, thin or fat)
// at `output`: its __TEXT pages, byte for byte, in a dylib signed with the keychain's
// developer identity (ad hoc in the simulator). Refuses an executable Local signing cannot run
// (a fixup in __TEXT, say). Returns NO with a reason a player can read.
BOOL PocketLocalSigningBuildContainer(NSString *executable, NSString *output, NSString *_Nullable *_Nullable reason);

NS_ASSUME_NONNULL_END
