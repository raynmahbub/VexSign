// Paired-installation journey.
//
// This is a pure evidence ledger over the EXISTING owners: PairingBridge,
// InstallPreflight, PairedInstallationValidation, InstallQueue, InstallConfirmation
// and the installed-app inventory. It does not pair, sign, submit or install
// anything, and it is not a second installation coordinator.
//
// Its only job is to keep the four outcomes separate:
//   1. the route and pairing record were admitted,
//   2. the exact signed artifact was validated,
//   3. an installation request was accepted,
//   4. the exact app was confirmed on the selected device and then launched.
// A navigation callback, a command acknowledgement or a different app version
// cannot complete a later step.

import Foundation
import IDeviceSwift
import NimbleExtensions

enum PairedInstallationStep: String, CaseIterable, Equatable, Hashable, Sendable {
    case route
    case pairing
    case device
    case artifact
    case signature
    case submission
    case confirmation
    case launch

    var title: String {
        switch self {
        case .route: return .localized("Check the paired route")
        case .pairing: return .localized("Verify the pairing record")
        case .device: return .localized("Verify the selected device")
        case .artifact: return .localized("Choose the exact IPA")
        case .signature: return .localized("Validate the signed bundle")
        case .submission: return .localized("Submit the install request")
        case .confirmation: return .localized("Confirm the installed app")
        case .launch: return .localized("Open the installed app")
        }
    }
}

enum PairedInstallationRejection: Error, Equatable, CaseIterable, LocalizedError, Sendable {
    case outOfOrder
    case routeBlocked
    case invalidFingerprint
    case wrongPairingFormat
    case pairingMismatch
    case invalidDeviceIdentifier
    case wrongDevice
    case invalidArtifact
    case artifactMismatch
    case invalidSigner
    case expiredAuthorization
    case submissionMismatch
    case confirmationBeforeSubmission
    case invalidReceipt
    case launchMismatch

    var errorDescription: String? {
        switch self {
        case .outOfOrder:
            return .localized("This paired-installation step is out of order. Finish the current step first.")
        case .routeBlocked:
            return .localized("This pairing route is not admitted for installation, or the installation bridge has not been accepted. No package was submitted.")
        case .invalidFingerprint:
            return .localized("The pairing fingerprint is not a SHA-256 digest. No device was trusted.")
        case .wrongPairingFormat:
            return .localized("The pairing record format does not match the admitted route. No device was trusted.")
        case .pairingMismatch:
            return .localized("The device query used a different pairing record. No device was trusted.")
        case .invalidDeviceIdentifier:
            return .localized("The device identifier is not a valid iPhone UDID. No device was trusted.")
        case .wrongDevice:
            return .localized("The device that answered is not the selected device. No device was trusted.")
        case .invalidArtifact:
            return .localized("The IPA metadata or checksum is incomplete. No package was submitted.")
        case .artifactMismatch:
            return .localized("The signed, submitted or installed app is not the exact selected artifact.")
        case .invalidSigner:
            return .localized("The signing identity fingerprint is not a SHA-256 digest.")
        case .expiredAuthorization:
            return .localized("The profile or signer authorization had already expired. No package was submitted.")
        case .submissionMismatch:
            return .localized("The install receipt does not describe the validated artifact and selected device.")
        case .confirmationBeforeSubmission:
            return .localized("Installed-app evidence was recorded before a submission receipt. It cannot confirm this attempt.")
        case .invalidReceipt:
            return .localized("There is no bounded receipt for this attempt. The outcome stays unconfirmed.")
        case .launchMismatch:
            return .localized("The launched app is not the exact confirmed bundle and version.")
        }
    }
}

struct PairedInstallationEvidence: Equatable, Sendable {
    var route: DevicePairingRoute?
    var pairingFormat: PairingRecordFormat?
    var pairingFingerprint: String?
    var deviceIdentifier: String?
    var deviceOS: String?
    var bundleIdentifier: String?
    var version: String?
    var build: String?
    var artifactSHA256: String?
    var signerFingerprint: String?
    var authorizationExpiresAt: Date?
    var submissionReceipt: String?
    var submissionAt: Date?
    var confirmationReceipt: String?
    var confirmationAt: Date?
}

enum PairedInstallationEvent: Equatable, Sendable {
    /// `inventoryAccepted` is `InstallationAppProxy.hasAcceptedInventoryBridge` from the
    /// build being tested. Until a real device pass accepts it, this event is rejected.
    case route(DevicePairingRoute, inventoryAccepted: Bool)
    case pairing(format: PairingRecordFormat, fingerprint: String)
    case device(identifier: String, productVersion: String, pairingFingerprint: String)
    case artifact(bundleIdentifier: String, version: String, build: String, sha256: String)
    case signature(bundleIdentifier: String, signerFingerprint: String, sha256: String,
                   authorizationExpiresAt: Date, at: Date)
    /// Acknowledgement only. It never fills `.confirmation` or `.launch`.
    case submission(bundleIdentifier: String, sha256: String, receipt: String, at: Date)
    /// Must carry a positive, exact, same-device installed-app reading from
    /// `InstallConfirmation`; a private negative or a different version is not this event.
    case confirmation(bundleIdentifier: String, version: String, build: String, sha256: String,
                      receipt: String, at: Date)
    /// A person opened the installed app. Installation evidence alone is not this event.
    case launch(bundleIdentifier: String, version: String)
}

struct PairedInstallationJourney: Equatable, Sendable {
    let expectedDeviceIdentifier: String?

    private(set) var completed: Set<PairedInstallationStep> = []
    private(set) var evidence = PairedInstallationEvidence()
    private(set) var lastRejection: PairedInstallationRejection?
    /// Fixed step names only. No UDID, fingerprint, PIN, receipt or path is logged here.
    private(set) var eventLog: [String] = []

    init(expectedDeviceIdentifier: String? = nil) {
        self.expectedDeviceIdentifier = expectedDeviceIdentifier
    }

    var nextStep: PairedInstallationStep? {
        PairedInstallationStep.allCases.first { !completed.contains($0) }
    }

    var isComplete: Bool { completed.count == PairedInstallationStep.allCases.count }

    /// True once a command acknowledgement exists, even when the app was never
    /// confirmed. Kept separate so a UI can say "submitted, unconfirmed".
    var hasSubmission: Bool { completed.contains(.submission) }

    /// True only after an exact installed-app reading, never after a submission.
    var hasConfirmedInstallation: Bool { completed.contains(.confirmation) }

    mutating func reset() {
        completed = []
        evidence = PairedInstallationEvidence()
        lastRejection = nil
        eventLog = []
    }

    @discardableResult
    mutating func record(_ event: PairedInstallationEvent) -> Result<PairedInstallationStep, PairedInstallationRejection> {
        guard event.step == nextStep else { return reject(.outOfOrder) }
        do {
            try apply(event)
            completed.insert(event.step)
            eventLog.append(event.step.rawValue)
            lastRejection = nil
            return .success(event.step)
        } catch let reason as PairedInstallationRejection {
            return reject(reason)
        } catch {
            return reject(.outOfOrder)
        }
    }

    private mutating func reject(_ reason: PairedInstallationRejection) -> Result<PairedInstallationStep, PairedInstallationRejection> {
        lastRejection = reason
        return .failure(reason)
    }

    private mutating func apply(_ event: PairedInstallationEvent) throws {
        switch event {
        case .route(let route, let inventoryAccepted):
            guard inventoryAccepted,
                  (route == .importedClassic || route == .onDeviceHostPairing) else {
                throw PairedInstallationRejection.routeBlocked
            }
            evidence.route = route

        case .pairing(let format, let fingerprint):
            guard Self.isDigest(fingerprint) else { throw PairedInstallationRejection.invalidFingerprint }
            guard let route = evidence.route else { throw PairedInstallationRejection.outOfOrder }
            switch route {
            case .onDeviceHostPairing:
                guard format.containsRemotePairing else { throw PairedInstallationRejection.wrongPairingFormat }
            case .importedClassic:
                guard format.containsLockdown else { throw PairedInstallationRejection.wrongPairingFormat }
            default:
                throw PairedInstallationRejection.routeBlocked
            }
            evidence.pairingFormat = format
            evidence.pairingFingerprint = fingerprint

        case .device(let identifier, let productVersion, let fingerprint):
            let normalized = PairingRecordDocument.normalizeDeviceIdentifier(identifier)
            guard PairingRecordDocument.isDeviceIdentifier(normalized) else {
                throw PairedInstallationRejection.invalidDeviceIdentifier
            }
            if let expected = expectedDeviceIdentifier,
               PairingRecordDocument.normalizeDeviceIdentifier(expected) != normalized {
                throw PairedInstallationRejection.wrongDevice
            }
            guard evidence.pairingFingerprint == fingerprint, !productVersion.isEmpty else {
                throw PairedInstallationRejection.pairingMismatch
            }
            evidence.deviceIdentifier = normalized
            evidence.deviceOS = productVersion

        case .artifact(let identifier, let version, let build, let digest):
            guard DeviceApplicationInventory.isBundleIdentifier(identifier),
                  DeviceApplicationInventory.isVersion(version),
                  DeviceApplicationInventory.isVersion(build),
                  Self.isDigest(digest) else { throw PairedInstallationRejection.invalidArtifact }
            evidence.bundleIdentifier = identifier
            evidence.version = version
            evidence.build = build
            evidence.artifactSHA256 = digest

        case .signature(let identifier, let signer, let digest, let expiry, let at):
            guard Self.isDigest(signer), identifier == evidence.bundleIdentifier,
                  digest == evidence.artifactSHA256 else { throw PairedInstallationRejection.artifactMismatch }
            guard expiry > at, at.timeIntervalSince1970.isFinite else {
                throw PairedInstallationRejection.expiredAuthorization
            }
            evidence.signerFingerprint = signer
            evidence.authorizationExpiresAt = expiry

        case .submission(let identifier, let digest, let receipt, let at):
            guard identifier == evidence.bundleIdentifier,
                  digest == evidence.artifactSHA256,
                  Self.isReceipt(receipt) else { throw PairedInstallationRejection.submissionMismatch }
            guard let expiry = evidence.authorizationExpiresAt, expiry > at else {
                throw PairedInstallationRejection.expiredAuthorization
            }
            evidence.submissionReceipt = receipt
            evidence.submissionAt = at

        case .confirmation(let identifier, let version, let build, let digest, let receipt, let at):
            guard identifier == evidence.bundleIdentifier, version == evidence.version,
                  build == evidence.build, digest == evidence.artifactSHA256 else {
                throw PairedInstallationRejection.artifactMismatch
            }
            guard let submittedAt = evidence.submissionAt, at >= submittedAt else {
                throw PairedInstallationRejection.confirmationBeforeSubmission
            }
            guard Self.isReceipt(receipt), receipt != evidence.submissionReceipt,
                  let expiry = evidence.authorizationExpiresAt, expiry > at else {
                throw PairedInstallationRejection.invalidReceipt
            }
            evidence.confirmationReceipt = receipt
            evidence.confirmationAt = at

        case .launch(let identifier, let version):
            guard identifier == evidence.bundleIdentifier, version == evidence.version else {
                throw PairedInstallationRejection.launchMismatch
            }
        }
    }

    private static func isDigest(_ raw: String) -> Bool {
        raw.utf8.count == 64 && raw.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isReceipt(_ raw: String) -> Bool {
        let count = raw.utf8.count
        return count >= 4 && count <= 128 && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension PairedInstallationEvent {
    var step: PairedInstallationStep {
        switch self {
        case .route: return .route
        case .pairing: return .pairing
        case .device: return .device
        case .artifact: return .artifact
        case .signature: return .signature
        case .submission: return .submission
        case .confirmation: return .confirmation
        case .launch: return .launch
        }
    }
}
