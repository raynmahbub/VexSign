//
//  NestedBundleAuditTests.swift
//  VexSignTests
//
//  Tests for what the selected profile can do for the extensions inside an app.
//
//  The app trees here are built on disk — real `Info.plist` files, real directories — so the scan
//  is exercised the way it runs on a device. The profiles are injected rather than parsed: a
//  nested bundle's own `embedded.mobileprovision` cannot be produced without a CMS-signed profile,
//  and the interesting logic is the comparison, not the decoder.
//

import Foundation
import XCTest
@testable import VexSign

final class NestedBundleAuditTests: XCTestCase {
	private var appBundle: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()

		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("NestedBundleAuditTests-\(UUID().uuidString)", isDirectory: true)
		appBundle = root
			.appendingPathComponent("Payload", isDirectory: true)
			.appendingPathComponent("Example.app", isDirectory: true)
		try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let appBundle {
			// …/Payload/Example.app → the per-test root.
			let root = appBundle.deletingLastPathComponent().deletingLastPathComponent()
			try? FileManager.default.removeItem(at: root)
		}
		appBundle = nil
		try super.tearDownWithError()
	}

	// MARK: Fixtures

	@discardableResult
	private func makeBundle(_ relativePath: String, identifier: String?) throws -> URL {
		let url = appBundle.appendingPathComponent(relativePath, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

		var plist: [String: Any] = ["CFBundlePackageType": "XPC!"]
		if let identifier {
			plist["CFBundleIdentifier"] = identifier
		}
		let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
		try data.write(to: url.appendingPathComponent("Info.plist"))

		return url
	}

	private func report(pattern: String?, shipped: String? = nil) -> NestedBundleAudit.Report {
		NestedBundleAudit.report(
			appBundle: appBundle,
			profilePattern: pattern,
			shippedProfile: { _ in shipped }
		)
	}

    func testKnownIncompatibleExtensionBlocksBeforeSigning() throws {
        try makeBundle("PlugIns/Widget.appex", identifier: "com.example.app.widget")
        let incompatible = report(pattern: "TEAM.com.example.app")
        XCTAssertThrowsError(try incompatible.requireCompatibleProfile()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Remove App Extensions"))
            XCTAssertTrue(error.localizedDescription.contains("Widget.appex"))
        }
        XCTAssertNoThrow(try report(pattern: "TEAM.com.example.*").requireCompatibleProfile())
        // Lack of evidence must not be invented as a known profile mismatch.
        XCTAssertNoThrow(try report(pattern: nil).requireCompatibleProfile())
    }

	// MARK: Scanning

	func testScanFindsExtensionsAndWatchApps() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")
		try makeBundle("Extensions/Share.appex", identifier: "com.example.share")
		try makeBundle("Watch/Example Watch.app", identifier: "com.example.watch")

		let bundles = NestedBundleAudit.bundles(in: appBundle)

		XCTAssertEqual(bundles.count, 3)
		XCTAssertEqual(
			bundles.map(\.path),
			["PlugIns/Widget.appex", "Extensions/Share.appex", "Watch/Example Watch.app"]
		)
		XCTAssertEqual(
			bundles.map(\.kind),
			[.appExtension, .appExtension, .watchApp]
		)
		XCTAssertEqual(bundles.first?.displayName, "Widget.appex")
	}

	/// Frameworks never need their own profile, and a `.appex` that is a file rather than a
	/// directory is not a bundle. Neither belongs in the audit.
	func testScanSkipsFrameworksAndLooseFiles() throws {
		try makeBundle("Frameworks/SwiftUI.framework", identifier: "com.apple.SwiftUI")

		let directory = appBundle.appendingPathComponent("PlugIns", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data("not a bundle".utf8).write(to: directory.appendingPathComponent("Stray.appex"))

		XCTAssertTrue(NestedBundleAudit.bundles(in: appBundle).isEmpty)
	}

	// MARK: Coverage

	func testAWildcardProfileCoversExtensions() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		let report = report(pattern: "ABCDE12345.com.example.*")

		XCTAssertEqual(report.entries.count, 1)
		XCTAssertEqual(report.entries.first?.coverage, .covered(pattern: "ABCDE12345.com.example.*"))
		XCTAssertTrue(report.isClean)
		XCTAssertTrue(report.uncovered.isEmpty)
	}

	func testAnExplicitProfileDoesNotCoverASibling() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		let report = report(pattern: "ABCDE12345.com.example.app")

		XCTAssertEqual(report.entries.first?.coverage, .notCovered(pattern: "ABCDE12345.com.example.app"))
		XCTAssertEqual(report.uncovered.count, 1)
		XCTAssertFalse(report.isClean)
	}

	func testCompatibilityRemovalSkipsOnlyKnownUncoveredBundles() throws {
		let covered = try makeBundle("PlugIns/Compatible.appex", identifier: "com.frameradar.app.widget")
		let unsupportedNames = ["AirportNotifications", "Intents", "IntentsUI", "LiveActivitiesWidget", "RichNotifications"]
		let unsupported = try unsupportedNames.map { name in
			try makeBundle("PlugIns/\(name).appex", identifier: "org.frameradar.extension.\(name)")
		}
		let watchApp = try makeBundle("Watch/Example Watch.app", identifier: "org.frameradar.watch")
		let appInfo = appBundle.appendingPathComponent("Info.plist")
		try Data("main app".utf8).write(to: appInfo)

		let removed = try NestedBundleAudit.removeUncoveredBundles(
			in: appBundle,
			profilePattern: "TEAM12345.com.frameradar.app.*"
		)

		XCTAssertEqual(Set(removed.map(\.bundle.displayName)), Set(unsupportedNames.map { "\($0).appex" }))
		XCTAssertTrue(FileManager.default.fileExists(atPath: covered.path))
		for bundle in unsupported {
			XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: appInfo.path), "the main app must remain intact")
		XCTAssertTrue(FileManager.default.fileExists(atPath: watchApp.path), "watch apps are not removable app extensions")
		XCTAssertFalse(removed.contains { $0.bundle.kind == .watchApp })
	}

	func testRemoveAppExtensionsStillRequiresWatchAppCoverage() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")
		try makeBundle("Watch/Example Watch.app", identifier: "com.example.watch")

		XCTAssertEqual(
			NestedBundleAudit.requiredIdentifiers(in: appBundle, removeAppExtensions: true),
			["com.example.watch"]
		)
	}

	func testRetainedWatchStillBlocksAfterAppExtensionsAreRemoved() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")
		let watch = try makeBundle("Watch/Example Watch.app", identifier: "com.other.watch")
		for extensionURL in AppExtensionEnumerator.appexBundles(in: appBundle) {
			try FileManager.default.removeItem(at: extensionURL)
		}

		let remaining = report(pattern: "TEAM.com.example.*")
		XCTAssertTrue(FileManager.default.fileExists(atPath: watch.path))
		XCTAssertEqual(remaining.entries.map(\.bundle.kind), [.watchApp])
		XCTAssertThrowsError(try remaining.requireCompatibleProfile())
	}

	/// An extension is only reported when the comparison actually says no. Without a profile, or
	/// without an identifier, nothing is known — and unknown must never be dressed up as a failure.
	func testWithoutAProfileEverythingIsUnknownAndNeverReported() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		let report = report(pattern: nil)

		XCTAssertEqual(report.entries.first?.coverage, .unknown)
		XCTAssertTrue(report.uncovered.isEmpty)
		XCTAssertTrue(report.isClean)
		XCTAssertEqual(report.profilePattern, nil)
	}

	func testABundleWithoutAnIdentifierIsListedButNotCompared() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: nil)

		let report = report(pattern: "ABCDE12345.com.example.*")

		XCTAssertEqual(report.entries.count, 1)
		XCTAssertEqual(report.entries.first?.bundle.identifier, nil)
		XCTAssertEqual(report.entries.first?.coverage, .unknown)
	}

	func testABlankPatternCountsAsNoProfile() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		let report = report(pattern: "   ")

		XCTAssertEqual(report.profilePattern, nil)
		XCTAssertEqual(report.entries.first?.coverage, .unknown)
	}

	// MARK: Reporting

	func testAnUncoveredBundleIsNamedInTheWarning() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		let report = report(pattern: "ABCDE12345.com.example.app")

		XCTAssertEqual(report.warnings.count, 1)
		let warning = try XCTUnwrap(report.warnings.first)
		XCTAssertTrue(warning.contains("Widget.appex"))
		XCTAssertTrue(warning.contains("com.example.widget"))
		XCTAssertTrue(warning.contains("ABCDE12345.com.example.app"))
	}

	/// An extension that arrives carrying another account's profile is the usual reason an install
	/// fails, and it is nameable before signing starts.
	func testTheWarningNamesTheProfileTheExtensionShips() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		let report = report(pattern: "ABCDE12345.com.example.app", shipped: "OTHER.com.example.widget")

		let warning = try XCTUnwrap(report.warnings.first)
		XCTAssertTrue(warning.contains("OTHER.com.example.widget"))
		XCTAssertEqual(report.entries.first?.shippedProfileIdentifier, "OTHER.com.example.widget")
	}

	func testACoveredAppStillSummarisesWhatWasChecked() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		let report = report(pattern: "ABCDE12345.com.example.*")

		let summary = try XCTUnwrap(report.summary)
		XCTAssertTrue(summary.contains("1"))
		XCTAssertTrue(report.warnings.isEmpty)
	}

	func testAnAppWithoutNestedBundlesHasNothingToReport() {
		let report = report(pattern: "ABCDE12345.com.example.*")

		XCTAssertTrue(report.isEmpty)
		XCTAssertEqual(report.summary, nil)
		XCTAssertTrue(report.warnings.isEmpty)
		XCTAssertTrue(report.isClean)
	}

	// MARK: Required identifiers

	func testRequiredIdentifiersListsEveryNestedBundle() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")
		try makeBundle("Extensions/Share.appex", identifier: "com.example.share")

		XCTAssertEqual(
			NestedBundleAudit.requiredIdentifiers(in: appBundle, removeAppExtensions: false),
			["com.example.share", "com.example.widget"]
		)
	}

	/// Extensions the options strip are gone before the engine runs, so the profile does not have
	/// to cover them — the preflight used to warn about bundles that no longer existed.
	func testStrippedExtensionsAreNotRequired() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")

		XCTAssertEqual(
			NestedBundleAudit.requiredIdentifiers(in: appBundle, removeAppExtensions: true),
			[]
		)
	}

	func testRequiredIdentifiersSkipsBundlesWithoutIdentifiers() throws {
		try makeBundle("PlugIns/Widget.appex", identifier: "com.example.widget")
		try makeBundle("Extensions/Broken.appex", identifier: nil)

		XCTAssertEqual(
			NestedBundleAudit.requiredIdentifiers(in: appBundle, removeAppExtensions: false),
			["com.example.widget"]
		)
	}
}
