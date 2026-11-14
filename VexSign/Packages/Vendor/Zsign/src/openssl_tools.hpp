//
//  p12_password_check.hpp
//  feather
//
//  Created by HAHALOSAH on 8/6/24.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
/// Returns only CMS-authenticated content chained to an Apple provisioning signer.
NSData * _Nullable VexVerifyProvisioningProfileCMS(NSData * _Nonnull data, NSTimeInterval verificationTime);
/// Verifies a detached code-signature CMS over the supplied primary CodeDirectory.
/// Returns the actual signer DER, not a certificate guessed from CMS set order.
/// Trust/authorization is supplied by the already-authenticated profile inventory.
NSData * _Nullable VexVerifyCodeSignatureCMS(NSData * _Nonnull data, NSData * _Nonnull codeDirectory,
                                          NSData * _Nullable alternateCodeDirectory);
/// Public-certificate compatibility only. This is not profile authentication or key proof.
bool VexNativeSupportsSigningCertificate(NSData * _Nonnull certificateDER);
bool p12_password_check(NSString *file, NSString *pass);
void password_check_fix_WHAT_THE_FUCK(NSString *path);
void password_check_fix_WHAT_THE_FUCK_free(NSString *path);
#ifdef __cplusplus
}
#endif
