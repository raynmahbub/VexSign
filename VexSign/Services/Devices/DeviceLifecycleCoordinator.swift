// MARK: - Device lifecycle operations
//
// Install, reinstall, update and remove are sequences over existing owners: the library
// installation adapter submits the signed artifact, the paired inventory service reads the
// device back, and DeviceAppRemoval owns the guarded uninstall path. A command acknowledgement
// is never promoted to an installed-app result.

import Foundation
import IDeviceSwift
import NimbleExtensions

enum DeviceLifecycleAction: String, Sendable {
    case install, reinstall, update, remove
}

enum DeviceLifecycleOutcome: String, Sendable {
    case submitted
    case installed
    case removalRequested
    case removed
    case stillInstalled
    case outcomeUnknown
    case refused
    case cancelled

    var title: String {
        switch self {
        case .submitted: String.localized("Submitted, not confirmed")
        case .installed: String.localized("Confirmed installed")
        case .removalRequested: String.localized("Removal requested")
        case .removed: String.localized("Confirmed removed")
        case .stillInstalled: String.localized("Still installed")
        case .outcomeUnknown: String.localized("Outcome unknown")
        case .refused: String.localized("Not attempted")
        case .cancelled: String.localized("Cancelled")
        }
    }
}

struct DeviceLifecycleResult: Equatable, Sendable, Identifiable {
    let id: String
    let action: DeviceLifecycleAction
    let deviceID: String
    let bundleIdentifier: String
    let outcome: DeviceLifecycleOutcome
    let message: String
    let at: Date

    init(action: DeviceLifecycleAction, deviceID: String, bundleIdentifier: String,
         outcome: DeviceLifecycleOutcome, message: String, at: Date = Date()) {
        self.id = UUID().uuidString
        self.action = action
        self.deviceID = deviceID
        self.bundleIdentifier = bundleIdentifier
        self.outcome = outcome
        self.message = message
        self.at = at
    }
}

struct DeviceLifecycleTarget: Equatable, Sendable {
    let deviceID: String
    let reference: LibraryAppReference
    let bundleIdentifier: String
    let version: String
    let build: String?
    let certificateExpiry: Date?
    let authorizedRemoval: Bool

    init(deviceID: String, reference: LibraryAppReference, bundleIdentifier: String, version: String,
         build: String? = nil, certificateExpiry: Date? = nil, authorizedRemoval: Bool = false) {
        self.deviceID = deviceID
        self.reference = reference
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.certificateExpiry = certificateExpiry
        self.authorizedRemoval = authorizedRemoval
    }
}

@MainActor
protocol DeviceApplicationSubmitting: AnyObject {
    func submit(_ reference: LibraryAppReference, exporting: Bool) throws -> LibraryInstallationSubmission
}

@MainActor
final class PairedDeviceApplicationInstaller: DeviceApplicationSubmitting {
    private let installation: any LibraryInstallationProviding

    init(installation: any LibraryInstallationProviding) {
        self.installation = installation
    }

    func submit(_ reference: LibraryAppReference, exporting: Bool) throws -> LibraryInstallationSubmission {
        try installation.enqueueLibraryApp(reference, exporting: exporting)
    }
}

@MainActor
protocol DeviceApplicationRemoving: AnyObject {
    func remove(bundleIdentifier: String) async -> DeviceAppRemoval.Outcome
}

@MainActor
final class PairedDeviceApplicationRemover: DeviceApplicationRemoving {
    func remove(bundleIdentifier: String) async -> DeviceAppRemoval.Outcome {
        await DeviceAppRemoval.remove(bundleIdentifier: bundleIdentifier,
                                      uninstaller: PairedDeviceUninstaller())
    }
}

@MainActor
final class DeviceLifecycleCoordinator {
    private let registry: DeviceRegistryService
    private let inventory: DeviceInventoryService
    private let installer: any DeviceApplicationSubmitting
    private let remover: any DeviceApplicationRemoving
    private let reporter: DeviceLifecycleTaskReporter

    init(registry: DeviceRegistryService,
         inventory: DeviceInventoryService,
         installer: any DeviceApplicationSubmitting,
         remover: any DeviceApplicationRemoving,
         reporter: DeviceLifecycleTaskReporter) {
        self.registry = registry
        self.inventory = inventory
        self.installer = installer
        self.remover = remover
        self.reporter = reporter
    }

    /// Submits the selected, already-signed library artifact. Installation is confirmed only
    /// when a fresh, same-device reading reports the exact bundle and version afterwards.
    @discardableResult
    func install(_ target: DeviceLifecycleTarget, action: DeviceLifecycleAction) async throws -> DeviceLifecycleResult {
        guard action != .remove else { return try await remove(target) }
        guard DeviceApplicationInventory.isBundleIdentifier(target.bundleIdentifier) else {
            throw DeviceLifecycleError.invalidIdentifier
        }
        let device = try await registry.devices().first { $0.id == target.deviceID }
        guard let device else { throw DeviceLifecycleError.deviceRequired }
        guard device.supportsInstallation else {
            throw DeviceLifecycleError.operationBlocked(
                String.localized("This device has no admitted installation route. The signed IPA can be exported instead.")
            )
        }
        if action == .reinstall || action == .update {
            guard let snapshot = try await inventory.latestSnapshot(deviceID: target.deviceID),
                  let installed = snapshot.application(bundleIdentifier: target.bundleIdentifier) else {
                throw DeviceLifecycleError.operationBlocked(
                    String.localized("Refresh inventory before replacing an installed app. Its current bundle identity must be confirmed.")
                )
            }
            guard installed.bundleIdentifier == target.bundleIdentifier else {
                throw DeviceLifecycleError.operationBlocked(
                    String.localized("The installed bundle identifier differs from the selected library app. Nothing was replaced.")
                )
            }
            if action == .update, let installedVersion = installed.version,
               VersionOrder.precedence(target.version, installedVersion) != .orderedDescending {
                throw DeviceLifecycleError.invalidUpdate(
                    String.localized("The selected version is not newer than the installed version. No downgrade or reinstall was submitted.")
                )
            }
        }
        if let expiry = target.certificateExpiry, expiry <= Date() {
            throw DeviceLifecycleError.operationBlocked(
                String.localized("The certificate or provisioning authorization is expired or revoked. Use a valid identity before installing.")
            )
        }

        let subject = "device-lifecycle." + target.deviceID + "." + target.bundleIdentifier
        let title = action == .install ? "Install on device" : (action == .update ? "Update on device" : "Reinstall on device")
        guard let taskID = await reporter.beginOnce(kind: .install, title: String.localized(title),
                                                    subtitle: target.bundleIdentifier, subjectID: subject)
        else { throw DeviceLifecycleError.operationBlocked(
            String.localized("An operation for this app and device is already running.")
        ) }
        do {
            await reporter.transition(id: taskID, to: .preparingInstallation)
            try Task.checkCancellation()
            let submission = try installer.submit(target.reference, exporting: false)
            await reporter.transition(id: taskID, to: .waitingForIOS)
            let submittedAt = Date()

            // The queue has acknowledged the request. It has not installed the app.
            guard submission == .submittedForInstallation else {
                let message = submission == .submittedForGuestImport
                    ? String.localized("The app was staged for an embedded host import. This is not an iOS device installation.")
                    : String.localized("The request was prepared for export. No device installation was attempted.")
                await reporter.transition(id: taskID, to: .completed)
                return DeviceLifecycleResult(action: action, deviceID: target.deviceID,
                    bundleIdentifier: target.bundleIdentifier, outcome: .submitted, message: message, at: submittedAt)
            }

            var outcome = DeviceLifecycleOutcome.submitted
            var message = String.localized("The device service accepted the request. Installation has not been confirmed; refresh inventory before retrying.")
            do {
                try await inventory.refresh(deviceID: target.deviceID,
                                            wantedBundleIdentifiers: [target.bundleIdentifier])
                await reporter.transition(id: taskID, to: .verifying)
                if let snapshot = try await inventory.latestSnapshot(deviceID: target.deviceID),
                   let installed = snapshot.application(bundleIdentifier: target.bundleIdentifier),
                   installed.version == target.version,
                   target.build.map({ $0 == installed.build }) ?? true,
                   installed.observedAt >= submittedAt {
                    outcome = .installed
                    message = String.localized("The device reported the exact bundle and version after the request.")
                }
            } catch {
                message = String.localized("The request was accepted, but a same-device confirmation could not be read. Check the Home Screen before retrying.")
            }
            await reporter.transition(id: taskID,
                to: outcome == .installed ? .completed : .unconfirmed)
            return DeviceLifecycleResult(action: action, deviceID: target.deviceID,
                                         bundleIdentifier: target.bundleIdentifier,
                                         outcome: outcome, message: message)
        } catch {
            let cancelled = error is CancellationError || error as? DeviceTransportError == .operationCancelled
            await reporter.transition(id: taskID, to: cancelled ? .cancelled : .failed,
                                      error: error.localizedDescription)
            do { try await registry.recordFailure(deviceID: target.deviceID, error: error) }
            catch { /* Preserve the original operation error for the caller. */ }
            throw error
        }
    }

    @discardableResult
    func remove(_ target: DeviceLifecycleTarget) async throws -> DeviceLifecycleResult {
        guard DeviceApplicationInventory.isBundleIdentifier(target.bundleIdentifier) else {
            throw DeviceLifecycleError.invalidIdentifier
        }
        guard target.authorizedRemoval else {
            throw DeviceLifecycleError.operationBlocked(
                String.localized("Removal requires explicit confirmation for this exact bundle identifier.")
            )
        }
        let device = try await registry.devices().first { $0.id == target.deviceID }
        guard let device, device.supportsRemoval else {
            throw DeviceLifecycleError.operationBlocked(
                String.localized("This device does not expose a supported removal interface. Delete the app from its Home Screen instead.")
            )
        }
        let subject = "device-removal." + target.deviceID + "." + target.bundleIdentifier
        guard let taskID = await reporter.beginOnce(kind: .deviceSetup, title: String.localized("Remove app from device"),
                                                    subtitle: target.bundleIdentifier, subjectID: subject)
        else { throw DeviceLifecycleError.operationBlocked(
            String.localized("A removal for this app is already running.")
        ) }
        do {
            await reporter.transition(id: taskID, to: .queryingDevice)
            let native = await remover.remove(bundleIdentifier: target.bundleIdentifier)
            try Task.checkCancellation()
            var outcome: DeviceLifecycleOutcome
            switch native {
            case .removed: outcome = .removed
            case .requested: outcome = .removalRequested
            case .outcomeUnknown: outcome = .outcomeUnknown
            case .stillInstalled: outcome = .stillInstalled
            case .refused, .failed: outcome = .refused
            }
            if case .failed(let reason) = native {
                try await registry.recordFailure(deviceID: target.deviceID,
                                                 error: DeviceLifecycleError.operationBlocked(reason))
            }
            await reporter.transition(id: taskID, to: .completed)
            return DeviceLifecycleResult(action: .remove, deviceID: target.deviceID,
                                         bundleIdentifier: target.bundleIdentifier,
                                         outcome: outcome, message: native.message)
        } catch {
            let cancelled = error is CancellationError
            await reporter.transition(id: taskID, to: cancelled ? .cancelled : .failed,
                                      error: error.localizedDescription)
            throw error
        }
    }
}
