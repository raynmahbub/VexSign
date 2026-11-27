// Computer-free bootstrap journey.
//
// This is a pure state machine over evidence produced by the EXISTING owners
// (PairingHostBridge / PairingBridge / account flow / signing pipeline /
// InstallQueue). It does not pair, sign, install, or contact Apple. Its job is to
// make the guided bootstrap refuse a step when the evidence for the previous
// step is missing or inconsistent, so a screen transition can never be reported
// as a device result.

import Foundation
import IDeviceSwift
import NimbleExtensions

// MARK: - Capability

enum BootstrapRoute: String, Equatable, Hashable, Sendable {
    case onDeviceHost
    case pairingFileImport
    case unavailable

    var isComputerFree: Bool { self == .onDeviceHost }

    var title: String {
        switch self {
        case .onDeviceHost: return .localized("On-device pairing (no computer)")
        case .pairingFileImport: return .localized("Pairing file required")
        case .unavailable: return .localized("No supported bootstrap route")
        }
    }
}

enum BootstrapBlocker: String, Equatable, Hashable, Sendable {
    case simulator
    case unsupportedOS
    case hostUnavailable
    case pairingFileRequired
    case installationBridgePending

    var detail: String {
        switch self {
        case .simulator:
            return .localized("A simulator cannot pair with an iPhone or confirm an installation.")
        case .unsupportedOS:
            return .localized("This iOS version is outside the reviewed bootstrap compatibility matrix. Use an eligible external installer or export a signed IPA.")
        case .hostUnavailable:
            return .localized("The on-device RPPairing host is not available in this build. Do not substitute a pairing file for a host session.")
        case .pairingFileRequired:
            return .localized("This route needs an existing compatible pairing file. It is not a computer-free bootstrap.")
        case .installationBridgePending:
            return .localized("The paired installation inventory bridge has not been accepted. Pairing may proceed; installation stays gated.")
        }
    }
}

struct BootstrapCapability: Equatable, Sendable {
    let route: BootstrapRoute
    let osVersion: DeviceOSVersion
    let hostAvailable: Bool
    let isSimulator: Bool
    let pairedInstallationAccepted: Bool

    init(osVersion: DeviceOSVersion, hostAvailable: Bool, isSimulator: Bool,
         pairedInstallationAccepted: Bool) {
        self.osVersion = osVersion
        self.hostAvailable = hostAvailable
        self.isSimulator = isSimulator
        self.pairedInstallationAccepted = pairedInstallationAccepted
        if isSimulator {
            self.route = .unavailable
        } else {
            switch DevicePairingRoute.resolve(osVersion) {
            case .onDeviceHostPairing:
                self.route = hostAvailable ? .onDeviceHost : .unavailable
            case .importedClassic:
                self.route = .pairingFileImport
            case .unsupported, .unknownOS, .hostDependencyRequired, .importedRemoteRequired:
                self.route = .unavailable
            }
        }
    }

    var blockers: [BootstrapBlocker] {
        var found: [BootstrapBlocker] = []
        if isSimulator { found.append(.simulator) }
        switch DevicePairingRoute.resolve(osVersion) {
        case .unsupported, .unknownOS, .hostDependencyRequired, .importedRemoteRequired:
            found.append(.unsupportedOS)
        case .importedClassic:
            found.append(.pairingFileRequired)
        case .onDeviceHostPairing:
            if !hostAvailable { found.append(.hostUnavailable) }
        }
        if !pairedInstallationAccepted { found.append(.installationBridgePending) }
        return found
    }

    var canStartComputerFreePairing: Bool { !isSimulator && route == .onDeviceHost }
}

// MARK: - Steps and evidence

enum BootstrapStep: String, CaseIterable, Equatable, Hashable, Sendable {
    case environment
    case pairing
    case verification
    case account
    case artifact
    case signing
    case installation
    case confirmation

    var title: String {
        switch self {
        case .environment: return .localized("Check this iOS version")
        case .pairing: return .localized("Pair on this iPhone")
        case .verification: return .localized("Verify the selected device")
        case .account: return .localized("Authorize an account or certificate")
        case .artifact: return .localized("Choose the IPA to install")
        case .signing: return .localized("Sign and verify the IPA")
        case .installation: return .localized("Submit the installation")
        case .confirmation: return .localized("Confirm the installed app")
        }
    }
}

enum BootstrapAccountKind: String, Equatable, Hashable, Sendable {
    case appleAccountFree
    case appleAccountPaid
    case importedCertificate

    var title: String {
        switch self {
        case .appleAccountFree: return .localized("Free Apple Account")
        case .appleAccountPaid: return .localized("Paid developer account")
        case .importedCertificate: return .localized("Imported certificate")
        }
    }
}

struct BootstrapEvidence: Equatable, Sendable {
    var route: BootstrapRoute?
    var pairingFormat: PairingRecordFormat?
    var pairingFingerprint: String?
    var deviceIdentifier: String?
    var deviceOS: String?
    var accountKind: BootstrapAccountKind?
    var teamIdentifier: String?
    var bundleIdentifier: String?
    var version: String?
    var build: String?
    var artifactSHA256: String?
    var signerFingerprint: String?
    var installationSHA256: String?
    var receipt: String?
}

// MARK: - Events

enum BootstrapEvent: Equatable, Sendable {
    case environment(route: BootstrapRoute, simulator: Bool)
    case pairing(format: PairingRecordFormat, fingerprint: String)
    case verified(deviceIdentifier: String, productVersion: String, pairingFingerprint: String)
    case authorized(kind: BootstrapAccountKind, teamIdentifier: String)
    case artifact(bundleIdentifier: String, version: String, build: String, sha256: String)
    case signed(bundleIdentifier: String, signerFingerprint: String, sha256: String)
    case installationRequested(bundleIdentifier: String, sha256: String)
    /// `receipt` must name an existing installation task whose context passed
    /// `hasConfirmedInstallation(notAfter:)`. A UI completion callback, an OTA
    /// handoff or a private negative inventory answer is not this event.
    case installationConfirmed(bundleIdentifier: String, version: String, build: String,
                               sha256: String, receipt: String)

    var step: BootstrapStep {
        switch self {
        case .environment: return .environment
        case .pairing: return .pairing
        case .verified: return .verification
        case .authorized: return .account
        case .artifact: return .artifact
        case .signed: return .signing
        case .installationRequested: return .installation
        case .installationConfirmed: return .confirmation
        }
    }
}

enum BootstrapRejection: String, Error, Equatable, Hashable, LocalizedError, Sendable {
    case outOfOrder
    case unsupportedRoute
    case simulator
    case invalidFingerprint
    case wrongPairingFormat
    case pairingMismatch
    case invalidDeviceIdentifier
    case deviceMismatch
    case invalidTeamIdentifier
    case invalidArtifact
    case artifactMismatch
    case invalidSigner
    case invalidReceipt

    var errorDescription: String? {
        switch self {
        case .outOfOrder:
            return .localized("This bootstrap step is out of order. Finish the current step first.")
        case .unsupportedRoute:
            return .localized("This iOS version has no supported computer-free bootstrap route.")
        case .simulator:
            return .localized("A simulator cannot complete device bootstrap.")
        case .invalidFingerprint:
            return .localized("The pairing record fingerprint is not a SHA-256 digest. No trust was recorded.")
        case .wrongPairingFormat:
            return .localized("The pairing record format does not match this bootstrap route. No trust was recorded.")
        case .pairingMismatch:
            return .localized("The verified device used a different pairing record. No device trust was recorded.")
        case .invalidDeviceIdentifier:
            return .localized("The device identifier is not a valid iPhone UDID. No device trust was recorded.")
        case .deviceMismatch:
            return .localized("The device that answered is not the selected device. No device trust was recorded.")
        case .invalidTeamIdentifier:
            return .localized("The account or certificate has no valid team identifier.")
        case .invalidArtifact:
            return .localized("The IPA metadata is incomplete or its checksum is not SHA-256.")
        case .artifactMismatch:
            return .localized("The signed or installed app is not the exact selected IPA.")
        case .invalidSigner:
            return .localized("The signing identity fingerprint is not a SHA-256 digest.")
        case .invalidReceipt:
            return .localized("There is no bounded installation receipt for this attempt. Installation is unconfirmed.")
        }
    }
}

enum BootstrapEventResult: Equatable, Hashable, Sendable {
    case accepted(BootstrapStep)
    case rejected(BootstrapRejection)
}

// MARK: - Journey

struct BootstrapJourney: Equatable, Sendable {
    let expectedBundleIdentifier: String
    let expectedVersion: String?
    let expectedDeviceIdentifier: String?

    private(set) var completed: Set<BootstrapStep> = []
    private(set) var evidence = BootstrapEvidence()
    private(set) var lastRejection: BootstrapRejection?
    /// Step names only. Fingerprints, UDIDs, PINs and receipt data are never logged here.
    private(set) var eventLog: [String] = []

    init(expectedBundleIdentifier: String, expectedVersion: String? = nil,
         expectedDeviceIdentifier: String? = nil) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedVersion = expectedVersion
        self.expectedDeviceIdentifier = expectedDeviceIdentifier
    }

    var nextStep: BootstrapStep? { BootstrapStep.allCases.first { !completed.contains($0) } }
    var isComplete: Bool { completed.count == BootstrapStep.allCases.count }
    var isComputerFree: Bool { evidence.route?.isComputerFree == true }

    @discardableResult
    mutating func record(_ event: BootstrapEvent) -> BootstrapEventResult {
        guard let expected = nextStep else { return reject(.outOfOrder) }
        guard expected == event.step else { return reject(.outOfOrder) }

        switch event {
        case .environment(let route, let simulator):
            guard !simulator else { return reject(.simulator) }
            guard route != .unavailable else { return reject(.unsupportedRoute) }
            evidence.route = route

        case .pairing(let format, let fingerprint):
            guard Self.isSHA256(fingerprint) else { return reject(.invalidFingerprint) }
            switch evidence.route {
            case .onDeviceHost:
                guard format.containsRemotePairing else { return reject(.wrongPairingFormat) }
            case .pairingFileImport:
                guard format.containsLockdown else { return reject(.wrongPairingFormat) }
            case nil, .unavailable:
                return reject(.outOfOrder)
            }
            evidence.pairingFormat = format
            evidence.pairingFingerprint = fingerprint

        case .verified(let deviceIdentifier, let productVersion, let pairingFingerprint):
            guard PairingRecordDocument.isDeviceIdentifier(
                PairingRecordDocument.normalizeDeviceIdentifier(deviceIdentifier)
            ) else { return reject(.invalidDeviceIdentifier) }
            guard pairingFingerprint == evidence.pairingFingerprint else { return reject(.pairingMismatch) }
            if let expected = expectedDeviceIdentifier,
               !expected.isEmpty,
               PairingRecordDocument.normalizeDeviceIdentifier(expected)
                != PairingRecordDocument.normalizeDeviceIdentifier(deviceIdentifier) {
                return reject(.deviceMismatch)
            }
            evidence.deviceIdentifier = PairingRecordDocument.normalizeDeviceIdentifier(deviceIdentifier)
            evidence.deviceOS = productVersion

        case .authorized(let kind, let teamIdentifier):
            guard Self.isTeamIdentifier(teamIdentifier) else { return reject(.invalidTeamIdentifier) }
            evidence.accountKind = kind
            evidence.teamIdentifier = teamIdentifier

        case .artifact(let bundleIdentifier, let version, let build, let sha256):
            guard bundleIdentifier == expectedBundleIdentifier,
                  !version.isEmpty, !build.isEmpty, Self.isSHA256(sha256) else {
                return reject(.invalidArtifact)
            }
            if let expectedVersion, expectedVersion != version { return reject(.invalidArtifact) }
            evidence.bundleIdentifier = bundleIdentifier
            evidence.version = version
            evidence.build = build
            evidence.artifactSHA256 = sha256

        case .signed(let bundleIdentifier, let signerFingerprint, let sha256):
            guard Self.isSHA256(signerFingerprint) else { return reject(.invalidSigner) }
            guard bundleIdentifier == evidence.bundleIdentifier, sha256 == evidence.artifactSHA256 else {
                return reject(.artifactMismatch)
            }
            evidence.signerFingerprint = signerFingerprint

        case .installationRequested(let bundleIdentifier, let sha256):
            guard bundleIdentifier == evidence.bundleIdentifier, sha256 == evidence.artifactSHA256 else {
                return reject(.artifactMismatch)
            }
            evidence.installationSHA256 = sha256

        case .installationConfirmed(let bundleIdentifier, let version, let build, let sha256, let receipt):
            guard !receipt.isEmpty, receipt.count <= 128 else { return reject(.invalidReceipt) }
            guard bundleIdentifier == evidence.bundleIdentifier,
                  evidence.installationSHA256 == sha256,
                  version == evidence.version, build == evidence.build,
                  sha256 == evidence.artifactSHA256 else {
                return reject(.artifactMismatch)
            }
            evidence.receipt = receipt
        }

        completed.insert(event.step)
        if eventLog.count >= 32 { eventLog.removeFirst() }
        eventLog.append(event.step.rawValue)
        lastRejection = nil
        return .accepted(event.step)
    }

    mutating func reset() {
        completed = []
        evidence = BootstrapEvidence()
        lastRejection = nil
        eventLog = []
    }

    private mutating func reject(_ rejection: BootstrapRejection) -> BootstrapEventResult {
        lastRejection = rejection
        return .rejected(rejection)
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        return value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
}
