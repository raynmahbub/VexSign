import Foundation
import NimbleExtensions

extension DownloadManager {
    /// Small atomic writes only at phase transitions, never on progress callbacks.
    @discardableResult
    func checkpointRecovery(_ download: Download, stage: DownloadRecoveryJournal.Stage, file: URL? = nil) -> Bool {
        do { try writeRecovery(download, stage: stage, file: file); return true }
        catch { recoveryWarning = error.localizedDescription; return false }
    }

    private func writeRecovery(_ download: Download, stage: DownloadRecoveryJournal.Stage, file: URL? = nil) throws {
        guard let recoveryJournal else { return } // Isolated tests do not enable system services or persistence.
        let isStaged = file?.deletingLastPathComponent().standardizedFileURL == FileManager.default.downloadStaging.standardizedFileURL
        let record = DownloadRecoveryJournal.Record(
            id: download.recoveryID, name: String(download.fileName.prefix(1024)),
            sourceURL: DownloadRecoveryJournal.publicURL(download.url),
            expectedBytes: download.integrity?.byteCount, expectedHash: download.integrity?.sha256,
            stage: stage, stagedName: isStaged ? file?.lastPathComponent : nil, updatedAt: Date(),
            libraryUUID: download.importLibraryUUID)
        try recoveryJournal.save(record)
    }

    func ownImportRecovery(_ download: Download) {
        download.importCommitCheckpoint = { [weak self, weak download] uuid, committed in
            guard let self, let download else { throw CancellationError() }
            download.importLibraryUUID = uuid
            // Before commit, persistence failure aborts the write. After commit, retain the previous
            // .committing checkpoint (with UUID) and report the problem; never undo a successful save.
            do { try self.writeRecovery(download, stage: committed ? .committed : .committing, file: download.pendingFileURL) }
            catch {
                self.recoveryWarning = error.localizedDescription
                if !committed { throw error }
            }
        }
    }

    /// Only pre-commit phases can reuse input, and every reuse repeats integrity verification.
    func reverifyRecovery(_ record: DownloadRecoveryJournal.Record) {
        guard record.canReverify, let recoveryJournal,
              interruptedDownloads.contains(where: { $0.id == record.id }),
              !downloads.contains(where: { $0.recoveryID == record.id }),
              let file = recoveryJournal.stagedFile(for: record, in: FileManager.default.downloadStaging) else { return }
        let download = Download(id: "VexSignManualDownload_" + UUID().uuidString,
                                url: record.sourceURL ?? file, appName: record.name,
                                integrity: .init(byteCount: record.expectedBytes, sha256: record.expectedHash),
                                recoveryID: record.id)
        ownImportRecovery(download)
        downloads.append(download)
        do {
            try handlePackageFile(url: file, dl: download)
            interruptedDownloads.removeAll { $0.id == record.id }
        } catch {
            downloads.removeAll { $0 === download }
            recoveryWarning = error.localizedDescription
        }
    }

    func clearRecovery(_ download: Download) {
        guard let recoveryJournal else { return }
        do { try recoveryJournal.remove(download.recoveryID) }
        catch { recoveryWarning = error.localizedDescription }
    }

    /// Forgetting never removes the retained IPA or claims that an interrupted import rolled back.
    func forgetRecovery(_ record: DownloadRecoveryJournal.Record) {
        guard let recoveryJournal else { return }
        do {
            try recoveryJournal.remove(record.id)
            interruptedDownloads.removeAll { $0.id == record.id }
        } catch { recoveryWarning = error.localizedDescription }
    }

    func retryRecoveryDownload(_ record: DownloadRecoveryJournal.Record) {
        guard let url = record.sourceURL, interruptedDownloads.contains(where: { $0.id == record.id }) else { return }
        let resumeData: Data?
        do { resumeData = record.stage == .downloading ? try recoveryJournal?.resumeData(id: record.id, source: url) : nil }
        catch { recoveryWarning = error.localizedDescription; return }
        let download = startDownload(from: url, appName: record.name,
                                     integrity: DownloadIntegrity.Expectation(byteCount: record.expectedBytes, sha256: record.expectedHash),
                                     recoveryID: record.id, recoveredResumeData: resumeData)
        // A policy block or a different live owner keeps the old recovery entry for explicit review.
        guard downloads.contains(where: { $0 === download }), download.recoveryID == record.id else { return }
        interruptedDownloads.removeAll { $0.id == record.id }
    }
}
