//
//  SigningLog.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation

/// The app's single log store, and the reason the Logs tab can be live: everything signed,
/// injected, installed or fetched is appended here (and mirrored to `FileLogger` on disk).
///
/// zsign stdout batches rather than one view update per appended line, so entries are queued
/// and flushed on an interval. Both published arrays are newest first, which is also the order
/// the console renders, so new rows appear at the top without the text view scrolling.
final class SigningLog: ObservableObject {
	static let shared = SigningLog()

	/// This session's entries followed by the tail of the on-disk log — what the Logs tab shows.
	@Published private(set) var entries: [LogEntry] = []

	/// This session only. The signing console sheet renders this, so a signing run is never
	/// mixed in with what previous runs left behind.
	@Published private(set) var sessionEntries: [LogEntry] = []

	/// Historic name for `sessionEntries`; kept so the signing console reads the same as before.
	var lines: [LogEntry] { sessionEntries }

	private static let _maxEntries = 4000
	private static let _flushInterval = 0.08
	/// How much of the rotated file is loaded into the Logs tab. The file holds up to ~2 MB,
	/// which is far more than any console wants to render.
	private static let _historyLimit = 600

	/// Entries from earlier launches, kept apart from `sessionEntries` so `reset()` can drop one
	/// without dropping the other.
	private var _history: [LogEntry] = []
	private var _didLoadHistory = false
	/// Log lines older than this are history; anything at or after it is already in the session.
	private let _sessionStart = Date()

	private let _queue = DispatchQueue(label: "app.vexsign.signinglog")
	private var _pending: [LogEntry] = []
	private var _flushScheduled = false

	private init() {}

	// MARK: - Writing

	/// Clears the console for a new signing run. History stays, so the Logs tab is never blank.
	func reset() {
		_queue.async {
			self._pending.removeAll()
			let history = self._history
			DispatchQueue.main.async {
				self.sessionEntries.removeAll()
				self.entries = history
			}
		}
	}

	func info(_ message: String, category: String = "sign") { _append(.info, message, category: category) }
	func success(_ message: String, category: String = "sign") { _append(.success, message, category: category) }
	func warn(_ message: String, category: String = "sign") { _append(.warn, message, category: category) }
	func error(_ message: String, category: String = "sign") { _append(.error, message, category: category) }

	/// Wipes both consoles and the file on disk.
	func clear() {
		FileLogger.clear()
		_queue.async {
			self._pending.removeAll()
			self._history.removeAll()
			self._didLoadHistory = true
			DispatchQueue.main.async {
				self.sessionEntries.removeAll()
				self.entries = []
			}
		}
	}

	// MARK: - History

	/// Reads the on-disk tail once so the Logs tab opens with context instead of one session.
	/// `force` re-reads it (pull to refresh).
	func loadHistory(force: Bool = false) {
		_queue.async {
			guard force || !self._didLoadHistory else { return }
			self._didLoadHistory = true

			// Entries written during this launch are already in `sessionEntries`; re-parsing the
			// file would show them twice. The 1 s slack absorbs the file's second-resolution stamps.
			let cutoff = self._sessionStart.addingTimeInterval(1)
			let history = LogParser.parseFile(FileLogger.readAll(), limit: Self._historyLimit)
				.filter { entry in
					guard let date = entry.date else { return true }
					return date < cutoff
				}
			self._history = history

			DispatchQueue.main.async {
				self.entries = Array((self.sessionEntries + history).prefix(Self._maxEntries))
			}
		}
	}

	// MARK: - Export

	/// Newest first, one line per entry, ready for the share sheet or the pasteboard.
	func exportText(_ filtered: [LogEntry]? = nil) -> String {
		let formatter = ISO8601DateFormatter()
		return (filtered ?? entries).reversed().map { entry in
			let message = entry.kind == .error
				? "ERROR: \(entry.message)"
				: (entry.kind == .warn ? "WARNING: \(entry.message)" : entry.message)
			guard let date = entry.date else { return message }
			return "\(formatter.string(from: date))  \(message)"
		}.joined(separator: "\n")
	}

	// MARK: - Internal

	private func _append(_ level: LogKind, _ rawMessage: String, category: String) {
		// Same text in the console as in the file: a secret masked in one place and shown in the
		// other would be worse than not masking at all.
		let classified = LogParser.classify(LogRedaction.redact(rawMessage), level: level)
		guard !classified.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

		switch classified.kind {
		case .error:
			FileLogger.error(classified.text, category: category)
		case .warn:
			FileLogger.warn(classified.text, category: category)
		default:
			// Re-add the ">>>" marker so re-parsing the file classifies detail lines the same way.
			let logged = classified.kind == .detail ? ">>> \(classified.text)" : classified.text
			FileLogger.log(logged, category: category)
		}

		let entry = LogEntry(date: Date(), category: category, message: classified.text, kind: classified.kind)

		_queue.async {
			self._pending.append(entry)
			guard !self._flushScheduled else { return }
			self._flushScheduled = true
			self._queue.asyncAfter(deadline: .now() + Self._flushInterval) { self._flush() }
		}
	}

	private func _flush() {
		_flushScheduled = false
		guard !_pending.isEmpty else { return }

		let batch = Array(_pending.reversed())
		_pending.removeAll(keepingCapacity: true)

		DispatchQueue.main.async {
			self.sessionEntries.insert(contentsOf: batch, at: 0)
			if self.sessionEntries.count > Self._maxEntries {
				self.sessionEntries.removeLast(self.sessionEntries.count - Self._maxEntries)
			}

			self.entries.insert(contentsOf: batch, at: 0)
			if self.entries.count > Self._maxEntries {
				self.entries.removeLast(self.entries.count - Self._maxEntries)
			}
		}
	}
}
