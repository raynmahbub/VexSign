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
import NimbleExtensions

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
	/// Repository URL, not the package/CDN URL. Kept only as provenance for update matching.
	private let _originURL: URL?
	/// Whether the unpacked payload is a `Payload/` folder rather than the whole work
	/// directory. Only that folder may be moved into the library: the work directory
	/// also holds the copied archive, which must never be stored as app content.
	private var _payloadIsPayloadFolder = true
	private let _appDescription: String?
	private var _didAddToDatabase = false

	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		originURL: URL? = nil
	) {
		self._ipa = ipa
		self._fileName = ipa.lastPathComponent
		self._install = install
		self._download = download
		self._originURL = originURL ?? download?.originURL
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

			// The picker can hand over a `.zip`/`.tipa` whose container is what
			// matters, never its suffix. A gzipped tar has no reader here, so it is
			// named as such instead of failing later as a damaged ZIP.
			try _requireReadableContainer(at: _ipa)

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

	/// Rejects a container this app cannot unpack, before copying it into the
	/// workspace and before extraction fails with an unrelated message.
	private func _requireReadableContainer(at url: URL) throws {
		switch PackageArchiveType.detect(at: url) {
		case .zip:
			return
		case .tarGzip:
			throw _error(.copy, reason: .localized("This archive is compressed as .tar.gz, which VexSign cannot unpack. Extract it and import the .ipa or .tipa inside."))
		case .unsupported, .none:
			// Some providers hand over a zero-byte or still-downloading file; both
			// are reported as unreadable rather than as a broken ZIP.
			throw _error(.copy, reason: .localized("This file is not an IPA, TIPA or ZIP archive. Import the app package exactly as it was downloaded."))
		}
	}

	/// Check the temporary copy separately from extraction. The extractor validates
	/// the ZIP and checks its declared expanded size after the copy has been made;
	/// multiplying the compressed size here can reject a perfectly viable import.
	/// Capacity is advisory and real write errors still propagate through cleanup.
	private func _checkDiskSpace() throws {
		guard let fileSize = try? _ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize,
		      fileSize > 0 else { return }
		do {
			try IPAImportStorage.checkCopy(bytes: Int64(fileSize), at: _uniqueWorkDir)
		} catch let error as StoragePreflight.Insufficient {
			Logger.misc.error("[\(self._uuid)] Insufficient space for IPA copy")
			throw _error(.diskSpace, reason: error.localizedDescription, underlying: error)
		}
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
            // A `.tipa` has no `Payload` folder, so the location is remembered rather
        // than assumed: the work directory holds the payload whatever its layout.
        let payload = _uniqueWorkDir.appendingPathComponent("Payload")
        let payloadIsPresent = _fileManager.fileExists(atPath: payload.path)
        uniqueWorkDirPayload = payloadIsPresent ? payload : _uniqueWorkDir
        _payloadIsPayloadFolder = payloadIsPresent
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
			throw _error(.payload, reason: "The archive could not be located after extraction. Nothing was unpacked into the workspace.")
		}

		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			Logger.misc.error("[\(self._uuid)] Payload does not exist at: \(payloadURL.path)")
			throw _error(.payload, reason: "The unpacked app is missing from disk. The archive may have failed to extract completely.")
		}

		// Do not let filesystem enumeration order choose which app gets imported and
		// signed. A valid IPA has exactly one top-level application bundle; nested
		// apps inside that bundle are not candidates.
		do {
			_ = try IPAImportPayload.validateApplication(in: payloadURL)
		} catch {
			throw _error(.payload, reason: error.localizedDescription, underlying: error)
		}

		do {
			let destinationURL = try await _directory()

			try _fileManager.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())

			try _fileManager.removeFileIfNeeded(at: destinationURL)

			if _payloadIsPayloadFolder {
				try _fileManager.moveItem(at: payloadURL, to: destinationURL)
			} else {
				// No `Payload/` folder: move only the app bundle, so the copy of the
				// original archive does not become part of the library entry. The
				// bundle is checked again after the move, as for a normal IPA.
				let app = try IPAImportPayload.application(in: payloadURL)
				try _fileManager.createDirectoryIfNeeded(at: destinationURL)
				try _fileManager.moveItem(at: app, to: destinationURL.appendingPathComponent(app.lastPathComponent))
			}
            LibrarySizeSnapshot.invalidate()
			Logger.misc.info("[\(self._uuid)] Moved payload to: \(destinationURL.path)")

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

		let appUrl: URL
		do {
			appUrl = try IPAImportPayload.validateApplication(in: app)
		} catch {
			throw _error(.database, reason: error.localizedDescription, underlying: error)
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
				source: _originURL,
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

/// Storage for the compressed temporary copy; expanded bytes are checked by
/// ArchiveSafetyValidator before IPAExtractor writes any archive entries.
enum IPAImportStorage {
    static func checkCopy(bytes: Int64, at destination: URL, available: Int64? = nil) throws {
        try StoragePreflight.check(bytes: bytes, copies: 1, at: destination, available: available)
    }
}

/// Identify the only top-level app before registering an imported IPA. Picking the
/// first match would make a malformed multi-app Payload depend on directory order.
enum IPAImportPayload {
    enum ValidationError: LocalizedError, Equatable {
        case missingApp
        case missingPayload
        case multipleApps
        case invalidApp
        case invalidMetadata
        case invalidIdentifier
        case invalidExecutable

        var errorDescription: String? {
            switch self {
            case .missingApp: return "The archive does not contain an app bundle (.app). Import an IPA, TIPA or a ZIP that holds the app together with its Payload folder."
            case .missingPayload: return "The archive has no Payload folder and no app bundle, so there is nothing to sign. Import the IPA or TIPA exactly as it was downloaded."
            case .multipleApps: return "The archive contains more than one app bundle. Import a package containing one app; split the others into their own imports."
            case .invalidApp: return "The app in the IPA's Payload is not a directory."
            case .invalidMetadata: return "The app's Info.plist is missing or unreadable."
            case .invalidIdentifier: return "The app's Info.plist does not contain a bundle identifier."
            case .invalidExecutable: return "The app's executable is missing, unreadable, or has an unsafe name."
            }
        }
    }

    /// The one app bundle an archive contains, wherever its payload sits.
    ///
    /// This used to read `Payload/` and nothing else. A `.tipa` is an `.ipa` renamed
    /// for AirDrop, so it keeps `Payload/`; but an app shared as a plain `.zip`, or
    /// repacked by a tool that writes the bundle at the top level, was refused as
    /// "does not contain an app bundle in its Payload folder" after a full
    /// extraction, with nothing the user could act on. The standard layout still
    /// wins, then a bundle one folder deep, and the search only runs when neither
    /// applies.
    static func application(in payload: URL) throws -> URL {
        let manager = FileManager.default

        /// App bundles directly inside `directory`, not deeper: a nested watch app or an
        /// app extension inside the bundle is not a second candidate.
        func appsDirectly(in directory: URL) throws -> [URL] {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] // try? ok: unreadable directory holds no app bundle
            return entries.filter { $0.pathExtension.lowercased() == "app" }
        }

        /// The one app among `apps`, refusing the ambiguous cases instead of picking by
        /// directory order.
        func onlyApp(of apps: [URL]) throws -> URL? {
            if apps.count > 1 { throw ValidationError.multipleApps }
            guard let app = apps.first else { return nil }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError.invalidApp
            }
            return app
        }

        /// Every app bundle one folder below `directory`, skipping the metadata folder a
        /// macOS zip adds.
        func appsOneLevelDown(in directory: URL) throws -> [URL] {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] // try? ok: unreadable directory holds no app bundle
            var found: [URL] = []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if entry.lastPathComponent.lowercased() == "__macosx" { continue }
                if let app = try onlyApp(of: try appsDirectly(in: entry)) { found.append(app) }
            }
            return found
        }

        // A standard IPA: `Payload/App.app`.
        if let app = try onlyApp(of: try appsDirectly(in: payload)) { return app }

        // Not the standard layout. A directory *named* `Payload` that exists and is empty is
        // malformed, not a differently packed app: the search must not reach sideways for some
        // unrelated bundle beside it.
        let namedPayload = payload.lastPathComponent == "Payload"
        if namedPayload, manager.fileExists(atPath: payload.path) {
            throw ValidationError.missingApp
        }

        // A `Payload` that was never extracted from the archive means the package is packed
        // differently: a plain `.zip`, a repack, or a tool that wrapped the app in a folder.
        // Those keep the bundle beside the metadata, so the search starts at the directory the
        // extraction produced (`Payload`'s parent) rather than at the missing folder itself.
        let container = namedPayload ? payload.deletingLastPathComponent() : payload

        // Top level: `Root/App.app` beside `iTunesMetadata.plist`.
        if let app = try onlyApp(of: try appsDirectly(in: container)) { return app }

        // One folder deep: `Root/Release/App.app`. Two bundles in different folders are still
        // ambiguous: choosing one by directory order is what this function exists to avoid.
        let nested = try appsOneLevelDown(in: container)
        guard nested.count <= 1 else { throw ValidationError.multipleApps }
        guard let app = nested.first else {
            // Say "no Payload folder" rather than blaming an empty Payload that is not there.
            throw namedPayload ? ValidationError.missingPayload : ValidationError.missingApp
        }
        return app
    }

    /// Check the same minimum bundle metadata needed by the signing pipeline,
    /// before moving an unusable payload into the library. Recheck at registration
    /// because the workspace may have changed after the move.
    static func validateApplication(in payload: URL) throws -> URL {
        let app = try application(in: payload)
        guard let info = SignatureVerifier.readInfo(at: app) else {
            throw ValidationError.invalidMetadata
        }
        guard let identifier = info["CFBundleIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalidIdentifier
        }
        guard SigningInputValidation.executable(in: app) != nil else {
            throw ValidationError.invalidExecutable
        }
        return app
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
