// SPDX-License-Identifier: MIT
// Independently written VexSign integration; retain the IDeviceKit wrapper LICENSE.
import Foundation
import CryptoKit

/// Opaque, record-scoped device identity. This is a comparison token, not a trust
/// credential. In particular it cannot authorize a session without a fresh native
/// identity query. Neither Codable nor descriptions contain a UDID or host UUID.
public struct DeviceSessionBinding: Codable, Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sha256: String

    public init?(deviceIdentifier: String, pairingSHA256: String) {
        let identifier = PairingRecordDocument.normalizeDeviceIdentifier(deviceIdentifier)
        guard PairingRecordDocument.isDeviceIdentifier(identifier), Self.isDigest(pairingSHA256) else { return nil }
        let input = Data(("VexSign.device-session.v1\u{0}" + identifier + "\u{0}" + pairingSHA256).utf8)
        sha256 = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    public var isWellFormed: Bool { Self.isDigest(sha256) }
    public var description: String { "DeviceSessionBinding(redacted)" }
    public var debugDescription: String { description }

    public static func isDigest(_ raw: String) -> Bool {
        raw.utf8.count == 64 && raw.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// A positive CoreDevice App Service entry, after validating the native result.
/// Missing versions stay missing. A path is retained for replacement comparison,
/// never treated as independently observed evidence or opened in this process.
public struct DeviceInstalledApplication: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let build: String?
    public let bundlePath: String
    public let binding: DeviceSessionBinding
    public let observedAt: Date

    public var description: String { "DeviceInstalledApplication(metadata redacted)" }
    public var debugDescription: String { description }
}

/// There is deliberately NO `notInstalled` result. Even a successful list may be
/// scoped/filtered by the device. Only a matching positive entry is evidence;
/// omission, an empty list, a service error and a cancelled query prove no absence.
public struct DeviceApplicationInventory: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let applications: [DeviceInstalledApplication]
    public let binding: DeviceSessionBinding
    public let observedAt: Date

    public func application(for bundleIdentifier: String) -> DeviceInstalledApplication? {
        guard Self.isBundleIdentifier(bundleIdentifier) else { return nil }
        return applications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    public var description: String { "DeviceApplicationInventory(count: \(applications.count), identity redacted)" }
    public var debugDescription: String { description }

    public static func isBundleIdentifier(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        return raw.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
            }
        }
    }

    public static func isVersion(_ raw: String) -> Bool {
        guard (1...64).contains(raw.utf8.count), let first = raw.utf8.first, (48...57).contains(first) else { return false }
        return raw.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 43].contains($0)
        }
    }

    /// Internal, credential-free seam shared by the FFI adapter and exact-source
    /// host tests. These fields are NOT a second protocol/parser implementation.
    struct Record {
        let bundleIdentifier: String
        let name: String
        let version: String?
        let build: String?
        let path: String
        let isAppClip: Bool
    }

    static let maximumEntries = 10_000

    static func validated(_ records: [Record], binding: DeviceSessionBinding, observedAt: Date) throws -> Self {
        guard binding.isWellFormed, records.count <= maximumEntries,
              observedAt.timeIntervalSince1970.isFinite else { throw DeviceTransportError.invalidDeviceResponse }
        var seen = Set<String>()
        var applications = [DeviceInstalledApplication]()
        applications.reserveCapacity(records.count)
        for record in records {
            guard isBundleIdentifier(record.bundleIdentifier), seen.insert(record.bundleIdentifier).inserted,
                  !record.name.isEmpty, record.name.utf8.count <= 1024,
                  !record.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  record.version.map(isVersion) ?? true, record.build.map(isVersion) ?? true,
                  validPath(record.path) else { throw DeviceTransportError.invalidDeviceResponse }
            // App Clips are not the full application we are confirming. Never
            // substitute an extension/clip or trim/normalize an identifier to fit.
            guard !record.isAppClip, record.path.hasSuffix(".app") else { continue }
            applications.append(DeviceInstalledApplication(bundleIdentifier: record.bundleIdentifier,
                name: record.name, version: record.version, build: record.build,
                bundlePath: record.path, binding: binding, observedAt: observedAt))
        }
        return Self(applications: applications, binding: binding, observedAt: observedAt)
    }

    private static func validPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.contains("\\"), !path.contains("//"), !path.contains(":") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
