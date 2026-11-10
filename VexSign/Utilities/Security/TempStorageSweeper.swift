//
//  TempStorageSweeper.swift
//  VexSign
//
//  Removes leftover temporary working directories from signing, backup,
//  diagnostics and tweak-import runs that were interrupted (app killed,
//  crash, background expiration). Each flow cleans up after itself in a
//  `defer`, but a hard kill leaves the directory behind — and signing work
//  dirs contain complete app bundles, which is exactly the kind of data that
//  should not sit in temporary storage longer than necessary.
//
//  The sweep only touches well-known prefixes inside the system temporary
//  directory, and only entries older than `maxAge` (default 24h). Age alone
//  does not prove a worker is idle: the cleanup lease and retention policy apply too.
//

import Foundation
import OSLog

enum TempStorageSweeper {
	/// Working-directory prefixes owned by VexSign flows.
	private static let ownedPrefixes = [
		"VexSigning_",   // SigningHandler per-sign work dir
		"VexBackup",     // BackupManager staging/pack/output dirs
		"DiagnosticBundle" // Diagnostics export staging
	]

	static let defaultMaxAge: TimeInterval = 24 * 60 * 60

	/// Sweeps stale VexSign temp directories. Returns the number of removed
	/// entries (0 when nothing qualified). Safe to call on any queue.
	@discardableResult
	static func sweep(maxAge: TimeInterval = TempStorageSweeper.defaultMaxAge,
                      temporaryRoot: URL = FileManager.default.temporaryDirectory,
                      registry: AppOperationRegistry = .shared, now: Date = Date()) -> Int {
        guard let lease = registry.acquireCleanup() else { return 0 }
        defer { withExtendedLifetime(lease) {} }
		let fm = FileManager.default
		let temp = temporaryRoot
		guard let contents = try? fm.contentsOfDirectory(
			at: temp,
			includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
		) else { return 0 }

		let cutoff = now.addingTimeInterval(-maxAge)
		var removed = 0

		for url in contents {
			guard ownedPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) else { continue }
            if TemporaryCleanupPolicy.isRetained(url, temporaryRoot: temp,
                downloadStaging: temp.appendingPathComponent(FileManager.default.downloadStaging.lastPathComponent)) { continue }
			let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
			guard modified < cutoff else { continue }

			do {
				try fm.removeItem(at: url)
				removed += 1
			} catch {
				Logger.security.warning("Temp sweep could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
			}
		}

		if removed > 0 {
			Logger.security.info("Temp sweep removed \(removed, privacy: .public) stale working directories")
		}
		return removed
	}
}
