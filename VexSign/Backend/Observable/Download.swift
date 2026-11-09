//
//  Download.swift
//  VexSign
//

import Foundation
import Combine
import UIKit
import UserNotifications
import BackgroundTasks
import ActivityKit

class Download: Identifiable, @unchecked Sendable {
    let importControl = ImportControl()
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	@Published var isActive: Bool = false
	@Published var isPaused: Bool = false
	@Published var isImporting: Bool = false
	@Published var isSigning: Bool = false

	var phase: DownloadPhase {
		if isSigning { return .signing }
		if isImporting { return isPaused ? .paused : .importing }
		if unpackageProgress >= 1.0 { return .completed }
		if onlyArchiving || progress >= 1.0 { return .importing }
		if isPaused { return .paused }
		return (isActive || progress > 0) ? .downloading : .queued
	}

	var phaseProgress: Double {
		switch phase {
		case .queued: return 0
		case .downloading, .paused: return isImporting ? unpackageProgress : progress
		case .importing: return unpackageProgress
		case .signing, .completed: return 1
		}
	}

	var task: URLSessionDownloadTask?
	var resumeData: Data?
	var pendingFileURL: URL?
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	let appDescription: String?

	/// What the source promised about the file, checked before anything is unpacked.
	/// Mutable so a resumed row can take a promise the first fetch did not know.
	var integrity: DownloadIntegrity.Expectation?

	/// The staged package a failed integrity check left alone. The row is removed when the check
	/// fails — exactly like any other failed import — so the one deliberate override is offered in
	/// the alert, and this is what it imports.
	var retainedPackageURL: URL?
	/// Set immediately before a size-limit cancellation so it is not mistaken for a user pause.
	var exceededPackageSizeLimit = false

	var isManual: Bool {
		id.contains("VexSignManualDownload")
	}

	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		appName: String? = nil,
		appDescription: String? = nil,
		integrity: DownloadIntegrity.Expectation? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.fileName = appName ?? url.lastPathComponent
		self.appDescription = appDescription
		self.integrity = integrity
	}

	func beginImport() {
		isImporting = true
		unpackageProgress = 0.05
	}

	func endImport() {
		isImporting = false
		pendingFileURL = nil
	}

	func pause() {
		DownloadManager.shared.pauseDownload(self)
	}

	func resume() {
		DownloadManager.shared.resumeDownload(self)
	}
}

struct DownloadProgressSummary: Equatable {
	let phase: DownloadPhase
	let progress: Double
	let downloadingCount: Int
	let pausedCount: Int
	let importingCount: Int
	let signingCount: Int

	init(_ downloads: [Download]) {
		let byPhase = Dictionary(grouping: downloads, by: \.phase)
        let pausedImports = (byPhase[.paused] ?? []).filter { $0.isImporting }
        let pending = (byPhase[.downloading] ?? []) + (byPhase[.queued] ?? []) + (byPhase[.paused] ?? []).filter { !$0.isImporting }
		let importing = byPhase[.importing] ?? []
		let signing = byPhase[.signing] ?? []

		downloadingCount = byPhase[.downloading]?.count ?? 0
		pausedCount = byPhase[.paused]?.count ?? 0
		importingCount = importing.count
		signingCount = signing.count

		if !pending.isEmpty {
			phase = downloadingCount == 0 && pausedCount > 0 ? .paused : .downloading
			let expected = pending.reduce(Int64(0)) { $0 + $1.totalBytes }
			if expected > 0 {
				let received = pending.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
				progress = min(1, Double(received) / Double(expected))
			} else {
				progress = Self.average(pending.map(\.phaseProgress))
			}
        } else if !importing.isEmpty || !signing.isEmpty || !pausedImports.isEmpty {
            phase = !importing.isEmpty ? .importing : (!signing.isEmpty ? .signing : .paused)
            progress = Self.average((importing + signing + pausedImports).map(\.phaseProgress))
		} else {
			phase = downloads.isEmpty ? .queued : .completed
			progress = downloads.isEmpty ? 0 : 1
		}
	}

	private static func average(_ values: [Double]) -> Double {
		guard !values.isEmpty else { return 0 }
		return values.reduce(0, +) / Double(values.count)
	}
}
