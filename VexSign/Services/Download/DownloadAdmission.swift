import Foundation

/// Admission result for a transfer request.
///
/// `DownloadManager.startDownload` deliberately returns a `Download` object even when the
/// request was refused (URL policy, Game Mode, Wi-Fi/charge-only rules, missing session).
/// That object is a presentation placeholder, not a transfer. Comparing its identity to the
/// manager's list is the only honest way to tell a caller whether the download actually
/// started; matching URL, id or name is not enough.
enum DownloadAdmission {
    static func isAccepted(_ candidate: Download, in downloads: [Download]) -> Bool {
        downloads.contains { $0 === candidate }
    }
}
