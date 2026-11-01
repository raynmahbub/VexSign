import Foundation
import NimbleExtensions

/// Optional, user-supplied byte-integrity check; not a publisher trust verdict.
enum CompanionIPAIntegrity: Equatable {
    case notRequested, invalidExpectedHash, needsFingerprint, matches, mismatch

    static func evaluate(expected: String, actual: String?) -> Self {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notRequested }
        let expected = FileIntegrity.normalize(expected)
        guard expected.count == 64, expected.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return .invalidExpectedHash }
        guard let actual else { return .needsFingerprint }
        return FileIntegrity.normalize(actual) == expected ? .matches : .mismatch
    }

    var allowsSharing: Bool { self == .notRequested || self == .matches }

    var message: String {
        switch self {
        case .notRequested:
            return .localized("No publisher hash supplied. Sharing does not verify authenticity.")
        case .invalidExpectedHash:
            return .localized("Enter a 64-character hexadecimal SHA-256 value, optionally prefixed with sha256:.")
        case .needsFingerprint:
            return .localized("Calculate this IPA's SHA-256 before sharing against the supplied hash.")
        case .matches:
            return .localized("The file matches the supplied hash. This does not verify who published the hash or whether the app can run.")
        case .mismatch:
            return .localized("Hash mismatch. Sharing is blocked while this expected hash is set. Obtain the correct file and hash from a trusted source.")
        }
    }
}
