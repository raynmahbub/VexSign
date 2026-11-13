// MARK: - DeviceConnectivityTests
/// The device layer's states and capability answers, tested as values.
///
/// Nothing here needs a device, a cable or a pairing record: the inspector takes data, the
/// record is a value, and the resolver takes states. That is deliberate — the picker's old
/// behaviour (a file became a trusted device with a fresh identity per load) was untestable
/// precisely because it was entangled with the filesystem and the framework.

import Foundation
import Testing
@testable import VexSign

@Suite("Device Connectivity")
struct DeviceConnectivityTests {

    // MARK: - Fixtures

    /// A complete pairing record, with `DeviceID` spelled the way the user's tool wrote it.
    private func record(udid: String = "00008120-001A2B3C4D5E6F70") -> [String: Any] {
        [
            "DeviceID": udid,
            "HostID": "A1B2C3D4-0000-1111-2222-333344445555",
            "SystemBUID": "B5C6D7E8-0000-1111-2222-333344445555",
            "HostPrivateKey": Data([0x01, 0x02, 0x03]),
            "HostCertificate": Data([0x04, 0x05]),
            "DeviceCertificate": Data([0x06, 0x07]),
            "RootCertificate": Data([0x08, 0x09])
        ]
    }

    private func data(_ record: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
    }

    // MARK: - Inspector

    @Test("No file is absent, not unreadable")
    func testMissingFileIsAbsent() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
        #expect(PairingRecordInspector.inspect(fileAt: url) == .absent)
        #expect(PairingRecordInspector.inspect(fileAt: url).udid == nil)
    }

    @Test("A file that is not a property list is unreadable, not absent")
    func testGarbageIsUnreadable() {
        #expect(PairingRecordInspector.inspect(Data("not a plist".utf8)) == .unreadable)
        #expect(PairingRecordInspector.inspect(Data()) == .unreadable)
    }

    @Test("An oversized file is refused before parsing")
    func testOversizedIsRefused() {
        let oversized = Data(repeating: 0, count: PairingRecordInspector.maximumSize + 1)
        #expect(PairingRecordInspector.inspect(oversized) == .oversized)
    }

    @Test("Missing keys are named, sorted, and all of them")
    func testIncompleteNamesEveryMissingKey() throws {
        var partial = record()
        partial.removeValue(forKey: "HostPrivateKey")
        partial.removeValue(forKey: "SystemBUID")
        partial.removeValue(forKey: "HostCertificate")

        let state = PairingRecordInspector.inspect(try data(partial))
        #expect(state == .incomplete(["HostCertificate", "HostPrivateKey", "SystemBUID"]))
        #expect(state.udid == nil)
        #expect(state.isUsable == false)
    }

    @Test("An empty value counts as missing")
    func testEmptyValuesAreMissing() throws {
        var partial = record()
        partial["DeviceID"] = "   "
        partial["RootCertificate"] = Data()

        let state = PairingRecordInspector.inspect(try data(partial))
        #expect(state == .incomplete(["DeviceID", "RootCertificate"]))
    }

    @Test("A complete record is readable and its UDID is normalized")
    func testCompleteRecordIsReadable() throws {
        let state = PairingRecordInspector.inspect(try data(record(udid: " 00008120-001a2b3c4d5e6f70 ")))
        #expect(state == .readable(udid: "00008120-001A2B3C4D5E6F70"))
        #expect(state.isUsable)
        // Readable is not trusted; the sentence has to say so.
        #expect(state.detail.localizedCaseInsensitiveContains("not authorization"))
    }

    @Test("A key with an unexpected type is present, not missing")
    func testUnexpectedTypeIsNotMissing() {
        var unusual = record()
        unusual["HostID"] = 42
        let state = PairingRecordInspector.inspect(unusual)
        #expect(state == .readable(udid: "00008120-001A2B3C4D5E6F70"))
    }

    @Test("Normalization ignores case and surrounding whitespace")
    func testNormalize() {
        #expect(PairingRecordInspector.normalize(" abcd-ef01 ") == "ABCD-EF01")
    }

    // MARK: - Duplicate records

    @Test("Records for one device collapse, case-insensitively, with the newest evidence kept")
    func testDuplicateRecordsCollapse() {
        let first = self.record(udid: "00008120-001A2B3C4D5E6F70", name: "iPhone")
        let second = self.record(udid: "00008120-001a2b3c4d5e6f70", name: "Renamed iPhone")

        let unique = PairedDeviceRecord.unique([first, second])
        #expect(unique.count == 1)
        #expect(unique.first?.name == "Renamed iPhone")
        #expect(unique.first?.udid == "00008120-001A2B3C4D5E6F70")
    }

    @Test("Two devices keep the order they were first seen in")
    func testOrderIsFirstAppearance() {
        let a = record(udid: "AAAAAAAA-0000", name: "A")
        let b = record(udid: "BBBBBBBB-0000", name: "B")
        let aAgain = record(udid: "aaaaaaaa-0000", name: "A renamed")

        let unique = PairedDeviceRecord.unique([a, b, aAgain])
        #expect(unique.map(\.name) == ["A renamed", "B"])
    }

    // MARK: - Logs

    @Test("Log-safe identifiers never contain the whole UDID")
    func testLogSafeIdentifierIsRedacted() {
        let mac = self.record(udid: "00008120-001A2B3C4D5E6F70", name: "iPhone")
        #expect(!mac.logSafeIdentifier.contains("00008120"))
        #expect(mac.logSafeIdentifier.hasSuffix("6F70"))
        #expect(mac.logSafeIdentifier == "…6F70")

        let short = self.record(udid: "AB", name: "Odd")
        #expect(short.logSafeIdentifier == "…")
    }

    // MARK: - Capability resolver

    @Test("No pairing record means the user has to import one")
    func testNoPairingNeedsUserAction() {
        let report = DeviceCapabilityResolver.report(DeviceCapabilityContext())
        #expect(report.status(for: .pairedInstall) == .requiresUserAction)
        #expect(report.capability(for: .pairedInstall)?.detail.localizedCaseInsensitiveContains("pairing") == true)
    }

    @Test("An incomplete record says which part is missing")
    func testIncompleteRecordNamesTheGap() {
        let report = DeviceCapabilityResolver.report(
            DeviceCapabilityContext(pairing: .incomplete(["HostPrivateKey"]))
        )
        #expect(report.status(for: .pairedInstall) == .requiresUserAction)
        #expect(report.capability(for: .pairedInstall)?.detail.contains("HostPrivateKey") == true)
    }

    @Test("A complete record still needs the pairing session")
    func testReadableRecordNeedsTransport() {
        let context = DeviceCapabilityContext(pairing: .readable(udid: "AAAA"))
        let report = DeviceCapabilityResolver.report(context)
        #expect(report.status(for: .pairedInstall) == .requiresCompanion)

        var running = context
        running.pairingTransportAvailable = true
        #expect(DeviceCapabilityResolver.report(running).status(for: .pairedInstall) == .supported)
    }

    @Test("An unauthorized device is not a setup problem")
    func testUnauthorizedIsDistinct() {
        var context = DeviceCapabilityContext(pairing: .readable(udid: "AAAA"))
        context.presence = .unauthorized
        context.pairingTransportAvailable = true
        #expect(DeviceCapabilityResolver.report(context).status(for: .pairedInstall) == .requiresAuthorization)
    }

    @Test("An unsupported device is not a setup problem either")
    func testUnsupportedIsDistinct() {
        var context = DeviceCapabilityContext(pairing: .readable(udid: "AAAA"))
        context.presence = .unsupported
        context.pairingTransportAvailable = true
        #expect(DeviceCapabilityResolver.report(context).status(for: .pairedInstall) == .unsupported)
    }

    @Test("OTA needs the local server certificate; the pairing is irrelevant to it")
    func testOTACompanionRequirement() {
        var context = DeviceCapabilityContext()
        #expect(DeviceCapabilityResolver.report(context).status(for: .otaInstall) == .requiresCompanion)

        context.companionAvailable = true
        #expect(DeviceCapabilityResolver.report(context).status(for: .otaInstall) == .supported)
    }

    @Test("The inventory is a local probe, so it works with no pairing at all")
    func testInventoryNeedsNoPairing() {
        #expect(DeviceCapabilityResolver.report(DeviceCapabilityContext()).status(for: .inventoryRead) == .supported)
    }

    @Test("Uninstall needs exactly what a paired install needs")
    func testUninstallFollowsThePairingSession() {
        let ready = DeviceCapabilityResolver.report(
            DeviceCapabilityContext(pairing: .readable(udid: "AAAA"), pairingTransportAvailable: true)
        )
        #expect(ready.status(for: .uninstall) == ready.status(for: .pairedInstall))

        // Without the session it is not offered, and it names the same missing piece.
        for context in [
            DeviceCapabilityContext(),
            DeviceCapabilityContext(pairing: .readable(udid: "AAAA"), pairingTransportAvailable: false)
        ] {
            let report = DeviceCapabilityResolver.report(context)
            #expect(report.status(for: .uninstall) != .supported)
            #expect(report.status(for: .uninstall) == report.status(for: .pairedInstall))
            #expect(report.capability(for: .uninstall)?.detail == report.capability(for: .pairedInstall)?.detail)
        }
    }

    @Test("Every operation gets exactly one answer")
    func testEveryOperationIsAnsweredOnce() {
        let report = DeviceCapabilityResolver.report(DeviceCapabilityContext())
        #expect(report.capabilities.count == DeviceOperation.allCases.count)
        #expect(Set(report.capabilities.map(\.operation)) == Set(DeviceOperation.allCases))
        #expect(DeviceOperation.allCases.allSatisfy { report.capability(for: $0) != nil })
    }

    @Test("Capability log lines are deterministic and carry no identifier")
    func testLogLinesAreSafe() {
        let report = DeviceCapabilityResolver.report(
            DeviceCapabilityContext(pairing: .readable(udid: "00008120-001A2B3C4D5E6F70"))
        )
        #expect(report.logLines.count == DeviceOperation.allCases.count)
        #expect(report.logLines == report.logLines)
        #expect(report.logLines.allSatisfy { !$0.contains("00008120") })
        #expect(report.logLines.allSatisfy { $0.hasPrefix("Device capability (") })
    }

    // MARK: - Install preflight integration

    @Test("Install preflight distinguishes a missing record from a broken one")
    func testPreflightDistinguishesBrokenRecords() {
        let missing = InstallPreflight.readiness(
            for: .idevice,
            InstallPreflightInputs(pairing: .absent)
        )
        guard case .missing(let missingMessage) = missing else {
            return Issue.record("A missing record is not setup-complete")
        }
        #expect(missingMessage.localizedCaseInsensitiveContains("no pairing file"))

        let broken = InstallPreflight.readiness(
            for: .idevice,
            InstallPreflightInputs(pairing: .incomplete(["HostPrivateKey"]))
        )
        guard case .missing(let brokenMessage) = broken else {
            return Issue.record("A record that cannot carry a session is not 'unknown'")
        }
        #expect(brokenMessage.contains("HostPrivateKey"))

        let usable = InstallPreflight.readiness(
            for: .idevice,
            InstallPreflightInputs(pairing: .readable(udid: "AAAA"))
        )
        guard case .unknown = usable else {
            return Issue.record("A readable record still has to prove trust at connect time")
        }
    }
}

// MARK: - Helpers

private extension DeviceConnectivityTests {
    /// A record value derived from the same inspector the app uses, so the fixture cannot drift
    /// from the model it feeds.
    func record(udid: String, name: String) -> PairedDeviceRecord {
        let pairing = DevicePairingState.readable(udid: PairingRecordInspector.normalize(udid))
        return PairedDeviceRecord(
            udid: pairing.udid ?? udid,
            name: name,
            deviceType: "iPhone",
            iosVersion: "17.2",
            presence: .discovered,
            pairing: pairing,
            trust: .unverified
        )
    }
}
