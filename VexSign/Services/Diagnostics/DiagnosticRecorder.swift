//
//  DiagnosticRecorder.swift
//  VexSign
//
//  The narrow write interface used by services. It is a closure, so tests can
//  collect events in memory and the composition root owns the real journal.
//

import Foundation
import OSLog

struct DiagnosticExportFilter: Sendable {
    var categories: Set<DiagnosticCategory>?
    var from: Date?
    var to: Date?
    var operationID: String?

    var isUnfiltered: Bool {
        categories == nil && from == nil && to == nil && operationID == nil
    }

    func matches(_ event: DiagnosticEvent) -> Bool {
        if let categories, !categories.contains(event.category) { return false }
        if let from, event.timestamp < from { return false }
        if let to, event.timestamp > to { return false }
        if let operationID, event.operationID != operationID { return false }
        return true
    }

    func matches(_ outcome: OperationOutcomeRecord) -> Bool {
        if let categories, !categories.contains(Self.category(for: outcome.operation)) { return false }
        if let operationID, outcome.correlationID != operationID { return false }
        if let from, outcome.finishedAt < from { return false }
        if let to, outcome.finishedAt > to { return false }
        return true
    }

    /// Operation names are the stable stage names already written by the
    /// existing outcome journals; mapping them here lets one category filter
    /// cover both events and outcomes in a filtered export.
    private static func category(for operation: String) -> DiagnosticCategory {
        switch operation {
        case "sign": return .signing
        case "import": return .ipa
        case "install": return .installation
        case "download": return .download
        default: return .app
        }
    }

    var jsonObject: [String: Any] {
        var result: [String: Any] = [:]
        if let categories {
            result["categories"] = categories.map(\.rawValue).sorted()
        }
        if let from { result["from"] = ISO8601DateFormatter().string(from: from) }
        if let to { result["to"] = ISO8601DateFormatter().string(from: to) }
        if let operationID { result["operationID"] = operationID }
        return result
    }
}

struct DiagnosticRecorder: Sendable {
    private let write: @Sendable (DiagnosticEvent) async -> Void

    init(write: @escaping @Sendable (DiagnosticEvent) async -> Void) {
        self.write = write
    }

    /// File-backed default for callers with no view tree (MetricKit callbacks,
    /// AppDelegate background handlers). It reads and writes the same protected
    /// file the injected journal does; it holds no separate in-memory history.
    static let fileRecorder = DiagnosticRecorder { event in
        await DiagnosticEventJournal.fileJournal.record(event)
    }

    func record(_ event: DiagnosticEvent) async {
        let safe = DiagnosticEventSanitizer.sanitize(event)
        emitToUnifiedLog(safe)
        await write(safe)
    }

    /// Records a classified error without duplicating the classification logic:
    /// `VexSignError` stays the single error hierarchy, this is only its flat view.
    func recordError(
        _ error: Error,
        code: String,
        category: DiagnosticCategory,
        operationID: String? = nil,
        userMessage: String? = nil,
        metadata: [String: String] = [:]
    ) async {
        let classified = ErrorBoundary.classify(error)
        let safeReason = OperationOutcomeSanitizer.reason(error.localizedDescription) ?? "The operation could not be completed."
        await record(.make(
            code: code,
            severity: .error,
            category: category,
            operationID: operationID,
            userMessage: userMessage ?? safeReason,
            developerDetail: "\(classified.code.rawValue): \(safeReason)",
            recoverySuggestion: DiagnosticRecoveryGuide.suggestion(for: classified.code),
            metadata: metadata.merging(["errorCode": classified.code.rawValue]) { _, new in new }
        ))
    }

    private func emitToUnifiedLog(_ event: DiagnosticEvent) {
        let logger = Logger(subsystem: event.subsystem, category: event.category.rawValue)
        let level = Self.logLevel(for: event.severity)
        // Only fixed codes and validated identifiers are public. Dynamic text is
        // private even after redaction: a future caller must not be able to turn
        // a mistake into a public leak just by changing a message.
        logger.log(level: level, "\(event.code, privacy: .public) [\(event.category.rawValue, privacy: .public)] [\(event.operationID ?? "-", privacy: .public)] \(event.userMessage, privacy: .private)")
        if let detail = event.developerDetail {
            logger.log(level: level, "detail: \(detail, privacy: .private)")
        }
    }

    private static func logLevel(for severity: DiagnosticSeverity) -> OSLogType {
        switch severity {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }
}

extension DiagnosticEvent {
    /// Turns an existing outcome into a flat event. This is the bridge between
    /// the operation journal and the diagnostic journal; it does not create a
    /// second source of truth for the outcome itself.
    static func fromOutcome(
        _ outcome: OperationOutcomeRecord,
        category: DiagnosticCategory,
        code: String? = nil,
        recoverySuggestion: String? = nil
    ) -> DiagnosticEvent {
        let resolvedCode = code ?? Self.diagnosticCode(for: outcome.operation, status: outcome.status)
        let severity: DiagnosticSeverity
        switch outcome.status {
        case .succeeded, .unconfirmed: severity = .info
        case .cancelled: severity = .warning
        case .failed: severity = .error
        }
        let duration = max(0, outcome.finishedAt.timeIntervalSince(outcome.startedAt))
        let suggestion = recoverySuggestion ?? (outcome.status == .failed
            ? "Export a diagnostic bundle from Troubleshooting Center and retry the operation."
            : nil)
        return .make(
            code: resolvedCode,
            severity: severity,
            category: category,
            operationID: outcome.correlationID,
            timestamp: outcome.finishedAt,
            userMessage: Self.message(for: outcome),
            developerDetail: outcome.reason,
            recoverySuggestion: suggestion,
            metadata: [
                "operation": outcome.operation,
                "stage": outcome.stage,
                "status": outcome.status.rawValue,
                "durationMs": String(format: "%.1f", duration * 1000)
            ]
        )
    }

    private static func diagnosticCode(for operation: String, status: OperationOutcomeStatus) -> String {
        switch (operation, status) {
        case ("sign", .succeeded): return DiagnosticEventCode.signSucceeded
        case ("sign", _): return DiagnosticEventCode.signFailed
        case ("import", .succeeded): return DiagnosticEventCode.importSucceeded
        case ("import", _): return DiagnosticEventCode.importFailed
        case ("install", .unconfirmed): return DiagnosticEventCode.installUnconfirmed
        case ("install", _): return DiagnosticEventCode.installFailed
        case ("download", .succeeded): return DiagnosticEventCode.downloadSucceeded
        case ("download", _): return DiagnosticEventCode.downloadFailed
        default: return DiagnosticEventCode.appHealth
        }
    }

    private static func message(for outcome: OperationOutcomeRecord) -> String {
        switch outcome.status {
        case .succeeded: return "\(outcome.operation.capitalized) finished."
        case .unconfirmed: return "\(outcome.operation.capitalized) was handed off without device confirmation."
        case .cancelled: return "\(outcome.operation.capitalized) was cancelled."
        case .failed: return "\(outcome.operation.capitalized) failed."
        }
    }
}
