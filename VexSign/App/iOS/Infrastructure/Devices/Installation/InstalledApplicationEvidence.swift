import Foundation
import IDeviceSwift

/// A dated local observation, not a portable cryptographic installation attestation
/// and not evidence that the app remains installed after this observation. Only
/// positive metadata from the identity-bound native service can create it. Never
/// reconstruct one by copying the requested version or a native acknowledgement.
struct InstalledApplicationEvidence: Codable, Equatable, Sendable {
    let schema: Int
    let source: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let deviceBinding: DeviceSessionBinding
    let observedAt: Date

    init?(application: DeviceInstalledApplication) {
        guard let version = application.version, let build = application.build else { return nil }
        self.init(bundleIdentifier: application.bundleIdentifier, version: version, build: build,
                  deviceBinding: application.binding, observedAt: application.observedAt)
    }

    /// Shared validation seam for native adaptation and credential-free tests.
    init?(bundleIdentifier: String, version: String, build: String,
          deviceBinding: DeviceSessionBinding, observedAt: Date) {
        self.schema = 1
        self.source = "coredevice-appservice"
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.deviceBinding = deviceBinding
        self.observedAt = observedAt
        guard isWellFormed else { return nil }
    }

    /// Decoded history is untrusted input. Codable success alone never promotes it.
    var isWellFormed: Bool {
        schema == 1 && source == "coredevice-appservice" && deviceBinding.isWellFormed
            && DeviceApplicationInventory.isBundleIdentifier(bundleIdentifier)
            && DeviceApplicationInventory.isVersion(version) && DeviceApplicationInventory.isVersion(build)
            && Self.isObservationDate(observedAt)
    }

    private static func isObservationDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        // Bound untrusted history before formatting it in receipts (1970...9999).
        return seconds.isFinite && (0...253_402_300_799).contains(seconds)
    }

    func confirms(bundleIdentifier: String, version: String?, build: String?,
                  binding: DeviceSessionBinding?, notBefore: Date?, notAfter: Date? = nil) -> Bool {
        guard isWellFormed, self.bundleIdentifier == bundleIdentifier,
              let version, let build, self.version == version, self.build == build,
              let binding, binding.isWellFormed, deviceBinding == binding,
              let notBefore, notBefore.timeIntervalSince1970.isFinite,
              observedAt >= notBefore else { return false }
        if let notAfter {
            guard notAfter.timeIntervalSince1970.isFinite, observedAt <= notAfter else { return false }
        }
        return true
    }
}
