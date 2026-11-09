//
//  RepositorySnapshotCache.swift
//  VexSign
//
//  Offline repository cache: keeps the raw JSON of every successfully
//  loaded repository on disk so the App Store can be browsed with no
//  network at all. A snapshot is only ever replaced by a *successful*
//  refresh, so a failing source keeps its last-known-good catalog
//  instead of blanking out.
//
//  Snapshots are plain catalog JSON (already fetched over HTTPS) — they
//  contain no credentials, cookies or headers.
//

import Foundation
import CryptoKit
import AltSourceKit
import OSLog

enum RepositorySnapshotCache {
	private static let directoryName = "SourceSnapshots"
	private static let maxSnapshots = 64

	/// Envelope stored on disk next to the payload.
	private struct Envelope: Codable {
		var identifier: String
		var sourceURL: String?
		var savedAt: Date
		var payload: Data
	}

	// MARK: - Paths

	private static var cacheDirectory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent(directoryName, isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // try? ok: best-effort cache directory; store() logs any write failure
		return dir
	}

	/// Legacy lossy filename, retained only to read snapshots written by older versions.
	private static func _legacyFileName(for id: String) -> String {
		let allowed = id.unicodeScalars.map { scalar -> Character in
			if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
				return Character(scalar)
			}
			return "_"
		}
		let name = String(allowed).suffix(120)
		return name.isEmpty ? "source" : String(name)
	}

	/// Stable, collision-resistant filename for an arbitrary source identifier.
	private static func _fileName(for id: String) -> String {
		SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	private static func _url(for id: String) -> URL {
		cacheDirectory.appendingPathComponent("\(_fileName(for: id)).snapshot-v2.json")
	}

	private static func _legacyURL(for id: String) -> URL {
		cacheDirectory.appendingPathComponent(_legacyFileName(for: id)).appendingPathExtension("snapshot.json")
	}

	// MARK: - API

	/// Saves the raw catalog JSON for a source. Never throws into the caller's
	/// flow — a failed snapshot write must not fail a successful refresh.
	static func store(identifier: String, sourceURL: URL?, payload: Data) {
		let envelope = Envelope(
			identifier: identifier,
			sourceURL: sourceURL?.absoluteString,
			savedAt: Date(),
			payload: payload
		)
		do {
			let encoder = JSONEncoder()
			let data = try encoder.encode(envelope)
			try data.write(to: _url(for: identifier), options: .atomic)
			_evictIfNeeded()
		} catch {
			Logger.misc.warning("Snapshot write failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Loads the last stored snapshot for a source, if one exists.
	/// Legacy lossy paths are accepted only when their envelope names this exact identifier.
	static func load(identifier: String) -> (repository: ASRepository, savedAt: Date)? {
		for url in [_url(for: identifier), _legacyURL(for: identifier)] {
			guard let data = try? Data(contentsOf: url), // try? ok: optional snapshot read; a miss falls back to the network
			      let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { // try? ok: optional snapshot decode; corrupt or missing is treated as a miss
				continue
			}
			guard envelope.identifier == identifier else { continue }
			do {
				let repository = try JSONDecoder().decode(ASRepository.self, from: envelope.payload)
				return (repository, envelope.savedAt)
			} catch {
				// Corrupt snapshot — remove it so it can't resurface.
				try? FileManager.default.removeItem(at: url) // try? ok: best-effort removal of a corrupt snapshot
			}
		}
		return nil
	}

	/// The date of the stored snapshot, without decoding the payload.
	static func snapshotDate(for identifier: String) -> Date? {
		for url in [_url(for: identifier), _legacyURL(for: identifier)] {
			guard let data = try? Data(contentsOf: url), // try? ok: optional snapshot read for the saved date
			      let envelope = try? JSONDecoder().decode(Envelope.self, from: data), // try? ok: optional snapshot decode; corrupt or missing is treated as a miss
			      envelope.identifier == identifier else {
				continue
			}
			return envelope.savedAt
		}
		return nil
	}

	/// Removes the snapshot of a deleted source.
	static func remove(identifier: String) {
		let current = _url(for: identifier)
		try? FileManager.default.removeItem(at: current) // try? ok: best-effort removal of a deleted source's snapshot

		let legacy = _legacyURL(for: identifier)
		guard legacy != current,
		      let data = try? Data(contentsOf: legacy), // try? ok: optional lookup before removing a legacy cache file
		      let envelope = try? JSONDecoder().decode(Envelope.self, from: data), // try? ok: optional lookup; never remove a collision owned by another source
		      envelope.identifier == identifier else {
			return
		}
		try? FileManager.default.removeItem(at: legacy) // try? ok: best-effort removal of this source's legacy snapshot
	}

	/// Drops snapshots for every source that is no longer installed.
	static func retainOnly(identifiers: Set<String>) {
		let fm = FileManager.default
		guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { // try? ok: best-effort enumeration; skip retention when the cache is unreadable
			return
		}
		for file in files where file.pathExtension == "json" {
			guard let data = try? Data(contentsOf: file), // try? ok: skip an unreadable snapshot during retention
			      let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { // try? ok: optional snapshot decode; corrupt or missing is treated as a miss
				continue
			}
			if !identifiers.contains(envelope.identifier) {
				try? fm.removeItem(at: file) // try? ok: best-effort retention cleanup
			}
		}
	}

	/// Simple size cap: when the snapshot count exceeds `maxSnapshots`, the
	/// oldest files (by modification date) are dropped.
	private static func _evictIfNeeded() {
		let fm = FileManager.default
		guard let files = try? fm.contentsOfDirectory( // try? ok: best-effort enumeration for eviction
			at: cacheDirectory,
			includingPropertiesForKeys: [.contentModificationDateKey]
		) else { return }
		let snapshots = files.filter { $0.pathExtension == "json" }
		guard snapshots.count > maxSnapshots else { return }

		let sorted = snapshots.sorted { lhs, rhs in
			let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast // try? ok: best-effort modification date; distantPast when unavailable
			let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast // try? ok: best-effort modification date; distantPast when unavailable
			return lhsDate < rhsDate
		}
		for stale in sorted.prefix(snapshots.count - maxSnapshots) {
			try? fm.removeItem(at: stale) // try? ok: best-effort eviction of the oldest snapshots
		}
	}
}
