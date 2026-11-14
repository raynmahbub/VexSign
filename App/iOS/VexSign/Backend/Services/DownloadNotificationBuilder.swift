import Foundation
import UserNotifications

/// Builds requests only. DownloadManager still owns eligibility, delivery,
/// lifecycle, Live Activity preference and clearing delivered notifications.
/// Keep wording, identifiers and arithmetic compatible with existing callers.
enum DownloadNotificationBuilder {
    static func progress(forActiveDownloads activeDownloads: [Download]) -> UNNotificationRequest? {
        // Imports have no network bytes and must not create phantom 0% entries.
        let downloads = activeDownloads.filter { !$0.onlyArchiving }
        guard !downloads.isEmpty else { return nil }
        let content = UNMutableNotificationContent()
        if downloads.count == 1 {
            let download = downloads[0]
            let percent = Int(download.progress * 100)
            content.title = download.fileName
            content.body = "\(formatBytes(download.bytesDownloaded)) / \(formatBytes(download.totalBytes))"
            content.subtitle = "Progress: \(percent)%"
        } else {
            let totalProgress = downloads.reduce(0.0) { $0 + $1.progress }
            let averageProgress = totalProgress / Double(downloads.count)
            let percent = Int(averageProgress * 100)
            let received = downloads.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
            let expected = downloads.reduce(Int64(0)) { $0 + $1.totalBytes }
            content.title = "Downloading \(downloads.count) files"
            content.subtitle = "Overall Progress: \(percent)%"
            content.body = "\(formatBytes(received)) / \(formatBytes(expected))"
        }
        content.sound = nil
        content.interruptionLevel = .passive
        return UNNotificationRequest(identifier: "merged_download_progress", content: content, trigger: nil)
    }

    static func system(title: String, body: String, identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    static func completion(for download: Download, status: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = status
        content.body = download.fileName
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        return UNNotificationRequest(identifier: "completion_\(download.id)", content: content, trigger: nil)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}
