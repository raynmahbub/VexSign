#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Available only in the combined host, never inferred from a URL handler.
FOUNDATION_EXPORT BOOL VEXEmbeddedRuntimeAvailable(void);
/// Calls the loaded host runtime directly. YES means restart requested, not login success.
FOUNDATION_EXPORT BOOL VEXEmbeddedRuntimeOpen(BOOL sideStore);
/// Stages a guest-local IPA in the host inbox. Does not launch or transfer credentials.
FOUNDATION_EXPORT BOOL VEXEmbeddedRuntimeStageIPA(NSURL *source);
NS_ASSUME_NONNULL_END
