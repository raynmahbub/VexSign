// MARK: - DevicePickerTests
/// Unit tests for the device picker's model.
///
/// The picker's job is narrower than it used to be: it reports what the pairing record says and
/// refuses to invent the rest. These tests pin that down — the record's fields, the stable
/// identity, and the fact that a readable file never becomes a trust claim.

import Foundation
import Testing
import NimbleExtensions
@testable import VexSign

@Suite("DevicePicker Tests")
struct DevicePickerTests {

    // MARK: - DeviceInfo Tests

    @Test("DeviceInfo displayName format")
    func testDeviceInfoDisplayName() {
        let info = DeviceInfo(
            udid: "ABCDEF1234567890",
            name: "John's iPhone",
            deviceType: "iPhone",
            iosVersion: "17.2",
            buildVersion: "21C62",
            modelNumber: "iPhone15,2",
            trust: .verified
        )

        #expect(info.displayName == "John's iPhone (iPhone)")
    }

    @Test("DeviceInfo with iPad device type")
    func testDeviceInfoIPad() {
        let info = DeviceInfo(
            udid: "ABCDEF1234567890",
            name: "Jane's iPad",
            deviceType: "iPad",
            iosVersion: "17.2",
            buildVersion: "21C62",
            modelNumber: "iPad14,3",
            trust: .verified
        )

        #expect(info.displayName == "Jane's iPad (iPad)")
    }

    @Test("Trust is a claim about the device, not about the file")
    func testTrustIsNotPresence() {
        let unverified = DeviceInfo(
            udid: "ABCDEF1234567890",
            name: "iPhone",
            deviceType: "iPhone",
            iosVersion: "17.2",
            buildVersion: "21C62",
            modelNumber: "iPhone15,2",
            trust: .unverified
        )
        #expect(unverified.isTrusted == false, "a readable pairing record is not authorization")

        let verified = DeviceInfo(
            udid: "ABCDEF1234567890",
            name: "iPhone",
            deviceType: "iPhone",
            iosVersion: "17.2",
            buildVersion: "21C62",
            modelNumber: "iPhone15,2",
            trust: .verified
        )
        #expect(verified.isTrusted)
    }

    // MARK: - Record identity

    @Test("A record's identity is its UDID, so a refresh cannot reseat the selection")
    func testRecordIdentityIsStable() {
        let first = PairedDeviceRecord(
            udid: "00008120-001A2B3C4D5E6F70",
            name: "iPhone",
            deviceType: "iPhone",
            iosVersion: "17.2",
            presence: .discovered,
            pairing: .readable(udid: "00008120-001A2B3C4D5E6F70"),
            trust: .unverified
        )
        let second = PairedDeviceRecord(
            udid: "00008120-001A2B3C4D5E6F70",
            name: "Renamed iPhone",
            deviceType: "iPhone",
            iosVersion: "18.0",
            presence: .discovered,
            pairing: .readable(udid: "00008120-001A2B3C4D5E6F70"),
            trust: .unverified
        )

        #expect(first.id == second.id)
        #expect(first.id == first.udid)
    }

    // MARK: - UDID Formatting Tests

    @Test("UDID formatting removes invalid characters")
    func testUDIDFormatting() {
        // Only hex digits and the group separator are valid UDID characters;
        // g-z are dropped even after uppercasing.
        let input = "abc-def-ghi-jkl-mno-pqr"
        let filtered = input.uppercased().filter { "0123456789ABCDEF-".contains($0) }
        #expect(filtered == "ABC-DEF----")

        let input2 = "abcdefghijklmnopqrstuvwxyz123456"
        let filtered2 = input2.uppercased().filter { "0123456789ABCDEF-".contains($0) }
        #expect(filtered2 == "ABCDEF123456")

        let legacy = "abcdef0123456789abcdef0123456789abcdef01"
        let filteredLegacy = legacy.uppercased().filter { "0123456789ABCDEF-".contains($0) }
        #expect(filteredLegacy == "ABCDEF0123456789ABCDEF0123456789ABCDEF01")
    }

    // MARK: - LockdownClientError Tests

    @Test("LockdownClientError descriptions")
    func testLockdownClientErrorDescriptions() {
        #expect(LockdownClientError.pairingFileNotFound.errorDescription?.contains("Pairing file not found") == true)
        #expect(LockdownClientError.invalidPairingFile.errorDescription?.contains("invalid or corrupted") == true)
        #expect(LockdownClientError.connectionFailed("test").errorDescription?.contains("test") == true)
        #expect(LockdownClientError.deviceNotFound.errorDescription?.contains("No device found") == true)
        #expect(LockdownClientError.queryFailed("test").errorDescription?.contains("test") == true)
        #expect(LockdownClientError.invalidResponse.errorDescription?.contains("invalid response") == true)
        #expect(LockdownClientError.sslError("test").errorDescription?.contains("SSL/TLS error") == true)
    }

    // MARK: - IDeviceManager Tests

    @MainActor
    @Test("IDeviceManager answers from the pairing file and nothing else")
    func testPairedDevicesComeFromPairingFile() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pairingFile = documents.appendingPathComponent("pairingFile.plist")
        #expect(pairingFile.path.contains("Documents"))
        #expect(pairingFile.path.contains("pairingFile.plist"))

        // One device per usable pairing record and none without one: the manager never invents
        // a device out of a UDID it could not read, and an unusable record produces no row.
        let result = await IDeviceManager.shared.pairedDevices()
        #expect(result.devices.count <= 1)
        #expect(result.devices.isEmpty == (result.pairing.udid == nil))
        if let record = result.devices.first {
            #expect(record.udid == result.pairing.udid)
            #expect(record.trust != .verified, "no session was opened, so nothing may claim trust")
        }
    }
}
