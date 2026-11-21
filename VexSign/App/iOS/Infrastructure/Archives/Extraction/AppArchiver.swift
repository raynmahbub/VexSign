//
//  AppArchiver.swift
//  VexSign
//
//  Shared "app bundle -> IPA" zipping, used by the installer and the Web Manager server.
//

import Foundation

enum AppArchiver {
	/// Zips a prepared `Payload/` directory into an IPA at `ipaURL`.
	static func zip(
		payload: URL,
		to ipaURL: URL,
		compression: ArchiveCompression,
		progress: ((Double) -> Void)? = nil
	) throws {
		let fm = FileManager.default
		// Stage beside the destination so publication stays on the same filesystem.
		// A unique name avoids overwriting a user's sibling .zip or another operation's
		// intermediate archive. Never remove the previous output before the new zip
		// has been successfully created.
		let zipURL = ipaURL.deletingLastPathComponent()
			.appendingPathComponent(".VexSignArchive-\(UUID().uuidString).zip")
		defer { try? fm.removeItem(at: zipURL) } // try? ok: failed staging cleanup must not hide the packaging error
		let stagingProgress: ((Double) -> Void)? = progress.map { report in
			{ value in report(min(value, 0.99)) }
		}
		// Archiving is not complete until the staged file is published.
		try ArchiveEngine.zipDirectory(payload, to: zipURL, compression: compression, progress: stagingProgress)
		if fm.fileExists(atPath: ipaURL.path) {
			_ = try fm.replaceItemAt(ipaURL, withItemAt: zipURL)
		} else {
			try fm.moveItem(at: zipURL, to: ipaURL)
		}
		progress?(1)
	}

	/// Wraps an `.app` bundle in `Payload/` and zips it into an IPA at `ipaURL`.
	static func archive(
		appDir: URL,
		to ipaURL: URL,
		compression: ArchiveCompression,
		progress: ((Double) -> Void)? = nil
	) throws {
		let fm = FileManager.default
		let work = fm.uniqueTemporaryDirectory("VexSignArchive")
		let payload = work.appendingPathComponent("Payload")
		defer { try? fm.removeItem(at: work) }

		try fm.createDirectoryIfNeeded(at: payload)
		try fm.copyItem(at: appDir, to: payload.appendingPathComponent(appDir.lastPathComponent))
		try zip(payload: payload, to: ipaURL, compression: compression, progress: progress)
	}
}
