// Runs against the production parser/policy in app tests and the focused Apple
// host smoke package. None of these fixtures establishes a device capability.
import Foundation
import XCTest
#if canImport(DeviceFoundation)
@testable import DeviceFoundation
#else
import IDeviceSwift
#endif

final class PairingRecordFoundationTests: XCTestCase {
    func testClassicXMLAndBinaryHaveTheSameMeaningWithoutRewritingBytes() throws {
        for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
            var fixture = PairingRecordTestFixtures.classic()
            fixture["UDID"] = "  " + PairingRecordTestFixtures.device.lowercased() + "\n"
            let data = try PairingRecordTestFixtures.data(fixture, format: format)
            let metadata = try PairingRecordDocument.inspect(data)
            XCTAssertEqual(metadata.format, .lockdown)
            XCTAssertEqual(metadata.deviceIdentifier, PairingRecordTestFixtures.device)
            XCTAssertEqual(metadata.schemaVersion, "unversioned")
            XCTAssertEqual(metadata.byteCount, data.count)
            XCTAssertEqual(metadata.sha256, PairingRecordDocument.fingerprint(data))
        }
    }

    func testClassicDeviceIdentityMayBeAbsentButRequiredFieldTypesCannotBeFaked() throws {
        var fixture = PairingRecordTestFixtures.classic()
        fixture.removeValue(forKey: "UDID")
        XCTAssertNil(try PairingRecordDocument.inspect(PairingRecordTestFixtures.data(fixture)).deviceIdentifier)
        for key in PairingRecordDocument.classicDataKeys {
            var invalid = fixture
            invalid[key] = "not credential data"
            expect(.invalidFields([key]), try PairingRecordTestFixtures.data(invalid))
        }
        fixture["HostID"] = 1
        expect(.invalidFields(["HostID"]), try PairingRecordTestFixtures.data(fixture))
    }

    func testRemoteHostUUIDIsNeverADeviceUDID() throws {
        let data = try PairingRecordTestFixtures.data(PairingRecordTestFixtures.remote())
        let metadata = try PairingRecordDocument.inspect(data)
        XCTAssertEqual(metadata.format, .remotePairing)
        XCTAssertNil(metadata.deviceIdentifier)
        XCTAssertFalse(PairingRecordDocument.isDeviceIdentifier(PairingRecordTestFixtures.host))
    }

    func testCombinedAndOptionalIRKStayTheirOriginalFormat() throws {
        var fixture = PairingRecordTestFixtures.classic()
        fixture.merge(try PairingRecordTestFixtures.remote()) { _, remote in remote }
        fixture["alt_irk"] = Data(repeating: 0, count: 16)
        for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
            let metadata = try PairingRecordDocument.inspect(PairingRecordTestFixtures.data(fixture, format: format))
            XCTAssertEqual(metadata.format, .combined)
            XCTAssertEqual(metadata.deviceIdentifier, PairingRecordTestFixtures.device)
        }
        fixture["alt_irk"] = Data(repeating: 0, count: 32)
        expect(.invalidFields(["alt_irk"]), try PairingRecordTestFixtures.data(fixture))
    }

    func testRemoteSigningKeyRelationAndFieldSizesAreChecked() throws {
        var fixture = try PairingRecordTestFixtures.remote()
        fixture["public_key"] = Data(repeating: 0, count: 32)
        expect(.remoteKeyMismatch, try PairingRecordTestFixtures.data(fixture))
        fixture = try PairingRecordTestFixtures.remote()
        fixture["private_key"] = Data(repeating: 0, count: 64)
        expect(.invalidFields(["private_key"]), try PairingRecordTestFixtures.data(fixture))
        fixture = try PairingRecordTestFixtures.remote()
        fixture["identifier"] = PairingRecordTestFixtures.device
        expect(.invalidFields(["identifier"]), try PairingRecordTestFixtures.data(fixture))
    }

    func testConflictingDeviceAliasesCannotAuthorizeAnotherDevice() throws {
        var fixture = PairingRecordTestFixtures.classic()
        fixture["DeviceID"] = PairingRecordTestFixtures.device.lowercased()
        XCTAssertEqual(try PairingRecordDocument.inspect(PairingRecordTestFixtures.data(fixture)).deviceIdentifier,
                       PairingRecordTestFixtures.device)
        fixture["remotepairing_udid"] = PairingRecordTestFixtures.otherDevice
        expect(.conflictingDeviceIdentity, try PairingRecordTestFixtures.data(fixture))
        fixture["remotepairing_udid"] = 7
        expect(.invalidFields(["remotepairing_udid"]), try PairingRecordTestFixtures.data(fixture))
    }

    func testUnknownVersionsAndWrapperSchemasAreNotDownConverted() throws {
        for key in ["version", "Version", "schemaVersion", "schema_version", "FormatVersion"] {
            var fixture = PairingRecordTestFixtures.classic()
            fixture[key] = "next-version"
            expect(.unsupportedFormat, try PairingRecordTestFixtures.data(fixture))
        }
        expect(.malformed, try PairingRecordTestFixtures.data(["pairing": PairingRecordTestFixtures.classic()]))
        expect(.unsupportedFormat, try PairingRecordTestFixtures.data(["unrelated": "file"]))
    }

    func testEmptyOversizedNestedAndDuplicateXMLAreRefused() throws {
        expect(.malformed, Data())
        expect(.oversized, Data(repeating: 0, count: PairingRecordDocument.maximumSize + 1))
        for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
            var nested = PairingRecordTestFixtures.classic()
            nested["unknown"] = ["nested": ["deep": "value"]]
            expect(.malformed, try PairingRecordTestFixtures.data(nested, format: format))
        }
        let duplicate = "<plist version=\"1.0\"><dict><key>HostID</key><string>a</string><key>HostID</key><string>b</string></dict></plist>"
        expect(.malformed, Data(duplicate.utf8))
        let deep = "<plist version=\"1.0\">" + String(repeating: "<dict>", count: 2000)
            + String(repeating: "</dict>", count: 2000) + "</plist>"
        expect(.malformed, Data(deep.utf8))
    }

    func testEntitiesTruncatedBinaryExcessiveObjectsAndCyclesAreRefused() throws {
        let entity = "<!DOCTYPE plist [<!ENTITY secret SYSTEM 'file:///not-a-fixture-secret'>]><plist version=\"1.0\"><dict><key>HostID</key><string>&secret;</string></dict></plist>"
        expect(.malformed, Data(entity.utf8))
        expect(.malformed, Data("bplist00".utf8))
        var binary = try PairingRecordTestFixtures.data(PairingRecordTestFixtures.classic())
        binary.replaceSubrange((binary.count - 24)..<(binary.count - 16), with: [0, 0, 0, 0, 0, 0, 0x10, 1])
        expect(.malformed, binary) // 4097 objects, rejected before Foundation allocation
        var cycle = Data("bplist00".utf8)
        cycle.append(contentsOf: [0xd1, 0, 0, 8]) // one dictionary, referring to itself for key and value
        var trailer = [UInt8](repeating: 0, count: 32)
        trailer[6] = 1; trailer[7] = 1; trailer[15] = 1; trailer[31] = 11
        cycle.append(contentsOf: trailer)
        expect(.malformed, cycle)
    }

    func testMetadataAndErrorsNeverDescribeCredentialValuesOrDeviceIdentity() throws {
        let metadata = try PairingRecordDocument.inspect(PairingRecordTestFixtures.data(PairingRecordTestFixtures.classic()))
        for description in [String(describing: metadata), String(reflecting: metadata), PairingRecordError.remoteKeyMismatch.localizedDescription] {
            XCTAssertFalse(description.contains(PairingRecordTestFixtures.device))
            XCTAssertFalse(description.contains(PairingRecordTestFixtures.host))
            XCTAssertTrue(description.count < 300)
        }
    }

    func testOSRouteBoundaryMatrixDoesNotPromiseSupport() {
        let cases: [(Int, Int, DevicePairingRoute)] = [
            (17, 3, .unsupported), (17, 4, .importedClassic), (18, 7, .importedClassic),
            (26, 3, .importedClassic), (26, 4, .importedRemoteRequired), (26, 7, .importedRemoteRequired),
            (26, 8, .unknownOS), (26, 9, .unknownOS), (27, 0, .onDeviceHostPairing), (28, 0, .onDeviceHostPairing)
        ]
        for (major, minor, route) in cases {
            XCTAssertEqual(DevicePairingRoute.resolve(.init(major: major, minor: minor)), route)
        }
    }

    func testNativeRouteRejectsWrongFormatsAndUnacceptedModernDependencies() throws {
        let classicOS = DeviceOSVersion(major: 26, minor: 3)
        XCTAssertNoThrow(try DeviceTransportPolicy.requireClassicRoute(format: .lockdown, version: classicOS))
        XCTAssertNoThrow(try DeviceTransportPolicy.requireClassicRoute(format: .combined, version: classicOS))
        XCTAssertThrowsError(try DeviceTransportPolicy.requireClassicRoute(format: .remotePairing, version: classicOS))
        for format: PairingRecordFormat in [.lockdown, .remotePairing, .combined] {
            for os in [DeviceOSVersion(major: 17, minor: 3), .init(major: 26, minor: 4),
                       .init(major: 26, minor: 8), .init(major: 27, minor: 0)] {
                XCTAssertThrowsError(try DeviceTransportPolicy.requireClassicRoute(format: format, version: os))
            }
        }
    }

    func testOnDeviceHostPairingRoutePolicy() throws {
        XCTAssertNoThrow(try DeviceTransportPolicy.requireOnDeviceHostPairingRoute(version: .init(major: 27, minor: 0)))
        XCTAssertNoThrow(try DeviceTransportPolicy.requireOnDeviceHostPairingRoute(version: .init(major: 28, minor: 0)))
        for os in [DeviceOSVersion(major: 17, minor: 3), .init(major: 17, minor: 4), .init(major: 26, minor: 3),
                   .init(major: 26, minor: 4), .init(major: 26, minor: 8)] {
            XCTAssertThrowsError(try DeviceTransportPolicy.requireOnDeviceHostPairingRoute(version: os))
        }
    }

    func testMalformedOSStringsDoNotSkipComponents() {
        XCTAssertEqual(DeviceOSVersion.parse("17.4"), .init(major: 17, minor: 4))
        XCTAssertEqual(DeviceOSVersion.parse("26.3.1"), .init(major: 26, minor: 3, patch: 1))
        for invalid in ["17", "17.x.4", "17.4.beta", "-17.4", "17..4", "17.4.1.1", "17.4 ", "1000.0"] {
            XCTAssertNil(DeviceOSVersion.parse(invalid), invalid)
        }
    }

    private func expect(_ expected: PairingRecordError, _ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PairingRecordDocument.inspect(data), file: file, line: line) { error in
            XCTAssertEqual(error as? PairingRecordError, expected, file: file, line: line)
        }
    }
}
