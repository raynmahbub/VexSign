// SPDX-License-Identifier: MIT
// VexSign local extension; retain the IDeviceKit wrapper LICENSE.
// Independently written VexSign transport policy. No Apple authorization is inferred here.
import Foundation

public struct DeviceOSVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    public static func parse(_ raw: String) -> Self? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) })
                  && Int($0).map({ (0...999).contains($0) }) == true }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return Self(major: major, minor: minor, patch: parts.count == 3 ? Int(parts[2]) ?? 0 : 0)
    }
    public static var current: Self {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return Self(major: value.majorVersion, minor: value.minorVersion, patch: value.patchVersion)
    }
}

public enum DevicePairingRoute: String, Equatable, Sendable {
    case unsupported, importedClassic, importedRemoteRequired, hostDependencyRequired, onDeviceHostPairing, unknownOS
    public static func resolve(_ version: DeviceOSVersion) -> Self {
        guard version >= .init(major: 17, minor: 4) else { return .unsupported }
        if version >= .init(major: 27, minor: 0) { return .onDeviceHostPairing }
        if version >= .init(major: 26, minor: 8) { return .unknownOS }
        if version >= .init(major: 26, minor: 4) { return .importedRemoteRequired }
        return .importedClassic
    }
}

public enum DeviceConnectionStage: String, Equatable, Sendable {
    case inspectingRecord, checkingTransport, openingTunnel, discoveringServices
    case queryingDevice, authorized, disconnecting
}

/// Sanitized, typed failures. Never include a raw native error message: upstream
/// protocol errors can embed plists, pairing identifiers or authentication material.
public enum DeviceTransportError: Error, Equatable, LocalizedError {
    case consentRequired, unsupportedOS, unknownOS, simulator, remoteRecordRequired
    case remoteBridgeUnavailable, hostUnavailable, onDeviceHostPairingRequired, expectedDeviceRequired, wrongDevice
    case invalidPeer, permissionDenied, connectionRefused, transportTimeout, transportUnavailable
    case nativeFailure(stage: DeviceConnectionStage, code: Int32)
    case invalidDeviceResponse, serviceUnavailable(String), operationCancelled, operationBusy, operationTimedOut
    case developerModeUnverified, inventoryBridgeUnavailable, installationUnconfirmed, removalOutcomeUnknown, versionMismatch

    public var errorDescription: String? {
        switch self {
        case .consentRequired: return "Approve experimental device-service communication in the bootstrap guide first. Imported-certificate signing and OTA do not require this approval."
        case .unsupportedOS: return "This paired-device route requires iOS 17.4 or later. Use an eligible external installer or signed IPA export."
        case .unknownOS: return "This OS version is outside the reviewed compatibility matrix. Use an eligible companion or signed IPA export."
        case .simulator: return "A simulator cannot authorize pairing, Developer Mode, or installation on a physical iPhone."
        case .remoteRecordRequired: return "iOS 26.4 and later require a compatible Remote Pairing record for this loopback route. A classic lockdown record is not equivalent. A computer may be required to generate the remote record."
        case .remoteBridgeUnavailable: return "The record is Remote Pairing, but the pinned device library has no accepted modern on-device loopback bridge. The record is preserved; use a compatible companion. Do not repeatedly re-pair to fix this dependency limitation."
        case .hostUnavailable: return "On-device RPPairing hosting is unavailable in the pinned library. No service or PIN was advertised. Import a compatible remote record and use an eligible companion."
        case .onDeviceHostPairingRequired: return "This iOS version requires the on-device RPPairing host bootstrap flow. Start pairing from the bootstrap guide; a classic lockdown session cannot be used for this route."
        case .expectedDeviceRequired: return "Select the intended device UDID before connecting. A remote host identifier is not a device UDID."
        case .wrongDevice: return "The device did not match the selected identity. No device operation was authorized. Select the correct device or import its pairing record."
        case .invalidPeer: return "Use the VPN peer's Device IP, not this iPhone's interface, Wi-Fi, or localhost address. The usual LocalDevVPN peer is 10.7.0.1, not 10.7.1.1."
        case .permissionDenied: return "Local transport access was denied. Check Local Network permission, Developer Mode, and the VPN peer address; an EPERM response does not prove the pairing is revoked."
        case .connectionRefused: return "The configured peer refused the connection. Open the VPN app, activate its tunnel yourself, check the peer address and retry."
        case .transportTimeout: return "The local transport probe timed out. Reconnect the VPN and retry; no device authorization was established."
        case .transportUnavailable: return "The local transport is unavailable. Activate the required VPN in its own app or Settings and retry."
        case .nativeFailure(let stage, let code): return "Device service failed at \(stage.rawValue) (code \(code)). Unlock the iPhone, check Developer Mode and trust. If pairing was revoked, generate a new record. No connection success is claimed."
        case .invalidDeviceResponse: return "The device returned incomplete or invalid identity information. Authorization remains unverified."
        case .serviceUnavailable(let name): return "The device did not open the required service: " + name + "."
        case .operationCancelled: return "Cancelled. A native call already in progress must retire before another device operation can start."
        case .operationBusy: return "Another device operation still owns the transport. Wait for it to retire before retrying. If a native call never returns, reopen VexSign; do not replace its record while it is running."
        case .operationTimedOut: return "Stopped waiting after the device-service deadline. A blocked native call may still be retiring; no authorization or installation success is claimed. Retry only after the transport is free, or reopen VexSign."
        case .developerModeUnverified: return "Developer Mode has not been verified. Check Settings → Privacy & Security → Developer Mode. VexSign cannot silently enable it."
        case .inventoryBridgeUnavailable: return "Paired installation is gated pending native binary/header tests and physical acceptance of same-device version/build confirmation. An experimental read-only CoreDevice inventory query is available in setup; source-level ownership review alone does not authorize installation or removal. Use an eligible companion or export the signed IPA."
        case .installationUnconfirmed: return "The device accepted an installation request but did not confirm the expected app and version. Check the Home Screen; this is not installation success."
        case .removalOutcomeUnknown: return "A removal command may have reached the selected device, but its result is unknown. Check the device before retrying; no removal success or rejection is claimed."
        case .versionMismatch: return "The device reports another app version or build. The requested installation is not confirmed."
        }
    }
}

public struct DeviceConnectionRequest: Sendable {
    /// Process-local identity of this request value, preserved by copies but not
    /// recreated from equal device/record fields. This is not native trust. App
    /// selection can reject an old request after revoke/reselect of the same peer.
    public let selectionID = UUID()
    public let pairingFile: URL
    public let expectedDeviceIdentifier: String
    public let peerAddress: String
    public let protocolConsent: Bool
    /// Freeze the reviewed credential for a multi-step attempt. Nil is permitted
    /// for an initial read-only identity query, never for a mutation/confirmation.
    public let expectedPairingSHA256: String?
    public init(pairingFile: URL, expectedDeviceIdentifier: String, peerAddress: String = "10.7.0.1", protocolConsent: Bool,
                expectedPairingSHA256: String? = nil) {
        self.pairingFile = pairingFile
        self.expectedDeviceIdentifier = PairingRecordDocument.normalizeDeviceIdentifier(expectedDeviceIdentifier)
        self.peerAddress = peerAddress
        self.protocolConsent = protocolConsent
        self.expectedPairingSHA256 = expectedPairingSHA256
    }

    public var binding: DeviceSessionBinding? {
        expectedPairingSHA256.flatMap { DeviceSessionBinding(deviceIdentifier: expectedDeviceIdentifier, pairingSHA256: $0) }
    }
}

public enum DeviceTransportPolicy {
    /// Selection only. Imported remote records remain storable/exportable, but the
    /// old binary's createListener-based path must not be advertised as supported.
    public static func requireClassicRoute(format: PairingRecordFormat, version: DeviceOSVersion) throws {
        switch DevicePairingRoute.resolve(version) {
        case .unsupported: throw DeviceTransportError.unsupportedOS
        case .unknownOS: throw DeviceTransportError.unknownOS
        case .hostDependencyRequired: throw DeviceTransportError.hostUnavailable
        case .onDeviceHostPairing: throw DeviceTransportError.onDeviceHostPairingRequired
        case .importedRemoteRequired:
            guard format.containsRemotePairing else { throw DeviceTransportError.remoteRecordRequired }
            throw DeviceTransportError.remoteBridgeUnavailable
        case .importedClassic:
            guard format.containsLockdown else { throw DeviceTransportError.remoteBridgeUnavailable }
        }
    }

    /// iOS 27+ on-device bootstrap: the device pairs through a local RPPairing host.
    /// This route is for creating a new pairing; it does not silently trust imported records.
    public static func requireOnDeviceHostPairingRoute(version: DeviceOSVersion) throws {
        switch DevicePairingRoute.resolve(version) {
        case .unsupported: throw DeviceTransportError.unsupportedOS
        case .unknownOS: throw DeviceTransportError.unknownOS
        case .onDeviceHostPairing: return
        case .hostDependencyRequired: throw DeviceTransportError.hostUnavailable
        case .importedClassic, .importedRemoteRequired:
            throw DeviceTransportError.hostUnavailable
        }
    }
}

/// Data returned by a fresh native device query. No raw record or private key.
/// Service support lists only services opened successfully for this operation.
public struct AuthorizedDeviceSnapshot: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deviceIdentifier: String
    public let name: String
    public let productType: String
    public let productVersion: String
    public let buildVersion: String
    public let services: Set<String>
    public let observedAt: Date
    public let pairingSHA256: String
    public var description: String { "AuthorizedDeviceSnapshot(identity redacted, services: \(services.sorted()))" }
    public var debugDescription: String { description }
}
