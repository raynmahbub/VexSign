//
//  p12_password_check.cpp
//  feather
//
//  Created by HAHALOSAH on 8/6/24.
//

#include "openssl_tools.hpp"
#include "common.h"

#include <openssl/pem.h>
#include <openssl/cms.h>
#include <openssl/err.h>
#include <openssl/provider.h>
#include <openssl/pkcs12.h>
#include <openssl/conf.h>
#include <openssl/evp.h>
#include <openssl/x509.h>

#include <string>
#include <memory>

using namespace std;

// Compatibility entry points retained for existing callers. Password checking
// and decoder warm-up are not profile authentication or private-key proof.
static NSData *ReadBoundedIdentityInput(NSString *path) {
    if (!path) return nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:nil];
    if (!handle) return nil;
    NSData *data = [handle readDataUpToLength:10 * 1024 * 1024 + 1 error:nil];
    const BOOL closed = [handle closeAndReturnError:nil];
    return closed && data.length > 0 && data.length <= 10 * 1024 * 1024 ? data : nil;
}

bool p12_password_check(NSString *file, NSString *pass) {
    NSData *data = ReadBoundedIdentityInput(file);
    if (!data || !pass) return false;
    const char *password = pass.UTF8String;
    if (!password) return false;
    std::unique_ptr<OSSL_PROVIDER, decltype(&OSSL_PROVIDER_unload)> primary(OSSL_PROVIDER_load(NULL, "default"), OSSL_PROVIDER_unload);
    std::unique_ptr<OSSL_PROVIDER, decltype(&OSSL_PROVIDER_unload)> legacy(OSSL_PROVIDER_load(NULL, "legacy"), OSSL_PROVIDER_unload);
    if (!primary) return false;
    const unsigned char *start = static_cast<const unsigned char *>(data.bytes), *cursor = start;
    std::unique_ptr<PKCS12, decltype(&PKCS12_free)> p12(d2i_PKCS12(NULL, &cursor, data.length), PKCS12_free);
    return p12 && cursor == start + data.length &&
        (PKCS12_verify_mac(p12.get(), NULL, 0) == 1 || PKCS12_verify_mac(p12.get(), password, -1) == 1);
}

void password_check_fix_WHAT_THE_FUCK_free(NSString *path) {
    NSData *data = ReadBoundedIdentityInput(path);
    if (!data) return;
    const unsigned char *cursor = static_cast<const unsigned char *>(data.bytes);
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(
        d2i_CMS_ContentInfo(NULL, &cursor, data.length), CMS_ContentInfo_free);
}

void password_check_fix_WHAT_THE_FUCK(NSString *path) {
    password_check_fix_WHAT_THE_FUCK_free(path);
}

// Profile authentication is independent of signing and never accepts raw XML.
// OpenSSL verifies CMS (including BER/DER envelope decoding); Security evaluates
// the actual Apple signer chain against the platform trust store, offline.
#import <Security/Security.h>
#include <openssl/sha.h>
#include "openssl.h"
#include <cmath>
#include <cstring>

NSData *VexVerifyProvisioningProfileCMS(NSData *data, NSTimeInterval verificationTime) {
    if (!std::isfinite(verificationTime)) return nil;
    if (data.length == 0 || data.length > 10 * 1024 * 1024) return nil;
    const unsigned char *start = static_cast<const unsigned char *>(data.bytes);
    const unsigned char *cursor = start;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(
        d2i_CMS_ContentInfo(NULL, &cursor, static_cast<long>(data.length)), CMS_ContentInfo_free);
    if (!cms || cursor != start + data.length || CMS_is_detached(cms.get()) != 0 ||
        OBJ_obj2nid(CMS_get0_eContentType(cms.get())) != NID_pkcs7_data) return nil;
    STACK_OF(CMS_SignerInfo) *infos = CMS_get0_SignerInfos(cms.get());
    if (!infos || sk_CMS_SignerInfo_num(infos) != 1) return nil;
    X509_ALGOR *digest = NULL;
    CMS_SignerInfo_get0_algs(sk_CMS_SignerInfo_value(infos, 0), NULL, NULL, &digest, NULL);
    const ASN1_OBJECT *algorithm = NULL;
    if (!digest) return nil;
    X509_ALGOR_get0(&algorithm, NULL, NULL, digest);
    int nid = OBJ_obj2nid(algorithm);
    if (nid != NID_sha256 && nid != NID_sha384 && nid != NID_sha512) return nil;
    std::unique_ptr<BIO, decltype(&BIO_free)> output(BIO_new(BIO_s_mem()), BIO_free);
    // Only chain verification is delegated. Content/signature/attributes are
    // still checked by CMS_verify; no NOSIGS/NO_ATTR_VERIFY fallback is allowed.
    if (!output || CMS_verify(cms.get(), NULL, NULL, NULL, output.get(),
                              CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY) != 1) return nil;
    STACK_OF(X509) *signers = CMS_get0_signers(cms.get());
    if (!signers || sk_X509_num(signers) != 1) { sk_X509_free(signers); return nil; }
    X509 *signer = sk_X509_value(signers, 0);
    auto hasSingleCN = [](X509_NAME *name, const char *expected) {
        int index = X509_NAME_get_index_by_NID(name, NID_commonName, -1);
        if (index < 0 || X509_NAME_get_index_by_NID(name, NID_commonName, index) >= 0) return false;
        X509_NAME_ENTRY *entry = X509_NAME_get_entry(name, index);
        ASN1_STRING *value = X509_NAME_ENTRY_get_data(entry);
        return ASN1_STRING_length(value) == static_cast<int>(strlen(expected)) &&
            memcmp(ASN1_STRING_get0_data(value), expected, strlen(expected)) == 0;
    };
    bool named = hasSingleCN(X509_get_subject_name(signer), "Apple iPhone OS Provisioning Profile Signing") &&
                 hasSingleCN(X509_get_issuer_name(signer), "Apple iPhone Certification Authority");
    if (!named) { sk_X509_free(signers); return nil; }
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    auto append = [certificates](X509 *cert) {
        unsigned char *bytes = NULL;
        int size = i2d_X509(cert, &bytes);
        if (size > 0 && bytes) {
            CFDataRef der = CFDataCreate(NULL, bytes, size);
            SecCertificateRef appleCert = SecCertificateCreateWithData(NULL, der);
            if (appleCert) { CFArrayAppendValue(certificates, appleCert); CFRelease(appleCert); }
            CFRelease(der);
        }
        OPENSSL_free(bytes);
    };
    append(signer);
    STACK_OF(X509) *embedded = CMS_get1_certs(cms.get());
    if (!embedded || sk_X509_num(embedded) > 16) {
        sk_X509_pop_free(embedded, X509_free); sk_X509_free(signers); CFRelease(certificates); return nil;
    }
    for (int i = 0; embedded && i < sk_X509_num(embedded); ++i) {
        X509 *cert = sk_X509_value(embedded, i);
        if (X509_cmp(cert, signer) != 0) append(cert);
    }
    sk_X509_pop_free(embedded, X509_free);
    sk_X509_free(signers);
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    bool trusted = SecTrustCreateWithCertificates(certificates, policy, &trust) == errSecSuccess;
    CFRelease(certificates);
    CFRelease(policy);
    CFDateRef date = CFDateCreate(NULL, verificationTime - kCFAbsoluteTimeIntervalSince1970);
    if (trusted) trusted = SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess &&
        SecTrustSetVerifyDate(trust, date) == errSecSuccess && SecTrustEvaluateWithError(trust, NULL);
    CFRelease(date);
    SecTrustResultType result = kSecTrustResultInvalid;
    if (trusted) trusted = SecTrustGetTrustResult(trust, &result) == errSecSuccess && result == kSecTrustResultUnspecified;
    CFArrayRef chain = trusted ? SecTrustCopyCertificateChain(trust) : NULL;
    trusted = chain && CFArrayGetCount(chain) == 3;
    if (trusted) {
        SecCertificateRef leaf = static_cast<SecCertificateRef>(const_cast<void *>(CFArrayGetValueAtIndex(chain, 0)));
        CFDataRef leafData = SecCertificateCopyData(leaf);
        const unsigned char *leafCursor = CFDataGetBytePtr(leafData);
        X509 *leafX509 = d2i_X509(NULL, &leafCursor, CFDataGetLength(leafData));
        // Re-fetch the CMS signer after the array container was released.
        STACK_OF(X509) *actual = CMS_get0_signers(cms.get());
        trusted = leafX509 && actual && sk_X509_num(actual) == 1 && X509_cmp(leafX509, sk_X509_value(actual, 0)) == 0;
        X509_free(leafX509); sk_X509_free(actual); CFRelease(leafData);
    }
    if (trusted) {
        SecCertificateRef root = static_cast<SecCertificateRef>(const_cast<void *>(CFArrayGetValueAtIndex(chain, 2)));
        CFDataRef der = SecCertificateCopyData(root);
        unsigned char hash[SHA256_DIGEST_LENGTH];
        SHA256(CFDataGetBytePtr(der), CFDataGetLength(der), hash);
        CFRelease(der);
        char hex[SHA256_DIGEST_LENGTH * 2 + 1];
        for (int i = 0; i < SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2 * i, 3, "%02x", hash[i]);
        // Production Apple public roots, also reviewed by the isolated native
        // signing policy. Embedded roots and user-installed trust are not anchors.
        trusted = strcmp(hex, "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024") == 0 ||
                  strcmp(hex, "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050") == 0 ||
                  strcmp(hex, "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179") == 0;
    }
    if (chain) CFRelease(chain);
    if (trust) CFRelease(trust);
    if (!trusted) return nil;
    char *bytes = NULL;
    long size = BIO_get_mem_data(output.get(), &bytes);
    if (size <= 0 || size > 10 * 1024 * 1024) return nil;
    return [NSData dataWithBytes:bytes length:static_cast<NSUInteger>(size)];
}


NSData *VexVerifyCodeSignatureCMS(NSData *data, NSData *codeDirectory, NSData *alternateCodeDirectory) {
    if (!data.length || data.length > 1024 * 1024 || codeDirectory.length < 44 || codeDirectory.length > 16 * 1024 * 1024) return nil;
    const unsigned char *start = static_cast<const unsigned char *>(data.bytes), *cursor = start;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(
        d2i_CMS_ContentInfo(NULL, &cursor, static_cast<long>(data.length)), CMS_ContentInfo_free);
    if (!cms || cursor != start + data.length || CMS_is_detached(cms.get()) != 1 ||
        OBJ_obj2nid(CMS_get0_eContentType(cms.get())) != NID_pkcs7_data) return nil;
    STACK_OF(CMS_SignerInfo) *infos = CMS_get0_SignerInfos(cms.get());
    if (!infos || sk_CMS_SignerInfo_num(infos) != 1) return nil;
    std::unique_ptr<BIO, decltype(&BIO_free)> content(
        BIO_new_mem_buf(codeDirectory.bytes, static_cast<int>(codeDirectory.length)), BIO_free);
    if (!content || CMS_verify(cms.get(), NULL, NULL, content.get(), NULL,
                               CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY) != 1) return nil;
    CMS_SignerInfo *info = sk_CMS_SignerInfo_value(infos, 0);
    X509_ALGOR *digest = NULL;
    CMS_SignerInfo_get0_algs(info, NULL, NULL, &digest, NULL);
    const ASN1_OBJECT *digestOID = NULL;
    if (!digest) return nil;
    X509_ALGOR_get0(&digestOID, NULL, NULL, digest);
    int digestNID = OBJ_obj2nid(digestOID);
    if (digestNID != NID_sha256 && digestNID != NID_sha384 && digestNID != NID_sha512) return nil;
    auto attribute = [info](const char *oid) -> ASN1_TYPE * {
        ASN1_OBJECT *object = OBJ_txt2obj(oid, 1);
        int index = CMS_signed_get_attr_by_OBJ(info, object, -1);
        bool unique = index >= 0 && CMS_signed_get_attr_by_OBJ(info, object, index) < 0;
        ASN1_OBJECT_free(object);
        if (!unique) return NULL;
        X509_ATTRIBUTE *attr = CMS_signed_get_attr(info, index);
        return attr && X509_ATTRIBUTE_count(attr) == 1 ? X509_ATTRIBUTE_get0_type(attr, 0) : NULL;
    };
    // Authenticate the alternate SHA256 directory, not just the primary SHA1
    // directory. Otherwise a cryptographically valid primary could accompany an
    // unauthenticated alternate chosen by the device.
    NSData *strongDirectory = alternateCodeDirectory ?: codeDirectory;
    if (strongDirectory.length < 44 || strongDirectory.length > 16 * 1024 * 1024) return nil;
    unsigned char strongHash[SHA256_DIGEST_LENGTH];
    SHA256(static_cast<const unsigned char *>(strongDirectory.bytes), strongDirectory.length, strongHash);
    ASN1_TYPE *hashes = attribute("1.2.840.113635.100.9.2");
    if (!hashes || hashes->type != V_ASN1_SEQUENCE) return nil;
    const unsigned char *encoded = ASN1_STRING_get0_data(hashes->value.sequence), *position = encoded;
    int encodedLength = ASN1_STRING_length(hashes->value.sequence);
    STACK_OF(ASN1_TYPE) *sequence = d2i_ASN1_SEQUENCE_ANY(NULL, &position, encodedLength);
    bool bound = sequence && position == encoded + encodedLength && sk_ASN1_TYPE_num(sequence) == 2;
    if (bound) {
        ASN1_TYPE *oid = sk_ASN1_TYPE_value(sequence, 0), *hash = sk_ASN1_TYPE_value(sequence, 1);
        bound = oid->type == V_ASN1_OBJECT && OBJ_obj2nid(oid->value.object) == NID_sha256 &&
            hash->type == V_ASN1_OCTET_STRING && ASN1_STRING_length(hash->value.octet_string) == SHA256_DIGEST_LENGTH &&
            CRYPTO_memcmp(ASN1_STRING_get0_data(hash->value.octet_string), strongHash, SHA256_DIGEST_LENGTH) == 0;
    }
    sk_ASN1_TYPE_pop_free(sequence, ASN1_TYPE_free);
    if (!bound) return nil;
    ASN1_TYPE *legacyHashes = attribute("1.2.840.113635.100.9.1");
    if (!legacyHashes || legacyHashes->type != V_ASN1_OCTET_STRING) return nil;
    NSData *plistData = [NSData dataWithBytes:ASN1_STRING_get0_data(legacyHashes->value.octet_string)
                                     length:ASN1_STRING_length(legacyHashes->value.octet_string)];
    id plist = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:NULL error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]] || [(NSDictionary *)plist count] != 1) return nil;
    id array = [(NSDictionary *)plist objectForKey:@"cdhashes"];
    if (![array isKindOfClass:[NSArray class]] || [(NSArray *)array count] != (alternateCodeDirectory ? 2 : 1)) return nil;
    NSData *strongTruncated = [NSData dataWithBytes:strongHash length:20];
    if (alternateCodeDirectory) {
        unsigned char weakHash[SHA_DIGEST_LENGTH];
        SHA1(static_cast<const unsigned char *>(codeDirectory.bytes), codeDirectory.length, weakHash);
        if (![[array objectAtIndex:0] isEqual:[NSData dataWithBytes:weakHash length:20]]) return nil;
    }
    if (![[array lastObject] isEqual:strongTruncated]) return nil;
    STACK_OF(X509) *signers = CMS_get0_signers(cms.get());
    if (!signers || sk_X509_num(signers) != 1) { sk_X509_free(signers); return nil; }
    unsigned char *bytes = NULL;
    int length = i2d_X509(sk_X509_value(signers, 0), &bytes);
    NSData *der = length > 0 && bytes ? [NSData dataWithBytes:bytes length:static_cast<NSUInteger>(length)] : nil;
    OPENSSL_free(bytes); sk_X509_free(signers);
    return der;
}

// The pinned CMS writer has a finite issuer set. Surface an unsupported result
// during resolution rather than showing Ready and failing in native signing.
bool VexNativeSupportsSigningCertificate(NSData *certificateDER) {
    if (!certificateDER.length || certificateDER.length > 64 * 1024) return false;
    return ZSignAsset::SupportsSigningCertificate(string(static_cast<const char *>(certificateDER.bytes), certificateDER.length));
}
