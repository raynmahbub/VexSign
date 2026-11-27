// MARK: - Unified device lifecycle records
//
// These models describe evidence VexSign can actually hold about a device. A pairing file is
// not a connection, a remembered row is not a paired device, and an app-service response is
// not proof of a full application list. The vocabulary keeps those states apart so neither the
// UI nor a task can promote one into another.
//
// Nothing in this file contacts a device.

import Foundation
import CryptoKit
import IDeviceSwift
import NimbleExtensions

/// How the current record relates to a device. This is a statement about *now*, not a
/// lifetime label: reconnecting moves a remembered row back to `.connected` only after a fresh
/// device query succeeds.
enum ManagedDeviceLink: String, Codable, Sendable, CaseIterable {
    /// A fresh, identity-bound session answered in this process.
    case connected
    /// A complete pairing record exists for this device, but no current session.
    case paired
    /// The row was observed earlier; the pairing record is no longer available here.
    case remembered
    /// The device was seen before but the latest attempt could not reach it.
    case unavailable
    /// The device is reachable enough to answer, but has not authorized this host.
    case pairingRequired
    /// The device refused this host; re-pairing is required.
    case untrusted

    var isConnected: Bool { self == .connected }

    var title: String {
        switch self {
        case .connected: .localized("Connected now")
        case .paired: .localized("Paired, not connected")
        case .remembered: .localized("Remembered device")
        case .unavailable: .localized("Unavailable")
        case .pairingRequired: .localized("Pairing required")
        case .untrusted: .localized("Not trusted")
        }
    }

    var detail: String {
        switch self {
        case .connected:
            .localized("A fresh device service query succeeded in this session. The session is closed when the operation ends.")
        case .paired:
            .localized("A complete pairing record names this device. Nothing currently proves the device would accept a session.")
        case .remembered:
            .localized("This is a stored observation from an earlier session. No pairing record for this device is available now.")
        case .unavailable:
            .localized("A previous connection exists, but the most recent attempt could not reach the device. No current state is inferred.")
        case .pairingRequired:
            .localized("Unlock the device and tap Trust. A pairing file alone never grants access.")
        case .untrusted:
            .localized("The device refused this host. Remove the old pairing on the device and pair again.")
        }
    }
}

/// Persistable pairing state. It intentionally keeps the distinction between an absent file,
/// an unreadable file and a readable record; readability is never trust.
enum StoredPairingState: String, Codable, Sendable, CaseIterable {
    case absent, unreadable, incomplete, readable

    static func from(_ state: DevicePairingState) -> StoredPairingState {
        switch state {
        case .absent: .absent
        case .readable, .validated: .readable
        case .incomplete: .incomplete
        case .unreadable, .oversized: .unreadable
        }
    }

    var title: String {
        switch self {
        case .absent: .localized("No pairing record")
        case .unreadable: .localized("Pairing record unreadable")
        case .incomplete: .localized("Pairing record incomplete")
        case .readable: .localized("Pairing record found")
        }
    }
}

/// Codable counterpart of `DeviceTrust`; there is deliberately no `.trusted` case that a
/// pairing file can set on its own.
enum StoredDeviceTrust: String, Codable, Sendable, CaseIterable {
    case verified, unverified, unknown

    static func from(_ trust: DeviceTrust) -> StoredDeviceTrust {
        switch trust {
        case .verified: .verified
        case .unverified: .unverified
        case .unknown: .unknown
        }
    }

    var title: String {
        switch self {
        case .verified: .localized("Device verified this host")
        case .unverified: .localized("Not yet verified")
        case .unknown: .localized("Trust unknown")
        }
    }
}

struct StoredDeviceCapability: Codable, Equatable, Sendable, Identifiable {
    let operation: String
    let status: String
    let detail: String

    var id: String { operation }

    init(operation: DeviceOperation, status: DeviceCapabilityStatus, detail: String) {
        self.operation = operation.rawValue
        self.status = status.rawValue
        self.detail = detail
    }

    var title: String {
        DeviceOperation(rawValue: operation)?.title ?? operation
    }

    var statusTitle: String {
        DeviceCapabilityStatus(rawValue: status)?.title ?? status
    }

    var isSupported: Bool { status == DeviceCapabilityStatus.supported.rawValue }

    static func from(_ report: DeviceCapabilityReport) -> [StoredDeviceCapability] {
        report.capabilities.map { StoredDeviceCapability(operation: $0.operation, status: $0.status, detail: $0.detail) }
    }

    func matches(_ operation: DeviceOperation) -> Bool { self.operation == operation.rawValue }
}

/// A diagnostic line. Messages are written by VexSign code only; native error strings and
/// identifiers are never copied into it.
struct DeviceDiagnostic: Codable, Equatable, Sendable, Identifiable {
    enum Severity: String, Codable, Sendable { case info, warning, error }

    let id: String
    let at: Date
    let severity: Severity
    let code: String
    let message: String

    init(id: String = UUID().uuidString, at: Date = Date(), severity: Severity,
         code: String, message: String) {
        self.id = id
        self.at = at
        self.severity = severity
        self.code = code
        self.message = message
    }
}

/// One durable device row. `id` is the normalized UDID when the device supplies one. When a
/// remote pairing format has no device identifier, a salted pseudonymous ID derived from the
/// reviewed pairing fingerprint is used; the fingerprint itself is never stored here.
struct ManagedDeviceRecord: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1
    static let maximumRecords = 128
    static let maximumDiagnostics = 24

    let schemaVersion: Int
    let id: String
    /// False when only a pseudonymous, record-scoped ID is available.
    let hasStableIdentifier: Bool
    var name: String
    var deviceType: String
    var productType: String?
    var osVersion: String?
    var buildVersion: String?
    var modelNumber: String?
    var link: ManagedDeviceLink
    var pairing: StoredPairingState
    var trust: StoredDeviceTrust
    var capabilities: [StoredDeviceCapability]
    var lastConnectedAt: Date?
    var lastInventoryAt: Date?
    var lastSyncAt: Date?
    var lastSeenAt: Date?
    var diagnostics: [DeviceDiagnostic]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        hasStableIdentifier: Bool,
        name: String,
        deviceType: String = "",
        productType: String? = nil,
        osVersion: String? = nil,
        buildVersion: String? = nil,
        modelNumber: String? = nil,
        link: ManagedDeviceLink,
        pairing: StoredPairingState = .absent,
        trust: StoredDeviceTrust = .unknown,
        capabilities: [StoredDeviceCapability] = [],
        lastConnectedAt: Date? = nil,
        lastInventoryAt: Date? = nil,
        lastSyncAt: Date? = nil,
        lastSeenAt: Date? = nil,
        diagnostics: [DeviceDiagnostic] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.hasStableIdentifier = hasStableIdentifier
        self.name = name
        self.deviceType = deviceType
        self.productType = productType
        self.osVersion = osVersion
        self.buildVersion = buildVersion
        self.modelNumber = modelNumber
        self.link = link
        self.pairing = pairing
        self.trust = trust
        self.capabilities = capabilities
        self.lastConnectedAt = lastConnectedAt
        self.lastInventoryAt = lastInventoryAt
        self.lastSyncAt = lastSyncAt
        self.lastSeenAt = lastSeenAt
        self.diagnostics = Array(diagnostics.prefix(Self.maximumDiagnostics))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayName: String { name.isEmpty ? .localized("Unnamed device") : name }

    var subtitle: String {
        [productType ?? deviceType, osVersion.map { "iOS " + $0 }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Only the last four characters are shown, so two rows can be told apart without
    /// putting a full hardware identifier on screen or in a support log.
    var logSafeIdentifier: String {
        id.count <= 4 ? "…" : "…\(id.suffix(4))"
    }

    var supportsInstallation: Bool {
        capabilities.contains { $0.matches(.pairedInstall) && $0.isSupported }
    }

    var supportsInventory: Bool {
        capabilities.contains { $0.matches(.inventoryRead) && $0.isSupported }
    }

    var supportsRemoval: Bool {
        capabilities.contains { $0.matches(.uninstall) && $0.isSupported }
    }

    func capability(for operation: DeviceOperation) -> StoredDeviceCapability? {
        capabilities.first { $0.matches(operation) }
    }

    /// Returns a copy with one bounded diagnostic. An unrecognized schema is refused at
    /// load time rather than silently migrated into an empty record.
    func withDiagnostic(_ diagnostic: DeviceDiagnostic, at date: Date = Date()) -> ManagedDeviceRecord {
        var copy = self
        copy.diagnostics.insert(diagnostic, at: 0)
        copy.diagnostics = Array(copy.diagnostics.prefix(Self.maximumDiagnostics))
        copy.updatedAt = date
        return copy
    }

    var isWellFormed: Bool {
        schemaVersion == Self.schemaVersion
            && !id.isEmpty && id.utf8.count <= 128
            && name.utf8.count <= 512
            && capabilities.count <= DeviceOperation.allCases.count
            && diagnostics.count <= Self.maximumDiagnostics
    }

    /// Builds a stable identity without persisting pairing material or exposing a UDID in
    /// a pseudonymous fallback. Returns nil for an unusable identifier/fingerprint pair.
    static func identity(udid: String?, pairingFingerprint: String?) -> (id: String, stable: Bool)? {
        let normalized = udid.map { PairingRecordInspector.normalize($0) } ?? ""
        if PairingRecordDocument.isDeviceIdentifier(normalized) {
            return (normalized, true)
        }
        guard let fingerprint = pairingFingerprint, DeviceSessionBinding.isDigest(fingerprint) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("VexSign.device-record.v1\u{0}".utf8))
        hasher.update(data: Data(fingerprint.utf8))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ("pseudo-" + String(digest.prefix(32)), false)
    }

    /// Converts a fresh device query into a record. Only the query supplies trust and
    /// presence; the caller supplies the pairing state observed from its own storage.
    static func from(
        snapshot: AuthorizedDeviceSnapshot,
        pairing: StoredPairingState,
        capabilities: [StoredDeviceCapability],
        previous: ManagedDeviceRecord? = nil,
        now: Date = Date()
    ) -> ManagedDeviceRecord? {
        guard let identity = identity(udid: snapshot.deviceIdentifier, pairingFingerprint: snapshot.pairingSHA256) else {
            return nil
        }
        let model = snapshot.productType.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManagedDeviceRecord(
            id: identity.id,
            hasStableIdentifier: identity.stable,
            name: name.isEmpty ? (previous?.name ?? .localized("Unnamed device")) : name,
            deviceType: previous?.deviceType ?? model,
            productType: model.isEmpty ? nil : model,
            osVersion: snapshot.productVersion,
            buildVersion: snapshot.buildVersion,
            link: .connected,
            pairing: pairing,
            trust: .verified,
            capabilities: capabilities,
            lastConnectedAt: now,
            lastInventoryAt: previous?.lastInventoryAt,
            lastSyncAt: previous?.lastSyncAt,
            lastSeenAt: now,
            diagnostics: previous?.diagnostics ?? [],
            createdAt: previous?.createdAt ?? now,
            updatedAt: now
        )
    }
}

/// The persisted shape of a list of devices. A separate type makes schema evolution explicit
/// instead of treating a decoded array as trustworthy.
struct ManagedDeviceCollection: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var devices: [ManagedDeviceRecord]

    init(devices: [ManagedDeviceRecord] = []) {
        self.schemaVersion = 1
        self.devices = devices
    }

    var isWellFormed: Bool {
        schemaVersion == 1 && devices.count <= ManagedDeviceRecord.maximumRecords
            && devices.allSatisfy(\.isWellFormed)
            && Set(devices.map(\.id)).count == devices.count
    }
}

enum DeviceLifecycleError: LocalizedError, Equatable {
    case invalidRecord
    case invalidIdentifier
    case deviceRequired
    case inventoryUnavailable(String)
    case operationBlocked(String)
    case interrupted
    case invalidUpdate(String)
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            .localized("The stored device record is incomplete and was not applied.")
        case .invalidIdentifier:
            .localized("This device identifier cannot be used safely.")
        case .deviceRequired:
            .localized("Verify a device before starting this operation.")
        case .inventoryUnavailable(let reason):
            String.localized("Device inventory is unavailable: %@", arguments: reason)
        case .operationBlocked(let reason):
            reason
        case .interrupted:
            .localized("The operation stopped before the device answered. Check the device before retrying.")
        case .invalidUpdate(let reason):
            reason
        case .storageUnavailable:
            .localized("Device records could not be stored. No device state was changed.")
        }
    }
}
