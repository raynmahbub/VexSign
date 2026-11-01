//
//  DiscoveryViewModelTests.swift
//  VexSignTests
//
//  a view model is constructible with a fake. Until this existed, every store-facing view
//  model reached `DownloadManager.shared` directly, so the test target could not build one without
//  the real session, storage and notification centre.
//

import Foundation
import XCTest
@testable import VexSign

@MainActor
final class DiscoveryViewModelTests: XCTestCase {
	private final class FakeDownloads: PackageDownloading {
		var started: [URL] = []
		var lastIntegrity: DownloadIntegrity.Expectation?

		@discardableResult
		func startPackageDownload(
			from url: URL,
			appName: String?,
			appDescription: String?,
			integrity: DownloadIntegrity.Expectation?
		) -> Download {
			started.append(url)
			lastIntegrity = integrity
			return Download(id: "fake-\(started.count)", url: url, appName: appName, appDescription: appDescription)
		}
	}

	private func app(download: String?) -> DiscoveryApp {
		DiscoveryApp(
			id: "source#com.example.app",
			source: "source",
			bundleIdentifier: "com.example.app",
			name: "Example",
			summary: "Example app",
			developer: "Example",
			category: "Utilities",
			version: "1.0",
			icon: nil,
			download: download.flatMap(URL.init(string:)),
			updated: nil,
			releases: 0
		)
	}

	func testAViewModelCanBeBuiltWithAFake() {
		let model = DiscoveryViewModel(downloads: FakeDownloads())
		XCTAssertTrue(model.apps.isEmpty)
		XCTAssertNil(model.error)
	}

	func testAnInvalidDownloadURLIsRefusedBeforeThePipelineIsTouched() async {
		let fake = FakeDownloads()
		let model = DiscoveryViewModel(downloads: fake)

		// Not https, so the store refuses it locally.
		await model.download(app(download: "ftp://example.com/app.ipa"))

		XCTAssertTrue(fake.started.isEmpty)
		XCTAssertNotNil(model.error)
	}

	func testAnAppWithNoDownloadURLIsRefused() async {
		let fake = FakeDownloads()
		let model = DiscoveryViewModel(downloads: fake)

		await model.download(app(download: nil))

		XCTAssertTrue(fake.started.isEmpty)
		XCTAssertNotNil(model.error)
	}
}
