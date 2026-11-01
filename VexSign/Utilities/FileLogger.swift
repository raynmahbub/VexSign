//
//  FileLogger.swift
//  VexSign
//
//  Lightweight append-only logger that writes to the app's Documents folder so a user can
//  pull it over USB (Documents is exposed via UIFileSharingEnabled) or via Web Manager.
//  Mirrors to OSLog. Used to debug signing/tweak issues that otherwise vanish on device.
//

import Foundation
import OSLog

enum FileLogger {
	private static let _queue = DispatchQueue(label: "app.vexsign.filelogger")
	private static let _fm = FileManager.default
	private static let _maxBytes: UInt64 = 2 * 1024 * 1024 // rotate at ~2 MB

	/// `Documents/Logs/vexsign.log`
	static var logFileURL: URL {
		_fm.logs.appendingPathComponent("vexsign.log")
	}

	private static var _rotatedFileURL: URL {
		logFileURL.deletingPathExtension().appendingPathExtension("1.log")
	}

	static func log(_ message: String, category: String = "general") {
		// The single choke point for everything that reaches the file and OSLog: one redaction here
		// covers `SigningLog`, the signing console's mirror and every direct caller.
		let redacted = LogRedaction.redact(message)

		Logger.misc.info("[\(category, privacy: .public)] \(redacted, privacy: .public)")
		let line = "\(_timestamp()) [\(category)] \(redacted)\n"
		_queue.async {
			let url = logFileURL
			do {
				try _fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				_rotateIfNeeded(url)
				if let handle = try? FileHandle(forWritingTo: url) {
					defer { try? handle.close() }
					try handle.seekToEnd()
					handle.write(Data(line.utf8))
				} else {
					try Data(line.utf8).write(to: url, options: .atomic)
				}
			} catch {
				Logger.misc.error("FileLogger write failed: \(error.localizedDescription)")
			}
		}
	}

	static func error(_ message: String, category: String = "general") {
		log("ERROR: \(message)", category: category)
	}

	/// Warnings keep a `WARNING:` marker so `LogParser` classifies them again when the file is
	/// read back (Settings → Activity Logs, the Logs tab).
	static func warn(_ message: String, category: String = "general") {
		log("WARNING: \(message)", category: category)
	}

	/// Current log contents (for an in-app share/export).
	static func read() -> String {
		(try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
	}

	/// Full history including the rotated file, oldest first.
	static func readAll() -> String {
		let rotated = (try? String(contentsOf: _rotatedFileURL, encoding: .utf8)) ?? ""
		return rotated + read()
	}

	static func clear() {
		_queue.async {
			try? _fm.removeItem(at: logFileURL)
			try? _fm.removeItem(at: _rotatedFileURL)
		}
	}

	// MARK: Internal

	private static func _rotateIfNeeded(_ url: URL) {
		guard
			let attrs = try? _fm.attributesOfItem(atPath: url.path),
			let bytes = attrs[.size] as? UInt64,
			bytes > _maxBytes
		else { return }
		let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
		try? _fm.removeItem(at: rotated)
		try? _fm.moveItem(at: url, to: rotated)
	}

	private static func _timestamp() -> String {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime]
		return f.string(from: Date())
	}
}
