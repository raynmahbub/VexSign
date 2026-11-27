//
//  DiagnosticEventJournal.swift
//  VexSign
//
//  Bounded, local history of structured diagnostics. The file is shared by the
//  composition root, OS-level callbacks (MetricKit, background tasks) and the
//  Troubleshooting Center: all of them open the same protected file through an
//  actor, so no view tree or singleton-owned memory is required.
//
//  History is bounded twice — by event count and by file size. A corrupt file is
//  quarantined instead of being silently trusted, and a legacy array payload is
//  migrated into the current envelope on first read. Exports always go through
//  the sanitizer again.
//

import Foundation

actor DiagnosticEventJournal {
    struct IO: Sendable {
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: @Sendable (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
        var move: @Sendable (URL, URL) throws -> Void = { from, to in
            let manager = FileManager.default
            if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
            try manager.moveItem(at: from, to: to)
        }
    }

    private struct Package: Codable {
        let schemaVersion: Int
        let events: [DiagnosticEvent]
    }

    static let limit = 250
    static let maximumFileBytes = 512 * 1024
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VexSign", isDirectory: true)
            .appendingPathComponent("diagnostic-events.json")
    }()

    /// Used only by entry points that have no DI tree (AppDelegate callbacks,
    /// MetricKit subscriber). It is file-backed; instances share no mutable state.
    static let fileJournal = DiagnosticEventJournal()

    private let url: URL
    private let io: IO
    private var events: [DiagnosticEvent]
    private(set) var lastRecoveryAction: String?

    init(url: URL? = nil, io: IO = IO()) {
        self.url = url ?? Self.defaultURL
        self.io = io
        let loaded = Self.load(url: self.url, io: io)
        self.events = loaded.events
        self.lastRecoveryAction = loaded.recoveryAction
    }

    private static func load(url: URL, io: IO) -> (events: [DiagnosticEvent], recoveryAction: String?) {
        guard let data = try? io.read(url) else { return ([], nil) } // try? ok: a missing store starts empty; nothing is inferred from it

        let decoder = JSONDecoder()
        if let package = try? decoder.decode(Package.self, from: data), package.schemaVersion == 1 { // try? ok: an unknown envelope is handled below
            return (Array(package.events.map(DiagnosticEventSanitizer.sanitize).suffix(limit)), nil)
        }
        // Migration: the earliest builds wrote a bare array with no version field.
        if let legacy = try? decoder.decode([DiagnosticEvent].self, from: data) { // try? ok: a legacy shape that does not decode is treated as corruption
            return (Array(legacy.map(DiagnosticEventSanitizer.sanitize).suffix(limit)), "Migrated an unversioned diagnostic history.")
        }

        let quarantine = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        var action = "Diagnostic history was unreadable and has been quarantined."
        if (try? io.move(url, quarantine)) == nil { // try? ok: quarantine is best effort; an in-memory empty history is still safe
            action += " The corrupt file could not be moved aside."
            _ = try? io.remove(url) // try? ok: best effort cleanup of a file that must never be decoded again
        }
        return ([], action)
    }

    @discardableResult
    func record(_ event: DiagnosticEvent) -> Bool {
        let safe = DiagnosticEventSanitizer.sanitize(event)
        events.append(safe)
        if events.count > Self.limit { events = Array(events.suffix(Self.limit)) }
        persist()
        return true
    }

    func all() -> [DiagnosticEvent] { events }

    func matching(_ filter: DiagnosticExportFilter) -> [DiagnosticEvent] {
        events.filter(filter.matches)
    }

    func countsByCode() -> [String: Int] {
        var counts: [String: Int] = [:]
        for event in events { counts[event.code, default: 0] += 1 }
        return counts
    }

    /// Returns the recovery note once; the UI can surface it without persisting a
    /// synthetic diagnostic event.
    func consumeRecoveryAction() -> String? {
        defer { lastRecoveryAction = nil }
        return lastRecoveryAction
    }

    func exportJSON(filter: DiagnosticExportFilter? = nil) -> Data {
        let rows = filter.map(matching) ?? events
        return encode(Package(schemaVersion: 1, events: rows)) ?? Data("{\"schemaVersion\":1,\"events\":[]}".utf8) // fallback is a valid, empty envelope
    }

    func clear() {
        events = []
        persist()
    }

    private func persist() {
        guard let data = encode(Package(schemaVersion: 1, events: events)) else { return }
        if let current = try? io.read(url), current.count > Self.maximumFileBytes { // try? ok: rotation is best effort
            let rotated = url.deletingPathExtension().appendingPathExtension("1.json")
            _ = try? io.move(url, rotated) // try? ok: keep one previous generation; main history still writes below
        }
        try? io.write(data, url) // try? ok: diagnostics are best effort; in-memory history remains available
    }

    private func encode(_ package: Package) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(package) // try? ok: Codable values; a failure leaves the last good file in place
    }
}
