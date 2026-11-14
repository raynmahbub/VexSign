// Credential-free behavioral tests of the production C++ signing core.
// All Mach-O images are generated data, never runnable applications. Ad-hoc
// output exercises directory/DER/layout code only; it is NOT device acceptance.
#include "common.h"
#include "macho.h"
#include "bundle.h"
#include "signing.h"
#include "base64.h"
#include <openssl/pem.h>
#include <openssl/cms.h>
#include <openssl/ec.h>
#include <openssl/pkcs12.h>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <cstdlib>
#include <ctime>

namespace fs = std::filesystem;
using Bytes = std::vector<uint8_t>;
static int failures = 0;
static int checks = 0;
static fs::path work;

static void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
static void test(const char* name, const std::function<void()>& body) {
    ++checks;
    try { body(); std::cout << "ok " << checks << " - " << name << '\n'; }
    catch (const std::exception& error) { ++failures; std::cerr << "not ok " << checks << " - " << name << ": " << error.what() << '\n'; }
}
static void put(Bytes& bytes, size_t offset, uint64_t value, size_t count = 4, bool big = false) {
    require(offset <= bytes.size() && count <= bytes.size() - offset, "fixture write bounds");
    for (size_t i = 0; i < count; ++i) bytes[offset + (big ? count - i - 1 : i)] = (value >> (8 * i)) & 0xff;
}
static uint64_t get(const Bytes& bytes, size_t offset, size_t count = 4, bool big = false) {
    require(offset <= bytes.size() && count <= bytes.size() - offset, "fixture read bounds");
    uint64_t value = 0;
    for (size_t i = 0; i < count; ++i) value |= uint64_t(bytes[offset + (big ? count - i - 1 : i)]) << (8 * i);
    return value;
}
static void text(Bytes& bytes, size_t offset, const std::string& value) {
    require(offset <= bytes.size() && value.size() <= bytes.size() - offset, "fixture string bounds");
    std::copy(value.begin(), value.end(), bytes.begin() + offset);
}
static std::string plist(const std::string& body) {
    return "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>" + body + "</dict></plist>";
}
static std::string info(const std::string& identifier, const std::string& executable = "App") {
    return plist("<key>CFBundleIdentifier</key><string>" + identifier + "</string>"
        "<key>CFBundleExecutable</key><string>" + executable + "</string>"
        "<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string>");
}

// __TEXT with a real bounded __text section, optional __info_plist, __LINKEDIT,
// iOS LC_BUILD_VERSION, and a zero-filled LC_CODE_SIGNATURE reservation.
static Bytes image(bool big = false, uint64_t vmSize = 4096, uint32_t type = MH_EXECUTE,
                   uint32_t reservation = 4096, const std::string& metadata = "") {
    const uint32_t code = 4096, size = code + (reservation ? reservation : 32);
    Bytes bytes(size, 0);
    const uint32_t textSize = 72 + 80 * (metadata.empty() ? 1 : 2);
    const uint32_t link = 32 + textSize, version = link + 72, sign = version + 24;
    put(bytes, 0, MH_MAGIC_64, 4, big); put(bytes, 4, CPU_TYPE_ARM64, 4, big);
    put(bytes, 8, 0, 4, big); put(bytes, 12, type, 4, big);
    put(bytes, 16, reservation ? 4 : 3, 4, big);
    put(bytes, 20, textSize + 72 + 24 + (reservation ? 16 : 0), 4, big);
    put(bytes, 32, LC_SEGMENT_64, 4, big); put(bytes, 36, textSize, 4, big);
    text(bytes, 40, "__TEXT"); put(bytes, 64, vmSize, 8, big);
    put(bytes, 80, code, 8, big); put(bytes, 88, 5, 4, big); put(bytes, 92, 5, 4, big);
    put(bytes, 96, metadata.empty() ? 1 : 2, 4, big);
    text(bytes, 104, "__text"); text(bytes, 120, "__TEXT");
    put(bytes, 136, 1024, 8, big); put(bytes, 144, 16, 8, big); put(bytes, 152, 1024, 4, big);
    for (int i = 0; i < 16; ++i) bytes[1024 + i] = i + 1;
    if (!metadata.empty()) {
        text(bytes, 184, "__info_plist"); text(bytes, 200, "__TEXT");
        put(bytes, 216, 1536, 8, big); put(bytes, 224, metadata.size(), 8, big); put(bytes, 232, 1536, 4, big);
        require(metadata.size() < 2048, "fixture metadata too long"); text(bytes, 1536, metadata);
    }
    put(bytes, link, LC_SEGMENT_64, 4, big); put(bytes, link + 4, 72, 4, big);
    text(bytes, link + 8, "__LINKEDIT"); put(bytes, link + 24, vmSize, 8, big);
    put(bytes, link + 32, size - code, 8, big); put(bytes, link + 40, code, 8, big);
    put(bytes, link + 48, size - code, 8, big);
    put(bytes, version, 0x32, 4, big); put(bytes, version + 4, 24, 4, big); put(bytes, version + 8, 2, 4, big);
    if (reservation) {
        put(bytes, sign, LC_CODE_SIGNATURE, 4, big); put(bytes, sign + 4, 16, 4, big);
        put(bytes, sign + 8, code, 4, big); put(bytes, sign + 12, reservation, 4, big);
    }
    return bytes;
}
static bool accepted(Bytes bytes) { ZArchO value; return value.Init(bytes.data(), bytes.size()); }
static fs::path write(const std::string& name, const Bytes& bytes) {
    auto path = work / name;
    fs::create_directories(path.parent_path());
    std::ofstream file(path, std::ios::binary); file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    require(bool(file), "fixture file could not be written"); return path;
}
static fs::path write(const std::string& name, const std::string& value) { return write(name, Bytes(value.begin(), value.end())); }
static Bytes read(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    require(bool(file), "fixture file could not be read");
    return Bytes(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}
static Bytes fat(const std::vector<Bytes>& slices, bool wide, bool big) {
    const size_t entrySize = wide ? 32 : 20;
    Bytes bytes(4096, 0);
    put(bytes, 0, wide ? 0xcafebabfU : 0xcafebabeU, 4, big); put(bytes, 4, slices.size(), 4, big);
    for (size_t i = 0; i < slices.size(); ++i) {
        const size_t start = bytes.size(), entry = 8 + i * entrySize;
        bool sliceBig = get(slices[i], 0) == MH_CIGAM_64;
        put(bytes, entry, get(slices[i], 4, 4, sliceBig), 4, big);
        put(bytes, entry + 4, get(slices[i], 8, 4, sliceBig), 4, big);
        put(bytes, entry + 8, start, wide ? 8 : 4, big);
        put(bytes, entry + (wide ? 16 : 12), slices[i].size(), wide ? 8 : 4, big);
        put(bytes, entry + (wide ? 24 : 16), 12, 4, big);
        bytes.insert(bytes.end(), slices[i].begin(), slices[i].end());
        bytes.resize((bytes.size() + 4095) / 4096 * 4096, 0);
    }
    return bytes;
}
static Bytes blob(const Bytes& bytes, uint32_t slot) {
    bool big = get(bytes, 0) == MH_CIGAM_64;
    size_t command = 32, start = 0;
    for (size_t i = 0; i < get(bytes, 16, 4, big); ++i) {
        if (get(bytes, command, 4, big) == LC_CODE_SIGNATURE) start = get(bytes, command + 8, 4, big);
        command += get(bytes, command + 4, 4, big);
    }
    require(start && get(bytes, start, 4, true) == CSMAGIC_EMBEDDED_SIGNATURE, "no generated signature");
    for (size_t i = 0; i < get(bytes, start + 8, 4, true); ++i) {
        if (get(bytes, start + 12 + i * 8, 4, true) != slot) continue;
        auto offset = start + get(bytes, start + 16 + i * 8, 4, true);
        auto end = offset + get(bytes, offset + 4, 4, true);
        require(end <= bytes.size(), "generated slot out of bounds");
        return Bytes(bytes.begin() + offset, bytes.begin() + end);
    }
    throw std::runtime_error("generated slot missing");
}
static void adhoc(ZSignAsset& asset) {
    asset.m_bAdhoc = true; asset.m_strTeamId = "TESTTEAM00";
    asset.m_strEntitleData = plist("<key>get-task-allow</key><false/><key>test-zero</key><integer>0</integer>");
}
static bool sign(const fs::path& path, ZSignAsset& asset, const std::string& identifier = "com.example.fixture", ZMachO* reusable = nullptr) {
    ZMachO local; ZMachO& file = reusable ? *reusable : local;
    return file.Init(path.c_str()) && file.Sign(&asset, true, identifier, std::string(20, 0), std::string(32, 0), "");
}
static void verifyPages(const Bytes& bytes) {
    for (uint32_t slot : {0U, 0x1000U}) {
        const Bytes directory = blob(bytes, slot);
        const auto codeLength = get(directory, 32, 4, true), offset = get(directory, 16, 4, true);
        const auto pages = get(directory, 28, 4, true);
        const size_t hashSize = directory[36];
        require(pages == (codeLength + 4095) / 4096, "page count");
        for (size_t page = 0; page < pages; ++page) {
            const size_t start = page * 4096, length = std::min<size_t>(4096, codeLength - start);
            std::string hash;
            if (hashSize == 20) ZSHA::SHA1(const_cast<uint8_t*>(bytes.data()) + start, length, hash);
            else ZSHA::SHA256(const_cast<uint8_t*>(bytes.data()) + start, length, hash);
            require(std::equal(hash.begin(), hash.end(), directory.begin() + offset + page * hashSize,
                [](char a, uint8_t b) { return static_cast<uint8_t>(a) == b; }), "page hash differs");
        }
    }
}

struct PublicSealFixture { Bytes executable; std::string certificate; std::string attachedCMS; };
static PublicSealFixture publicSealFixture() {
    // Test-only ephemeral EC key. No private key is exported, saved, or logged.
    std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)> context(EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL), EVP_PKEY_CTX_free);
    EVP_PKEY* rawKey = NULL;
    require(context && EVP_PKEY_keygen_init(context.get()) == 1 &&
        EVP_PKEY_CTX_set_ec_paramgen_curve_nid(context.get(), NID_X9_62_prime256v1) == 1 &&
        EVP_PKEY_keygen(context.get(), &rawKey) == 1, "test key generation");
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key(rawKey, EVP_PKEY_free);
    std::unique_ptr<X509, decltype(&X509_free)> certificate(X509_new(), X509_free);
    require(certificate && X509_set_version(certificate.get(), 2) == 1 &&
        ASN1_INTEGER_set(X509_get_serialNumber(certificate.get()), 1) == 1 &&
        ASN1_TIME_set_string(X509_getm_notBefore(certificate.get()), "20200101000000Z") == 1 &&
        ASN1_TIME_set_string(X509_getm_notAfter(certificate.get()), "20360101000000Z") == 1 &&
        X509_set_pubkey(certificate.get(), key.get()) == 1, "test certificate fields");
    X509_NAME* name = X509_get_subject_name(certificate.get());
    require(X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("VexSign Non-Apple Unit Test"), -1, -1, 0) == 1 &&
        X509_NAME_add_entry_by_txt(name, "OU", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("TESTTEAM00"), -1, -1, 0) == 1 &&
        X509_set_issuer_name(certificate.get(), name) == 1 && X509_sign(certificate.get(), key.get(), EVP_sha256()) > 0, "test certificate sign");
    unsigned char* rawDER = NULL;
    int size = i2d_X509(certificate.get(), &rawDER);
    require(size > 0 && rawDER, "test certificate DER");
    std::string der(reinterpret_cast<char*>(rawDER), size); OPENSSL_free(rawDER);
    require(!ZSignAsset::SupportsSigningCertificate(der), "a non-Apple issuer was admitted to the production backend");
    auto executable = image(false, 4096, MH_EXECUTE, 8192);
    std::string requirements, xml, encodedDER;
    require(ZSign::SlotBuildRequirements("com.example.sealfixture", "VexSign Non-Apple Unit Test", requirements) &&
        ZSign::SlotBuildEntitlements(plist(""), xml) && ZSign::SlotBuildDerEntitlements(plist(""), encodedDER), "test special slots");
    std::string req1, req256, xml1, xml256, der1, der256;
    ZSHA::SHA(requirements, req1, req256); ZSHA::SHA(xml, xml1, xml256); ZSHA::SHA(encodedDER, der1, der256);
    std::string primary, alternate;
    for (bool strong : {false, true}) require(ZSign::SlotBuildCodeDirectory(strong, executable.data(), 4096, NULL, 0, 4096, 1,
        "com.example.sealfixture", "TESTTEAM00", std::string(strong ? 32 : 20, 0), strong ? req256 : req1,
        std::string(strong ? 32 : 20, 0), strong ? xml256 : xml1, strong ? der256 : der1,
        true, false, strong ? alternate : primary), "test CodeDirectory");
    std::string weakHash, strongHash;
    ZSHA::SHA1(primary, weakHash); ZSHA::SHA256(alternate, strongHash);
    jvalue legacy; legacy["cdhashes"].push_back(jvalue("data:" + weakHash));
    legacy["cdhashes"].push_back(jvalue("data:" + strongHash.substr(0, 20)));
    std::string legacyPlist; legacy.style_write_plist(legacyPlist);
    const int flags = CMS_PARTIAL | CMS_DETACHED | CMS_NOSMIMECAP | CMS_BINARY;
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(CMS_sign(NULL, NULL, NULL, NULL, flags), CMS_ContentInfo_free);
    require(bool(cms), "test CMS allocate");
    CMS_SignerInfo* signer = CMS_add1_signer(cms.get(), certificate.get(), key.get(), EVP_sha256(), flags);
    std::unique_ptr<ASN1_OBJECT, decltype(&ASN1_OBJECT_free)> legacyOID(OBJ_txt2obj("1.2.840.113635.100.9.1", 1), ASN1_OBJECT_free);
    std::unique_ptr<ASN1_OBJECT, decltype(&ASN1_OBJECT_free)> strongOID(OBJ_txt2obj("1.2.840.113635.100.9.2", 1), ASN1_OBJECT_free);
    std::string hex; static const char alphabet[] = "0123456789abcdef";
    for (unsigned char byte : strongHash) { hex.push_back(alphabet[byte >> 4]); hex.push_back(alphabet[byte & 15]); }
    std::unique_ptr<ASN1_TYPE, decltype(&ASN1_TYPE_free)> digest(static_cast<ASN1_TYPE*>(ZSignAsset::GenerateASN1Type(hex)), ASN1_TYPE_free);
    require(signer && legacyOID && strongOID && digest && CMS_signed_add1_attr_by_OBJ(signer, legacyOID.get(), V_ASN1_OCTET_STRING,
        legacyPlist.data(), legacyPlist.size()) == 1 && CMS_signed_add1_attr_by_OBJ(signer, strongOID.get(), V_ASN1_SEQUENCE,
        ASN1_STRING_get0_data(digest->value.sequence), ASN1_STRING_length(digest->value.sequence)) == 1, "test CMS signed attributes");
    std::unique_ptr<BIO, decltype(&BIO_free)> content(BIO_new_mem_buf(primary.data(), primary.size()), BIO_free);
    require(content && CMS_final(cms.get(), content.get(), NULL, flags) == 1, "test CMS final");
    unsigned char* cmsDER = NULL; size = i2d_CMS_ContentInfo(cms.get(), &cmsDER);
    require(size > 0 && cmsDER, "test CMS DER");
    Bytes cmsSlot(size + 8); put(cmsSlot, 0, CSMAGIC_BLOBWRAPPER, 4, true); put(cmsSlot, 4, size + 8, 4, true);
    std::copy(cmsDER, cmsDER + size, cmsSlot.begin() + 8); OPENSSL_free(cmsDER);
    std::vector<std::pair<uint32_t, std::string>> slots = {{0, primary}, {2, requirements}, {5, xml}, {7, encodedDER}, {0x1000, alternate},
        {0x10000, std::string(cmsSlot.begin(), cmsSlot.end())}};
    Bytes signature(12 + slots.size() * 8);
    put(signature, 0, CSMAGIC_EMBEDDED_SIGNATURE, 4, true); put(signature, 8, slots.size(), 4, true);
    for (size_t index = 0; index < slots.size(); ++index) {
        put(signature, 12 + index * 8, slots[index].first, 4, true); put(signature, 16 + index * 8, signature.size(), 4, true);
        signature.insert(signature.end(), slots[index].second.begin(), slots[index].second.end());
    }
    put(signature, 4, signature.size(), 4, true); require(signature.size() <= 8192, "test signature reservation");
    std::copy(signature.begin(), signature.end(), executable.begin() + 4096);
    verifyPages(executable);
    const std::string payload = "Untrusted synthetic CMS content; not a provisioning profile";
    std::unique_ptr<BIO, decltype(&BIO_free)> payloadBIO(BIO_new_mem_buf(payload.data(), payload.size()), BIO_free);
    std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> attached(
        CMS_sign(certificate.get(), key.get(), NULL, payloadBIO.get(), CMS_BINARY), CMS_ContentInfo_free);
    unsigned char* attachedBytes = NULL;
    require(attached && (size = i2d_CMS_ContentInfo(attached.get(), &attachedBytes)) > 0 && attachedBytes, "attached CMS fixture");
    const std::string attachedDER(reinterpret_cast<char*>(attachedBytes), size); OPENSSL_free(attachedBytes);
    return {executable, der, attachedDER};
}

// Ephemeral, encrypted test-only PKCS#12 bytes. These never enter the retained
// public fixture; the enclosing TemporaryDirectory owns every generated file.
struct NativeIdentityFixture { std::string p12, profile, differentLeafProfile, missingLeafProfile, differentTeamProfile; };
static NativeIdentityFixture nativeIdentityFixture() {
    std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)> context(EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL), EVP_PKEY_CTX_free);
    EVP_PKEY* rawKey = NULL;
    require(context && EVP_PKEY_keygen_init(context.get()) == 1 &&
        EVP_PKEY_CTX_set_ec_paramgen_curve_nid(context.get(), NID_X9_62_prime256v1) == 1 &&
        EVP_PKEY_keygen(context.get(), &rawKey) == 1, "ephemeral identity key generation");
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key(rawKey, EVP_PKEY_free);
    std::unique_ptr<X509, decltype(&X509_free)> certificate(X509_new(), X509_free);
    require(certificate && X509_set_version(certificate.get(), 2) == 1 &&
        ASN1_INTEGER_set(X509_get_serialNumber(certificate.get()), 10) == 1 &&
        ASN1_TIME_set_string(X509_getm_notBefore(certificate.get()), "20200101000000Z") == 1 &&
        ASN1_TIME_set_string(X509_getm_notAfter(certificate.get()), "20360101000000Z") == 1 &&
        X509_set_pubkey(certificate.get(), key.get()) == 1, "ephemeral identity certificate fields");
    X509_NAME* name = X509_get_subject_name(certificate.get());
    require(X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("Non-Apple Pairing Test"), -1, -1, 0) == 1 &&
        X509_NAME_add_entry_by_txt(name, "OU", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("TESTTEAM00"), -1, -1, 0) == 1 &&
        X509_set_issuer_name(certificate.get(), name) == 1 && X509_sign(certificate.get(), key.get(), EVP_sha256()) > 0,
        "ephemeral identity certificate signing");
    std::unique_ptr<PKCS12, decltype(&PKCS12_free)> container(
        PKCS12_create("synthetic-only", "Unit test only", key.get(), certificate.get(), NULL, 0, 0, 0, 0, 0), PKCS12_free);
    unsigned char* encoded = NULL;
    int length = container ? i2d_PKCS12(container.get(), &encoded) : 0;
    require(length > 0 && encoded, "ephemeral encrypted PKCS12 creation");
    std::string p12(reinterpret_cast<char*>(encoded), length); OPENSSL_free(encoded);
    auto profile = [&](bool different, bool missing, const std::string& team) {
        std::unique_ptr<X509, decltype(&X509_free)> leaf(X509_dup(certificate.get()), X509_free);
        require(bool(leaf), "test leaf duplication");
        if (different) require(ASN1_INTEGER_set(X509_get_serialNumber(leaf.get()), 11) == 1 &&
            X509_sign(leaf.get(), key.get(), EVP_sha256()) > 0, "different certificate, same key fixture");
        unsigned char* der = NULL;
        int count = i2d_X509(leaf.get(), &der);
        require(count > 0 && der, "test leaf encoding");
        jvalue value;
        value["TeamIdentifier"].push_back(team);
        if (!missing) { jvalue bytes; bytes.assign_data(der, count); value["DeveloperCertificates"].push_back(bytes); }
        OPENSSL_free(der);
        std::string payload; value.style_write_plist(payload);
        std::unique_ptr<BIO, decltype(&BIO_free)> input(BIO_new_mem_buf(payload.data(), payload.size()), BIO_free);
        std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(
            CMS_sign(certificate.get(), key.get(), NULL, input.get(), CMS_BINARY), CMS_ContentInfo_free);
        unsigned char* bytes = NULL;
        count = cms ? i2d_CMS_ContentInfo(cms.get(), &bytes) : 0;
        require(count > 0 && bytes, "synthetic non-Apple CMS creation");
        std::string output(reinterpret_cast<char*>(bytes), count); OPENSSL_free(bytes);
        return output;
    };
    return {p12, profile(false, false, "TESTTEAM00"), profile(true, false, "TESTTEAM00"),
        profile(false, true, "TESTTEAM00"), profile(false, false, "OTHER00000")};
}

static Bytes binaryPlist(const std::vector<Bytes>& objects, size_t root = 0) {
    Bytes bytes = {'b', 'p', 'l', 'i', 's', 't', '0', '0'}, offsets;
    for (const auto& object : objects) {
        require(bytes.size() < 256, "small binary plist fixture offset");
        offsets.push_back(static_cast<uint8_t>(bytes.size()));
        bytes.insert(bytes.end(), object.begin(), object.end());
    }
    const size_t table = bytes.size(); bytes.insert(bytes.end(), offsets.begin(), offsets.end());
    const size_t trailer = bytes.size(); bytes.resize(trailer + 32);
    bytes[trailer + 6] = bytes[trailer + 7] = 1;
    put(bytes, trailer + 8, objects.size(), 8, true); put(bytes, trailer + 16, root, 8, true); put(bytes, trailer + 24, table, 8, true);
    return bytes;
}
static bool parsePlist(const Bytes& bytes, jvalue& value) {
    return !bytes.empty() && value.read_plist(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}

int main(int argc, char** argv) {
    require(argc == 2 || argc == 3, "usage: signing-core-tests <temporary-directory> [public-fixture-json]");
    work = argv[1]; fs::create_directories(work); ZLog::SetLogLever(ZLog::E_ERROR);
    test("valid thin images and full-width segment/section names", [] {
        for (bool big : {false, true}) {
            auto bytes = image(big); require(accepted(bytes), "valid image rejected");
            text(bytes, 40, "SIXTEENBYTE_NAME"); text(bytes, 104, "FULL_WIDTH_NAME!");
            require(accepted(bytes), "16-byte names require no NUL");
        }
    });
    test("truncated headers and malformed load-command tables reject", [] {
        auto valid = image();
        for (size_t size = 0; size < 32; ++size) require(!accepted(Bytes(valid.begin(), valid.begin() + size)), "truncated header accepted");
        for (uint32_t size : {0U, 4U, 10U, 0xffffffffU}) {
            auto bytes = valid; put(bytes, 36, size); require(!accepted(bytes), "bad command size accepted");
        }
        auto bytes = valid; put(bytes, 16, 0xffffffffU); require(!accepted(bytes), "excessive command count accepted");
        bytes = valid; put(bytes, 20, get(bytes, 20) + 8); require(!accepted(bytes), "unconsumed command bytes accepted");
        bytes = valid; put(bytes, 96, 0xffffffffU); require(!accepted(bytes), "unbounded sections accepted");
        bytes = valid; put(bytes, 80, bytes.size() + 1, 8); require(!accepted(bytes), "segment exceeds file");
    });
    test("section offsets cannot create fictitious mutation space", [] {
        auto bytes = image(); put(bytes, 152, bytes.size() + 64); require(!accepted(bytes), "out-of-file __text accepted");
        bytes = image(); put(bytes, 144, uint64_t(1) << 40, 8); require(!accepted(bytes), "out-of-file section size accepted");
        bytes = image(); put(bytes, 152, 64); require(!accepted(bytes), "section overlaps load commands");
    });
    test("string-bearing load commands must be bounded and NUL-terminated", [] {
        auto bytes = image();
        // Replace the 24-byte version command with an equally sized dylib command.
        const size_t at = 32 + 152 + 72;
        put(bytes, at, LC_LOAD_DYLIB); put(bytes, at + 8, 0xffff);
        require(!accepted(bytes), "unbounded dylib name accepted");
        put(bytes, at + 8, 24); require(!accepted(bytes), "name at command end accepted");
        put(bytes, at, LC_RPATH); put(bytes, at + 8, 12);
        std::fill(bytes.begin() + at + 12, bytes.begin() + at + 24, 'x');
        require(!accepted(bytes), "unterminated rpath accepted");
        bytes[at + 23] = 0; require(accepted(bytes), "bounded rpath rejected");
    });
    test("signature reservations and nested superblob bounds", [] {
        auto bytes = image(); require(accepted(bytes), "zero reservation rejected");
        bytes[4200] = 1; require(!accepted(bytes), "nonzero untyped reservation accepted");
        bytes = image(); put(bytes, 4096, CSMAGIC_EMBEDDED_SIGNATURE, 4, true); put(bytes, 4100, 12, 4, true);
        put(bytes, 4104, 0xffffffffU, 4, true); require(!accepted(bytes), "unbounded signature index accepted");
        bytes = image(); put(bytes, 4096, CSMAGIC_EMBEDDED_SIGNATURE, 4, true); put(bytes, 4100, 28, 4, true);
        put(bytes, 4104, 1, 4, true); put(bytes, 4108, 0, 4, true); put(bytes, 4112, 24, 4, true);
        require(!accepted(bytes), "truncated nested signature header accepted");
    });
    test("execution metadata belongs to each image and resets on reuse", [] {
        auto first = image(false, 4096), second = image(true, 8192);
        ZArchO a, b; require(a.Init(first.data(), first.size()) && b.Init(second.data(), second.size()), "image init");
        ZSignAsset asset; adhoc(asset);
        require(a.Sign(&asset, true, "com.example.one", std::string(20, 0), std::string(32, 0), ""), "first sign");
        require(get(blob(first, 0), 72, 8, true) == 4096, "cross-instance execution metadata leaked");
        require(b.IsExecute(), "big-endian executable type not decoded");
        auto clean = image(); a.m_bEncrypted = true; a.m_bEnoughSpace = false;
        require(a.Init(clean.data(), clean.size()), "re-init");
        require(!a.m_bEncrypted && a.m_bEnoughSpace, "per-image status did not reset");
    });
    test("both hash directories seal every code page and clear signature padding", [] {
        for (bool big : {false, true}) {
            auto path = write(big ? "signed-big" : "signed-little", image(big));
            ZSignAsset asset; adhoc(asset); require(sign(path, asset), "ad-hoc fixture signing failed");
            auto bytes = read(path); verifyPages(bytes);
            const size_t end = 4096 + get(bytes, 4100, 4, true);
            require(std::all_of(bytes.begin() + end, bytes.end(), [](uint8_t value) { return value == 0; }), "signature padding not cleared");
        }
    });
    test("CodeDirectory builder failure propagates without signing or zeroing", [] {
        auto bytes = image(); const auto original = bytes; ZArchO a;
        require(a.Init(bytes.data(), bytes.size()), "init"); ZSignAsset asset; adhoc(asset);
        require(!a.Sign(&asset, true, "", std::string(20, 0), std::string(32, 0), ""), "empty identifier signed");
        require(bytes == original, "failed builder modified executable");
    });
    test("FAT32 and FAT64 tables support both byte orders", [] {
        for (bool wide : {false, true}) for (bool big : {false, true}) {
            auto a = image(), b = image(true, 8192); put(b, 8, 2, 4, true);
            auto path = write(std::string("fat-") + (wide ? "64" : "32") + (big ? "-be" : "-le"), fat({a, b}, wide, big));
            ZMachO file; require(file.Init(path.c_str()), "valid FAT rejected"); require(!file.CheckSignature(), "zero reservation is signed");
            require(file.Free(), "mapping not released");
        }
    });
    test("malformed FAT range/alignment/CPU/reserved/count metadata rejects", [] {
        for (bool wide : {false, true}) for (bool big : {false, true}) {
            auto check = [&](Bytes bytes) { auto path = write("bad-fat", bytes); ZMachO file; require(!file.Init(path.c_str()), "malformed FAT accepted"); };
            auto valid = fat({image(), image()}, wide, big); const size_t entry = 8 + (wide ? 32 : 20);
            auto bytes = valid; put(bytes, 4, 65, 4, big); check(bytes);
            bytes = valid; put(bytes, entry + 8, 4096, wide ? 8 : 4, big); check(bytes);
            bytes = valid; put(bytes, 16, 8, wide ? 8 : 4, big); check(bytes);
            bytes = valid; put(bytes, 8, 7, 4, big); check(bytes);
            bytes = valid; put(bytes, wide ? 32 : 24, 31, 4, big); check(bytes);
            bytes = valid; put(bytes, wide ? 24 : 20, uint64_t(1) << 31, wide ? 8 : 4, big); check(bytes);
            if (wide) { bytes = valid; put(bytes, 36, 1, 4, big); check(bytes); }
        }
    });
    test("FAT resizing normalizes the table and preserves per-slice identifiers and Info hashes", [] {
        for (bool wide : {false, true}) for (bool big : {false, true}) {
            const std::string one = info("com.example.slice.one"), two = info("com.example.slice.two");
            auto a = image(false, 4096, MH_DYLIB, 64, one), b = image(true, 8192, MH_DYLIB, 64, two);
            put(b, 8, 2, 4, true);
            auto path = write(std::string("resize-") + (wide ? "64" : "32") + (big ? "-be" : "-le"), fat({a, b}, wide, big));
            ZSignAsset asset; adhoc(asset); ZMachO file;
            require(file.Init(path.c_str()) && file.Sign(&asset, true, "", "", "", ""), "FAT reallocation/sign failed");
            auto bytes = read(path); require(get(bytes, 0, 4, true) == FAT_MAGIC, "not a canonical FAT32 output");
            for (size_t i = 0; i < 2; ++i) {
                const size_t start = get(bytes, 8 + i * 20 + 8, 4, true), length = get(bytes, 8 + i * 20 + 12, 4, true);
                Bytes slice(bytes.begin() + start, bytes.begin() + start + length); verifyPages(slice);
                const Bytes directory = blob(slice, 0x1000); const std::string expected = i ? "com.example.slice.two" : "com.example.slice.one";
                const auto idStart = get(directory, 20, 4, true);
                require(std::string(directory.begin() + idStart, directory.begin() + idStart + expected.size()) == expected, "identifier reused from another slice");
                std::string hash; ZSHA::SHA256(i ? two : one, hash);
                const size_t hashAt = get(directory, 16, 4, true) - 32;
                require(std::equal(hash.begin(), hash.end(), directory.begin() + hashAt,
                    [](char a, uint8_t b) { return static_cast<uint8_t>(a) == b; }), "Info hash reused from another slice");
            }
        }
    });
    test("a reused file owner can resize a second independent input", [] {
        auto one = write("reused-one", image(false, 4096, MH_EXECUTE, 0));
        auto two = write("reused-two", image(false, 4096, MH_EXECUTE, 0));
        ZSignAsset asset; adhoc(asset); ZMachO file;
        require(sign(one, asset, "com.example.one", &file), "first resize failed");
        require(sign(two, asset, "com.example.two", &file), "reallocation state leaked between files");
    });
    test("canonical DER encodes false/zero/negative integers and SET ordering", [] {
        std::string result;
        require(ZSign::SlotBuildDerEntitlements(plist("<key>z</key><integer>0</integer><key>a</key><false/>"), result), "DER builder failed");
        Bytes expected = {0x31, 0x10, 0x30, 0x06, 0x0c, 0x01, 'a', 0x01, 0x01, 0x00, 0x30, 0x06, 0x0c, 0x01, 'z', 0x02, 0x01, 0x00};
        require(Bytes(result.begin() + 8, result.end()) == expected, "noncanonical bool/integer/set output");
        require(ZSign::SlotBuildDerEntitlements(plist("<key>n</key><integer>-129</integer>"), result), "negative DER builder failed");
        require(result.substr(result.size() - 4) == std::string("\x02\x02\xff\x7f", 4), "negative integer not minimal signed DER");
    });
    test("unsupported entitlement values fail without assert or silent coercion", [] {
        for (const auto& value : {"<data>AA==</data>", "<real>1.2</real>", "<date>2025-01-01T00:00:00Z</date>"}) {
            std::string output; require(!ZSign::SlotBuildDerEntitlements(plist(std::string("<key>x</key>") + value), output), "unsupported DER value accepted");
            require(output.empty(), "partial DER output escaped failure");
        }
    });
    test("injection with no proven command padding refuses without modifying bytes", [] {
        auto bytes = image(); text(bytes, 104, "__not_text"); ZArchO file;
        require(file.Init(bytes.data(), bytes.size()), "init"); const auto original = bytes;
        require(!file.InjectDylib(false, "@rpath/Injected.dylib"), "injection overwrote unproven data");
        require(bytes == original, "refused injection changed bytes");
    });
    test("loose dylib initialization and signing failures stop bundle signing", [] {
        for (bool corrupt : {false, true}) {
            const std::string prefix = corrupt ? "BadInit.app/" : "BadSign.app/";
            write(prefix + "Info.plist", info("com.example.parent")); write(prefix + "App", image());
            write(prefix + "Odd/Deep/Child.DYLIB", corrupt ? Bytes{1, 2, 3} : image(false, 4096, MH_DYLIB));
            ZSignAsset asset; adhoc(asset); if (!corrupt) asset.m_bAdhoc = false;
            ZBundle bundle;
            require(!bundle.SignFolder(&asset, (work / prefix.substr(0, prefix.size() - 1)).string(), "", "", "", {}, true, false, false, false), "loose failure swallowed");
            require(bundle.signFailedFiles.find("Child.DYLIB") != std::string::npos, "failed component missing from error evidence");
            require(!fs::exists(work / prefix / "_CodeSignature/CodeResources"), "main was sealed after loose-code failure");
        }
    });
    test("bundle metadata must be fully parsed with string identifier and executable before sealing", [] {
        const std::vector<std::string> invalid = {
            "", "not a plist", info("com.example.invalid") + "trailing",
            plist("<key>CFBundleIdentifier</key><string>com.example.partial</string>"
                "<key>CFBundleExecutable</key><string>App</string><key>broken</key>"),
            plist("<key>CFBundleIdentifier</key><integer>7</integer>"
                "<key>CFBundleExecutable</key><string>App</string>"),
            plist("<key>CFBundleIdentifier</key><string>com.example.invalid</string>"
                "<key>CFBundleExecutable</key><integer>7</integer>"),
            "<plist><array><string>not a dictionary</string></array></plist>"
        };
        for (size_t i = 0; i <= invalid.size(); ++i) {
            const std::string prefix = "InvalidMetadata" + std::to_string(i) + ".app/";
            // The final case has no Info.plist at all. A file named 7 makes a
            // coercible numeric executable a meaningful negative control.
            if (i < invalid.size()) write(prefix + "Info.plist", invalid[i]);
            write(prefix + "App", image()); write(prefix + "7", image());
            const Bytes original = read(work / prefix / "App"), numeric = read(work / prefix / "7");
            ZSignAsset asset; adhoc(asset); ZBundle bundle;
            require(!bundle.SignFolder(&asset, (work / prefix.substr(0, prefix.size() - 1)).string(),
                "", "", "", {}, true, false, false, false), "invalid metadata reached sealing");
            require(!fs::exists(work / prefix / "_CodeSignature/CodeResources"), "invalid metadata produced a seal");
            require(read(work / prefix / "App") == original && read(work / prefix / "7") == numeric,
                "rejected metadata modified executable bytes");
        }
        write("ValidMetadata.app/Info.plist", info("com.example.valid")); write("ValidMetadata.app/App", image());
        ZSignAsset asset; adhoc(asset); ZBundle bundle;
        require(bundle.SignFolder(&asset, (work / "ValidMetadata.app").string(), "", "", "", {},
            true, false, false, false), "well-formed metadata was rejected");
        verifyPages(read(work / "ValidMetadata.app/App"));
    });
    test("signature-directory creation failure propagates", [] {
        write("BlockedDirectory.app/Info.plist", info("com.example.blocked")); write("BlockedDirectory.app/App", image());
        write("BlockedDirectory.app/_CodeSignature", "not a directory"); ZSignAsset asset; adhoc(asset); ZBundle bundle;
        require(!bundle.SignFolder(&asset, (work / "BlockedDirectory.app").string(), "", "", "", {}, true, false, false, false), "directory creation error swallowed");
    });
    test("a missing native image is never vacuously signed", [] {
        ZMachO file; require(!file.CheckSignature(), "empty image list is signed");
        auto path = write("empty-native", Bytes{}); require(!file.Init(path.c_str()), "empty file accepted");
        require(!file.CheckSignature(), "failed initialization is signed");
    });
    test("base64 buffers are bounded, canonical and safe for every hash length", [] {
        jbase64 codec;
        for (size_t size = 1; size <= 128; ++size) {
            std::string input;
            for (size_t index = 0; index < size; ++index) input.push_back(static_cast<char>(index));
            std::string encoded = codec.encode(input), decoded;
            codec.decode(encoded.c_str(), decoded); require(decoded == input, "base64 roundtrip mismatch");
        }
        for (const char* invalid : {"x", "abcd=", "AB==", "AAB=", "a?cd", "====", "a=cd"}) {
            int count = 99; codec.decode(invalid, 0, &count); require(count == 0, "malformed base64 decoded");
        }
    });
    test("native plist data accepts XML whitespace but rejects malformed base64", [] {
        jvalue value;
        require(value.read_plist(plist("<key>payload</key><data> \n\t YW Jj\r\n ZA== \t</data>")), "formatted XML base64 rejected");
        require(value["payload"].as_data() == "abcd", "formatted XML base64 changed bytes");
        for (const char* malformed : {"x", "AB==", "AAB=", "YW?j", "YWJj=", "===="}) {
            require(!value.read_plist(plist(std::string("<key>payload</key><data>") + malformed + "</data>")), "malformed XML data accepted");
        }
        require(value.read_plist(plist("<key>empty</key><data> \n\t </data>")) && value["empty"].as_data().empty(), "empty XML data rejected");
        for (const std::string& truncated : {std::string("<plist><dict><key>unterminated key"),
            std::string("<plist><dict><key>key</key><data>AAAA"),
            std::string("<plist><dict><key>key</key>      ")}) {
            // No sentinel byte: a decoder must never dereference the end.
            auto bytes = std::make_unique<char[]>(truncated.size());
            memcpy(bytes.get(), truncated.data(), truncated.size());
            require(!value.read_plist(bytes.get(), truncated.size()), "truncated XML accepted");
        }
    });
    test("binary plists preserve typed values, unaligned tables, Unicode scalars and the UTC epoch", [] {
        jvalue original;
        original["name"] = "Synthetic"; original["false"] = false; original["zero"] = 0;
        original["negative"] = int64_t(-1); original["real"] = 1.25;
        original["bytes"].assign_data("abc", 3); original["date"].assign_date(978307200);
        std::string encoded; jpwriter writer; writer.write_to_binary(original, encoded);
        jvalue decoded;
        require(decoded.read_plist(encoded), "binary typed roundtrip rejected");
        require(decoded["false"].is_bool() && !decoded["false"].as_bool() && decoded["zero"].is_int() && decoded["zero"].as_int64() == 0,
            "binary Boolean/numeric distinction lost");
        require(decoded["negative"].as_int64() == -1 && decoded["real"].as_double() == 1.25 && decoded["bytes"].as_data() == "abc" &&
            decoded["date"].as_date() == 978307200, "binary typed values changed");
        require(parsePlist(binaryPlist({Bytes{0x62, 0xd8, 0x3d, 0xde, 0x00}}), decoded) && decoded.as_string() == "\xf0\x9f\x98\x80",
            "UTF16 surrogate pair was not converted to a Unicode scalar");
        require(parsePlist(binaryPlist({Bytes{0x60}}), decoded) && decoded.is_string() && decoded.as_string().empty(), "empty Unicode string rejected");
        require(parsePlist(binaryPlist({Bytes{0x33, 0, 0, 0, 0, 0, 0, 0, 0}}), decoded) && decoded.as_date() == 978307200,
            "independent binary UTC epoch differs");
    });
    test("binary plist tables, references, lengths, cycles, duplicate keys and unsupported types fail closed", [] {
        const Bytes valid = binaryPlist({Bytes{0xd1, 1, 2}, Bytes{0x51, 'k'}, Bytes{0x09}});
        jvalue value;
        require(parsePlist(valid, value) && value["k"].as_bool(), "independent binary dictionary rejected");
        const size_t trailer = valid.size() - 32;
        for (const auto& field : std::vector<std::pair<size_t, uint64_t>>{{trailer + 8, 0}, {trailer + 8, UINT64_MAX},
            {trailer + 16, 3}, {trailer + 24, 0}, {trailer + 24, UINT64_MAX}}) {
            auto bad = valid; put(bad, field.first, field.second, 8, true);
            require(!parsePlist(bad, value) && value.is_null(), "malformed trailer left an accepted/partial value");
        }
        for (size_t at : {trailer + 6, trailer + 7}) for (uint8_t width : {uint8_t(0), uint8_t(9), uint8_t(255)}) {
            auto bad = valid; bad[at] = width; require(!parsePlist(bad, value), "invalid binary table width accepted");
        }
        for (const auto& bad : {binaryPlist({Bytes{0xa1, 0}}), binaryPlist({Bytes{0xa1, 2}}),
            binaryPlist({Bytes{0xd2, 1, 1, 2, 2}, Bytes{0x51, 'k'}, Bytes{0x09}}),
            binaryPlist({Bytes{0x4f, 0x18, 0xff, 0xff}}), binaryPlist({Bytes{0x1f}}), binaryPlist({Bytes{0x80, 0}}),
            binaryPlist({Bytes{0x61, 0xd8, 0x00}}), binaryPlist({Bytes{0x62, 0xd8, 0x3d, 0, 0x41}}),
            binaryPlist({Bytes{0x51, 0}}), binaryPlist({Bytes{0x33, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0}})}) {
            require(!parsePlist(bad, value) && value.is_null(), "unsupported or malformed binary object accepted");
        }
        for (size_t length = 1; length < valid.size(); ++length) {
            Bytes prefix(valid.begin(), valid.begin() + length);
            require(!parsePlist(prefix, value), "truncated binary plist accepted");
        }
        // Mutation coverage is about memory safety/termination, not an assertion
        // that every possible byte change makes a plist semantically invalid.
        for (size_t index = 0; index < valid.size(); ++index) for (uint8_t byte : {uint8_t(0), uint8_t(0xff)}) {
            Bytes changed = valid; changed[index] = byte; parsePlist(changed, value);
        }
    });
    test("XML plist depth, duplicate keys and trailing bytes cannot bypass a failed parse", [] {
        jvalue value;
        require(!value.read_plist(plist("<key>x</key><true/><key>x</key><false/>")) && value.is_null(), "duplicate XML key accepted");
        require(!value.read_plist(plist("") + "trailing") && value.is_null(), "trailing XML bytes accepted");
        std::string deep = "<plist>";
        for (int index = 0; index < 100; ++index) deep += "<array>";
        deep += "<true/>";
        for (int index = 0; index < 100; ++index) deep += "</array>";
        require(!value.read_plist(deep + "</plist>") && value.is_null(), "excessive XML depth accepted");
        std::string message;
        require(!value.read_plist("", 0, &message) && !message.empty(), "short-input error reporting failed");
        std::string headers;
        for (int index = 0; index < 5000; ++index) headers += "<!-- iterative prolog > -->";
        require(value.read_plist(headers + plist("<key>value</key><true/>")), "iterative prolog scanner failed");
    });
    test("XML numeric types, grammar and signed limits are preserved without overflow or coercion", [] {
        jvalue value;
        require(value.read_plist(plist("<key>min</key><integer>-9223372036854775808</integer><key>max</key><integer>9223372036854775807</integer>"
            "<key>zero</key><integer>0</integer><key>real</key><real>1</real><key>fraction</key><real> -1.25e+2 </real>")), "valid XML numeric range rejected");
        require(value["min"].as_int64() == INT64_MIN && value["max"].as_int64() == INT64_MAX && value["zero"].is_int() &&
            value["real"].is_double() && value["real"].as_double() == 1.0 && value["fraction"].as_double() == -125, "XML numeric type/value changed");
        for (const auto& scalar : {"<integer>9223372036854775808</integer>", "<integer>-9223372036854775809</integer>",
            "<integer>999999999999999999999999999999999999999999999999</integer>", "<integer>-</integer>", "<integer></integer>",
            "<integer/>", "<integer>1.0</integer>", "<integer>1e1</integer>", "<real>1e</real>", "<real>1e9999</real>",
            "<real>1.0.2</real>", "<real>nan</real>", "<real></real>", "<real/>"}) {
            require(!value.read_plist(plist("<key>value</key>" + std::string(scalar))) && value.is_null(), "invalid XML scalar accepted");
        }
    });
    test("XML UTC dates reject impossible calendars and do not depend on the host timezone", [] {
        jvalue value;
#ifndef _WIN32
        const char* original = std::getenv("TZ");
        const std::string timezone = original ? original : "";
        struct RestoreTimezone {
            bool hadOriginal; std::string value;
            ~RestoreTimezone() { if (hadOriginal) setenv("TZ", value.c_str(), 1); else unsetenv("TZ"); tzset(); }
        } restore{original != NULL, timezone};
        setenv("TZ", "UTC-6", 1); tzset();
#endif
        for (const auto& date : std::vector<std::pair<std::string, int64_t>>{{"2001-01-01T00:00:00Z", 978307200},
            {"1970-01-01T00:00:00Z", 0}, {"1969-12-31T23:59:59Z", -1}, {"2000-02-29T00:00:00Z", 951782400}}) {
            require(value.read_plist(plist("<key>date</key><date>" + date.first + "</date>")) && value["date"].as_date() == date.second,
                "XML date is not the declared UTC instant");
        }
        for (const std::string& date : {"1900-02-29T00:00:00Z", "2026-02-30T00:00:00Z", "2026-13-32T00:00:00Z",
            "2026-00-00T00:00:00Z", "2026-11-13T24:00:00Z", "2026-11-13T00:60:00Z", "2026-11-13T00:00:60Z",
            "2026-11-13T00:00:00+06:00", "2026-11-13T00:00:00Ztrailing", "", "0000-01-01T00:00:00Z"}) {
            require(!value.read_plist(plist("<key>date</key><date>" + date + "</date>")), "invalid XML date normalized into acceptance");
        }
        require(!value.read_plist(plist("<key>date</key><date/>")), "empty XML date accepted");
    });
    test("XML entity decoding preserves whitespace and Unicode while rejecting ambiguous or invalid strings", [] {
        jvalue value;
        require(value.read_plist(plist("<key>a&amp;b</key><string>line1\n\tline2&#x1F600;&#38;&lt;&gt;&quot;&apos;</string>")), "valid XML entities rejected");
        require(value["a&b"].as_string() == "line1\n\tline2\xf0\x9f\x98\x80&<>\"'", "XML entities or significant whitespace changed");
        std::string encoded = value.write_plist(); jvalue again;
        require(again.read_plist(encoded) && again["a&b"].as_string() == value["a&b"].as_string(), "XML writer/reader entity disagreement");
        require(!value.read_plist(plist("<key>a</key><true/><key>&#97;</key><false/>")), "equivalent duplicate key evaded XML decoding");
        for (const std::string& text : {"&undefined;", "&amp", "&#;", "&#x;", "&#0;", "&#xD800;", "&#x110000;", "&#xFFFF;", "]]>",
            "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x28\xa1"}) {
            require(!value.read_plist(plist("<key>text</key><string>" + text + "</string>")), "malformed XML text accepted");
        }
        auto nul = plist("<key>text</key><string>before"); nul.push_back(0); nul += "after</string>";
        require(!value.read_plist(nul), "embedded XML NUL accepted");
    });
    test("XML labels, comments, declarations and truncations are consumed without DTD expansion", [] {
        jvalue value;
        const std::string valid = "\xef\xbb\xbf<?xml version='1.0' encoding='UTF-8'?>"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
            "<!-- comment > text --><plist version = '1.0'><dict ><key/><string />"
            "<key>flag</key><true /></dict ></plist><!-- end -->";
        require(value.read_plist(valid) && value[""].is_string() && value["flag"].as_bool(), "ordinary XML declaration/empty element rejected");
        for (size_t length = 1; length < valid.size() - 12; ++length) {
            require(!value.read_plist(valid.data(), length), "incomplete XML document accepted");
        }
        for (const std::string& bad : {"<!DOCTYPE plist [<!ENTITY x 'expanded'>]><plist><string>&x;</string></plist>",
            "<?xml encoding='UTF-16'?><plist><dict/></plist>", "<plist><dict unknown='ignored'/></plist>",
            "<plist><array><key>not-an-array-value</key><true/></array></plist>", "<plist><dict/></plist><dict/>",
            "<plist><dict/><plist/></plist>", "<plist><dict/></plist><!-- unclosed", "<plist><dict/></plist><!-- a -- b -->"}) {
            require(!value.read_plist(bad) && value.is_null(), "invalid/unsupported XML syntax accepted");
        }
    });
    test("XML and binary plist resource budgets refuse expansion and oversized inputs", [] {
        jvalue value;
        std::string many = "<plist><array>";
        for (int index = 0; index < 200001; ++index) many += "<true/>";
        many += "</array></plist>";
        require(!value.read_plist(many) && value.is_null(), "XML node budget did not stop the document");
        std::vector<Bytes> graph;
        for (uint8_t index = 0; index < 20; ++index) graph.push_back(Bytes{0xa2, uint8_t(index + 1), uint8_t(index + 1)});
        graph.push_back(Bytes{0x09});
        require(!parsePlist(binaryPlist(graph), value) && value.is_null(), "shared binary tree bypassed expansion budget");
        const std::string oversized(64 * 1024 * 1024 + 1, ' ');
        require(!value.read_plist(oversized) && value.is_null(), "plist input byte limit not enforced");
    });
    test("independent plistlib XML and binary fixtures agree with the production reader and writer", [] {
        jvalue decoded;
        for (const auto& name : {"reference-xml.plist", "reference-binary.plist"}) {
            const auto file = work / name;
            require(decoded.read_plist_from_file("%s", file.c_str()), "independent plistlib fixture rejected");
            require(decoded["unicode"].as_string() == "বাংলা & 😀" && decoded["key😀"].as_string() == "escaped < & > \" text\n\t",
                "independent Unicode/entity fixture changed");
            require(decoded["false"].is_bool() && !decoded["false"].as_bool() && decoded["zero"].is_int() &&
                decoded["zero"].as_int64() == 0 && decoded["real"].is_double() && decoded["negative"].as_int64() == -1,
                "independent plist scalar type mismatch");
            require(decoded["bytes"].as_data() == std::string("\0\xff" "ABC", 5) && decoded["date"].as_date() == 978307200,
                "independent binary data/date changed");
        }
        const auto output = work / "native-roundtrip.bplist";
        require(decoded.write_bplist_to_file("%s", output.c_str()), "native binary interoperability fixture write failed");
    });
    test("PKCS12 leaf membership and team are mandatory even when its private key matches", [] {
        const auto fixture = nativeIdentityFixture();
        const auto identity = write("ephemeral-pairing.p12", fixture.p12);
        const auto entitlements = write("pairing-entitlements.plist", plist(""));
        const auto profile = write("pairing.mobileprovision", fixture.profile);
        ZSignAsset asset;
        require(asset.Init("", identity.string(), profile.string(), entitlements.string(), "synthetic-only", false, false, false), "valid synthetic key/leaf pairing failed");
        // This test is pairing/cleanup only: the CMS signer is not Apple and it
        // cannot satisfy Swift/Security provisioning admission or GenerateCMS.
        for (const auto& bad : {fixture.differentLeafProfile, fixture.missingLeafProfile, fixture.differentTeamProfile}) {
            write("pairing.mobileprovision", bad);
            require(!asset.Init("", identity.string(), profile.string(), entitlements.string(), "synthetic-only", false, false, false), "unauthorized leaf/team accepted");
        }
        write("pairing.mobileprovision", fixture.profile);
        for (int index = 0; index < 12; ++index) {
            require(!asset.Init("", identity.string(), profile.string(), entitlements.string(), "wrong synthetic password", false, false, false), "wrong password accepted");
            require(asset.Init("", identity.string(), profile.string(), entitlements.string(), "synthetic-only", false, false, false), "retry after failed identity import failed");
        }
        require(!asset.Init("", identity.string(), profile.string(), "", "synthetic-only", false, false, false), "profile entitlement fallback returned");
    });
    test("CMS ASN1 digest attributes reject malformed/oversized input without config-parser crashes", [] {
        for (const std::string& value : {std::string(), std::string(63, '0'), std::string(64, 'z'), std::string(65, '0')})
            require(ZSignAsset::GenerateASN1Type(value) == NULL, "invalid digest attribute accepted");
        std::unique_ptr<ASN1_TYPE, decltype(&ASN1_TYPE_free)> value(static_cast<ASN1_TYPE*>(ZSignAsset::GenerateASN1Type(std::string(64, '0'))), ASN1_TYPE_free);
        require(value && value->type == V_ASN1_SEQUENCE, "bounded digest sequence failed");
    });
    test("synthetic detached CMS verifies its exact directory and rejects altered bytes", [&] {
        auto fixture = publicSealFixture(); const Bytes cmsBlob = blob(fixture.executable, 0x10000), directory = blob(fixture.executable, 0);
        const unsigned char* cursor = cmsBlob.data() + 8;
        std::unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)> cms(d2i_CMS_ContentInfo(NULL, &cursor, cmsBlob.size() - 8), CMS_ContentInfo_free);
        std::unique_ptr<BIO, decltype(&BIO_free)> content(BIO_new_mem_buf(directory.data(), directory.size()), BIO_free);
        require(cms && content && CMS_verify(cms.get(), NULL, NULL, content.get(), NULL, CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY) == 1, "valid test CMS rejected");
        auto altered = directory; altered.back() ^= 1;
        std::unique_ptr<BIO, decltype(&BIO_free)> badContent(BIO_new_mem_buf(altered.data(), altered.size()), BIO_free);
        require(CMS_verify(cms.get(), NULL, NULL, badContent.get(), NULL, CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY) != 1, "tampered test CMS verified");
        if (argc == 3) {
            jbase64 codec; jvalue output;
            output["notice"] = "Synthetic non-Apple public fixture; no private key retained; never device-install or profile-authentication evidence.";
            output["identifier"] = "com.example.sealfixture"; output["team"] = "TESTTEAM00";
            output["certificate"] = codec.encode(fixture.certificate);
            output["executable"] = codec.encode(reinterpret_cast<const char*>(fixture.executable.data()), fixture.executable.size());
            std::string json; output.style_write(json);
            require(ZFile::WriteFile(argv[2], json), "public fixture output failed");
        }
    });
    test("native file IO rejects invalid bounds and observes buffered write failures", [] {
        const auto path = write("file-io", "bytes");
        std::string value = "stale";
        require(ZFile::ReadFile(path.c_str(), value) && value == "bytes", "regular file read failed");
        require(!ZFile::ReadFile((work / "missing-file").c_str(), value) && value.empty(), "failed read retained stale bytes");
        require(!ZFile::ReadFile(work.c_str(), value) && value.empty(), "directory counted as a readable file");
        size_t length = 99;
        require(!ZFile::MapFile(path.c_str(), 6, 0, &length, true) && length == 0, "mapping beyond file succeeded");
        require(!ZFile::MapFile(path.c_str(), 0, 6, &length, true) && length == 0, "mapping size exceeded file");
        require(!ZFile::MapFile(work.c_str(), 0, 0, &length, true), "directory mapped");
        require(!ZFile::WriteFile(path.c_str(), NULL, 1), "invalid write input truncated file");
        require(read(path) == Bytes({'b', 'y', 't', 'e', 's'}), "rejected write changed existing bytes");
        const auto empty = write("empty-io", ""); require(ZFile::ReadFile(empty.c_str(), value) && value.empty(), "empty regular file rejected");
#ifndef _WIN32
        if (fs::exists("/dev/full")) {
            require(!ZFile::WriteFile("/dev/full", "data", 4), "write flush failure swallowed");
            require(!ZFile::AppendFile("/dev/full", "data", 4), "append flush failure swallowed");
        }
        const int saved = dup(STDIN_FILENO); close(STDIN_FILENO);
        void* mapped = ZFile::MapFile(path.c_str(), 0, 0, &length, true);
        const bool valid = mapped && length == 5 && memcmp(mapped, "bytes", 5) == 0;
        if (mapped) ZFile::UnmapFile(mapped, length);
        if (saved >= 0) { dup2(saved, STDIN_FILENO); close(saved); }
        require(valid, "file descriptor zero was mistaken for open failure");
#endif
    });
    test("native copy refuses same-file truncation and linked mappings without changing permissions", [] {
        const auto source = write("copy-source", "source"); const auto target = work / "copy-target";
        require(ZFile::CopyFile(source.c_str(), target.c_str()) && read(source) == read(target), "regular copy failed");
        require(!ZFile::CopyFile(source.c_str(), source.c_str()) && read(source) == Bytes({'s', 'o', 'u', 'r', 'c', 'e'}), "same-file copy destroyed source");
#ifndef _WIN32
        const auto hard = work / "copy-hard"; fs::create_hard_link(source, hard);
        require(!ZFile::CopyFile(source.c_str(), hard.c_str()) && read(hard) == read(source), "hard-linked target destroyed source");
        const auto linked = work / "copy-link"; fs::create_symlink(source, linked);
        size_t length = 99;
        require(!ZFile::MapFile(linked.c_str(), 0, 0, &length, false) && length == 0, "linked mapping followed target");
        require(!ZFile::CopyFile(linked.c_str(), target.c_str()), "copy followed a source link");
        struct stat before = {0}, after = {0}; require(stat(source.c_str(), &before) == 0, "stat");
        require(!ZFile::MapFile((work / "missing-parent/file").c_str(), 0, 0, &length, false), "missing mapping created file");
        require(stat(source.c_str(), &after) == 0 && before.st_mode == after.st_mode, "inspection changed permissions");
#endif
        require(!ZFile::IsFolder((work / "absent-folder").c_str()), "failed stat used uninitialized mode");
    });
    test("CMS metadata and extraction are bounded and release every OpenSSL owner", [] {
        const auto fixture = publicSealFixture(); const Bytes wrapped = blob(fixture.executable, 0x10000);
        std::string payload;
        require(ZSignAsset::GetCMSContent(fixture.attachedCMS, payload) && payload.find("Untrusted synthetic") == 0, "attached CMS extraction");
        require(!ZSignAsset::GetCMSContent(fixture.attachedCMS + "x", payload) && payload.empty(), "trailing CMS accepted");
        const std::string detached(wrapped.begin() + 8, wrapped.end());
        require(!ZSignAsset::GetCMSContent(detached, payload), "detached signature exposed attached content");
        for (int i = 0; i < 12; ++i) {
            jvalue info;
            require(ZSignAsset::GetCMSInfo(const_cast<uint8_t*>(wrapped.data()) + 8, wrapped.size() - 8, info), "valid public CMS diagnostic parse");
            auto invalid = wrapped; invalid.push_back(0);
            require(!ZSignAsset::GetCMSInfo(invalid.data() + 8, invalid.size() - 8, info), "diagnostic CMS ignored trailing bytes");
            require(!ZSignAsset::GetCMSInfo(NULL, 1, info), "NULL diagnostic input accepted");
        }
        const unsigned char* cursor = reinterpret_cast<const unsigned char*>(fixture.certificate.data());
        std::unique_ptr<X509, decltype(&X509_free)> certificate(d2i_X509(NULL, &cursor, fixture.certificate.size()), X509_free);
        require(bool(certificate), "public certificate decode");
        for (int i = 0; i < 12; ++i) {
            jvalue metadata;
            require(ZSignAsset::GetCertInfo(certificate.get(), metadata), "certificate metadata decode");
            require(metadata["Subject"]["CN"].as_string() == "VexSign Non-Apple Unit Test", "certificate CN metadata");
        }
    });
    std::cout << "1.." << checks << '\n' << checks - failures << " passed; " << failures << " failed (native core only; no Apple trust/device acceptance)\n";
    return failures ? 1 : 0;
}
