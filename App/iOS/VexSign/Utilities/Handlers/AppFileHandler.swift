//
//  IPAHandler.swift
//  VexSign
//
//  Created by VexSign Contributors on 11.04.2025.
//

import Foundation
import CoreData
import SwiftUI
import OSLog

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	/// Says, for as long as this import lives, that the copy `_uuid` names is being produced. Its
	/// payload is in the library before its row is, and without this a cleanup pass in between
	/// takes the folder for a leftover and deletes it.
	private let _importClaim: AppOperationRegistry.Lease
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	/// Captured before `copy()` relocates `_ipa`, so errors name the file the user shared.
	private let _fileName: String
	private let _install: Bool
	private let _download: Download?
	private let _appDescription: String?
	private var _didAddToDatabase = false

	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil
	) {
		self._ipa = ipa
		self._fileName = ipa.lastPathComponent
		self._install = install
		self._download = download
		self._appDescription = download?.appDescription
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("VexSignImport_\(_uuid)", isDirectory: true)
		self._importClaim = AppOperationRegistry.shared.claimProduction(of: _uuid)

		super.init()
		Logger.misc.debug("Import initiated for: \(self._ipa.lastPathComponent) with ID: \(self._uuid)")
	}

	/// Builds a detailed, copyable error tagged with the failing step.
	private func _error(_ step: ImportError.Step, reason: String, underlying: Error? = nil) -> ImportError {
		ImportError(step, fileName: _fileName, id: _uuid, reason: reason, underlying: underlying)
	}

	func copy() async throws {
        try _download?.importControl.checkpoint()
        try Task.checkCancellation()
		do {
			try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)

			let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

			try _fileManager.removeFileIfNeeded(at: destinationURL)

			guard _fileManager.fileExists(atPath: _ipa.path) else {
				Logger.misc.error("[\(self._uuid)] Source file does not exist: \(self._ipa.path)")
				throw _error(.copy, reason: "The source file no longer exists. It may have been moved or removed before the import finished.")
			}

			// Preflight storage: fail clearly instead of mid-write on a huge IPA.
			try _checkDiskSpace()

			try _fileManager.copyItem(at: _ipa, to: destinationURL)
            _ipa = destinationURL
            try _download?.importControl.checkpoint()
            try Task.checkCancellation()
			Logger.misc.info("[\(self._uuid)] File copied to: \(self._ipa.path)")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportError {
            throw error
        } catch {
			Logger.misc.error("[\(self._uuid)] Copy failed: \(error.localizedDescription)")
			throw _error(.copy, reason: error.localizedDescription, underlying: error)
		}
	}

	/// Requires headroom beyond the archive size (IPA is written several times: temp copy →
	/// unzip → Unsigned). Best-effort: proceeds if size or capacity can't be read.
	private func _checkDiskSpace() throws {
		guard
			let fileSize = try? _ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize,
			fileSize > 0,
			let available = _fileManager.availableImportantCapacity(at: _uniqueWorkDir)
		else {
			return
		}

		// Copy (~1x) + extracted payload (~1x) + safety margin.
		let required = Int64(fileSize) * 3
		guard available < required else { return }

		let needMB = required / 1_048_576
		let freeMB = available / 1_048_576
		Logger.misc.error("[\(self._uuid)] Insufficient space: need ~\(needMB)MB, have \(freeMB)MB")
		throw _error(
			.diskSpace,
			reason: "Not enough free storage to import this app. About \(needMB) MB is needed but only \(freeMB) MB is free. Free up space and try again."
		)
	}

    func extract() async throws {
        do {
            try IPAExtractor.extract(_ipa, to: _uniqueWorkDir, checkpoint: {
                try Task.checkCancellation()
                try self._download?.importControl.checkpoint()
            }, progress: { [download = _download] fraction in
                if let download {
                    DispatchQueue.main.async { download.unpackageProgress = fraction }
                }
            })
            uniqueWorkDirPayload = _uniqueWorkDir.appendingPathComponent("Payload")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportError {
            throw error
        } catch {
            Logger.misc.error("[\(self._uuid)] Extract failed: \(error.localizedDescription)")
            throw _error(.extract, reason: error.localizedDescription, underlying: error)
        }
    }

	func move() async throws {
        try _download?.importControl.checkpoint()
        try Task.checkCancellation()
		guard let payloadURL = uniqueWorkDirPayload else {
			Logger.misc.error("[\(self._uuid)] Payload URL is nil")
			throw _error(.payload, reason: "The Payload folder was missing after extraction. The IPA may be malformed.")
		}

		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			Logger.misc.error("[\(self._uuid)] Payload does not exist at: \(payloadURL.path)")
			throw _error(.payload, reason: "The Payload folder was not found on disk after extraction. The IPA may be malformed.")
		}

		do {
			let destinationURL = try await _directory()

			try _fileManager.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())

			try _fileManager.removeFileIfNeeded(at: destinationURL)

			try _fileManager.moveItem(at: payloadURL, to: destinationURL)
            LibrarySizeSnapshot.invalidate()
			Logger.misc.info("[\(self._uuid)] Moved Payload to: \(destinationURL.path)")

			try? _fileManager.removeItem(at: _uniqueWorkDir)
		} catch let error as ImportError {
			throw error
		} catch {
			Logger.misc.error("[\(self._uuid)] Move failed: \(error.localizedDescription)")
			throw _error(.move, reason: error.localizedDescription, underlying: error)
		}
	}

	@discardableResult
	func addToDatabase() async throws -> NSManagedObjectID {
		let app = try await _directory()

		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			Logger.misc.error("[\(self._uuid)] Could not find .app in Payload")
			throw _error(.database, reason: "Could not find the .app bundle inside the Payload folder.")
		}

		guard let bundle = Bundle(url: appUrl) else {
			Logger.misc.error("[\(self._uuid)] Could not create bundle from: \(appUrl.path)")
			throw _error(.database, reason: "The app bundle could not be read. It may be corrupted or incomplete.")
		}

        try _download?.importControl.checkpoint()
        try Task.checkCancellation()
        if let download = _download {
            try await MainActor.run { try download.importCommitCheckpoint?(self._uuid, false) }
        }
        try _download?.importControl.beginCommit()
        let objectID: NSManagedObjectID
        do {
            // The write runs on the storage write context and returns an object ID;
			// the row itself is resolved below on the view context. This used to be
			// a continuation with a 10 second watchdog, because inserting on the view
			// context from a detached task could block the main queue - the write
			// boundary removes that failure mode instead of timing out around it.
			objectID = try await Storage.shared.addImported(
				uuid: _uuid,
				appName: bundle.name,
				appIdentifier: bundle.bundleIdentifier,
				appVersion: bundle.version,
				appIcon: bundle.iconFileName,
				appDescription: _appDescription
			)
			Logger.misc.info("[\(self._uuid)] Added to database")
		} catch {
			Logger.misc.error("[\(self._uuid)] Database add failed: \(error.localizedDescription)")
			throw _error(.database, reason: error.localizedDescription, underlying: error)
		}

		_didAddToDatabase = true
		// A cleanup pass that read the library before this commit does not know the row, and
		// the claim ends with this import.
		AppOperationRegistry.shared.confirmProduction(of: _uuid)
        if let download = _download {
            // The callback swallows post-commit persistence failure, keeping the UUID checkpoint.
            try await MainActor.run { try download.importCommitCheckpoint?(self._uuid, true) }
        }

        return objectID
    }

    /// Resolve on the view context only when delivering the main-actor result.
    /// Managed objects must never cross MainActor.run's Sendable result boundary.
    @MainActor
    func importedApp(for objectID: NSManagedObjectID) throws -> AppInfoPresentable {
        guard let imported: Imported = Storage.shared.object(objectID) else {
            throw _error(.database, reason: "The app was saved but could not be read back from the library.")
        }
        return imported
    }

	private func _directory() async throws -> URL {
		// Documents/App/iOS/VexSign/Unsigned/\(UUID)
		_fileManager.unsigned(_uuid)
	}

	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
		// A moved-but-unregistered payload is unreachable from the library, so it would leak forever.
		if !_didAddToDatabase {
			try? _fileManager.removeFileIfNeeded(at: _fileManager.unsigned(_uuid))
		}
	}
}

/// Copyable error naming which import step failed; `errorDescription` is the support-friendly
/// text shown to the user, with a reference id to correlate with on-device logs.
struct ImportError: LocalizedError {
	enum Step: String {
		case copy      = "Copying file"
		case diskSpace = "Checking storage"
		case extract   = "Extracting IPA"
		case payload   = "Reading Payload"
		case move      = "Saving app files"
		case database  = "Adding to library"
	}

	let step: Step
	let fileName: String
	let id: String
	let reason: String
	/// Underlying system error, surfaced as domain/code for support.
	let underlying: NSError?

	init(_ step: Step, fileName: String, id: String, reason: String, underlying: Error? = nil) {
		self.step = step
		self.fileName = fileName
		self.id = id
		self.reason = reason
		self.underlying = underlying as NSError?
	}

	var errorDescription: String? {
		var lines: [String] = [
			reason,
			"",
			"File: \(fileName)",
			"Step: \(step.rawValue)"
		]
		if let underlying = underlying {
			// The domain and code alone are not diagnosable: every archive-safety
			// rejection shares one domain, and the message is what names the offending
			// entry ("unsupported symbolic link: Payload/…"). Keep both, so a report
			// says what happened as well as where it came from.
			let detail = underlying.localizedDescription
			if !detail.isEmpty, detail != reason {
				lines.append("Detail: \(detail)")
			}
			lines.append("Source: \(underlying.domain) (\(underlying.code))")
		}
		lines.append("Ref: \(id)")
		return lines.joined(separator: "\n")
	}
}
