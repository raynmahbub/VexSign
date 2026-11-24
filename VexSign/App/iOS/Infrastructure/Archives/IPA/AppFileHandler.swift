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

actor AppFileHandler {
    struct StateSnapshot: Equatable, Sendable {
        let id: String
        let fileName: String
        let lifecycle: ImportCleanupJournal.Lifecycle
        let didAddToDatabase: Bool
        let lastCleanupError: String?
    }

    private let _uuid = UUID().uuidString
    private let _workDirectoryName: String
    private let _journal: ImportCleanupJournal
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
    private var _lifecycle: ImportCleanupJournal.Lifecycle = .copying
    private var _lastCleanupError: String?

    init(
        file ipa: URL,
        install: Bool = false,
        download: Download? = nil,
        originURL: URL? = nil,
        journal: ImportCleanupJournal = .defaultJournal
    ) {
        _ipa = ipa
        _fileName = ipa.lastPathComponent
        _install = install
        _download = download
		self._originURL = originURL ?? download?.originURL
        _appDescription = download?.appDescription
        _journal = journal
        let workDirName = "VexSignImport_\(_uuid)"
        _workDirectoryName = workDirName
        _uniqueWorkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(workDirName, isDirectory: true)
		self._importClaim = AppOperationRegistry.shared.claimProduction(of: _uuid)

        let importID = _uuid
        Logger.misc.debug(
            "Import initiated for: \(ipa.lastPathComponent, privacy: .public) with ID: \(importID, privacy: .public)"
        )
    }

    func snapshot() -> StateSnapshot {
        StateSnapshot(
            id: _uuid,
            fileName: _fileName,
            lifecycle: _lifecycle,
            didAddToDatabase: _didAddToDatabase,
            lastCleanupError: _lastCleanupError
        )
    }

    /// Builds a detailed, copyable error tagged with the failing step.
    private nonisolated func _error(
        _ step: ImportError.Step,
        reason: String,
        underlying: Error? = nil
    ) -> ImportError {
        ImportError(step, fileName: _fileName, id: _uuid, reason: reason, underlying: underlying)
    }

    private func _persistLifecycle(
        _ state: ImportCleanupJournal.Lifecycle,
        cleanupError: String? = nil,
        incrementAttempts: Bool = false
    ) {
        _lifecycle = state
        if let cleanupError {
            _lastCleanupError = LogRedaction.redact(cleanupError)
        }
        let now = Date()
        do {
            try _journal.update(
                id: _uuid,
                state: state,
                cleanupError: cleanupError,
                incrementAttempts: incrementAttempts,
                now: now
            )
        } catch {
            let entry = ImportCleanupJournal.Entry(
                id: _uuid,
                fileName: _fileName,
                workDirectoryName: _workDirectoryName,
                libraryUUID: _uuid,
                state: state,
                cleanupAttempts: incrementAttempts ? 1 : 0,
                lastCleanupError: cleanupError.map(LogRedaction.redact),
                createdAt: now,
                updatedAt: now
            )
            do {
                try _journal.record(entry)
            } catch let recordError {
                let redacted = LogRedaction.redact(recordError.localizedDescription)
                Logger.misc.warning(
                    "Could not persist import cleanup journal for \(self._uuid, privacy: .public): \(redacted, privacy: .public)"
                )
            }
        }
    }

    func markInterrupted(cancelled: Bool) {
        _persistLifecycle(cancelled ? .cancelled : .failed)
    }

    func copy() async throws {
        try _download?.importControl.checkpoint()
        try Task.checkCancellation()
        _persistLifecycle(.copying)
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)

            let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

            // The picker can hand over a `.zip`/`.tipa` whose container is what
            // matters, never its suffix. A gzipped tar has no reader here, so it is
            // named as such instead of failing later as a damaged ZIP.
            try _requireReadableContainer(at: _ipa)

            try fileManager.removeFileIfNeeded(at: destinationURL)

            guard fileManager.fileExists(atPath: _ipa.path) else {
                Logger.misc.error("[\(_uuid, privacy: .public)] Source file does not exist")
                throw _error(
                    .copy,
                    reason: "The source file no longer exists. It may have been moved or removed before the import finished."
                )
            }

            // Preflight storage: fail clearly instead of mid-write on a huge IPA.
            try _checkDiskSpace()

            try fileManager.copyItem(at: _ipa, to: destinationURL)
            _ipa = destinationURL
            try _download?.importControl.checkpoint()
            try Task.checkCancellation()
            Logger.misc.info("[\(_uuid, privacy: .public)] File copied into import workspace")
        } catch is CancellationError {
            _persistLifecycle(.cancelled)
            throw CancellationError()
        } catch let error as ImportError {
            _persistLifecycle(.failed)
            throw error
        } catch {
            _persistLifecycle(.failed)
            Logger.misc.error(
                "[\(_uuid, privacy: .public)] Copy failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
            )
            throw _error(.copy, reason: error.localizedDescription, underlying: error)
        }
    }

    /// Rejects a container this app cannot unpack, before copying it into the
    /// workspace and before extraction fails with an unrelated message.
    ///
    /// The sentences come from `PackageArchiveType.rejectionReason(at:)` so the
    /// shared-file path and this one cannot describe the same bytes differently.
    /// Some providers hand over a zero-byte or still-downloading file; that case
    /// has its own "could not be read" wording rather than being called a broken
    /// ZIP the user never wrote.
    private func _requireReadableContainer(at url: URL) throws {
        guard let reason = PackageArchiveType.rejectionReason(at: url) else { return }
        throw _error(.copy, reason: reason)
    }

    /// Check the temporary copy separately from extraction. The extractor validates
    /// the ZIP and checks its declared expanded size after the copy has been made;
    /// multiplying the compressed size here can reject a perfectly viable import.
    /// Capacity is advisory and real write errors still propagate through cleanup.
    private func _checkDiskSpace() throws {
        guard let fileSize = try? _ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize, // try? ok: advisory size check before copy
              fileSize > 0 else { return }
        do {
            try IPAImportStorage.checkCopy(bytes: Int64(fileSize), at: _uniqueWorkDir)
        } catch let error as StoragePreflight.Insufficient {
            Logger.misc.error("[\(_uuid, privacy: .public)] Insufficient space for IPA copy")
            throw _error(.diskSpace, reason: error.localizedDescription, underlying: error)
        }
    }

    func extract() async throws {
        _persistLifecycle(.extracting)
        do {
            let download = _download
            try IPAExtractor.extract(_ipa, to: _uniqueWorkDir, checkpoint: {
                try Task.checkCancellation()
                try download?.importControl.checkpoint()
            }, progress: { fraction in
                if let download {
                    DispatchQueue.main.async { download.unpackageProgress = fraction }
                }
            })
            // A `.tipa` has no `Payload` folder, so the location is remembered rather
            // than assumed: the work directory holds the payload whatever its layout.
            let payload = _uniqueWorkDir.appendingPathComponent("Payload")
            let payloadIsPresent = FileManager.default.fileExists(atPath: payload.path)
            uniqueWorkDirPayload = payloadIsPresent ? payload : _uniqueWorkDir
            _payloadIsPayloadFolder = payloadIsPresent
        } catch is CancellationError {
            _persistLifecycle(.cancelled)
            throw CancellationError()
        } catch let error as ImportError {
            _persistLifecycle(.failed)
            throw error
        } catch {
            _persistLifecycle(.failed)
            Logger.misc.error(
                "[\(_uuid, privacy: .public)] Extract failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
            )
            throw _error(.extract, reason: error.localizedDescription, underlying: error)
        }
    }

    func move() async throws {
        try _download?.importControl.checkpoint()
        try Task.checkCancellation()
        _persistLifecycle(.validating)
        guard let payloadURL = uniqueWorkDirPayload else {
            _persistLifecycle(.failed)
            Logger.misc.error("[\(_uuid, privacy: .public)] Payload URL is nil")
            throw _error(
                .payload,
                reason: "The archive could not be located after extraction. Nothing was unpacked into the workspace."
            )
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: payloadURL.path) else {
            _persistLifecycle(.failed)
            Logger.misc.error("[\(_uuid, privacy: .public)] Payload does not exist on disk")
            throw _error(
                .payload,
                reason: "The unpacked app is missing from disk. The archive may have failed to extract completely."
            )
        }

        // Do not let filesystem enumeration order choose which app gets imported and
        // signed. A valid IPA has exactly one top-level application bundle; nested
        // apps inside that bundle are not candidates.
        do {
            _ = try IPAImportPayload.validateApplication(in: payloadURL)
        } catch {
            _persistLifecycle(.failed)
            throw _error(.payload, reason: error.localizedDescription, underlying: error)
        }

        _persistLifecycle(.moving)
        do {
            let destinationURL = try await _directory()

            try fileManager.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())

            try fileManager.removeFileIfNeeded(at: destinationURL)

            if _payloadIsPayloadFolder {
                try fileManager.moveItem(at: payloadURL, to: destinationURL)
            } else {
                // No `Payload/` folder: move only the app bundle, so the copy of the
                // original archive does not become part of the library entry. The
                // bundle is checked again after the move, as for a normal IPA.
                let app = try IPAImportPayload.application(in: payloadURL)
                try fileManager.createDirectoryIfNeeded(at: destinationURL)
                try fileManager.moveItem(at: app, to: destinationURL.appendingPathComponent(app.lastPathComponent))
            }
            LibrarySizeSnapshot.invalidate()
            Logger.misc.info("[\(_uuid, privacy: .public)] Moved payload into unsigned library")

            do {
                try fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
            } catch {
                // Leave the journal entry active so `clean()` or launch recovery retries removal.
                let redacted = LogRedaction.redact(error.localizedDescription)
                _lastCleanupError = redacted
                Logger.misc.warning(
                    "[\(_uuid, privacy: .public)] Deferred work directory cleanup after move: \(redacted, privacy: .public)"
                )
            }
        } catch let error as ImportError {
            _persistLifecycle(.failed)
            throw error
        } catch {
            _persistLifecycle(.failed)
            Logger.misc.error(
                "[\(_uuid, privacy: .public)] Move failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
            )
            throw _error(.move, reason: error.localizedDescription, underlying: error)
        }
    }

    @discardableResult
    func addToDatabase() async throws -> NSManagedObjectID {
        _persistLifecycle(.registering)
        let app = try await _directory()

        let appUrl: URL
        do {
            appUrl = try IPAImportPayload.validateApplication(in: app)
        } catch {
            _persistLifecycle(.failed)
            throw _error(.database, reason: error.localizedDescription, underlying: error)
        }

        guard let bundle = Bundle(url: appUrl) else {
            _persistLifecycle(.failed)
            Logger.misc.error("[\(_uuid, privacy: .public)] Could not create bundle from moved payload")
            throw _error(.database, reason: "The app bundle could not be read. It may be corrupted or incomplete.")
        }

        try _download?.importControl.checkpoint()
        try Task.checkCancellation()
        let importUUID = _uuid
        if let download = _download {
            try await MainActor.run { try download.importCommitCheckpoint?(importUUID, false) }
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
            Logger.misc.info("[\(_uuid, privacy: .public)] Added to database")
        } catch {
            _persistLifecycle(.failed)
            Logger.misc.error(
                "[\(_uuid, privacy: .public)] Database add failed: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
            )
            throw _error(.database, reason: error.localizedDescription, underlying: error)
        }

        _didAddToDatabase = true
        _persistLifecycle(.committed)
        // A cleanup pass that read the library before this commit does not know the row, and
        // the claim ends with this import.
        AppOperationRegistry.shared.confirmProduction(of: _uuid)
        if let download = _download {
            // The callback swallows post-commit persistence failure, keeping the UUID checkpoint.
            try await MainActor.run { try download.importCommitCheckpoint?(importUUID, true) }
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
        FileManager.default.unsigned(_uuid)
    }

    func clean() async throws {
        let fileManager = FileManager.default
        var firstError: Error?

        do {
            try fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
        } catch {
            firstError = error
            Logger.misc.warning(
                "[\(_uuid, privacy: .public)] Failed to clean import work directory: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
            )
        }

        // A moved-but-unregistered payload is unreachable from the library, so it would leak forever.
        if !_didAddToDatabase {
            do {
                try fileManager.removeFileIfNeeded(at: fileManager.unsigned(_uuid))
            } catch {
                if firstError == nil { firstError = error }
                Logger.misc.warning(
                    "[\(_uuid, privacy: .public)] Failed to clean uncommitted import payload: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
                )
            }
        }

        if let firstError {
            _persistLifecycle(
                .cleanupPending,
                cleanupError: firstError.localizedDescription,
                incrementAttempts: true
            )
            throw ImportCleanupJournal.CleanupError(
                importID: _uuid,
                fileName: _fileName,
                underlying: firstError
            )
        }

        _lastCleanupError = nil
        do {
            try _journal.remove(id: _uuid)
        } catch {
            Logger.misc.warning(
                "[\(_uuid, privacy: .public)] Failed to remove resolved import journal: \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
            )
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

        /// Every app bundle inside a `Payload` folder that is itself wrapped in another folder:
        /// `Root/Wrapped/Payload/App.app`, which is what zipping the directory an archive was
        /// extracted into produces. Returned as a list so two of them stay ambiguous.
        func appsInsideWrappedPayloads(in container: URL) throws -> [URL] {
            let entries = (try? manager.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)) ?? [] // try? ok: unreadable directory holds no app bundle
            var found: [URL] = []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if entry.lastPathComponent.lowercased() == "__macosx" { continue }
                let wrappedPayload = entry.appendingPathComponent("Payload", isDirectory: true)
                var payloadIsDirectory: ObjCBool = false
                guard manager.fileExists(atPath: wrappedPayload.path, isDirectory: &payloadIsDirectory),
                      payloadIsDirectory.boolValue else { continue }
                found.append(contentsOf: try appsDirectly(in: wrappedPayload))
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

        // A folder wrapped around the standard layout: `Root/Wrapped/Payload/App.app`. Zipping
        // the directory an archive was extracted into is an ordinary thing to do in Files, and
        // the one-level search below sees only a directory called `Payload` — a directory is
        // not a bundle, so the archive was refused after a full extraction.
        if let app = try onlyApp(of: try appsInsideWrappedPayloads(in: container)) { return app }

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
