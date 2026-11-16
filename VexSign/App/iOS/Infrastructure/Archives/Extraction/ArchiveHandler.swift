//
//  ArchiveHandler.swift
//  VexSign
//
//  Created by VexSign Contributors on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import SwiftUI
import IDeviceSwift
import os

@MainActor
final class ArchiveHandler: NSObject {
    let viewModel: InstallerStatusViewModel

    private let _fileManager = FileManager.default
    private let _uuid = UUID().uuidString
    private var _payloadUrl: URL?
    private let _app: AppInfoPresentable
    private let _uniqueWorkDir: URL
    private var backgroundTaskManager: BackgroundTaskManager?

    init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel, workspace: URL? = nil) {
        self.viewModel = viewModel
        self._app = app
        self._uniqueWorkDir = workspace ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("VexSignInstall_\(_uuid)", isDirectory: true)
        super.init()
    }

    /// Resolve any managed-object-backed metadata on the main actor, then copy
    /// only URLs into the detached file worker. Mutable handler state is updated
    /// after the worker returns to this actor.
    func move(from source: URL? = nil) async throws {
        try Task.checkCancellation()
        guard let appURL = source ?? Storage.shared.getAppDirectory(for: _app) else {
            throw SigningFileHandlerError.appNotFound
        }

        let payloadURL = _uniqueWorkDir.appendingPathComponent("Payload")
        let movedAppURL = payloadURL.appendingPathComponent(appURL.lastPathComponent)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try FileManager.default.createDirectoryIfNeeded(at: payloadURL)
            try StoragePreflight.checkBundle(appURL, copies: 2, destination: payloadURL)
            try FileManager.default.copyItem(at: appURL, to: movedAppURL)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        _payloadUrl = payloadURL
    }

    /// Zip state is snapshotted on the owner actor. The detached worker receives
    /// only immutable URLs/options and reports UI progress back through MainActor.
    func archive(compressForTransfer: Bool = false) async throws -> URL {
        guard let payloadURL = _payloadUrl else {
            throw SigningFileHandlerError.appNotFound
        }
        let ipaURL = _uniqueWorkDir.appendingPathComponent("Archive.ipa")
        let compression = ArchiveTransferPolicy.compression(
            storedIndex: Self.getCompressionLevel(), compressForTransfer: compressForTransfer
        )

        if backgroundTaskManager == nil {
            backgroundTaskManager = BackgroundTaskManager(
                taskName: "ArchiveHandler",
                expirationTitle: "Archiving continuing",
                expirationBody: "The archiving will continue when you reopen the app"
            )
            backgroundTaskManager?.start()
        }
        defer {
            backgroundTaskManager?.stop()
            backgroundTaskManager = nil
        }

        let gate = ProgressGate()
        let worker = Task.detached(priority: .background) { [weak self] in
            try Task.checkCancellation()
            try AppArchiver.zip(
                payload: payloadURL,
                to: ipaURL,
                compression: compression,
                progress: { progress in
                    guard gate.admit(progress) else { return }
                    Task { @MainActor [weak self] in
                        self?.viewModel.packageProgress = progress
                    }
                }
            )
            try Task.checkCancellation()
            return ipaURL
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// A handoff retains only the IPA, never a second unpacked copy of the app.
    /// This does not touch the original library bundle.
    func prepareCompanionArchive() async throws -> URL {
        do {
            try await move()
            let package = try await archive()
            if let payload = _payloadUrl {
                try _fileManager.removeItem(at: payload)
                _payloadUrl = nil
            }
            return package
        } catch {
            let originalError = error
            if _fileManager.fileExists(atPath: _uniqueWorkDir.path) {
                do {
                    try _fileManager.removeItem(at: _uniqueWorkDir)
                } catch {
                    FileLogger.log("Could not clean failed companion archive: \(error)", category: "install")
                }
            }
            throw originalError
        }
    }

    func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
        let destination = try IPAExportNaming.movePackage(
            package, to: _fileManager.archives, name: _app.name, version: _app.version
        )

        if shouldOpen, let sharedURL = FileManager.default.archives.toSharedDocumentsURL() {
            UIApplication.open(sharedURL)
        }
        return destination
    }

    nonisolated static func getCompressionLevel() -> Int {
        UserDefaults.standard.integer(forKey: "VexSign.compressionLevel")
    }
}

// MARK: - Coalescing
/// Zip reports once per entry and an app bundle holds thousands of them; hopping to the main
/// actor for every one of them stalls SwiftUI for the whole archive.
final class ProgressGate: Sendable {
    private let _last = OSAllocatedUnfairLock(initialState: -1.0)
    private let _step: Double

    init(step: Double = 0.01) {
        self._step = step
    }

    func admit(_ value: Double) -> Bool {
        _last.withLock { last in
            guard value >= 1 || value - last >= _step else { return false }
            last = value
            return true
        }
    }
}
