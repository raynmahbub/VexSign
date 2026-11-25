//
//  OperationOutcomeJournal.swift
//  VexSign
//
//  A bounded, local record of what operations did at each stage. It stores only
//  correlation IDs, stage names, statuses, timestamps and sanitized reasons.
//  No app names, identifiers, credentials, paths or raw errors are persisted.
//
//  The journal is an actor created by the composition root. Every instance reads
//  the same protected file, so a diagnostic export sees outcomes written by an
//  earlier instance without a global singleton.
//

import Foundation

actor OperationOutcomeJournal {
    struct IO: Sendable {
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: @Sendable (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static let limit = 200

    private let url: URL
    private let io: IO
    private var records: [OperationOutcomeRecord]

    init(url: URL? = nil, io: IO = IO()) {
        self.url = url ?? Self.defaultURL
        self.io = io
        let decoder = JSONDecoder()
        var loaded: [OperationOutcomeRecord] = []
        if let data = try? io.read(self.url) { // try? ok: a missing or unreadable journal starts empty; no operation is inferred from it
            loaded = (try? decoder.decode([OperationOutcomeRecord].self, from: data)) ?? [] // try? ok: corrupt history is discarded, never trusted as an outcome
        }
        records = Array(loaded.suffix(Self.limit))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VexSign", isDirectory: true)
            .appendingPathComponent("operation-outcomes.json")
    }

    /// Records one stage outcome. Reasons pass the sanitizer again at the boundary,
    /// so a caller cannot smuggle raw text past the model's own guard.
    func record(_ value: OperationOutcomeRecord) {
        var sanitized = value
        sanitized.reason = OperationOutcomeSanitizer.reason(value.reason)
        guard sanitized.correlationID.range(of: #"^[0-9a-fA-F-]{8,40}$"#, options: .regularExpression) != nil,
              !sanitized.operation.isEmpty, !sanitized.stage.isEmpty else { return }
        records.append(sanitized)
        if records.count > Self.limit { records = Array(records.suffix(Self.limit)) }
        persist()
    }

    func all() -> [OperationOutcomeRecord] { records }

    func records(forCorrelationID id: String) -> [OperationOutcomeRecord] {
        records.filter { $0.correlationID == id }
    }

    /// Exportable JSON. Empty history exports an empty array, never a claim.
    func exportJSON() -> Data {
        (try? Self.encoder().encode(records)) ?? Data("[]".utf8) // try? ok: in-memory values are Codable; a failure exports an empty, valid array
    }

    private func persist() {
        guard let data = try? Self.encoder().encode(records) else { return } // try? ok: values are Codable; a failed encode leaves the last good file untouched
        try? io.write(data, url) // try? ok: diagnostics are best-effort; in-memory outcomes remain available for this process
    }
}
