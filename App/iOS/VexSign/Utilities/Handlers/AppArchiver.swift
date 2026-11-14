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
		let zipURL = ipaURL.deletingPathExtension().appendingPathExtension("zip")
		try? fm.removeItem(at: zipURL)
		try ArchiveEngine.zipDirectory(payload, to: zipURL, compression: compression, progress: progress)
		try? fm.removeItem(at: ipaURL)
		try fm.moveItem(at: zipURL, to: ipaURL)
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
