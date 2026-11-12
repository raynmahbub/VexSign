//
//  UnifiedTaskArtifacts.swift
//  VexSign
//
//  Artifact recording for the unified task center.
//

import Foundation
import NimbleExtensions

extension UnifiedTaskCenter {
    func recordImportedArtifact(_ app: AppInfoPresentable, task: UnifiedTask?, downloadID: String?) {
        _syncMirrored(downloads: DownloadManager.shared.downloads)
        guard let record = task ?? (tasks + history).first(where: { $0.subjectID == downloadID && downloadID != nil }) else { return }
        var context = record.context ?? TaskContext()
        context.artifactID = app.uuid
        context.appVersion = TaskContext.versionToken(app.version)
        if let directory = Storage.shared.getAppDirectory(for: app),
           let info = NSDictionary(contentsOf: directory.appendingPathComponent("Info.plist")) {
            context.appBuild = TaskContext.versionToken(info["CFBundleVersion"] as? String)
        }
        context.confirmationReason = "import-registered"
        record.context = context
        transition(record, to: .readyToSign)
        if task != nil { transition(record, to: .completed, progress: 1) }
    }
}