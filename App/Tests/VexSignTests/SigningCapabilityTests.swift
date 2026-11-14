//
//  SigningCapabilityTests.swift
//  VexSignTests
//
//  The capability vocabulary and the nested-bundle plan, tested as values rather than
//  through a running sign: neither type touches Core Data, a session or the engine, so the
//  status ordering and the signing order can be asserted on a temporary directory.
//

import XCTest
@testable import VexSign
import NimbleExtensions

final class SigningCapabilityTests: XCTestCase {
	// MARK: - Status ordering

	func testStatusOrderingRunsFromSupportedToUnsupported() {
		let ordered: [SigningCapabilityStatus] = [
			.supported,
			.requiresAction,
			.ambiguous,
			.incompatible,
			.invalid,
			.expired,
			.unsupported
		]

		for (index, status) in ordered.enumerated() {
			for later in ordered[(index + 1)...] {
				XCTAssertLessThan(status, later, "\(status) must rank below \(later)")
				XCTAssertGreaterThan(later, status)
			}
			XCTAssertEqual(max(status, status), status)
		}
	}

	func testEveryStatusHasATitle() {
		for status in SigningCapabilityStatus.allCases {
			XCTAssertFalse(status.title.isEmpty, "\(status) has no title")
		}
	}

	// MARK: - Report

	func testReportWithoutIssuesIsSupportedAndProceeds() {
		let report = SigningCapability(issues: [])

		XCTAssertEqual(report.status, .supported)
		XCTAssertTrue(report.canProceed)
		XCTAssertTrue(report.blocking.isEmpty)
		XCTAssertTrue(report.advisories.isEmpty)
		XCTAssertEqual(report.summary, SigningCapabilityStatus.supported.title)
		XCTAssertTrue(report.logLines.isEmpty)
	}

	func testAdvisoryIssueIsReportedWithoutStoppingTheRun() {
		let report = SigningCapability(issues: [
			SigningCapability.Issue(
				code: .signerMismatch,
				severity: .advisory,
				title: .localized("Signed by a different certificate"),
				detail: .localized("The update will be signed by another identity.")
			)
		])

		XCTAssertTrue(report.canProceed)
		XCTAssertEqual(report.status, .supported)
		XCTAssertEqual(report.advisories.count, 1)
		XCTAssertEqual(report.logLines.count, 1)
		XCTAssertTrue(report.logLines[0].contains("Capability note"))
		// The code is in the line, so a log can be matched without parsing prose.
		XCTAssertTrue(report.logLines[0].contains("signerMismatch"))
	}

	func testBlockingIssueStopsTheRunAndSummaryCarriesTheRemediation() {
		let report = SigningCapability(issues: [
			SigningCapability.Issue(
				code: .profileMissing,
				severity: .blocking,
				status: .requiresAction,
				title: .localized("No provisioning profile"),
				detail: .localized("This app needs a profile that covers it."),
				remediation: .localized("Import the .mobileprovision file that came with this certificate.")
			)
		])

		XCTAssertFalse(report.canProceed)
		XCTAssertEqual(report.status, .requiresAction)
		XCTAssertTrue(report.summary.hasPrefix(report.blocking[0].detail))
		XCTAssertTrue(report.summary.contains("Import the .mobileprovision"))
	}

	func testWorstIssueDecidesTheStatus() {
		let report = SigningCapability(issues: [
			_advisory(.signerMismatch),
			_blocking(.certificateExpired, status: .expired),
			_blocking(.extensionNotCovered, status: .incompatible)
		])

		XCTAssertEqual(report.status, .expired)
	}

	func testLogLinesAreOrderedWorstFirstThenByCode() {
		let report = SigningCapability(issues: [
			_advisory(.signerMismatch),
			_blocking(.certificateExpired, status: .expired),
			_blocking(.bundleIdentifierMissing, status: .invalid),
			// Same status as the line above; the code breaks the tie so the order is stable.
			_blocking(.appIdentifierMismatch, status: .invalid)
		])

		let lines = report.logLines
		XCTAssertEqual(lines.count, 4)
		XCTAssertTrue(lines[0].contains("certificateExpired"))
		XCTAssertTrue(lines[1].contains("appIdentifierMismatch"))
		XCTAssertTrue(lines[2].contains("bundleIdentifierMissing"))
		XCTAssertTrue(lines[3].contains("Capability note"))
		// Determinism: the same input produces the same lines.
		XCTAssertEqual(lines, report.logLines)
	}

	func testIssueIdentityIsCodeAndDetail() {
		let first = SigningCapability.Issue(
			code: .profileMissing,
			severity: .blocking,
			title: .localized("No provisioning profile"),
			detail: .localized("Same sentence")
		)
		let second = SigningCapability.Issue(
			code: .profileMissing,
			severity: .advisory,
			title: .localized("Different title"),
			detail: .localized("Same sentence")
		)

		XCTAssertEqual(first.id, second.id)
		XCTAssertNotEqual(first, second)
	}

	// MARK: - Plan discovery

	func testEmptyBundleHasAnEmptyPlan() throws {
		let app = try _makeApp()
		let plan = SigningPlan.make(appBundle: app)

		XCTAssertTrue(plan.isEmpty)
		XCTAssertTrue(plan.validationIssues().isEmpty)
	}

	func testPlanFindsExtensionsWatchAppsFrameworksAndDylibs() throws {
		let app = try _makeApp()
		try _makeBundle(at: app, path: "PlugIns/Widget.appex", identifier: "com.example.app.widget", executable: "Widget")
		try _makeBundle(at: app, path: "Watch/App.app", identifier: "com.example.app.watchkitapp", executable: "App")
		try _makeBundle(
			at: app,
			path: "Watch/App.app/PlugIns/WatchWidget.appex",
			identifier: "com.example.app.watchkitapp.widget",
			executable: "WatchWidget"
		)
		try _makeBundle(at: app, path: "Frameworks/Kit.framework", identifier: "com.example.kit", executable: "Kit")
		try _makeFile(at: app, path: "Injected.dylib", executable: true)

		let plan = SigningPlan.make(appBundle: app)
		let kinds = Dictionary(uniqueKeysWithValues: plan.components.map { ($0.path, $0.kind) })

		XCTAssertEqual(kinds["PlugIns/Widget.appex"], .appExtension)
		XCTAssertEqual(kinds["Watch/App.app"], .watchApp)
		XCTAssertEqual(kinds["Watch/App.app/PlugIns/WatchWidget.appex"], .watchExtension)
		XCTAssertEqual(kinds["Frameworks/Kit.framework"], .framework)
		XCTAssertEqual(kinds["Injected.dylib"], .dylib)

		// Only the bundles iOS requires a profile for are profile-bound.
		let bound = plan.profileBoundComponents.map(\.path)
		XCTAssertEqual(
			Set(bound),
			[
				"PlugIns/Widget.appex",
				"Watch/App.app",
				"Watch/App.app/PlugIns/WatchWidget.appex"
			]
		)
		XCTAssertTrue(plan.validationIssues().isEmpty, "a well-formed bundle must not be blocked")
	}

	func testPlanCompletenessTreatsDylibsAsCodeRatherThanBundles() {
		let dylib = SigningPlan.Component(path: "Library.dylib", kind: .dylib, identifier: nil, hasExecutable: true)
		let missingDylib = SigningPlan.Component(path: "Missing.dylib", kind: .dylib, identifier: nil, hasExecutable: false)
		let unidentifiedBundle = SigningPlan.Component(
			path: "Widget.appex", kind: .appExtension, identifier: nil, hasExecutable: true
		)
		let completeBundle = SigningPlan.Component(
			path: "Widget.appex", kind: .appExtension, identifier: "com.example.widget", hasExecutable: true
		)

		XCTAssertTrue(dylib.isStructurallyComplete)
		XCTAssertFalse(missingDylib.isStructurallyComplete)
		XCTAssertFalse(unidentifiedBundle.isStructurallyComplete)
		XCTAssertTrue(completeBundle.isStructurallyComplete)
	}

	func testPlanRecognizesLooseAndNestedDylibFilesAsTheirOwnExecutables() throws {
		let app = try _makeApp()
		try _makeFile(at: app, path: "Loose.DYLIB", executable: true)
		try _makeFile(at: app, path: "Frameworks/Nested.DyLiB", executable: true)
		try _makeFile(at: app, path: "Notes.txt", executable: true)

		let plan = SigningPlan.make(appBundle: app)
		XCTAssertEqual(plan.components.map(\.path), ["Frameworks/Nested.DyLiB", "Loose.DYLIB"])
		XCTAssertTrue(plan.components.allSatisfy {
			$0.kind == .dylib && $0.hasExecutable && $0.isStructurallyComplete
		})
		XCTAssertTrue(plan.profileBoundComponents.isEmpty)
		XCTAssertTrue(plan.validationIssues().isEmpty)
	}

	func testPlanSkipsLinkedDylibsAndDirectoriesNamedDylib() throws {
		let app = try _makeApp()
		try _makeFile(at: app, path: "Real.dylib", executable: true)
		let manager = FileManager.default
		let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
		try manager.createDirectory(at: frameworks, withIntermediateDirectories: true)
		let target = app.appendingPathComponent("Real.dylib")
		try manager.createSymbolicLink(at: app.appendingPathComponent("Linked.dylib"), withDestinationURL: target)
		try manager.createSymbolicLink(at: frameworks.appendingPathComponent("Linked.dylib"), withDestinationURL: target)
		try manager.createDirectory(at: app.appendingPathComponent("Folder.dylib"), withIntermediateDirectories: true)
		try manager.createDirectory(at: frameworks.appendingPathComponent("Folder.dylib"), withIntermediateDirectories: true)

		let plan = SigningPlan.make(appBundle: app)
		XCTAssertEqual(plan.components.map(\.path), ["Real.dylib"])
		XCTAssertTrue(plan.validationIssues().isEmpty)
	}

	func testPlanAdvisesWhenADylibIsNotExecutable() throws {
		let app = try _makeApp()
		try _makeFile(at: app, path: "NotExecutable.dylib", executable: false)

		let plan = SigningPlan.make(appBundle: app)
		let component = try XCTUnwrap(plan.components.first)
		XCTAssertEqual(component.kind, .dylib)
		XCTAssertFalse(component.hasExecutable)
		XCTAssertFalse(component.isStructurallyComplete)
		let issue = try XCTUnwrap(plan.validationIssues().first)
		XCTAssertEqual(issue.code, .nestedComponentInvalid)
		XCTAssertEqual(issue.severity, .advisory)
	}

	func testPlanIsSignedDeepestFirstAndStableBetweenRuns() throws {
		let app = try _makeApp()
		try _makeBundle(at: app, path: "PlugIns/Widget.appex", identifier: "com.example.app.widget", executable: "Widget")
		try _makeBundle(at: app, path: "Frameworks/Kit.framework", identifier: "com.example.kit", executable: "Kit")
		try _makeBundle(at: app, path: "Watch/App.app", identifier: "com.example.app.watchkitapp", executable: "App")
		try _makeBundle(
			at: app,
			path: "Watch/App.app/PlugIns/WatchWidget.appex",
			identifier: "com.example.app.watchkitapp.widget",
			executable: "WatchWidget"
		)
		try _makeFile(at: app, path: "Injected.dylib", executable: true)

		let plan = SigningPlan.make(appBundle: app)
		XCTAssertEqual(
			plan.components.map(\.path),
			[
				"Watch/App.app/PlugIns/WatchWidget.appex",
				"Frameworks/Kit.framework",
				"PlugIns/Widget.appex",
				"Watch/App.app",
				"Injected.dylib"
			]
		)
		XCTAssertEqual(plan, SigningPlan.make(appBundle: app))
	}

	func testPlanFollowsNoSymbolicLinks() throws {
		let app = try _makeApp()
		let outside = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: outside) }
		try _makeBundle(at: outside, path: "Linked.appex", identifier: "com.example.linked", executable: "Linked")

		let plugins = app.appendingPathComponent("PlugIns", isDirectory: true)
		try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(
			at: plugins.appendingPathComponent("Linked.appex"),
			withDestinationURL: outside.appendingPathComponent("Linked.appex")
		)

		let plan = SigningPlan.make(appBundle: app)
		XCTAssertTrue(plan.isEmpty, "a symlinked bundle would be signed twice under two paths")
	}

	func testPlanDoesNotFollowSymlinkedDiscoveryRoots() throws {
		let app = try _makeApp()
		let manager = FileManager.default
		let outside = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try manager.createDirectory(at: outside, withIntermediateDirectories: true)
		defer { try? manager.removeItem(at: outside) }
		try _makeBundle(at: outside, path: "Widget.appex", identifier: "com.example.widget", executable: "Widget")
		try _makeBundle(at: outside, path: "Kit.framework", identifier: "com.example.kit", executable: "Kit")
		try _makeBundle(at: outside, path: "Frameworks/Kit.framework", identifier: "com.example.kit", executable: "Kit")
		try manager.createSymbolicLink(at: app.appendingPathComponent("PlugIns"), withDestinationURL: outside)
		try manager.createSymbolicLink(at: app.appendingPathComponent("Frameworks"), withDestinationURL: outside)
		try manager.createSymbolicLink(at: app.appendingPathComponent("Library"), withDestinationURL: outside)

		let plan = SigningPlan.make(appBundle: app)
		XCTAssertTrue(plan.isEmpty, "discovery roots and intermediate directories must not follow symlinks")
	}

	func testPlanBlocksAnExtensionWithoutAnIdentifier() throws {
		let app = try _makeApp()
		try _makeBundle(at: app, path: "PlugIns/Broken.appex", identifier: nil, executable: "Broken")

		let issues = SigningPlan.make(appBundle: app).validationIssues()
		let issue = try XCTUnwrap(issues.first)
		XCTAssertEqual(issue.code, .bundleIdentifierMissing)
		XCTAssertEqual(issue.severity, .blocking)
		XCTAssertNotNil(issue.remediation)
		XCTAssertTrue(issue.detail.contains("PlugIns/Broken.appex"))
	}

	func testPlanBlocksAnExtensionWithoutAnExecutable() throws {
		let app = try _makeApp()
		try _makeBundle(at: app, path: "PlugIns/Empty.appex", identifier: "com.example.app.empty", executable: nil)

		let issues = SigningPlan.make(appBundle: app).validationIssues()
		let issue = try XCTUnwrap(issues.first)
		XCTAssertEqual(issue.code, .executableUnavailable)
		XCTAssertEqual(issue.severity, .blocking)
	}

	func testPlanDoesNotBlockOnAFrameworkWithoutAnExecutable() throws {
		let app = try _makeApp()
		try _makeBundle(at: app, path: "Frameworks/Thin.framework", identifier: "com.example.thin", executable: nil)

		let issues = SigningPlan.make(appBundle: app).validationIssues()
		let issue = try XCTUnwrap(issues.first)
		XCTAssertEqual(issue.severity, .advisory)
		XCTAssertTrue(SigningCapability(issues: issues).canProceed)
	}

	// MARK: - Helpers

	private func _advisory(_ code: SigningCapability.Issue.Code) -> SigningCapability.Issue {
		SigningCapability.Issue(
			code: code,
			severity: .advisory,
			title: code.rawValue,
			detail: "note: \(code.rawValue)"
		)
	}

	private func _blocking(
		_ code: SigningCapability.Issue.Code,
		status: SigningCapabilityStatus
	) -> SigningCapability.Issue {
		SigningCapability.Issue(
			code: code,
			severity: .blocking,
			status: status,
			title: code.rawValue,
			detail: "blocked: \(code.rawValue)"
		)
	}

	/// A temporary directory to act as an app bundle.
	private func _makeApp() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("VexSignTests-\(UUID().uuidString).app", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		return url
	}

	/// Writes an `Info.plist`, and an executable when a name is given, inside `path`.
	private func _makeBundle(
		at root: URL,
		path: String,
		identifier: String?,
		executable: String?
	) throws {
		let bundle = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
		try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

		var plist: [String: Any] = ["CFBundlePackageType": "XPC!"]
		if let identifier {
			plist["CFBundleIdentifier"] = identifier
		}
		if let executable {
			plist["CFBundleExecutable"] = executable
			try _makeFile(at: bundle, path: executable, executable: true)
		}
		let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
		try data.write(to: bundle.appendingPathComponent("Info.plist"))
	}

	private func _makeFile(at root: URL, path: String, executable: Bool) throws {
		let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([0xCF, 0xFA, 0xED, 0xFE])))
		if executable {
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
		}
	}
}
