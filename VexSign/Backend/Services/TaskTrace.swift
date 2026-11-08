import Foundation
import CryptoKit

/// Deliberately allowlisted metadata: never store options payloads, certificate
/// contents, passwords, pairing records, raw URLs or filesystem paths here.
struct TaskContext: Codable, Equatable {
    var appVersion: String?
    var appBuild: String?
    var installationMethod: String?
    var certificateReference: String?
    var optionsFingerprint: String?
    var artifactID: String?
    var signingTaskID: String?
    var importTaskID: String?
    var confirmationReason: String?
    var errorCategory: String?
    var errorCode: Int?

    mutating func recordFailure(_ error: Error) {
        let error = error as NSError
        errorCode = error.code
        switch error.domain {
        case NSURLErrorDomain: errorCategory = "network"
        case NSCocoaErrorDomain: errorCategory = "filesystem"
        case NSOSStatusErrorDomain: errorCategory = "security"
        default: errorCategory = "operation"
        }
    }

    var clientVersion: String = BuildIdentity.version
    var sourceCommit: String = BuildIdentity.commit

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func versionToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 64, raw.first?.isNumber == true,
              raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+").contains($0) }) else { return nil }
        return raw
    }
}

struct TaskStageEntry: Codable, Equatable {
    let phase: UnifiedTaskPhase
    let date: Date
}

enum BuildIdentity {
    static var version: String {
        let version = TaskContext.versionToken(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        let build = TaskContext.versionToken(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        return "\(version) (\(build))"
    }
    static func validatedVersion(_ raw: String?) -> String {
        guard let raw, raw.count <= 135,
              raw.range(of: #"^[0-9][a-zA-Z0-9._+\-]{0,63} \([0-9][a-zA-Z0-9._+\-]{0,63}\)$"#, options: .regularExpression) != nil else { return "unavailable" }
        return raw
    }

    static var commit: String {
        validatedCommit(Bundle.main.object(forInfoDictionaryKey: "VexSignSourceCommit") as? String)
    }
    static func validatedCommit(_ raw: String?) -> String {
        guard let raw, (7...40).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return "unavailable" }
        return raw.lowercased()
    }
}
