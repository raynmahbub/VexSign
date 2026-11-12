//
//  FR+Import.swift
//  VexSign
//
//  IPA import and package handling.
//

import Foundation
import Security
import UIKit
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import OSLog
import NimbleExtensions

extension FR {
    static func handlePackageFile(
        _ ipa: URL,
        download: Download? = nil,
        completion: @escaping (Result<AppInfoPresentable, Error>) -> Void
    ) {
        Task.detached {
            let importRecord: UnifiedTask? = await MainActor.run {
                guard download == nil else { return nil }
                return UnifiedTaskCenter.shared.begin(kind: .importIPA, title: .localized("Import IPA"), phase: .importing)
            }
            let workLease: AppOperationRegistry.Lease
            do { workLease = try await AppOperationRegistry.shared.acquireTemporaryWork() }
            error {
                await MainActor.run {
                    if let importRecord {
                        importRecord.context?.recordFailure(error)
                        UnifiedTaskCenter.shared.transition(importRecord, to: .failed, error: error.localizedDescription)
                    }
                    completion(.failure(error))
                }
                return
            }
            defer { withExtendedLifetime(workLease) {} }
            let scoped = ipa.startAccessingSecurityScopedResource()
            defer { if scoped { ipa.stopAccessingSecurityScopedResource() } }
            let handler = AppFileHandler(file: ipa, download: download)
            
            do {
                try await handler.copy()
                try await handler.extract()
                try await handler.move()
                let objectID = try await handler.addToDatabase()
                let iconDirectory: URL? = await MainActor.run {
                    guard let app: Imported = Storage.shared.object(objectID) else { return nil }
                    return Storage.shared.getAppDirectory(for: app)
                }
                let historyIcon = iconDirectory.flatMap { iconTest($0) }
                if let download, let historyIcon {
                    await MainActor.run {
                        UnifiedTaskCenter.shared.captureHistoryIcon(historyIcon, subjectID: download.id)
                    }
                }
                try? await handler.clean() // try? ok: best-effort cleanup of temporary work directory
            await MainActor.run {
                    do {
                        let imported = try handler.importedApp(for: objectID)
                        UnifiedTaskCenter.shared.recordImportedArtifact(imported, task: importRecord, downloadID: download?.id)
                        completion(.success(imported))
                    } catch {
                        if let importRecord {
                            importRecord.context?.recordFailure(error)
                            UnifiedTaskCenter.shared.transition(importRecord, to: .failed, error: error.localizedDescription)
                        }
                        completion(.failure(error))
                    }
                }
            } catch {
                try? await handler.clean() // try? ok: best-effort cleanup of temporary work directory on error
                await MainActor.run {
                    if let importRecord {
                        importRecord.context?.recordFailure(error)
                        UnifiedTaskCenter.shared.transition(importRecord, to: error is CancellationError ? .cancelled : .failed, error: error.localizedDescription)
                    }
                    completion(.failure(error))
                }
            }
        }
    }
}