//
//  DownloadControlIntent.swift
//  VexSign
//
//  App Intents for Live Activity download controls
//

import Foundation
import AppIntents

@available(iOS 17.0, *)
struct PauseDownloadsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause Downloads"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            DownloadManager.shared.pauseAllDownloads()
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct ResumeDownloadsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume Downloads"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            DownloadManager.shared.resumeAllDownloads()
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopDownloadsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Downloads"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            DownloadManager.shared.cancelAllDownloads()
        }
        return .result()
    }
}
