// Presentation state for the EXISTING PairingBridge/native/storage owners.
// Does not sign, provision, install, host RPPairing, or own a second transport.
import Foundation
import Combine
import IDeviceSwift
import NimbleExtensions

@MainActor
final class DeviceBootstrapModel: ObservableObject {
    @Published private(set) var pairing: DevicePairingState = .absent
    @Published private(set) var fingerprint: String?
    @Published private(set) var formatTitle = ""
    @Published private(set) var isWorking = false
    @Published private(set) var isQuerying = false
    @Published private(set) var message: String?
    @Published private(set) var stageTitle: String?
    @Published private(set) var verifiedDeviceSummary: String?
    @Published private(set) var inventorySummary: String?
    @Published var inventoryBundleIdentifier = Bundle.main.bundleIdentifier ?? "" {
        didSet { if inventoryBundleIdentifier != oldValue { cancelQuery(); inventorySummary = nil } }
    }
    @Published var expectedIdentifier = "" {
        didSet { if expectedIdentifier != oldValue { cancelQuery(); PairingBridge.invalidateSelectedDevice(); verifiedDeviceSummary = nil; inventorySummary = nil } }
    }
    @Published var peerAddress = PairingBridge.peerAddress {
        didSet { if peerAddress != oldValue { cancelQuery(); PairingBridge.invalidateSelectedDevice(); verifiedDeviceSummary = nil; inventorySummary = nil } }
    }
    @Published var consent = PairingBridge.protocolConsent {
        didSet {
            PairingBridge.protocolConsent = consent
            verifiedDeviceSummary = nil
            inventorySummary = nil
            if !consent { cancelQuery() }
        }
    }

    private var operation: Task<Void, Never>?
    private var taskRecord: UnifiedTask?
    private var format: PairingRecordFormat?

    var routeTitle: String { PairingBridge.routeTitle }
    var routeDetail: String { PairingBridge.routeDetail }
    var installationLimitation: String { PairingBridge.pairedInstallationLimitation }
    var hasReviewedRecord: Bool { fingerprint != nil }
    var canImport: Bool { !isWorking && (pairing == .absent || fingerprint != nil) }
    var canVerify: Bool {
        !isWorking && consent && PairingBridge.canQuery(pairing, expectedIdentifier: expectedIdentifier)
    }
    var canReadApplication: Bool { canVerify && fingerprint != nil && DeviceApplicationInventory.isBundleIdentifier(inventoryBundleIdentifier) }
    var mayQueryThisRoute: Bool { PairingBridge.route == .importedClassic && format?.containsLockdown == true }
    var isTransportRetiring: Bool { !isWorking && PairingBridge.isBusy }

    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        stageTitle = UnifiedTaskPhase.inspectingPairing.title
        defer { isWorking = false; stageTitle = nil }
        verifiedDeviceSummary = nil // Never turn yesterday's handshake into a live capability.
        inventorySummary = nil
        message = nil
        do { try await reloadRecord() }
        catch {
            pairing = .unreadable
            fingerprint = nil
            format = nil
            formatTitle = .localized("Pairing storage unavailable")
            expectedIdentifier = ""
            message = safeDescription(error)
        }
    }

    private func reloadRecord() async throws {
        let current = try await PairingBridge.reviewRecord()
        let changed = fingerprint != current.fingerprint
        if changed { PairingBridge.invalidateSelectedDevice() }
        pairing = current.state
        fingerprint = current.fingerprint
        format = current.format
        switch current.format {
        case .lockdown: formatTitle = .localized("Classic lockdown · unversioned")
        case .remotePairing: formatTitle = .localized("Remote Pairing · unversioned")
        case .combined: formatTitle = .localized("Combined classic / Remote Pairing · unversioned")
        case nil: formatTitle = .localized("No recognized pairing format")
        }
        if changed || expectedIdentifier.isEmpty { expectedIdentifier = current.deviceIdentifier ?? "" }
    }

    func importRecord(from url: URL, replacing reviewedFingerprint: String?) {
        perform(title: .localized("Import pairing record"), reason: "pairing-record-imported") {
            try await PairingBridge.importRecord(from: url, replacing: reviewedFingerprint)
            try await self.reloadRecord()
            self.message = .localized("Pairing record stored securely. Its format is recognized, but device trust and transport have not been verified. No connection or installation was started.")
        }
    }

    func deleteRecord(reviewedFingerprint: String) {
        perform(title: .localized("Delete pairing record"), reason: "pairing-record-deleted") {
            try await PairingBridge.deleteRecord(fingerprint: reviewedFingerprint)
            try await self.reloadRecord()
            self.expectedIdentifier = ""
            self.message = .localized("The reviewed local pairing record was deleted. This does not revoke trust on the device or remove copies you exported elsewhere.")
        }
    }

    /// The system picker asks the user for a destination. Preparing a file or
    /// dismissing that picker is NOT a companion acknowledgement/received receipt.
    func exportRecord(reviewedFingerprint: String, present: @escaping (URL) -> Void) {
        perform(title: .localized("Prepare pairing export"), reason: "pairing-export-prepared-not-received") {
            let file = try await PairingBridge.prepareExport(fingerprint: reviewedFingerprint)
            if Task.isCancelled {
                PairingBridge.discardExport(at: file)
                throw CancellationError()
            }
            self.message = .localized("Choose an explicit export destination. This exact-byte pairing plist contains private credentials. The destination has not been verified as a compatible companion, and no receipt is claimed.")
            present(file)
        }
    }

    func finishExport(at url: URL) {
        PairingBridge.discardExport(at: url)
        message = .localized("The export picker closed. Temporary-file cleanup was requested; protected recovery cleanup also runs on the next launch. No companion receipt or destination compatibility was verified.")
    }

    func verifyDevice() {
        guard consent else { message = DeviceTransportError.consentRequired.localizedDescription; return }
        guard PairingBridge.canQuery(pairing, expectedIdentifier: expectedIdentifier) else {
            message = .localized("This route cannot be queried in this build. Review the OS and record requirements, and select the intended device UDID. Simulators cannot establish device trust.")
            return
        }
        let intendedDevice = expectedIdentifier
        let reviewedFingerprint = fingerprint
        let selectedPeer = peerAddress
        perform(title: .localized("Verify paired device"), reason: "fresh-device-query-not-installation", querying: true) {
            PairingBridge.peerAddress = selectedPeer
            let recordID = self.taskRecord?.id
            let evidence = try await PairingBridge.queryDevice(expectedIdentifier: intendedDevice, fingerprint: reviewedFingerprint) { [weak self] stage in
                Task { @MainActor [weak self] in self?.report(stage, for: recordID) }
            }
            try Task.checkCancellation()
            self.verifiedDeviceSummary = evidence.productType + " · iOS " + evidence.productVersion + " (" + evidence.buildVersion + ")"
            self.message = .localized("The selected device answered this fresh identity and service query. The session is now closed and this target selection is remembered only for this process. Future attempts recheck the record and device. This is not Developer Mode verification, installation support, a signing result, or a live connection.")
        }
    }

    func readInstalledApplication() {
        guard canReadApplication, let fingerprint else { return }
        let intendedDevice = expectedIdentifier
        let identifier = inventoryBundleIdentifier
        let selectedPeer = peerAddress
        perform(title: .localized("Read installed app metadata"), reason: "fresh-app-inventory-not-installation", querying: true) {
            PairingBridge.peerAddress = selectedPeer
            let recordID = self.taskRecord?.id
            let application = try await PairingBridge.queryInstalledApplication(identifier,
                expectedDevice: intendedDevice, fingerprint: fingerprint) { [weak self] stage in
                    Task { @MainActor [weak self] in self?.report(stage, for: recordID) }
                }
            try Task.checkCancellation()
            if let application, let version = application.version, let build = application.build {
                // Presence on the already selected target may refresh a Library
                // badge, but never completes a task or increments install analytics.
                LibraryStatusStore.shared.recordInstalledApplicationObservation(InstalledApp(application: application))
                self.inventorySummary = .localized("Device reports version %@ · build %@", arguments: version, build)
                self.message = .localized("This fresh read-only result came from CoreDevice App Service on the selected device and record. It does not prove that VexSign installed the app, verify its signature, or authorize installation or removal.")
            } else {
                self.inventorySummary = nil
                self.message = .localized("The device returned no matching app with comparable version and build metadata. This is unknown evidence, not proof that the app is absent. No installation or removal was attempted.")
            }
        }
    }

    func cancelQuery() {
        guard isQuerying else { return }
        operation?.cancel()
        verifiedDeviceSummary = nil
        inventorySummary = nil
    }

    func leaveScreen() { cancelQuery(); verifiedDeviceSummary = nil; inventorySummary = nil }

    private func perform(title: String, reason: String, querying: Bool = false,
                         work: @escaping () async throws -> Void) {
        let center = UnifiedTaskCenter.shared
        guard !isWorking,
              TaskSubmissionPolicy.inFlight(kind: .deviceSetup, subjectID: "device-bootstrap", in: center.tasks) == nil else { return }
        let record = center.begin(kind: .deviceSetup, title: title, progress: -1, subjectID: "device-bootstrap")
        taskRecord = record
        isWorking = true
        isQuerying = querying
        verifiedDeviceSummary = nil
        inventorySummary = nil
        message = nil
        stageTitle = UnifiedTaskPhase.inspectingPairing.title
        center.transition(record, to: .inspectingPairing, progress: -1)
        operation = Task {
            defer { self.operation = nil; self.isWorking = false; self.isQuerying = false; self.stageTitle = nil }
            do {
                try await work()
                record.context?.confirmationReason = reason
                // A very fast synthetic/native response can outrun queued UI stage
                // callbacks. Fill in the actual query's reached stages, not fake %s.
                if querying {
                    for phase in [UnifiedTaskPhase.checkingTransport, .discoveringServices, .queryingDevice] {
                        if Self.rank(record.phase) < Self.rank(phase) { center.transition(record, to: phase, progress: -1) }
                    }
                }
                center.transition(record, to: .completed)
            } catch {
                self.verifiedDeviceSummary = nil
                let cancelled = error is CancellationError || (error as? DeviceTransportError) == .operationCancelled
                self.message = self.safeDescription(error)
                record.context?.recordFailure(error)
                center.transition(record, to: cancelled ? .cancelled : .failed, error: self.message)
                // Only a read-only query is retryable without another destructive
                // approval or a newly chosen security-scoped input/destination.
                // Retain the read-only flow until its retry/history record is removed.
                // A weak, deallocated screen model must not leave a no-op Retry button.
                if querying {
                    center.registerRetry(record) {
                        if reason == "fresh-app-inventory-not-installation" { self.readInstalledApplication() }
                        else { self.verifyDevice() }
                    }
                }
            }
        }
    }

    private func report(_ stage: DeviceConnectionStage, for recordID: String?) {
        guard let record = taskRecord, record.id == recordID, !record.phase.isTerminal else { return }
        let phase: UnifiedTaskPhase
        switch stage {
        case .inspectingRecord: phase = .inspectingPairing
        case .checkingTransport: phase = .checkingTransport
        case .openingTunnel, .discoveringServices: phase = .discoveringServices
        case .queryingDevice, .authorized: phase = .queryingDevice
        case .disconnecting: return // Never regress a task while scoped cleanup runs.
        }
        guard Self.rank(phase) >= Self.rank(record.phase) else { return }
        stageTitle = phase.title
        UnifiedTaskCenter.shared.transition(record, to: phase, progress: -1)
    }

    private static func rank(_ phase: UnifiedTaskPhase) -> Int {
        switch phase {
        case .inspectingPairing: return 1
        case .checkingTransport: return 2
        case .discoveringServices: return 3
        case .queryingDevice: return 4
        default: return 0
        }
    }

    private func safeDescription(_ error: Error) -> String {
        if let error = error as? DeviceTransportError { return error.localizedDescription }
        if let error = error as? PairingRecordError { return error.localizedDescription }
        if error is CancellationError { return DeviceTransportError.operationCancelled.localizedDescription }
        return .localized("Pairing storage could not complete this action. Unlock the device and review the current record before retrying. No device success is claimed.")
    }
}
