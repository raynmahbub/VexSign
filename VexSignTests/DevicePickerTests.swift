// MARK: - DevicePickerTests
/// Unit tests for the DevicePickerView and LockdownClient functionality.

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
            isTrusted: true
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
            isTrusted: true
        )

        #expect(info.displayName == "Jane's iPad (iPad)")
    }

    // MARK: - PairedDevice Tests

    @Test("PairedDevice initialization")
    func testPairedDeviceInitialization() {
        let device = PairedDevice(
            udid: "ABCDEF1234567890",
            name: "Test iPhone",
            deviceType: "iPhone",
            iosVersion: "17.2",
            isTrusted: true
        )

        #expect(device.udid == "ABCDEF1234567890")
        #expect(device.name == "Test iPhone")
        #expect(device.deviceType == "iPhone")
        #expect(device.iosVersion == "17.2")
        #expect(device.isTrusted == true)
    }

    // MARK: - UDID Formatting Tests

    @Test("UDID formatting removes invalid characters")
    func testUDIDFormatting() {
        let input = "abc-def-ghi-jkl-mno-pqr"
        let filtered = input.uppercased().filter { "0123456789ABCDEF-".contains($0) }
        #expect(filtered == "ABC-DEF-GHI-JKL-MNO-PQR")

        let input2 = "abcdefghijklmnopqrstuvwxyz123456"
        let filtered2 = input2.uppercased().filter { "0123456789ABCDEF-".contains($0) }
        #expect(filtered2 == "ABCDEF123456")
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
    func testPairedDevicesComeFromPairingFile() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pairingFile = documents.appendingPathComponent("pairingFile.plist")
        #expect(pairingFile.path.contains("Documents"))
        #expect(pairingFile.path.contains("pairingFile.plist"))

        // One device per pairing record and none without one: the manager never
        // invents a device out of a UDID it could not read.
        let expected = FileManager.default.fileExists(atPath: pairingFile.path) ? 1 : 0
        let devices = try await IDeviceManager.shared.getPairedDevices()
        #expect(devices.count == expected)
    }
}