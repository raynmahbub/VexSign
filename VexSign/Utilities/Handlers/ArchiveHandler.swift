//
//  ArchiveHandler.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import Zip
import SwiftUI
import IDeviceSwift

final class ArchiveHandler: NSObject {
	let viewModel: InstallerStatusViewModel

	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?

	private var _app: AppInfoPresentable
	private let _uniqueWorkDir: URL
	private var backgroundTaskManager: BackgroundTaskManager?
	
	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel, workspace: URL? = nil) {
		self.viewModel = viewModel
		self._app = app
		self._uniqueWorkDir = workspace ?? (_fileManager.temporaryDirectory
            .appendingPathComponent("VexSignInstall_\(_uuid)", isDirectory: true))
		
		super.init()
	}
	
	func move(from source: URL? = nil) async throws {
		guard let appUrl = source ?? Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_payloadUrl = payloadUrl
	}
	
	func archive(compressForTransfer: Bool = false) async throws -> URL {
		// Keep archiving alive in the background.
		await MainActor.run {
			if self.backgroundTaskManager == nil {
				self.backgroundTaskManager = BackgroundTaskManager(
					taskName: "ArchiveHandler",
					expirationTitle: "Archiving continuing",
					expirationBody: "The archiving will continue when you reopen the app"
				)
				self.backgroundTaskManager?.start()
			}
		}

		let worker = Task.detached(priority: .background) { [self] in
			defer {
				Task { @MainActor in
					self.backgroundTaskManager?.stop()
					self.backgroundTaskManager = nil
				}
			}

            try Task.checkCancellation()
			guard let payloadUrl = self._payloadUrl else {
				throw SigningFileHandlerError.appNotFound
			}

			let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
			let gate = ProgressGate()

			try AppArchiver.zip(
				payload: payloadUrl,
				to: ipaUrl,
				compression: ArchiveTransferPolicy.compression(
                    storedIndex: ArchiveHandler.getCompressionLevel(), compressForTransfer: compressForTransfer
                ),
				progress: { progress in
					guard gate.admit(progress) else { return }
					Task { @MainActor in
						self.viewModel.packageProgress = progress
					}
				})

            try Task.checkCancellation()
			return ipaUrl
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
        let dest = try IPAExportNaming.movePackage(
            package, to: _fileManager.archives, name: _app.name, version: _app.version
        )

		if shouldOpen {
			await MainActor.run {
				if let sharedURL = FileManager.default.archives.toSharedDocumentsURL() {
					UIApplication.open(sharedURL)
				}
			}
		}
		
		return dest
	}
	
	static func getCompressionLevel() -> Int {
		UserDefaults.standard.integer(forKey: "VexSign.compressionLevel")
	}
}

// MARK: - Coalescing
/// Zip reports once per entry and an app bundle holds thousands of them; hopping to the main
/// actor for every one of them stalls SwiftUI for the whole archive.
final class ProgressGate {
	private let _lock = NSLock()
	private var _last = -1.0
	private let _step: Double

	init(step: Double = 0.01) {
		self._step = step
	}

	func admit(_ value: Double) -> Bool {
		_lock.lock()
		defer { _lock.unlock() }
		guard value >= 1 || value - _last >= _step else { return false }
		_last = value
		return true
	}
}
