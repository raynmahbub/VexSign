// SPDX-License-Identifier: MIT
// Independently written VexSign integration; retain the IDeviceKit wrapper LICENSE.
import Foundation
import os

/// Linearizes Stop against the native command boundary. Stopping preparation
/// first prevents submission even if cancellation has not reached a native waiter
/// yet. Once submitted, Stop can only end monitoring; it cannot retract installd.
@available(iOS 16.0, macOS 13.0, *)
public final class DeviceInstallationControl: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (stopped: false, submittedAt: Optional<Date>.none))

    public init() {}
    public var submittedAt: Date? { state.withLock { $0.submittedAt } }

    /// Call BEFORE deciding whether a stopped attempt is cancelled or unconfirmed.
    /// Repeated calls are inert. A non-nil date means a command may be in flight.
    @discardableResult
    public func stopBeforeSubmission() -> Date? {
        state.withLock {
            if $0.submittedAt == nil { $0.stopped = true }
            return $0.submittedAt
        }
    }

    func beginSubmission(at date: Date, cancellation: Progress) throws {
        try state.withLock {
            guard !$0.stopped, $0.submittedAt == nil, !cancellation.isCancelled,
                  date.timeIntervalSince1970.isFinite else { throw CancellationError() }
            $0.submittedAt = date
        }
    }
}

/// Exact metadata and digest supplied by the existing app-side verification and
/// packaging owners. This value validates shape; it does NOT validate a signature
/// or authorize an install on its own. The native adapter rehashes transmitted bytes.
public struct DeviceInstallationTarget: Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let packageSHA256: String
    /// Earliest authorized profile/signer expiry, checked again after upload.
    public let authorizationExpiresAt: Date
    /// Device OS against which all executable/profile checks were performed.
    public let verifiedDeviceOS: String

    public init?(bundleIdentifier: String, version: String, build: String, packageSHA256: String,
                 authorizationExpiresAt: Date, verifiedDeviceOS: String) {
        guard DeviceApplicationInventory.isBundleIdentifier(bundleIdentifier),
              DeviceApplicationInventory.isVersion(version), DeviceApplicationInventory.isVersion(build),
              DeviceSessionBinding.isDigest(packageSHA256),
              authorizationExpiresAt.timeIntervalSince1970.isFinite,
              DeviceApplicationInventory.isVersion(verifiedDeviceOS) else { return nil }
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.packageSHA256 = packageSHA256
        self.authorizationExpiresAt = authorizationExpiresAt
        self.verifiedDeviceOS = verifiedDeviceOS
    }

    public func permitsSubmission(deviceOS: String, at date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && authorizationExpiresAt > date && verifiedDeviceOS == deviceOS
    }
}

/// An acknowledged native command, NOT an installed-app receipt. The next stage
/// must read this exact target on this device/record, after acknowledgedAt. A
/// caller cannot create this by receiving an upload-completed callback.
public struct DeviceInstallationSubmission: Sendable {
    public let target: DeviceInstallationTarget
    public let binding: DeviceSessionBinding
    public let submittedAt: Date
    public let acknowledgedAt: Date
}
