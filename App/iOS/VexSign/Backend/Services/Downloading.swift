//
//  Downloading.swift
//  VexSign
//
//  a view model should be constructible without the real download pipeline.
//
//  VexSign has 56 `static let shared` globals; `DownloadManager` is the one every store-facing
//  view reaches for. This protocol is the narrow surface a view model actually needs — start a
//  download and get the row back — so a test can hand in a fake and assert on it instead of
//  bringing up `URLSession`, Core Data and the notification centre.
//
//  `.shared` stays the production instance; nothing here changes production behaviour.
//

import Foundation

/// Starting a package download, and nothing else.
protocol PackageDownloading: AnyObject {
	@discardableResult
	func startPackageDownload(
		from url: URL,
		appName: String?,
		appDescription: String?,
		integrity: DownloadIntegrity.Expectation?
	) -> Download
}

extension DownloadManager: PackageDownloading {
	/// The one production implementation: the existing entry point, with the store's own naming.
	@discardableResult
	func startPackageDownload(
		from url: URL,
		appName: String?,
		appDescription: String?,
		integrity: DownloadIntegrity.Expectation?
	) -> Download {
		startDownload(
			from: url,
			id: UUID().uuidString,
			appName: appName,
			appDescription: appDescription,
			integrity: integrity
		)
	}
}
