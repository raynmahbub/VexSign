// SPDX-License-Identifier: MIT
// VexSign local extension; retain the IDeviceKit wrapper LICENSE.
// VexSign independently maintained extension of the MIT-licensed IDeviceKit wrapper.
// Schema facts are from jkcoxson/idevice v0.1.57, not SideInstaller implementation code.
import Foundation
import CryptoKit

public enum PairingRecordFormat: String, Codable, Equatable, Sendable {
    case lockdown, remotePairing, combined

    public var containsLockdown: Bool { self != .remotePairing }
    public var containsRemotePairing: Bool { self != .lockdown }
}

/// Metadata only. `identifier` in a remote record identifies the HOST, not the iPhone.
/// None of the formats understood here declares a schema version. Do not invent one.
public struct PairingRecordMetadata: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let format: PairingRecordFormat
    public let deviceIdentifier: String?
    public let sha256: String
    public let byteCount: Int
    public var schemaVersion: String { "unversioned" }
    public var description: String { "PairingRecordMetadata(\(format.rawValue), unversioned, credentials and identity redacted)" }
    public var debugDescription: String { description }
}

public enum PairingRecordError: Error, Equatable, LocalizedError, Sendable {
    case missing, unreadable, oversized, unsafeFile, malformed, unsupportedFormat
    case invalidFields([String]), conflictingDeviceIdentity, remoteKeyMismatch, changedRecord

    public var errorDescription: String? {
        switch self {
        case .missing: return "No pairing record. Import a record from a trusted pairing tool."
        case .unreadable: return "Pairing storage is unavailable. Unlock the device and retry; no identity was replaced."
        case .oversized: return "Pairing record exceeds the 2 MiB limit. The existing record was not changed."
        case .unsafeFile: return "Pairing input must be a regular file, not a link or directory."
        case .malformed: return "Pairing data is not a bounded supported property list."
        case .unsupportedFormat: return "Unknown pairing format or version. Export an unmodified compatible pairing plist."
        case .invalidFields(let fields): return "Pairing record has missing or invalid fields: " + fields.joined(separator: ", ") + "."
        case .conflictingDeviceIdentity: return "Pairing record contains conflicting device identifiers. Nothing was imported."
        case .remoteKeyMismatch: return "Remote pairing public and private keys do not match. Nothing was imported."
        case .changedRecord: return "The pairing record changed. Review the current record before replacing or deleting it."
        }
    }
}

/// A single bounded read for lifecycle UI. A fingerprint can review malformed
/// legacy data; metadata is present ONLY if structural/key validation succeeded.
public struct PairingRecordReview: Sendable {
    public let metadata: PairingRecordMetadata?
    public let fingerprint: String?
    public let issue: PairingRecordError?
}

/// Structural/cryptographic key inspection is NOT device authorization. Native parsers
/// and a fresh device handshake still have to accept the actual record. Preserve original
/// bytes; never fabricate a lockdown half or convert an RPPairing host UUID into a UDID.
public enum PairingRecordDocument {
    public static let maximumSize = 2 * 1024 * 1024
    public static let classicStringKeys = ["HostID", "SystemBUID", "WiFiMACAddress"]
    public static let classicDataKeys = ["HostPrivateKey", "RootPrivateKey", "HostCertificate", "DeviceCertificate", "RootCertificate"]
    public static let remoteKeys = ["public_key", "private_key", "identifier"]

    public static func normalizeDeviceIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func isDeviceIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let hex: (UInt8) -> Bool = { (48...57).contains($0) || (65...70).contains($0) }
        if bytes.count == 40 { return bytes.allSatisfy(hex) }
        return bytes.count == 25 && bytes[8] == 45
            && bytes.enumerated().allSatisfy { $0.offset == 8 || hex($0.element) }
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func inspect(_ data: Data) throws -> PairingRecordMetadata {
        guard !data.isEmpty else { throw PairingRecordError.malformed }
        guard data.count <= maximumSize else { throw PairingRecordError.oversized }
        try PairingPlistEnvelope.validate(data)
        let root: Any
        do { root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw PairingRecordError.malformed }
        guard let record = root as? [String: Any], record.count <= 128,
              record.values.allSatisfy({ $0 is Data || $0 is String || $0 is NSNumber }) else {
            throw PairingRecordError.malformed
        }
        // These schemas are flat and unversioned. A wrapper/version envelope is not
        // silently unwrapped or relabelled as an older native record.
        let versionKeys: Set<String> = ["version", "schemaversion", "formatversion", "recordversion"]
        guard !record.keys.contains(where: {
            versionKeys.contains($0.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: ""))
        }) else { throw PairingRecordError.unsupportedFormat }
        let hasClassic = (classicStringKeys + classicDataKeys).contains { record[$0] != nil }
        let hasRemote = remoteKeys.contains { record[$0] != nil } || record["alt_irk"] != nil
        guard hasClassic || hasRemote else { throw PairingRecordError.unsupportedFormat }
        var invalid: [String] = []
        if hasClassic {
            invalid += classicStringKeys.filter { !validString(record[$0]) }
            invalid += classicDataKeys.filter { (record[$0] as? Data)?.isEmpty != false }
            if let bag = record["EscrowBag"], !(bag is Data) { invalid.append("EscrowBag") }
        }
        if hasRemote {
            invalid += ["public_key", "private_key"].filter { (record[$0] as? Data)?.count != 32 }
            if !validString(record["identifier"]) || UUID(uuidString: record["identifier"] as? String ?? "") == nil {
                invalid.append("identifier")
            }
            if let irk = record["alt_irk"], (irk as? Data)?.count != 16 { invalid.append("alt_irk") }
        }
        var deviceIDs: Set<String> = []
        for key in ["UDID", "DeviceID", "remotepairing_udid"] where record[key] != nil {
            guard let string = record[key] as? String else { invalid.append(key); continue }
            let normalized = normalizeDeviceIdentifier(string)
            if !isDeviceIdentifier(normalized) { invalid.append(key) }
            else { deviceIDs.insert(normalized) }
        }
        guard invalid.isEmpty else { throw PairingRecordError.invalidFields(invalid.sorted()) }
        guard deviceIDs.count <= 1 else { throw PairingRecordError.conflictingDeviceIdentity }
        if hasRemote {
            guard let seed = record["private_key"] as? Data, let publicKey = record["public_key"] as? Data,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
                  key.publicKey.rawRepresentation == publicKey else { throw PairingRecordError.remoteKeyMismatch }
        }
        return PairingRecordMetadata(format: hasClassic ? (hasRemote ? .combined : .lockdown) : .remotePairing,
            deviceIdentifier: deviceIDs.first,
            sha256: fingerprint(data), byteCount: data.count)
    }

    private static func validString(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && string.utf8.count <= 256
            && !string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
