import Foundation
import NimbleExtensions

/// Presentation-layer ViewModel for `DownloadsTabView`, isolating filesystem
/// staging enumeration and file import/cleanup from SwiftUI Views.
@MainActor
final class DownloadsTabViewModel: ObservableObject {
    @Published private(set) var downloadedFiles: [DownloadedFileItem] = []

    private let downloadedFilesManager: DownloadedFilesManaging
    private let securityPolicy: SecurityPolicyValidating
    private let platform: PlatformSystemAdapting
    private let startDownloadHandler: (URL) -> Bool

    init(
        downloadedFiles: DownloadedFilesManaging,
        securityPolicy: SecurityPolicyValidating,
        platform: PlatformSystemAdapting,
        startDownloadHandler: @escaping (URL) -> Bool = { url in
            _ = DownloadManager.shared.startDownload(from: url)
            return true
        }
    ) {
        self.downloadedFilesManager = downloadedFiles
        self.securityPolicy = securityPolicy
        self.platform = platform
        self.startDownloadHandler = startDownloadHandler
    }

    var stagingDirectoryURL: URL {
        downloadedFilesManager.stagingDirectoryURL()
    }

    func refreshStagedFiles() {
        downloadedFiles = downloadedFilesManager.listStagedPackages()
    }

    func importIntoStaging(_ urls: [URL]) {
        let count = downloadedFilesManager.importFiles(urls, intoStaging: true)
        platform.notifySuccess(
            .localized("%lld file(s) imported", arguments: count),
            systemImage: "tray.and.arrow.down"
        )
        refreshStagedFiles()
    }

    func importToLibrary(_ item: DownloadedFileItem) {
        _ = downloadedFilesManager.importToLibrary(from: item.url)
        platform.notifySuccess(.localized("Imported to Library"), systemImage: "tray.and.arrow.down")
    }

    func openInFiles(_ url: URL) {
        if let shared = downloadedFilesManager.sharedDocumentsURL(for: url) {
            platform.openExternalURL(shared)
        }
    }

    func initialURLFromPasteboard(currentText: String) -> String {
        guard currentText.isEmpty,
              let clip = platform.pasteboardString(),
              clip.hasPrefix("http") else {
            return currentText
        }
        return clip.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func startDownload(fromRawURL raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            platform.notifyError(.localized("Invalid URL"), sticky: false)
            return false
        }

        do {
            try securityPolicy.validatePackageDownloadURL(url)
        } catch {
            platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
            return false
        }

        guard startDownloadHandler(url) else { return false }
        platform.notifyInfo(.localized("Download started"), systemImage: "arrow.down.circle")
        return true
    }

    func clearCompleted(in downloadManager: DownloadManager) {
        let completed = downloadManager.downloads.filter { $0.phase == .completed }
        for download in completed {
            downloadManager.cancelDownload(download)
        }
        refreshStagedFiles()
        platform.notifySuccess(.localized("Cleared completed downloads"), systemImage: "trash")
    }
}
