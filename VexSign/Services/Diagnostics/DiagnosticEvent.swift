//
//  DiagnosticEvent.swift
//  VexSign
//
//  One structured, exportable diagnostic fact.
//
//  This is deliberately a *model*, not a second error hierarchy: `VexSignError` and
//  `OperationOutcomeRecord` remain the domain errors, and this type is the flat,
//  sanitized representation that can be logged, shown in the Troubleshooting
//  Center and written to an export. Every field is either a fixed code or a
//  bounded, redacted string — nothing here can carry a raw error, a private URL
//  or a free-form path out of the app.
//

import Foundation
import NimbleExtensions

enum DiagnosticSeverity: String, Codable, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
    case fault
}

enum DiagnosticCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case app
    case signing
    case ipa
    case download
    case network
    case device
    case installation
    case background
    case automation
    case security
    case storage
    case diagnostics
    case metricKit

    var id: String { rawValue }

    /// The subsystem written to OSLog for this category. A single stable prefix
    /// keeps `log show` predicates useful across the whole app.
    var subsystem: String { "app.vexsign.\(rawValue)" }
}

/// Stable, machine-readable identifiers for known diagnostic conditions. The
/// code never changes when wording changes; `eventID` identifies one occurrence.
enum DiagnosticEventCode {
    static let appLaunched = "VEX-APP-001"
    static let appHealth = "VEX-APP-002"
    static let signFailed = "VEX-SIGN-001"
    static let signSucceeded = "VEX-SIGN-002"
    static let importFailed = "VEX-IPA-001"
    static let importSucceeded = "VEX-IPA-002"
    static let downloadFailed = "VEX-DOWN-001"
    static let downloadSucceeded = "VEX-DOWN-002"
    static let networkFailure = "VEX-NET-001"
    static let deviceFailure = "VEX-DEV-001"
    static let installFailed = "VEX-INS-001"
    static let installUnconfirmed = "VEX-INS-002"
    static let taskFailed = "VEX-TASK-001"
    static let taskCancelled = "VEX-TASK-002"
    static let backgroundFailure = "VEX-BG-001"
    static let automationFailure = "VEX-AUTO-001"
    static let securityFailure = "VEX-SEC-001"
    static let storageFailure = "VEX-STO-001"
    static let diagnosticStoreRecovered = "VEX-DIAG-001"
    static let performanceMeasurement = "VEX-PERF-001"
    static let metricKitCrash = "VEX-MK-001"
    static let metricKitHang = "VEX-MK-002"
    static let metricKitCPU = "VEX-MK-003"
    static let metricKitLaunch = "VEX-MK-004"
    static let metricKitDisk = "VEX-MK-005"
}

struct DiagnosticEvent: Codable, Equatable, Sendable, Identifiable {
    /// Bumped only when an old on-disk record needs a migration.
    var schemaVersion: Int
    /// Unique per occurrence; use `code` to group occurrences of one condition.
    var eventID: String
    var code: String
    var severity: DiagnosticSeverity
    var category: DiagnosticCategory
    var subsystem: String
    /// Correlation ID shared with task-center / operation-outcome records.
    var operationID: String?
    var timestamp: Date
    var userMessage: String
    var developerDetail: String?
    var recoverySuggestion: String?
    /// Flat, redacted, length-bounded values only. No nested objects or raw errors.
    var metadata: [String: String]

    var id: String { eventID }

    static func make(
        code: String,
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        operationID: String? = nil,
        timestamp: Date = Date(),
        userMessage: String,
        developerDetail: String? = nil,
        recoverySuggestion: String? = nil,
        metadata: [String: String] = [:],
        eventID: String = UUID().uuidString.lowercased()
    ) -> DiagnosticEvent {
        let event = DiagnosticEvent(
            schemaVersion: 1,
            eventID: eventID,
            code: code,
            severity: severity,
            category: category,
            subsystem: category.subsystem,
            operationID: operationID,
            timestamp: timestamp,
            userMessage: userMessage,
            developerDetail: developerDetail,
            recoverySuggestion: recoverySuggestion,
            metadata: metadata
        )
        return DiagnosticEventSanitizer.sanitize(event)
    }
}

/// The last guard before an event reaches a file, a view or a zip. Every
/// constructor and every store applies it, so a caller cannot bypass it.
enum DiagnosticEventSanitizer {
    static let maximumTextLength = 240
    static let maximumDetailLength = 600
    static let maximumMetadataEntries = 12
    static let maximumMetadataKeyLength = 48
    static let maximumMetadataValueLength = 160

    static func sanitize(_ event: DiagnosticEvent) -> DiagnosticEvent {
        var result = event
        result.eventID = safeIdentifier(event.eventID, fallback: UUID().uuidString.lowercased())
        result.code = safeIdentifier(event.code, fallback: DiagnosticEventCode.appHealth)
        result.schemaVersion = 1
        result.operationID = event.operationID.flatMap { safeIdentifier($0, fallback: nil) }
        result.subsystem = event.category.subsystem
        result.userMessage = text(event.userMessage, limit: maximumTextLength) ?? "An operation could not be completed."
        result.developerDetail = text(event.developerDetail, limit: maximumDetailLength)
        result.recoverySuggestion = text(event.recoverySuggestion, limit: maximumDetailLength)
        result.metadata = metadata(event.metadata)
        if !result.timestamp.timeIntervalSince1970.isFinite {
            result.timestamp = Date()
        }
        return result
    }

    /// Redacts first (so a secret cannot be split across a truncation boundary),
    /// then folds control characters and bounds the length.
    static func text(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let redacted = LogRedaction.redact(raw)
        let flattened = redacted
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
        let cleaned = flattened.unicodeScalars.map { scalar -> String in
            (scalar.value < 0x20 || scalar.value == 0x7F) ? " " : String(scalar)
        }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    static func metadata(_ raw: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in raw.keys.sorted() {
            guard let cleanKey = text(key, limit: maximumMetadataKeyLength),
                  cleanKey.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
                  result.count < maximumMetadataEntries,
                  let value = text(raw[key], limit: maximumMetadataValueLength) else { continue }
            result[cleanKey] = value
        }
        return result
    }

    private static func safeIdentifier(_ raw: String, fallback: String?) -> String? {
        guard raw.count <= 96,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
              !raw.isEmpty else { return fallback }
        return raw
    }
}

/// Recovery text is static and describes controls that already exist in the app.
/// It never embeds an error string, path or account detail.
enum DiagnosticRecoveryGuide {
    static func suggestion(for code: VexSignError.Code) -> String {
        switch code {
        case .certificateExpired, .certificateRevoked, .certificateNotFound, .certificateImportFailed:
            return "Open Certificates and import a current signing certificate, then retry."
        case .certificatePasswordInvalid, .keychainOperationFailed, .provisioningProfileInvalid:
            return "Check the certificate password or provisioning profile in Certificates, then retry."
        case .signingFailed, .signingBusy, .preflightFailed, .entitlementsMismatch, .bundleIdMismatch, .teamIdMismatch:
            return "Review the signing preflight result, then retry the task from Task Center."
        case .deviceUnreachable, .pairingFileInvalid, .pairingFileMissing, .httpsTrustRequired:
            return "Unlock the device, trust this computer, confirm HTTPS pairing and reconnect, then retry."
        case .installationFailed, .installationCancelled, .installationUnconfirmed, .installationNeverStarted:
            return "Check the device connection in Devices and retry the install from Install Queue."
        case .downloadFailed, .downloadCancelled, .downloadPaused:
            return "Check the network connection and retry the download from Downloads."
        case .downloadSizeExceeded, .archiveSizeExceeded, .diskSpaceInsufficient:
            return "Free storage space or choose a smaller package, then retry."
        case .downloadIntegrityFailed, .archiveInvalid, .archiveExtractionFailed, .archiveUnsafePath:
            return "Re-download the IPA from its source and import the fresh file."
        case .sourceUnreachable, .sourceAuthFailed, .sourceRateLimited, .sourceInvalidFormat, .appNotFoundInSource:
            return "Refresh the affected source in Repositories and retry."
        case .networkUnavailable, .networkTimeout, .serverError, .invalidResponse:
            return "Check connectivity and retry; a source may also be temporarily unavailable."
        case .backupCorrupt, .backupPasswordInvalid, .backupCreationFailed, .backupRestoreFailed:
            return "Open Backup & Restore and choose a valid backup with its original password."
        case .permissionDenied, .privacyServicesDenied:
            return "Enable the requested permission in iOS Settings, then return to VexSign."
        case .storeUnavailable, .storeCorrupt, .storeMigrationFailed, .entityNotFound:
            return "Restart VexSign. If it persists, export a diagnostic bundle from Troubleshooting Center."
        case .tweakNotFound, .tweakInjectionFailed, .tweakDependencyMissing, .elleKitNotFound:
            return "Review the tweak selection and injection option in signing options, then retry."
        case .signingCancelled, .operationCancelled, .operationTimeout:
            return "No change was made. Retry the operation when ready."
        case .unknown:
            return "Export a diagnostic bundle from Troubleshooting Center and retry the operation."
        }
    }
}

extension DiagnosticEvent {
    /// One structured record for a failure that only physical hardware can produce.
    ///
    /// Every value is bounded and redacted by `DiagnosticEventSanitizer`; the UDID,
    /// pairing file, certificate and private key are never passed in. Callers provide
    /// only the state and category needed to triage the operation later.
    static func deviceFailure(
        operationID: String?,
        operationType: String,
        connectionState: String,
        failureCategory: String,
        systemErrorCode: String?,
        durationMs: Int,
        recoveryOutcome: String,
        deviceModel: String?,
        osVersion: String?,
        userMessage: String,
        timestamp: Date = Date()
    ) -> DiagnosticEvent {
        let code = Self.bounded(systemErrorCode, limit: 32)
        return .make(
            code: DiagnosticEventCode.deviceFailure,
            severity: .error,
            category: .device,
            operationID: operationID,
            timestamp: timestamp,
            userMessage: userMessage,
            developerDetail: String.localized(
                "Device operation %@ failed in state %@ (%@) after %lld ms.",
                arguments: operationType, connectionState, failureCategory, Int64(durationMs)
            ),
            recoverySuggestion: recoveryOutcome,
            metadata: [
                "operationType": Self.bounded(operationType, limit: 48),
                "connectionState": Self.bounded(connectionState, limit: 48),
                "failureCategory": Self.bounded(failureCategory, limit: 48),
                "systemErrorCode": code ?? "unavailable",
                "durationMs": String(max(0, durationMs)),
                "recoveryOutcome": Self.bounded(recoveryOutcome, limit: 120) ?? "none",
                "deviceModel": Self.bounded(deviceModel, limit: 48) ?? "unknown",
                "osVersion": Self.bounded(osVersion, limit: 32) ?? "unknown",
                "appVersion": VexSignBuildInfo.version,
                "appBuild": VexSignBuildInfo.build
            ]
        )
    }

    private static func bounded(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }
}
