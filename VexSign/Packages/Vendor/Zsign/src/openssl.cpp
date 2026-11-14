#include "common.h"
#include "base64.h"
#include "openssl.h"
#include <openssl/pem.h>
#include <openssl/cms.h>
#include <openssl/err.h>
#include <openssl/provider.h>
#include <openssl/pkcs12.h>
#include <openssl/conf.h>
#include <memory>

const char* ZSignAsset::s_szAppleDevCACert = ""
"-----BEGIN CERTIFICATE-----\n"
"MIIEIjCCAwqgAwIBAgIIAd68xDltoBAwDQYJKoZIhvcNAQEFBQAwYjELMAkGA1UE\n"
"BhMCVVMxEzARBgNVBAoTCkFwcGxlIEluYy4xJjAkBgNVBAsTHUFwcGxlIENlcnRp\n"
"ZmljYXRpb24gQXV0aG9yaXR5MRYwFAYDVQQDEw1BcHBsZSBSb290IENBMB4XDTEz\n"
"MDIwNzIxNDg0N1oXDTIzMDIwNzIxNDg0N1owgZYxCzAJBgNVBAYTAlVTMRMwEQYD\n"
"VQQKDApBcHBsZSBJbmMuMSwwKgYDVQQLDCNBcHBsZSBXb3JsZHdpZGUgRGV2ZWxv\n"
"cGVyIFJlbGF0aW9uczFEMEIGA1UEAww7QXBwbGUgV29ybGR3aWRlIERldmVsb3Bl\n"
"ciBSZWxhdGlvbnMgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkwggEiMA0GCSqGSIb3\n"
"DQEBAQUAA4IBDwAwggEKAoIBAQDKOFSmy1aqyCQ5SOmM7uxfuH8mkbw0U3rOfGOA\n"
"YXdkXqUHI7Y5/lAtFVZYcC1+xG7BSoU+L/DehBqhV8mvexj/avoVEkkVCBmsqtsq\n"
"Mu2WY2hSFT2Miuy/axiV4AOsAX2XBWfODoWVN2rtCbauZ81RZJ/GXNG8V25nNYB2\n"
"NqSHgW44j9grFU57Jdhav06DwY3Sk9UacbVgnJ0zTlX5ElgMhrgWDcHld0WNUEi6\n"
"Ky3klIXh6MSdxmilsKP8Z35wugJZS3dCkTm59c3hTO/AO0iMpuUhXf1qarunFjVg\n"
"0uat80YpyejDi+l5wGphZxWy8P3laLxiX27Pmd3vG2P+kmWrAgMBAAGjgaYwgaMw\n"
"HQYDVR0OBBYEFIgnFwmpthhgi+zruvZHWcVSVKO3MA8GA1UdEwEB/wQFMAMBAf8w\n"
"HwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wLgYDVR0fBCcwJTAjoCGg\n"
"H4YdaHR0cDovL2NybC5hcHBsZS5jb20vcm9vdC5jcmwwDgYDVR0PAQH/BAQDAgGG\n"
"MBAGCiqGSIb3Y2QGAgEEAgUAMA0GCSqGSIb3DQEBBQUAA4IBAQBPz+9Zviz1smwv\n"
"j+4ThzLoBTWobot9yWkMudkXvHcs1Gfi/ZptOllc34MBvbKuKmFysa/Nw0Uwj6OD\n"
"Dc4dR7Txk4qjdJukw5hyhzs+r0ULklS5MruQGFNrCk4QttkdUGwhgAqJTleMa1s8\n"
"Pab93vcNIx0LSiaHP7qRkkykGRIZbVf1eliHe2iK5IaMSuviSRSqpd1VAKmuu0sw\n"
"ruGgsbwpgOYJd+W+NKIByn/c4grmO7i77LpilfMFY0GCzQ87HUyVpNur+cmV6U/k\n"
"TecmmYHpvPm0KdIBembhLoz2IYrF+Hjhga6/05Cdqa3zr/04GpZnMBxRpVzscYqC\n"
"tGwPDBUf\n"
"-----END CERTIFICATE-----\n";

const char* ZSignAsset::s_szAppleDevCACertG3 = ""
"-----BEGIN CERTIFICATE-----\n"
"MIIEUTCCAzmgAwIBAgIQfK9pCiW3Of57m0R6wXjF7jANBgkqhkiG9w0BAQsFADBi\n"
"MQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBw\n"
"bGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3Qg\n"
"Q0EwHhcNMjAwMjE5MTgxMzQ3WhcNMzAwMjIwMDAwMDAwWjB1MUQwQgYDVQQDDDtB\n"
"cHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9u\n"
"IEF1dGhvcml0eTELMAkGA1UECwwCRzMxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJ\n"
"BgNVBAYTAlVTMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2PWJ/KhZ\n"
"C4fHTJEuLVaQ03gdpDDppUjvC0O/LYT7JF1FG+XrWTYSXFRknmxiLbTGl8rMPPbW\n"
"BpH85QKmHGq0edVny6zpPwcR4YS8Rx1mjjmi6LRJ7TrS4RBgeo6TjMrA2gzAg9Dj\n"
"+ZHWp4zIwXPirkbRYp2SqJBgN31ols2N4Pyb+ni743uvLRfdW/6AWSN1F7gSwe0b\n"
"5TTO/iK1nkmw5VW/j4SiPKi6xYaVFuQAyZ8D0MyzOhZ71gVcnetHrg21LYwOaU1A\n"
"0EtMOwSejSGxrC5DVDDOwYqGlJhL32oNP/77HK6XF8J4CjDgXx9UO0m3JQAaN4LS\n"
"VpelUkl8YDib7wIDAQABo4HvMIHsMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0j\n"
"BBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wRAYIKwYBBQUHAQEEODA2MDQGCCsG\n"
"AQUFBzABhihodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNh\n"
"MC4GA1UdHwQnMCUwI6AhoB+GHWh0dHA6Ly9jcmwuYXBwbGUuY29tL3Jvb3QuY3Js\n"
"MB0GA1UdDgQWBBQJ/sAVkPmvZAqSErkmKGMMl+ynsjAOBgNVHQ8BAf8EBAMCAQYw\n"
"EAYKKoZIhvdjZAYCAQQCBQAwDQYJKoZIhvcNAQELBQADggEBAK1lE+j24IF3RAJH\n"
"Qr5fpTkg6mKp/cWQyXMT1Z6b0KoPjY3L7QHPbChAW8dVJEH4/M/BtSPp3Ozxb8qA\n"
"HXfCxGFJJWevD8o5Ja3T43rMMygNDi6hV0Bz+uZcrgZRKe3jhQxPYdwyFot30ETK\n"
"XXIDMUacrptAGvr04NM++i+MZp+XxFRZ79JI9AeZSWBZGcfdlNHAwWx/eCHvDOs7\n"
"bJmCS1JgOLU5gm3sUjFTvg+RTElJdI+mUcuER04ddSduvfnSXPN/wmwLCTbiZOTC\n"
"NwMUGdXqapSqqdv+9poIZ4vvK7iqF0mDr8/LvOnP6pVxsLRFoszlh6oKw0E6eVza\n"
"UDSdlTs=\n"
"-----END CERTIFICATE-----\n";

const char* ZSignAsset::s_szAppleRootCACert = ""
"-----BEGIN CERTIFICATE-----\n"
"MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzET\n"
"MBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlv\n"
"biBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0\n"
"MDM2WhcNMzUwMjA5MjE0MDM2WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBw\n"
"bGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx\n"
"FjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw\n"
"ggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne+Uts9QerIjAC6Bg+\n"
"+FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4UadHJGXL1\n"
"XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9w\n"
"tj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IW\n"
"q6NxkkdTVcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKM\n"
"aLOPHd5lc/9nXmW8Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8E\n"
"BAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3\n"
"R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wggERBgNVHSAE\n"
"ggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggrBgEFBQcCARYeaHR0cHM6Ly93\n"
"d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCBthqBs1JlbGlhbmNl\n"
"IG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0\n"
"YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBj\n"
"b25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZp\n"
"Y2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBc\n"
"NplMLXi37Yyb3PN3m/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQP\n"
"y3lPNNiiPvl4/2vIB+x9OYOLUyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7\n"
"R6PVbyTi69G3cN8PReEnyvFteO3ntRcXqNx+IjXKJdXZD9Zr1KIkIxH3oayPc4Fg\n"
"xhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uujL/lTaltkwGMzd/c6ByxW69oP\n"
"IQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIqxw8dtk2cXmPIS4AX\n"
"UKqK1drk/NAJBzewdXUh\n"
"-----END CERTIFICATE-----\n";

ZSignAsset::OpenSSLInit::OpenSSLInit()
{
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	OpenSSL_add_all_algorithms();
	ERR_load_crypto_strings();
#endif
}

bool ZSignAsset::CMSError()
{
	ERR_print_errors_fp(stdout);
	return false;
}

void* ZSignAsset::GenerateASN1Type(const string& value)
{
    // A bounded SHA256 AlgorithmIdentifier + digest sequence. Avoid a dynamic
    // config parser (and its assert/double-free failure paths) for 32 bytes.
    if (value.size() != 64) return NULL;
    auto hex = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    string encoded("\x30\x2d\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x04\x20", 15);
    for (size_t index = 0; index < value.size(); index += 2) {
        int high = hex(value[index]), low = hex(value[index + 1]);
        if (high < 0 || low < 0) return NULL;
        encoded.push_back(static_cast<char>((high << 4) | low));
    }
    const unsigned char* cursor = reinterpret_cast<const unsigned char*>(encoded.data());
    return d2i_ASN1_TYPE(NULL, &cursor, encoded.size());
}

namespace {
const char* SigningIssuerPEM(X509* certificate)
{
    if (!certificate) return NULL;
    unsigned long hash = X509_issuer_name_hash(certificate);
    if (hash == 0x817d2f7a) return ZSignAsset::s_szAppleDevCACert;
    if (hash == 0x9b16b75c) return ZSignAsset::s_szAppleDevCACertG3;
    return NULL;
}
}

bool ZSignAsset::SupportsSigningCertificate(const string& der)
{
    if (der.empty() || der.size() > 64 * 1024) return false;
    const unsigned char* start = reinterpret_cast<const unsigned char*>(der.data());
    const unsigned char* cursor = start;
    std::unique_ptr<X509, decltype(&X509_free)> certificate(d2i_X509(NULL, &cursor, der.size()), X509_free);
    if (!certificate || cursor != start + der.size()) return false;
    const char* pem = SigningIssuerPEM(certificate.get());
    if (!pem) return false;
    std::unique_ptr<BIO, decltype(&BIO_free)> input(BIO_new_mem_buf(pem, -1), BIO_free);
    std::unique_ptr<X509, decltype(&X509_free)> issuer(input ? PEM_read_bio_X509(input.get(), NULL, NULL, NULL) : NULL, X509_free);
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key(issuer ? X509_get_pubkey(issuer.get()) : NULL, EVP_PKEY_free);
    return issuer && key && X509_NAME_cmp(X509_get_issuer_name(certificate.get()), X509_get_subject_name(issuer.get())) == 0 &&
        X509_verify(certificate.get(), key.get()) == 1;
}

bool ZSignAsset::GenerateCMS(void* pscert, void* pspkey, const string& strCDHashData, const string& strCDHashesPlist, const string& strCodeDirectorySlotSHA1, const string& strAltnateCodeDirectorySlot256, string& strCMSOutput)
{
    strCMSOutput.clear();
    X509* certificate = static_cast<X509*>(pscert);
    EVP_PKEY* key = static_cast<EVP_PKEY*>(pspkey);
    const char* issuerPEM = SigningIssuerPEM(certificate);
    if (!certificate || !key || !issuerPEM || strCDHashData.empty() || strCDHashData.size() > 16 * 1024 * 1024 ||
        strCDHashesPlist.empty() || strCDHashesPlist.size() > 1024 * 1024 || strAltnateCodeDirectorySlot256.size() != 32 ||
        X509_check_private_key(certificate, key) != 1) return false;
    std::unique_ptr<BIO, decltype(&BIO_free)> issuerInput(BIO_new_mem_buf(issuerPEM, -1), BIO_free);
    std::unique_ptr<BIO, decltype(&BIO_free)> rootInput(BIO_new_mem_buf(s_szAppleRootCACert, -1), BIO_free);
    std::unique_ptr<X509, decltype(&X509_free)> issuer(issuerInput ? PEM_read_bio_X509(issuerInput.get(), NULL, NULL, NULL) : NULL, X509_free);
    std::unique_ptr<X509, decltype(&X509_free)> root(rootInput ? PEM_read_bio_X509(rootInput.get(), NULL, NULL, NULL) : NULL, X509_free);
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> issuerKey(issuer ? X509_get_pubkey(issuer.get()) : NULL, EVP_PKEY_free);
    if (!issuer || !root || !issuerKey || X509_NAME_cmp(X509_get_issuer_name(certificate), X509_get_subject_name(issuer.get())) != 0 ||
        X509_verify(certificate, issuerKey.get()) != 1) return false;
    auto freeStack = [](STACK_OF(X509)* value) { sk_X509_free(value); };
    std::unique_ptr<STACK_OF(X509), decltype(freeStack)> chain(sk_X509_new_null(), freeStack);
    if (!chain || !sk_X509_push(chain.get(), issuer.get()) || !sk_X509_push(chain.get(), root.get())) return false;
    const int flags = CMS_PARTIAL | CMS_DETACHED | CMS_NOSMIMECAP | CMS_BINARY;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(CMS_sign(NULL, NULL, chain.get(), NULL, flags), CMS_ContentInfo_free);
    if (!cms) return CMSError();
    CMS_SignerInfo* signer = CMS_add1_signer(cms.get(), certificate, key, EVP_sha256(), flags);
    std::unique_ptr<ASN1_OBJECT, decltype(&ASN1_OBJECT_free)> plistOID(OBJ_txt2obj("1.2.840.113635.100.9.1", 1), ASN1_OBJECT_free);
    std::unique_ptr<ASN1_OBJECT, decltype(&ASN1_OBJECT_free)> digestOID(OBJ_txt2obj("1.2.840.113635.100.9.2", 1), ASN1_OBJECT_free);
    string hex;
    static const char alphabet[] = "0123456789abcdef";
    for (unsigned char byte : strAltnateCodeDirectorySlot256) { hex.push_back(alphabet[byte >> 4]); hex.push_back(alphabet[byte & 15]); }
    std::unique_ptr<ASN1_TYPE, decltype(&ASN1_TYPE_free)> digest(static_cast<ASN1_TYPE*>(GenerateASN1Type(hex)), ASN1_TYPE_free);
    if (!signer || !plistOID || !digestOID || !digest || digest->type != V_ASN1_SEQUENCE ||
        !CMS_signed_add1_attr_by_OBJ(signer, plistOID.get(), V_ASN1_OCTET_STRING, strCDHashesPlist.data(), strCDHashesPlist.size()) ||
        !CMS_signed_add1_attr_by_OBJ(signer, digestOID.get(), V_ASN1_SEQUENCE,
            ASN1_STRING_get0_data(digest->value.sequence), ASN1_STRING_length(digest->value.sequence))) return CMSError();
    std::unique_ptr<BIO, decltype(&BIO_free)> content(BIO_new_mem_buf(strCDHashData.data(), strCDHashData.size()), BIO_free);
    std::unique_ptr<BIO, decltype(&BIO_free)> output(BIO_new(BIO_s_mem()), BIO_free);
    if (!content || !output || !CMS_final(cms.get(), content.get(), NULL, flags) || !i2d_CMS_bio(output.get(), cms.get())) return CMSError();
    char* bytes = NULL;
    long length = BIO_get_mem_data(output.get(), &bytes);
    if (length <= 0 || length > 1024 * 1024 || !bytes) return false;
    strCMSOutput.assign(bytes, length);
    return true;
}

bool ZSignAsset::GetCMSContent(const string& strCMSDataInput, string& strContentOutput)
{
    // Extraction only. Profile authority is established by the authenticated
    // Swift/Security admission path, never by finding a parseable XML substring.
    strContentOutput.clear();
    if (strCMSDataInput.empty() || strCMSDataInput.size() > 10 * 1024 * 1024) return false;
    const unsigned char* start = reinterpret_cast<const unsigned char*>(strCMSDataInput.data()), *cursor = start;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(
        d2i_CMS_ContentInfo(NULL, &cursor, strCMSDataInput.size()), CMS_ContentInfo_free);
    if (!cms || cursor != start + strCMSDataInput.size() || CMS_is_detached(cms.get()) != 0) return false;
    ASN1_OCTET_STRING** content = CMS_get0_content(cms.get());
    if (!content || !*content || ASN1_STRING_length(*content) <= 0) return false;
    strContentOutput.assign(reinterpret_cast<const char*>(ASN1_STRING_get0_data(*content)), ASN1_STRING_length(*content));
    return true;
}

bool ZSignAsset::GetCertSubjectCN(void* pcert, string& strSubjectCN)
{
    strSubjectCN.clear();
    if (!pcert) return false;
    X509_NAME* name = X509_get_subject_name(static_cast<X509*>(pcert));
    const int index = X509_NAME_get_index_by_NID(name, NID_commonName, -1);
    if (index < 0 || X509_NAME_get_index_by_NID(name, NID_commonName, index) >= 0) return false;
    X509_NAME_ENTRY* entry = X509_NAME_get_entry(name, index);
    ASN1_STRING* value = entry ? X509_NAME_ENTRY_get_data(entry) : NULL;
    if (!value) return false;
    unsigned char* utf8 = NULL;
    const int length = ASN1_STRING_to_UTF8(&utf8, value);
    const bool valid = utf8 && length > 0 && length <= 1024 && memchr(utf8, 0, length) == NULL;
    if (valid) strSubjectCN.assign(reinterpret_cast<char*>(utf8), length);
    OPENSSL_free(utf8);
    return valid;
}

bool ZSignAsset::GetCertSubjectCN(const string& strCertData, string& strSubjectCN)
{
    strSubjectCN.clear();
    if (strCertData.empty() || strCertData.size() > 64 * 1024) return false;
    std::unique_ptr<BIO, decltype(&BIO_free)> buffer(BIO_new_mem_buf(strCertData.data(), strCertData.size()), BIO_free);
    if (!buffer) return false;
    std::unique_ptr<X509, decltype(&X509_free)> cert(PEM_read_bio_X509(buffer.get(), NULL, 0, NULL), X509_free);
    return cert && GetCertSubjectCN(cert.get(), strSubjectCN);
}

void ZSignAsset::ParseCertSubject(const string& strSubject, jvalue& jvSubject)
{
	vector<string> arrNodes;
	ZUtil::StringSplit(strSubject, "/", arrNodes);
	for (size_t i = 0; i < arrNodes.size(); i++) {
		vector<string> arrLines;
		ZUtil::StringSplit(arrNodes[i], "=", arrLines);
		if (2 == arrLines.size()) {
			jvSubject[arrLines[0]] = arrLines[1];
		}
	}
}

string ZSignAsset::ASN1_TIMEtoString(const void* time)
{
    std::unique_ptr<BIO, decltype(&BIO_free)> output(BIO_new(BIO_s_mem()), BIO_free);
    if (!time || !output || ASN1_TIME_print(output.get(), static_cast<const ASN1_TIME*>(time)) != 1) return "";
    BUF_MEM* data = NULL;
    BIO_get_mem_ptr(output.get(), &data);
    return data && data->data ? string(data->data, data->length) : "";
}

bool ZSignAsset::GetCertInfo(void* pcert, jvalue & jvCertInfo)
{
	if (!pcert) {
		return CMSError();
	}

	X509* cert = (X509*)pcert;

	jvCertInfo["Version"] = (int)X509_get_version(cert);

	ASN1_INTEGER* asn1_i = X509_get_serialNumber(cert);
	if (asn1_i) {
        std::unique_ptr<BIGNUM, decltype(&BN_free)> number(ASN1_INTEGER_to_BN(asn1_i, NULL), BN_free);
        if (number) {
            char* serial = BN_bn2hex(number.get());
            if (serial) jvCertInfo["SerialNumber"] = serial;
            OPENSSL_free(serial);
        }
	}

	jvCertInfo["SignatureAlgorithm"] = OBJ_nid2ln(X509_get_signature_nid(cert));

    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> publicKey(X509_get_pubkey(cert), EVP_PKEY_free);
    if (!publicKey) return false;
    const char* algorithm = OBJ_nid2ln(EVP_PKEY_base_id(publicKey.get()));
    if (algorithm) jvCertInfo["PublicKey"]["Algorithm"] = algorithm;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
	jvCertInfo["Validity"]["NotBefore"] = ASN1_TIMEtoString(X509_get_notBefore(cert));
	jvCertInfo["Validity"]["NotAfter"] = ASN1_TIMEtoString(X509_get_notAfter(cert));
#else
	jvCertInfo["Validity"]["NotBefore"] = ASN1_TIMEtoString(X509_get0_notBefore(cert));
	jvCertInfo["Validity"]["NotAfter"] = ASN1_TIMEtoString(X509_get0_notAfter(cert));
#endif

    char* issuer = X509_NAME_oneline(X509_get_issuer_name(cert), NULL, 0);
    char* subject = X509_NAME_oneline(X509_get_subject_name(cert), NULL, 0);
    const string strIssuer = issuer ? issuer : "", strSubject = subject ? subject : "";
    OPENSSL_free(issuer); OPENSSL_free(subject);

	ParseCertSubject(strIssuer, jvCertInfo["Issuer"]);
	ParseCertSubject(strSubject, jvCertInfo["Subject"]);

	return (!strIssuer.empty() && !strSubject.empty());
}

bool ZSignAsset::GetCMSInfo(uint8_t * pCMSData, uint32_t uCMSLength, jvalue & jvOutput)
{
    // Diagnostics only: parsing metadata is not CMS authentication.
    if (!pCMSData || uCMSLength == 0 || uCMSLength > 10 * 1024 * 1024) return false;
    const unsigned char* cursor = pCMSData;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> owned(
        d2i_CMS_ContentInfo(NULL, &cursor, uCMSLength), CMS_ContentInfo_free);
    CMS_ContentInfo* cms = owned.get();
    if (!cms || cursor != pCMSData + uCMSLength) return false;

	int detached = CMS_is_detached(cms);
	jvOutput["detached"] = detached;

	const ASN1_OBJECT* obj = CMS_get0_type(cms);
	const char* sn = OBJ_nid2ln(OBJ_obj2nid(obj));
	jvOutput["contentType"] = sn;

	ASN1_OCTET_STRING** pos = CMS_get0_content(cms);
	if (pos) {
		if ((*pos)) {
			jbase64 b64;
			jvOutput["content"] = b64.encode((const char*)(*pos)->data, (*pos)->length);
		}
	}

    auto freeCertificates = [](STACK_OF(X509)* values) { sk_X509_pop_free(values, X509_free); };
    std::unique_ptr<STACK_OF(X509), decltype(freeCertificates)> ownedCertificates(CMS_get1_certs(cms), freeCertificates);
    STACK_OF(X509)* certs = ownedCertificates.get();
    if (!certs || sk_X509_num(certs) > 16) return false;
	for (int i = 0; i < sk_X509_num(certs); i++) {
		jvalue jvCertInfo;
		if (GetCertInfo(sk_X509_value(certs, i), jvCertInfo)) {
			jvOutput["certs"].push_back(jvCertInfo);
		}
	}

	STACK_OF(CMS_SignerInfo)* sis = CMS_get0_SignerInfos(cms);
    if (!sis || sk_CMS_SignerInfo_num(sis) < 1 || sk_CMS_SignerInfo_num(sis) > 16) return false;
	for (int i = 0; i < sk_CMS_SignerInfo_num(sis); i++) {
		CMS_SignerInfo* si = sk_CMS_SignerInfo_value(sis, i);
		//int CMS_SignerInfo_get0_signer_id(CMS_SignerInfo *si, ASN1_OCTET_STRING **keyid, X509_NAME **issuer, ASN1_INTEGER **sno);

		int nSignedAttsCount = CMS_signed_get_attr_count(si);
        if (nSignedAttsCount > 128) return false;
		for (int j = 0; j < nSignedAttsCount; j++) {
			X509_ATTRIBUTE* attr = CMS_signed_get_attr(si, j);
			if (!attr) {
				continue;
			}
			int nCount = X509_ATTRIBUTE_count(attr);
            if (nCount > 16) return false;
			if (nCount <= 0) {
				continue;
			}

			ASN1_OBJECT* obj = X509_ATTRIBUTE_get0_object(attr);
			if (!obj) {
				continue;
			}

			char txtobj[128] = { 0 };
			OBJ_obj2txt(txtobj, 128, obj, 1);

			if (0 == strcmp("1.2.840.113549.1.9.3", txtobj)) { //V_ASN1_OBJECT
				ASN1_TYPE* av = X509_ATTRIBUTE_get0_type(attr, 0);
                if (!av || av->type != V_ASN1_OBJECT) return false;
				if (NULL != av) {
					jvOutput["attrs"]["ContentType"]["obj"] = txtobj;
					jvOutput["attrs"]["ContentType"]["data"] = OBJ_nid2ln(OBJ_obj2nid(av->value.object));
				}
			} else if (0 == strcmp("1.2.840.113549.1.9.4", txtobj)) { //V_ASN1_OCTET_STRING
				ASN1_TYPE* av = X509_ATTRIBUTE_get0_type(attr, 0);
                if (!av || av->type != V_ASN1_OCTET_STRING) return false;
				if (NULL != av) {
					string strSHASum;
					char buf[16] = { 0 };
					for (int m = 0; m < av->value.octet_string->length; m++) {
						snprintf(buf, sizeof(buf), "%02x", (uint8_t)av->value.octet_string->data[m]);
						strSHASum += buf;
					}
					jvOutput["attrs"]["MessageDigest"]["obj"] = txtobj;
					jvOutput["attrs"]["MessageDigest"]["data"] = strSHASum;
				}
			} else if (0 == strcmp("1.2.840.113549.1.9.5", txtobj)) { //V_ASN1_UTCTIME
				ASN1_TYPE* av = X509_ATTRIBUTE_get0_type(attr, 0);
                if (!av || av->type != V_ASN1_UTCTIME) return false;
				if (NULL != av) {
                    std::unique_ptr<BIO, decltype(&BIO_free)> output(BIO_new(BIO_s_mem()), BIO_free);
                    BIO* mem = output.get();
                    if (!mem || ASN1_UTCTIME_print(mem, av->value.utctime) != 1) return false;
					BUF_MEM* bptr = NULL;
					BIO_get_mem_ptr(mem, &bptr);
                    if (!bptr || !bptr->data) return false;
					string strTime;
					strTime.append(bptr->data, bptr->length);

					jvOutput["attrs"]["SigningTime"]["obj"] = txtobj;
					jvOutput["attrs"]["SigningTime"]["data"] = strTime;
				}
			} else if (0 == strcmp("1.2.840.113635.100.9.2", txtobj)) { //V_ASN1_SEQUENCE
				jvOutput["attrs"]["CDHashes2"]["obj"] = txtobj;
				for (int m = 0; m < nCount; m++) {
					ASN1_TYPE* av = X509_ATTRIBUTE_get0_type(attr, m);
                    if (!av || av->type != V_ASN1_SEQUENCE) return false;
					if (NULL != av) {
						ASN1_STRING* s = av->value.sequence;
                        std::unique_ptr<BIO, decltype(&BIO_free)> output(BIO_new(BIO_s_mem()), BIO_free);
                        BIO* mem = output.get();
                        if (!mem || ASN1_parse_dump(mem, s->data, s->length, 2, 0) != 1) return false;
						BUF_MEM* bptr = NULL;
						BIO_get_mem_ptr(mem, &bptr);
                        if (!bptr || !bptr->data) return false;
						string strData;
						strData.append(bptr->data, bptr->length);

						string strSHASum;
						size_t pos1 = strData.find("[HEX DUMP]:");
						if (string::npos != pos1) {
							size_t pos2 = strData.find("\n", pos1);
							if (string::npos != pos2) {
								strSHASum = strData.substr(pos1 + 11, pos2 - pos1 - 11);
							}
						}
						transform(strSHASum.begin(), strSHASum.end(), strSHASum.begin(), ::tolower);
						jvOutput["attrs"]["CDHashes2"]["data"].push_back(strSHASum);
					}
				}
			} else if (0 == strcmp("1.2.840.113635.100.9.1", txtobj)) { //V_ASN1_OCTET_STRING
				ASN1_TYPE* av = X509_ATTRIBUTE_get0_type(attr, 0);
                if (!av || av->type != V_ASN1_OCTET_STRING) return false;
				if (NULL != av) {
					string strPList;
					strPList.append((const char*)av->value.octet_string->data, av->value.octet_string->length);
					jvOutput["attrs"]["CDHashes"]["obj"] = txtobj;
					jvOutput["attrs"]["CDHashes"]["data"] = strPList;
				}
			} else {
				ASN1_TYPE* av = X509_ATTRIBUTE_get0_type(attr, 0);
				if (NULL != av) {
					jvalue jvAttr;
					jvAttr["obj"] = txtobj;
					jvAttr["name"] = OBJ_nid2ln(OBJ_obj2nid(obj));
					jvAttr["type"] = av->type;
					jvAttr["count"] = nCount;
					jvOutput["attrs"]["unknown"].push_back(jvAttr);
				}
			}
		}
	}

	return true;
}

ZSignAsset::ZSignAsset()
{
	m_evpPKey = NULL;
	m_x509Cert = NULL;
	m_bAdhoc = false;
	m_bSingleBinary = false;
	m_bSHA256Only = false;
}

ZSignAsset::~ZSignAsset()
{
    EVP_PKEY_free(static_cast<EVP_PKEY*>(m_evpPKey));
    X509_free(static_cast<X509*>(m_x509Cert));
}

bool ZSignAsset::Init(
	const string& strCertFile,
	const string& strPKeyFile, 
	const string& strProvFile, 
	const string& strEntitleFile, 
	const string& strPassword,
	bool bAdhoc,
	bool bSHA256Only,
	bool bSingleBinary)
{
    EVP_PKEY_free(static_cast<EVP_PKEY*>(m_evpPKey)); m_evpPKey = NULL;
    X509_free(static_cast<X509*>(m_x509Cert)); m_x509Cert = NULL;
    m_strTeamId.clear(); m_strSubjectCN.clear(); m_strProvData.clear(); m_strEntitleData.clear();
	m_bAdhoc = bAdhoc;
	m_bSHA256Only = bSHA256Only;
	m_bSingleBinary = bSingleBinary;

	if (m_bAdhoc) {
		if (!strEntitleFile.empty()) {
			if (!ZFile::ReadFile(strEntitleFile.c_str(), m_strEntitleData)) {
				ZLog::Error(">>> Can't read entitlements file!\n");
				return false;
			}
		}
		return true;
	}

	ZFile::ReadFile(strProvFile.c_str(), m_strProvData);
	ZFile::ReadFile(strEntitleFile.c_str(), m_strEntitleData);
	if (m_strProvData.empty()) {
		ZLog::Error(">>> Can't find provision file!\n");
		return false;
	}

	jvalue jvProv;
	string strProvContent;
	if (GetCMSContent(m_strProvData, strProvContent)) {
		if (jvProv.read_plist(strProvContent)) {
			m_strTeamId = jvProv["TeamIdentifier"][0].as_cstr();
            // A profile is a capability ceiling, never an entitlement template.
            // Device-signing callers must supply a component-specific checked plan.
            if (m_strEntitleData.empty()) {
                ZLog::Error(">>> Explicit component entitlements are required.\n");
                return false;
            }
		}
	}

	if (m_strTeamId.empty()) {
		ZLog::Error(">>> Can't find TeamId!\n");
		return false;
	}

    // Provider references are run-owned. Repeated failed imports must not leak
    // a legacy-provider reference; explicitly keep the default provider loaded
    // too, since loading legacy first disables automatic default loading.
    std::unique_ptr<OSSL_PROVIDER, decltype(&OSSL_PROVIDER_unload)> primaryProvider(
        OSSL_PROVIDER_load(NULL, "default"), OSSL_PROVIDER_unload);
    std::unique_ptr<OSSL_PROVIDER, decltype(&OSSL_PROVIDER_unload)> legacyProvider(
        OSSL_PROVIDER_load(NULL, "legacy"), OSSL_PROVIDER_unload);
    if (!primaryProvider) return false;
    X509* x509Cert = NULL;
    EVP_PKEY* evpPKey = NULL;
    struct ImportCleanup {
        X509*& certificate; EVP_PKEY*& key;
        ~ImportCleanup() { X509_free(certificate); EVP_PKEY_free(key); }
    } cleanup{x509Cert, evpPKey};
	BIO* bioPKey = BIO_new_file(strPKeyFile.c_str(), "rb");
	if (NULL != bioPKey) {
		evpPKey = PEM_read_bio_PrivateKey(bioPKey, NULL, NULL, (void*)strPassword.c_str());
		if (NULL == evpPKey) {
            ERR_clear_error();
			BIO_reset(bioPKey);
			evpPKey = d2i_PrivateKey_bio(bioPKey, NULL);
			if (NULL == evpPKey) {
                ERR_clear_error();
				BIO_reset(bioPKey);
				PKCS12* p12 = d2i_PKCS12_bio(bioPKey, NULL);
				if (NULL != p12) {
					if (0 == PKCS12_parse(p12, strPassword.c_str(), &evpPKey, &x509Cert, NULL)) {
						CMSError();
					}
					PKCS12_free(p12);
				} else {
					CMSError();
				}
			}
		}
		BIO_free(bioPKey);
	}

	if (NULL == evpPKey) {
		ZLog::Error(">>> Can't load p12 or private key file. Please input the correct file and password!\n");
		return false;
	}

	if (NULL == x509Cert && !strCertFile.empty()) {
		BIO* bioCert = BIO_new_file(strCertFile.c_str(), "r");
		if (NULL != bioCert) {
			x509Cert = PEM_read_bio_X509(bioCert, NULL, 0, NULL);
			if (NULL == x509Cert) {
				BIO_reset(bioCert);
				x509Cert = d2i_X509_bio(bioCert, NULL);
			}
			BIO_free(bioCert);
		}
	}

	if (NULL != x509Cert) {
		if (!X509_check_private_key(x509Cert, evpPKey)) {
			X509_free(x509Cert);
			x509Cert = NULL;
		}
	}

	if (NULL == x509Cert) {
		for (size_t i = 0; i < jvProv["DeveloperCertificates"].size(); i++) {
			string strCertData = jvProv["DeveloperCertificates"][i].as_data();
			BIO* bioCert = BIO_new_mem_buf(strCertData.c_str(), (int)strCertData.size());
			if (NULL != bioCert) {
				x509Cert = d2i_X509_bio(bioCert, NULL);
				if (NULL != x509Cert) {
                    if (X509_check_private_key(x509Cert, evpPKey)) {
                        BIO_free(bioCert);
						break;
					}
					X509_free(x509Cert);
					x509Cert = NULL;
				}
				BIO_free(bioCert);
			}
		}
	}

	if (NULL == x509Cert) {
		ZLog::Error(">>> Can't find paired certificate and private key!\n");
		return false;
	}

    // A PKCS#12-supplied leaf is not automatically authorized by the profile.
    // Compare the complete DER even when it already matches the private key;
    // previously only the fallback profile-certificate path did that pairing.
    unsigned char* rawCertificate = NULL;
    const int certificateLength = i2d_X509(x509Cert, &rawCertificate);
    string certificateDER;
    if (certificateLength > 0 && rawCertificate) certificateDER.assign(
        reinterpret_cast<const char*>(rawCertificate), certificateLength);
    OPENSSL_free(rawCertificate);
    bool namedByProfile = false;
    for (size_t index = 0; index < jvProv["DeveloperCertificates"].size(); ++index) {
        if (!certificateDER.empty() && jvProv["DeveloperCertificates"][index].as_data() == certificateDER) {
            namedByProfile = true; break;
        }
    }
    X509_NAME* subject = X509_get_subject_name(x509Cert);
    const int teamIndex = subject ? X509_NAME_get_index_by_NID(subject, NID_organizationalUnitName, -1) : -1;
    X509_NAME_ENTRY* teamEntry = teamIndex < 0 ? NULL : X509_NAME_get_entry(subject, teamIndex);
    ASN1_STRING* team = teamEntry ? X509_NAME_ENTRY_get_data(teamEntry) : NULL;
    if (!namedByProfile || !team || X509_NAME_get_index_by_NID(subject, NID_organizationalUnitName, teamIndex) >= 0 ||
        ASN1_STRING_length(team) != static_cast<int>(m_strTeamId.size()) ||
        memcmp(ASN1_STRING_get0_data(team), m_strTeamId.data(), m_strTeamId.size()) != 0 ||
        X509_cmp_current_time(X509_get0_notBefore(x509Cert)) != -1 ||
        X509_cmp_current_time(X509_get0_notAfter(x509Cert)) != 1) {
        ZLog::Error(">>> Certificate is not current or is not authorized by this profile's certificate/team.\n");
        return false;
    }

	if (!GetCertSubjectCN(x509Cert, m_strSubjectCN)) {
		ZLog::Error(">>> Can't find paired certificate subject common name!\n");
		return false;
	}

    m_evpPKey = evpPKey; evpPKey = NULL;
    m_x509Cert = x509Cert; x509Cert = NULL;
	return true;
}

bool ZSignAsset::GenerateCMS(const string& strCDHashData, const string& strCDHashesPlist, const string& strCodeDirectorySlotSHA1, const string& strAltnateCodeDirectorySlot256, string& strCMSOutput)
{
	return GenerateCMS((X509*)m_x509Cert, (EVP_PKEY*)m_evpPKey, strCDHashData, strCDHashesPlist, strCodeDirectorySlotSHA1, strAltnateCodeDirectorySlot256, strCMSOutput);
}
