//
//  PackageImportService.swift
//  VexSign
//
//  Package import pipeline for IPA and TIPA archives.
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

enum PackageImportService {
    @discardableResult
    static func importPackage(
        _ ipa: URL,
        download: Download? = nil,
        originURL: URL? = nil,
        completion: @escaping (Result<AppInfoPresentable, Error>) -> Void
    ) -> Task<Void, Never> {
        // Acquire any document-provider scope synchronously, while the caller still owns
        // the picker result. The detached worker may not start until after that access
        // window has otherwise ended; it holds this scope through the initial copy.
        let scoped = ipa.startAccessingSecurityScopedResource()
        return Task.detached {
            defer { if scoped { ipa.stopAccessingSecurityScopedResource() } }
            // Only the identity leaves the main actor. The mutable live task stays in
            // UnifiedTaskCenter; later actor hops resolve it again by ID.
            let importTaskID: String? = await MainActor.run {
                guard download == nil else { return nil }
                return UnifiedTaskCenter.shared.begin(kind: .importIPA, title: .localized("Import IPA"), phase: .importing).id
            }
            let workLease: AppOperationRegistry.Lease
            do { workLease = try AppOperationRegistry.shared.acquireTemporaryWork() }
            catch {
                await MainActor.run {
                    if let task = taskRecord(id: importTaskID) {
                        task.context?.recordFailure(error)
                        UnifiedTaskCenter.shared.transition(task, to: .failed, error: error.localizedDescription)
                    }
                    completion(.failure(error))
                }
                return
            }
            defer { withExtendedLifetime(workLease) {} }
            let handler = AppFileHandler(file: ipa, download: download, originURL: originURL)

            do {
                try await handler.copy()
                try await handler.extract()
                try await handler.move()
                try await handler.inspect()
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
                        UnifiedTaskCenter.shared.recordImportedArtifact(imported, taskID: importTaskID, downloadID: download?.id)
                        completion(.success(imported))
                    } catch {
                        if let task = taskRecord(id: importTaskID) {
                            task.context?.recordFailure(error)
                            UnifiedTaskCenter.shared.transition(task, to: .failed, error: error.localizedDescription)
                        }
                        completion(.failure(error))
                    }
                }
            } catch {
                try? await handler.clean() // try? ok: best-effort cleanup of temporary work directory on error
                await MainActor.run {
                    if let task = taskRecord(id: importTaskID) {
                        task.context?.recordFailure(error)
                        UnifiedTaskCenter.shared.transition(task, to: error is CancellationError ? .cancelled : .failed, error: error.localizedDescription)
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    @MainActor
    private static func taskRecord(id: String?) -> UnifiedTask? {
        guard let id else { return nil }
        return (UnifiedTaskCenter.shared.tasks + UnifiedTaskCenter.shared.history).first { $0.id == id }
    }
}
