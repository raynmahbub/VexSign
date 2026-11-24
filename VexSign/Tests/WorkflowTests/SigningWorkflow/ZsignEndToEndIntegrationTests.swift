import CryptoKit
import Foundation
import XCTest
@testable import VexSign

final class ZsignEndToEndIntegrationTests: XCTestCase {
    private func makeTempRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            ZsignEngine.clearCache()
        }
        return root
    }

    /// Builds a real 64-bit ARM64 Mach-O image (`__TEXT` + `__text`, `__LINKEDIT`,
    /// `LC_BUILD_VERSION`, and zeroed `LC_CODE_SIGNATURE` reservation) accepted by
    /// the real vendored `ZArchO::Init` / `ZMachO::Sign` engine.
    private static func makeSignableArm64MachO(
        fileType: UInt32,
        reservation: UInt32 = 16_384,
        seedByte: UInt8 = 1
    ) -> Data {
        let codeSize: UInt32 = 4096
        let totalSize = Int(codeSize + reservation)
        var bytes = [UInt8](repeating: 0, count: totalSize)

        func put32(_ offset: Int, _ value: UInt32) {
            bytes[offset] = UInt8(value & 0xff)
            bytes[offset + 1] = UInt8((value >> 8) & 0xff)
            bytes[offset + 2] = UInt8((value >> 16) & 0xff)
            bytes[offset + 3] = UInt8((value >> 24) & 0xff)
        }
        func put64(_ offset: Int, _ value: UInt64) {
            put32(offset, UInt32(value & 0xffff_ffff))
            put32(offset + 4, UInt32((value >> 32) & 0xffff_ffff))
        }
        func putString(_ offset: Int, _ value: String) {
            for (index, byte) in value.utf8.enumerated() {
                bytes[offset + index] = byte
            }
        }

        let textCmdSize: UInt32 = 72 + 80
        let linkCmdOffset = Int(32 + textCmdSize)
        let versionCmdOffset = linkCmdOffset + 72
        let signCmdOffset = versionCmdOffset + 24

        // mach_header_64
        put32(0, 0xfeed_facf) // MH_MAGIC_64
        put32(4, 0x0100_000c) // CPU_TYPE_ARM64
        put32(8, 0) // CPU_SUBTYPE_ARM64_ALL
        put32(12, fileType) // MH_EXECUTE (2) or MH_DYLIB (6)
        put32(16, 4) // ncmds
        put32(20, textCmdSize + 72 + 24 + 16) // sizeofcmds

        // LC_SEGMENT_64 __TEXT + __text section
        put32(32, 0x19) // LC_SEGMENT_64
        put32(36, textCmdSize)
        putString(40, "__TEXT")
        put64(64, UInt64(codeSize)) // vmsize
        put64(80, UInt64(codeSize)) // filesize
        put32(88, 5) // maxprot (r-x)
        put32(92, 5) // initprot (r-x)
        put32(96, 1) // nsects
        putString(104, "__text")
        putString(120, "__TEXT")
        put64(136, 1024) // addr
        put64(144, 16) // size
        put32(152, 1024) // offset
        for idx in 0..<16 {
            bytes[1024 + idx] = seedByte &+ UInt8(idx)
        }

        // LC_SEGMENT_64 __LINKEDIT
        put32(linkCmdOffset, 0x19)
        put32(linkCmdOffset + 4, 72)
        putString(linkCmdOffset + 8, "__LINKEDIT")
        put64(linkCmdOffset + 24, UInt64(codeSize)) // vmaddr
        put64(linkCmdOffset + 32, UInt64(reservation)) // vmsize
        put64(linkCmdOffset + 40, UInt64(codeSize)) // fileoff
        put64(linkCmdOffset + 48, UInt64(reservation)) // filesize

        // LC_BUILD_VERSION (iOS)
        put32(versionCmdOffset, 0x32)
        put32(versionCmdOffset + 4, 24)
        put32(versionCmdOffset + 8, 2) // PLATFORM_IOS
        put32(versionCmdOffset + 12, 0x0011_0000) // minos 17.0
        put32(versionCmdOffset + 16, 0x0011_0000) // sdk 17.0

        // LC_CODE_SIGNATURE reservation
        put32(signCmdOffset, 0x1d)
        put32(signCmdOffset + 4, 16)
        put32(signCmdOffset + 8, codeSize)
        put32(signCmdOffset + 12, reservation)

        return Data(bytes)
    }

    private static func writePlist(_ dict: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// Independently parses and verifies the SHA-1 and SHA-256 CodeDirectories written by
    /// Zsign into a Mach-O executable, checking header invariants, identifier, special slot
    /// hashes (Info.plist, CodeResources, XML & DER entitlements), and every 4 KB page hash.
    private static func verifySignedMachO(
        at executableURL: URL,
        expectedIdentifier: String,
        expectedInfoPlist: Data?,
        expectedCodeResources: Data?
    ) throws {
        let data = try Data(contentsOf: executableURL)
        let images = try MachOEntitlements.images(in: data)
        XCTAssertEqual(images.count, 1, "Expected single arm64 Mach-O slice at \(executableURL.lastPathComponent)")
        let image = try XCTUnwrap(images.first)
        let signatureRange = try XCTUnwrap(image.signatureRange, "Missing LC_CODE_SIGNATURE at \(executableURL.path)")
        let codeRange = image.range.lowerBound..<signatureRange.lowerBound

        let sha1Dir = try XCTUnwrap(image.blobs[0], "Missing SHA-1 CodeDirectory at \(executableURL.lastPathComponent)")
        let sha256Dir = try XCTUnwrap(
            image.blobs[0x1000],
            "Missing SHA-256 alternate CodeDirectory at \(executableURL.lastPathComponent)"
        )

        var specialBlobs: [UInt32: Data] = [:]
        if let expectedInfoPlist { specialBlobs[1] = expectedInfoPlist }
        if let requirements = image.blobs[2] { specialBlobs[2] = requirements }
        if let expectedCodeResources { specialBlobs[3] = expectedCodeResources }
        if let xmlEntitlements = image.blobs[5] { specialBlobs[5] = xmlEntitlements }
        if let derEntitlements = image.blobs[7] { specialBlobs[7] = derEntitlements }

        for (directory, expectedHashType) in [(sha1Dir, UInt8(1)), (sha256Dir, UInt8(2))] {
            let bytes = [UInt8](directory)
            func be32(_ offset: Int) -> Int {
                Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            }
            XCTAssertGreaterThanOrEqual(bytes.count, 88)
            XCTAssertEqual(be32(0), 0xfade_0c02, "CodeDirectory magic mismatch")
            XCTAssertEqual(be32(4), bytes.count, "CodeDirectory length mismatch")
            XCTAssertEqual(be32(8), 0x20400, "CodeDirectory version mismatch")
            XCTAssertEqual(be32(12) & 0x2, 0x2, "Expected CS_ADHOC flag on ad-hoc Zsign output")
            XCTAssertEqual(be32(32), codeRange.count, "codeLimit must cover exact pre-signature code range")
            XCTAssertEqual(bytes[37], expectedHashType)
            let hashSize = Int(bytes[36])
            XCTAssertEqual(hashSize, expectedHashType == 1 ? 20 : 32)
            XCTAssertEqual(bytes[39], 12, "Expected 4096-byte page size (2^12)")

            let identOffset = be32(20)
            let expectedIDBytes = Data(expectedIdentifier.utf8) + Data([0])
            XCTAssertEqual(
                Data(bytes[identOffset..<(identOffset + expectedIDBytes.count)]),
                expectedIDBytes,
                "CodeDirectory identifier mismatch for \(executableURL.lastPathComponent)"
            )

            let hashOffset = be32(16)
            let specialCount = be32(24)
            let codeSlots = be32(28)
            XCTAssertEqual(codeSlots, (codeRange.count + 4095) / 4096)

            func digest(_ payload: Data) -> Data {
                expectedHashType == 1
                    ? Data(Insecure.SHA1.hash(data: payload))
                    : Data(SHA256.hash(data: payload))
            }

            if specialCount > 0 {
                for slot in 1...specialCount {
                    let expected = specialBlobs[UInt32(slot)].map(digest) ?? Data(repeating: 0, count: hashSize)
                    let start = hashOffset - slot * hashSize
                    XCTAssertEqual(
                        Data(bytes[start..<(start + hashSize)]),
                        expected,
                        "Special slot -\(slot) hash mismatch in \(executableURL.lastPathComponent)"
                    )
                }
            }

            for page in 0..<codeSlots {
                let start = codeRange.lowerBound + page * 4096
                let end = min(start + 4096, codeRange.upperBound)
                let expected = digest(data.subdata(in: start..<end))
                let slotOffset = hashOffset + page * hashSize
                XCTAssertEqual(
                    Data(bytes[slotOffset..<(slotOffset + hashSize)]),
                    expected,
                    "Code page \(page) hash mismatch in \(executableURL.lastPathComponent)"
                )
            }
        }
    }

    func testRealZsignSignsAppFrameworkDylibExtensionVerifiesSealsAndRepackagesIPA() throws {
        let root = try makeTempRoot("ZsignE2E")
        let appURL = root.appendingPathComponent("VexSignE2E.app", isDirectory: true)
        let frameworkURL = appURL.appendingPathComponent("Frameworks/HelperKit.framework", isDirectory: true)
        let dylibURL = appURL.appendingPathComponent("Frameworks/libExtra.dylib")
        let extensionURL = appURL.appendingPathComponent("PlugIns/WidgetExt.appex", isDirectory: true)

        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Resources"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: frameworkURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)

        // 1. Construct main app, framework, dylib, and widget extension with real ARM64 Mach-O binaries.
        let mainExec = appURL.appendingPathComponent("VexSignE2E")
        try Self.makeSignableArm64MachO(fileType: 2, seedByte: 0x11).write(to: mainExec)
        try Self.writePlist([
            "CFBundleIdentifier": "com.vexsign.e2e.source",
            "CFBundleExecutable": "VexSignE2E",
            "CFBundleName": "VexSign Source",
            "CFBundleDisplayName": "VexSign Source",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "APPL"
        ], to: appURL.appendingPathComponent("Info.plist"))
        let appResourceURL = appURL.appendingPathComponent("Resources/app-config.json")
        try Data("{\"feature\":\"zsign-e2e\",\"version\":1}".utf8).write(to: appResourceURL)

        let frameworkExec = frameworkURL.appendingPathComponent("HelperKit")
        try Self.makeSignableArm64MachO(fileType: 6, seedByte: 0x22).write(to: frameworkExec)
        try Self.writePlist([
            "CFBundleIdentifier": "com.vexsign.e2e.source.HelperKit",
            "CFBundleExecutable": "HelperKit",
            "CFBundleName": "HelperKit",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "FMWK"
        ], to: frameworkURL.appendingPathComponent("Info.plist"))
        try Data("helper-kit-resource".utf8).write(to: frameworkURL.appendingPathComponent("helper-data.txt"))

        try Self.makeSignableArm64MachO(fileType: 6, seedByte: 0x33).write(to: dylibURL)

        let extExec = extensionURL.appendingPathComponent("WidgetExt")
        try Self.makeSignableArm64MachO(fileType: 2, seedByte: 0x44).write(to: extExec)
        try Self.writePlist([
            "CFBundleIdentifier": "com.vexsign.e2e.source.widget",
            "CFBundleExecutable": "WidgetExt",
            "CFBundleName": "WidgetExt",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "XPC!",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]
        ], to: extensionURL.appendingPathComponent("Info.plist"))
        try Data("{\"widget\":true}".utf8).write(to: extensionURL.appendingPathComponent("widget-data.json"))

        // Controlled entitlements sealed into the main executable.
        let entitlements: [String: Any] = [
            "application-identifier": "\(SigningRegressionFixture.team).com.vexsign.e2e.resigned",
            "com.apple.developer.team-identifier": SigningRegressionFixture.team,
            "com.apple.security.application-groups": ["group.com.vexsign.e2e"],
            "keychain-access-groups": ["\(SigningRegressionFixture.team).com.vexsign.e2e.resigned"]
        ]
        let entitlementsURL = root.appendingPathComponent("controlled.entitlements")
        try Self.writePlist(entitlements, to: entitlementsURL)

        // 2. Execute the REAL vendored Zsign C++/ObjC++ signing engine.
        let request = SigningEngineRequest(
            appPath: appURL.path,
            entitlementsPath: entitlementsURL.path,
            customIdentifier: "com.vexsign.e2e.resigned",
            customName: "VexSign E2E Signed",
            customVersion: "2.4.1",
            isAdHoc: true,
            removeProvisioning: true
        )
        let outcome = ZsignEngine.sign(request)
        XCTAssertTrue(outcome.succeeded, "Real ZsignEngine.sign failed: \(outcome.errorMessage ?? "unknown error")")
        XCTAssertNil(outcome.errorMessage)

        // 3. Verify bundle identifier, display name, version, and nested extension rewrites.
        let mainInfo = try XCTUnwrap(SignatureVerifier.readInfo(at: appURL))
        XCTAssertEqual(mainInfo["CFBundleIdentifier"] as? String, "com.vexsign.e2e.resigned")
        XCTAssertEqual(mainInfo["CFBundleDisplayName"] as? String, "VexSign E2E Signed")
        XCTAssertEqual(mainInfo["CFBundleShortVersionString"] as? String, "2.4.1")

        let extInfo = try XCTUnwrap(SignatureVerifier.readInfo(at: extensionURL))
        XCTAssertEqual(extInfo["CFBundleIdentifier"] as? String, "com.vexsign.e2e.resigned.widget")

        // 4. Verify CodeResources seals for main app, framework, and extension.
        var hashCache: [URL: SignatureVerifier.ResourceHashes] = [:]
        let appResources = try SignatureVerifier.verifyResources(in: appURL, executable: mainExec, cache: &hashCache)
        let frameworkResources = try SignatureVerifier.verifyResources(
            in: frameworkURL,
            executable: frameworkExec,
            cache: &hashCache
        )
        let extResources = try SignatureVerifier.verifyResources(
            in: extensionURL,
            executable: extExec,
            cache: &hashCache
        )

        // 5. Verify SHA-1 & SHA-256 CodeDirectories, special slots, and code pages on EVERY Mach-O.
        try Self.verifySignedMachO(
            at: mainExec,
            expectedIdentifier: "com.vexsign.e2e.resigned",
            expectedInfoPlist: try Data(contentsOf: appURL.appendingPathComponent("Info.plist")),
            expectedCodeResources: appResources
        )
        try Self.verifySignedMachO(
            at: frameworkExec,
            expectedIdentifier: "com.vexsign.e2e.source.HelperKit",
            expectedInfoPlist: try Data(contentsOf: frameworkURL.appendingPathComponent("Info.plist")),
            expectedCodeResources: frameworkResources
        )
        try Self.verifySignedMachO(
            at: dylibURL,
            expectedIdentifier: "libExtra.dylib",
            expectedInfoPlist: nil,
            expectedCodeResources: nil
        )
        try Self.verifySignedMachO(
            at: extExec,
            expectedIdentifier: "com.vexsign.e2e.resigned.widget",
            expectedInfoPlist: try Data(contentsOf: extensionURL.appendingPathComponent("Info.plist")),
            expectedCodeResources: extResources
        )

        // 6. Verify BOTH XML (slot 5) and DER (slot 7) entitlements match our controlled entitlements.
        let sealedEntitlements = try MachOEntitlements.requiredEntitlements(forExecutableAt: mainExec)
        XCTAssertTrue(
            MachOEntitlements.equivalent(sealedEntitlements, entitlements),
            "Sealed XML/DER entitlements did not match controlled entitlements."
        )

        // 7. Verify cryptographic tamper detection: mutating 1 byte of a sealed resource fails verification.
        let originalResourceBytes = try Data(contentsOf: appResourceURL)
        var tamperedBytes = originalResourceBytes
        tamperedBytes[0] ^= 0x01
        try tamperedBytes.write(to: appResourceURL)
        var tamperCache: [URL: SignatureVerifier.ResourceHashes] = [:]
        XCTAssertThrowsError(
            try SignatureVerifier.verifyResources(in: appURL, executable: mainExec, cache: &tamperCache),
            "Tampering with a sealed resource must fail CodeResources cryptographic verification."
        )
        try originalResourceBytes.write(to: appResourceURL)

        // 8. Repackage into a final IPA, validate archive safety, re-extract, and re-verify seals.
        let ipaURL = root.appendingPathComponent("VexSignE2E-Signed.ipa")
        try AppArchiver.archive(appDir: appURL, to: ipaURL, compression: .defaultCompression)

        let extractRoot = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        try ArchiveSafetyValidator.validate(ipaURL, destination: extractRoot)
        try IPAExtractor.extract(ipaURL, to: extractRoot)

        let extractedPayload = extractRoot.appendingPathComponent("Payload", isDirectory: true)
        let extractedApp = try IPAImportPayload.validateApplication(in: extractedPayload)
        let extractedExec = try XCTUnwrap(SigningInputValidation.executable(in: extractedApp))
        var roundTripCache: [URL: SignatureVerifier.ResourceHashes] = [:]
        _ = try SignatureVerifier.verifyResources(in: extractedApp, executable: extractedExec, cache: &roundTripCache)
        let roundTripEntitlements = try MachOEntitlements.requiredEntitlements(forExecutableAt: extractedExec)
        XCTAssertTrue(MachOEntitlements.equivalent(roundTripEntitlements, entitlements))
    }

    func testRealZsignRefusesNonAppleEphemeralIdentityWithoutDegradingToAdHoc() throws {
        let root = try makeTempRoot("ZsignRefusal")
        let appURL = root.appendingPathComponent("RefusalApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try Self.makeSignableArm64MachO(fileType: 2, seedByte: 0x55)
            .write(to: appURL.appendingPathComponent("RefusalApp"))
        try Self.writePlist([
            "CFBundleIdentifier": "com.vexsign.e2e.refuse",
            "CFBundleExecutable": "RefusalApp",
            "CFBundleName": "RefusalApp",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundlePackageType": "APPL"
        ], to: appURL.appendingPathComponent("Info.plist"))

        let ca = try EphemeralIdentityFixture.generateIdentity(commonName: "Untrusted E2E CA")
        let leaf = try EphemeralIdentityFixture.generateIdentity(commonName: "Untrusted E2E Leaf", issuer: ca)
        let password = "e2e-refusal-password"
        let p12URL = root.appendingPathComponent("untrusted.p12")
        try EphemeralIdentityFixture.buildPKCS12(identities: [leaf], password: password).write(to: p12URL)

        let profile = try SigningRegressionFixture.profile(
            pattern: "\(SigningRegressionFixture.team).com.vexsign.e2e.refuse",
            certificates: [leaf.certificateDER]
        )
        let provURL = root.appendingPathComponent("untrusted.mobileprovision")
        try EphemeralIdentityFixture.buildSignedProvisioningProfileCMS(profile: profile, signer: ca).write(to: provURL)

        let entitlementsURL = root.appendingPathComponent("entitlements.plist")
        try Self.writePlist([
            "application-identifier": "\(SigningRegressionFixture.team).com.vexsign.e2e.refuse",
            "com.apple.developer.team-identifier": SigningRegressionFixture.team
        ], to: entitlementsURL)

        let request = SigningEngineRequest(
            appPath: appURL.path,
            provisionPath: provURL.path,
            p12Path: p12URL.path,
            p12Password: password,
            entitlementsPath: entitlementsURL.path,
            isAdHoc: false,
            removeProvisioning: false
        )
        let outcome = ZsignEngine.sign(request)
        XCTAssertFalse(outcome.succeeded, "Non-Apple identity must never succeed in device-signing mode.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appURL.appendingPathComponent("_CodeSignature/CodeResources").path),
            "Refused signing run must not emit a forged CodeResources envelope."
        )
    }
}
