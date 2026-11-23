#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Available only in the combined host, never inferred from a URL handler.
FOUNDATION_EXPORT BOOL VEXEmbeddedRuntimeAvailable(void);
/// Calls the loaded host runtime directly. YES means restart requested, not login success.
FOUNDATION_EXPORT BOOL VEXEmbeddedRuntimeOpen(BOOL sideStore);
/// Stages a guest-local IPA in the host inbox. Does not launch or transfer credentials.
FOUNDATION_EXPORT BOOL VEXEmbeddedRuntimeStageIPA(NSURL *source);
/// Read-only guest inventory. nil means the host could not answer.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> * _Nullable VEXEmbeddedRuntimeGuestInfo(NSString *identifier);
/// The entry points this version calls that the loaded host does not answer, in
/// call order. Empty when the host implements all of them, and non-empty in an
/// ordinary install, which declares no host at all.
///
/// This is the check that `VEXEmbeddedRuntimeAvailable` cannot make: that one
/// boolean answers "is the host on", not "is the host the right version". A host
/// that renamed one method used to look like a device with nothing installed.
FOUNDATION_EXPORT NSArray<NSString *> *VEXEmbeddedRuntimeMissingSelectors(void);
NS_ASSUME_NONNULL_END
