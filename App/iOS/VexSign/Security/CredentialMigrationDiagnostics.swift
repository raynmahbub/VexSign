import Foundation
import Combine
import Security
import OSLog
import NimbleExtensions

enum CredentialMigrationIssue: String, CaseIterable, Sendable {
    case keychainUnavailable, accessUnavailable, storageFull, needsAttention

    static func classify(_ error: Error) -> Self {
        if let failure = error as? SecureSecretStore.Failure {
            switch failure.status {
            case errSecInteractionNotAllowed, errSecNotAvailable: return .keychainUnavailable
            default: return .needsAttention
            }
        }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .accessUnavailable
            case NSFileWriteOutOfSpaceError: return .storageFull
            default: break
            }
        }
        return .needsAttention
    }

    var message: String {
        switch self {
        case .keychainUnavailable:
            return .localized("Credential migration is waiting for Keychain access. Unlock the device and retry the original action. Existing credentials have not been discarded.")
        case .accessUnavailable:
            return .localized("Credential migration cannot access its files. Unlock the device and retry; if the warning continues, review file access. Unmigrated originals are retained.")
        case .storageFull:
            return .localized("Credential migration needs more storage. Free space and retry the original action. Unmigrated originals are retained.")
        case .needsAttention:
            return .localized("Credential migration could not finish. Retry the original action; if the warning continues, review certificate storage and Keychain access. Do not delete the original credentials.")
        }
    }
}

/// Session-only, allowlisted warnings. No paths, passwords, certificate names,
/// raw errors or account identifiers are exposed in UI/log output.
@MainActor
final class CredentialMigrationDiagnostics: ObservableObject {
    static let shared = CredentialMigrationDiagnostics()
    @Published private(set) var warnings: [CredentialMigrationIssue] = []
    private var issues: [String: CredentialMigrationIssue] = [:]

    enum Source: String, Sendable { case certificateFiles, certificatePassword }

    // All updates use the main dispatch queue, preserving submission order from
    // each serialized migration caller without introducing unchecked Sendable.
    nonisolated static func report(source: Source, id: String = "managed", issue: CredentialMigrationIssue?) {
        DispatchQueue.main.async { shared.update(source: source, id: id, issue: issue) }
    }

    func update(source: Source, id: String, issue: CredentialMigrationIssue?) {
        let key = "\(source.rawValue):\(id)"
        guard issues[key] != issue else { return }
        issues[key] = issue
        warnings = CredentialMigrationIssue.allCases.filter { Set(issues.values).contains($0) }
        if let issue {
            Logger.misc.warning("Credential migration requires attention: \(issue.rawValue, privacy: .public)")
        }
    }
}
