//
//  OperationOutcome.swift
//  VexSign
//
//  One recorded outcome of one stage of one operation.
//
//  A success at stage N says only that stage N finished. It is not a claim about
//  later stages, and it is not device evidence. Reasons are sanitized before they
//  reach this value: an exportable diagnostic must never carry an account name,
//  a private path, a UUID or a credential.
//

import Foundation

/// One injected recorder for a stage outcome. Composition owns the journal; services
/// receive this closure instead of creating another store or reaching for a singleton.
typealias OperationOutcomeRecording = @MainActor (OperationOutcomeRecord) async -> Void

enum OperationOutcomeStatus: String, Codable, CaseIterable, Sendable {
    case succeeded
    /// Work finished, but the available evidence does not establish the result.
    /// Used for an install handed to iOS without a device reading.
    case unconfirmed
    case failed
    case cancelled
}

struct OperationOutcomeRecord: Codable, Equatable, Identifiable, Sendable {
    let correlationID: String
    let operation: String
    let stage: String
    let status: OperationOutcomeStatus
    var reason: String?
    let startedAt: Date
    let finishedAt: Date

    var id: String {
        "\(correlationID)|\(operation)|\(stage)|\(finishedAt.timeIntervalSince1970)"
    }
}

enum OperationOutcomeSanitizer {
    /// The final guard on text that a user can export. Deliberately narrow: it removes
    /// identifiers and secret-bearing forms, keeps error codes and ordinary wording.
    static func reason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\r", with: " ")
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern.rule, options: [.caseInsensitive]) else { continue } // try? ok: an invalid static rule is skipped; the remaining rules still sanitize
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: pattern.replacement)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(240))
    }

    private static let patterns: [(rule: String, replacement: String)] = [
        (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, LogRedactionMarker.value),
        (#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, LogRedactionMarker.value),
        (#"(password|passwd|passphrase|token|secret|authorization)\s*[:=]\s*\S+"#, "$1=\(LogRedactionMarker.value)"),
        (#"(?:file://)?/(?:private/)?var/(?:mobile|containers)/[^\s]+"#, LogRedactionMarker.value),
        (#"https?://[^/\s:]+:[^/\s@]+@"#, "\(LogRedactionMarker.value)@")
    ]
}

/// Plain marker kept here so the pure model does not import a diagnostics module.
private enum LogRedactionMarker {
    static let value = "<redacted>"
}
