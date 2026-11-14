import Foundation
import CryptoKit
import XCTest
@testable import NativeSigningLinkSmoke

/// Deferred consistency policy fixtures. Synthetic main headers/profile bytes
/// are NOT a real executable/Apple profile or permission to sign/install.
final class NativeOutputPolicyTests: XCTestCase {
    private static let team = "ABCDE12345"
    private static let bundle = "com.example.fixture"
    private static let root = "Payload/Fixture.app/"
    private static let profile = Data("synthetic expected profile bytes".utf8)
    private static func le(_ value: Int) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func frame(_ magic: Int, _ data: Data) -> Data {
        func be(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) }) }
        return be(magic) + be(data.count + 8) + data
    }
    private static func xml() throws -> Data {
        try NativeMainAppAcceptance.signingEntitlements(requestedXML: nil, bundleIdentifier: bundle,
            applicationIdentifier: team + "." + bundle, teamIdentifier: team)
    }
    private static func der() throws -> Data {
        try NativeOutputEntitlements.canonicalDER(applicationIdentifier: team + "." + bundle, teamIdentifier: team)
    }
    private static func verifyClaims(xml: Data, der: Data, expectedXML: Data) throws {
        try NativeOutputEntitlements.verify(xmlBlob: frame(0xfade7171, xml), derBlob: frame(0xfade7172, der),
            expectedXML: expectedXML, applicationIdentifier: team + "." + bundle, teamIdentifier: team)
    }
    func testCanonicalDERHasExactlyExpectedFourClaimsAndTrueFF() throws {
        let expected = try Self.xml(); let der = try Self.der()
        try Self.verifyClaims(xml: expected, der: der, expectedXML: expected)
        let nodes = try NativeProfileDER.one(der, tag: 0x31).children(tag: 0x31, limit: 4, sorted: true)
        var claims: [String: NativeProfileDER.Node] = [:]
        for node in nodes {
            let pair = try node.children(tag: 0x30, limit: 2)
            XCTAssertEqual(pair.count, 2); XCTAssertEqual(pair[0].tag, 0x0c)
            claims[try XCTUnwrap(String(data: pair[0].content, encoding: .utf8))] = pair[1]
        }
        XCTAssertEqual(claims.count, 4)
        XCTAssertEqual(claims["get-task-allow"]?.content, Data([0xff]))
        XCTAssertEqual(claims["application-identifier"]?.content, Data((Self.team + "." + Self.bundle).utf8))
        XCTAssertEqual(claims["com.apple.developer.team-identifier"]?.content, Data(Self.team.utf8))
        let groups = try XCTUnwrap(claims["keychain-access-groups"]).children(tag: 0x30, limit: 1)
        XCTAssertEqual(groups.first?.content, Data((Self.team + "." + Self.bundle).utf8))
    }
    func testDualClaimsRejectBERBooleanWrongIdentityAndExtraBytes() throws {
        let xml = try Self.xml(); let der = try Self.der()
        var ber = der
        let range = try XCTUnwrap(ber.range(of: Data([1, 1, 0xff])))
        ber.replaceSubrange(range, with: Data([1, 1, 1]))
        XCTAssertThrowsError(try Self.verifyClaims(xml: xml, der: ber, expectedXML: xml))
        let foreign = try NativeOutputEntitlements.canonicalDER(applicationIdentifier: "ZZZZZ12345." + Self.bundle, teamIdentifier: "ZZZZZ12345")
        XCTAssertThrowsError(try Self.verifyClaims(xml: xml, der: foreign, expectedXML: xml))
        XCTAssertThrowsError(try Self.verifyClaims(xml: xml, der: der + Data([0]), expectedXML: xml))
        XCTAssertThrowsError(try Self.verifyClaims(xml: xml + Data([32]), der: der, expectedXML: xml))
    }
    func testExpectedXMLCannotSupplyExtraPrivilegesOrIntegerBoolean() throws {
        let original = try Self.xml(); let der = try Self.der()
        for change in ["integer", "extra", "foreignGroup"] {
            var dictionary = try NativeMainAppAcceptance.dictionary(original)
            if change == "integer" { dictionary["get-task-allow"] = 1 }
            if change == "extra" { dictionary["dynamic-codesigning"] = true }
            if change == "foreignGroup" { dictionary["keychain-access-groups"] = ["other.group"] }
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            XCTAssertThrowsError(try Self.verifyClaims(xml: data, der: der, expectedXML: data))
        }
    }
    func testEntitlementBlobFramingAndLongLengthEncoding() throws {
        let xml = try Self.xml(); let der = try Self.der()
        XCTAssertThrowsError(try NativeOutputEntitlements.verify(xmlBlob: Self.frame(0xfade7172, xml), derBlob: Self.frame(0xfade7172, der),
            expectedXML: xml, applicationIdentifier: Self.team + "." + Self.bundle, teamIdentifier: Self.team))
        let long = try NativeOutputEntitlements.canonicalDER(applicationIdentifier: Self.team + ".com." + String(repeating: "a", count: 120), teamIdentifier: Self.team)
        XCTAssertGreaterThan(long.count, 127)
        XCTAssertNoThrow(try NativeProfileDER.one(long, tag: 0x31).children(tag: 0x31, limit: 4, sorted: true))
        XCTAssertThrowsError(try NativeOutputEntitlements.canonicalDER(applicationIdentifier: Self.team + "." + Self.bundle, teamIdentifier: Self.team + "\n"))
    }

    private static func source() throws -> (Data, NativeVerifiedIPAContent, [NativeStoredZIPWriter.Entry]) {
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle,
            "CFBundleExecutable": "Main", "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"]], format: .xml, options: 0)
        let command = le(0x19) + le(72) + Data(repeating: 0, count: 64)
        let main = le(0xfeedfacf) + le(0x0100000c) + le(0) + le(2) + le(1) + le(command.count) + le(0) + le(0) + command
        let entries: [NativeStoredZIPWriter.Entry] = [
            .init(path: root + "Info.plist", bytes: info), .init(path: root + "Main", bytes: main, executable: true),
            .init(path: root + "Resources/a&<b>.txt", bytes: Data([4, 5, 6])),
            .init(path: root + "Resources/empty", bytes: Data()),
            .init(path: root + "_CodeSignature/Legacy", bytes: Data("old signature metadata".utf8))
        ]
        let archive = try NativeStoredZIPWriter.encode(entries)
        return (archive, try NativeIPAContentVerifier.verify(archive, bundleIdentifier: bundle), entries)
    }
    private static func output(_ source: [NativeStoredZIPWriter.Entry], changes: [String: Data] = [:],
                               drop: String? = nil, sealOverride: Data? = nil) throws -> Data {
        var entries = source.filter { !$0.path.hasPrefix(root + "_CodeSignature/") && $0.path != drop }.map {
            NativeStoredZIPWriter.Entry(path: $0.path, bytes: $0.path == root + "Main" ? Data([1, 2, 3]) : $0.bytes, executable: $0.executable)
        }
        entries.append(.init(path: root + "embedded.mobileprovision", bytes: profile))
        for (path, bytes) in changes {
            entries.removeAll { $0.path == path }; entries.append(.init(path: path, bytes: bytes))
        }
        var digests: [String: NativeStrictCodeResources.Digests] = [:]
        for entry in entries where entry.path != root + "Main" && !entry.path.hasPrefix(root + "_CodeSignature/") {
            digests[String(entry.path.dropFirst(root.count))] = .init(sha1: Data(Insecure.SHA1.hash(data: entry.bytes)), sha256: Data(SHA256.hash(data: entry.bytes)))
        }
        let seal = try sealOverride ?? NativeStrictCodeResources.encode(digests)
        entries.append(.init(path: root + "_CodeSignature/CodeResources", bytes: seal))
        return try NativeStoredZIPWriter.encode(entries)
    }
    private static func verifyResource(_ source: (Data, NativeVerifiedIPAContent, [NativeStoredZIPWriter.Entry]), _ output: Data) throws -> NativeResourceSealEvidence {
        try NativeResourceSealVerifier.verify(originalArchive: source.0, content: source.1, outputArchive: output, expectedProfileCMS: profile)
    }
    func testResourceMutationAllowlistAndExactCompleteSeal() throws {
        let source = try Self.source(); let output = try Self.output(source.2)
        let evidence = try Self.verifyResource(source, output)
        XCTAssertEqual(evidence.sourceArchiveSHA256, source.1.archiveSHA256)
        XCTAssertEqual(evidence.outputArchiveSHA256, NativeSigningIdentityOwner.hash(output))
        XCTAssertEqual(evidence.profileSHA256, NativeSigningIdentityOwner.hash(Self.profile))
    }
    func testChangedInfoResourceDeletedAndInjectedFilesRejectEvenWhenResealed() throws {
        let source = try Self.source()
        for path in ["Info.plist", "Resources/a&<b>.txt", "Resources/new", "_CodeSignature/Injected"] {
            let output = try Self.output(source.2, changes: [Self.root + path: Data([9])])
            XCTAssertThrowsError(try Self.verifyResource(source, output), path)
        }
        let missing = try Self.output(source.2, drop: Self.root + "Resources/empty")
        XCTAssertThrowsError(try Self.verifyResource(source, missing))
    }
    func testProfileAndOriginalArchiveCannotBeSubstituted() throws {
        let source = try Self.source(); let output = try Self.output(source.2)
        XCTAssertThrowsError(try NativeResourceSealVerifier.verify(originalArchive: source.0 + Data([0]), content: source.1, outputArchive: output, expectedProfileCMS: Self.profile))
        let foreign = try Self.output(source.2, changes: [Self.root + "embedded.mobileprovision": Data([8])])
        XCTAssertThrowsError(try Self.verifyResource(source, foreign))
    }
    func testNoncanonicalIncompleteOrOmitRuleManifestRejects() throws {
        let source = try Self.source()
        for seal in [Data([0]), try NativeStrictCodeResources.encode([:]), Data("<plist><dict><key>rules2</key><dict><key>.*</key><false/></dict></dict></plist>".utf8)] {
            let output = try Self.output(source.2, sealOverride: seal)
            XCTAssertThrowsError(try Self.verifyResource(source, output))
        }
    }
    func testStrictResourceManifestIsDeterministicAndEscapesFileNames() throws {
        let digest = NativeStrictCodeResources.Digests(sha1: Data(repeating: 1, count: 20), sha256: Data(repeating: 2, count: 32))
        let first = try NativeStrictCodeResources.encode(["z": digest, "a&<b>\"'.txt": digest])
        XCTAssertEqual(first, try NativeStrictCodeResources.encode(["a&<b>\"'.txt": digest, "z": digest]))
        let dictionary = try NativeMainAppAcceptance.dictionary(first)
        XCTAssertEqual(Set((dictionary["files2"] as? [String: Any])?.keys.map { $0 } ?? []), Set(["z", "a&<b>\"'.txt"]))
        XCTAssertThrowsError(try NativeStrictCodeResources.encode(["../outside": digest]))
    }
    func testComposedSignatureRejectsMissingDuplicateAndHiddenSlots() throws {
        let xml = try Self.xml()
        func check(_ data: Data) throws {
            _ = try NativeMainSignatureConsistency.verify(signature: data, executablePrefix: Data([1]), textFileRange: 0..<1,
                infoPlist: Data([1]), codeResources: Data([2]), expectedXML: xml, bundleIdentifier: Self.bundle,
                teamIdentifier: Self.team, expectedCertificate: Data([1]))
        }
        XCTAssertThrowsError(try check(Data()))
        XCTAssertThrowsError(try check(Self.frame(0xfade0cc0, Data(repeating: 0, count: 44))))
        var duplicate = Self.frame(0xfade0cc0, Data([0, 0, 0, 5]) + Data(repeating: 0, count: 40))
        duplicate += Data([1]) // nonzero hidden allocation payload
        XCTAssertThrowsError(try check(duplicate))
    }
}
