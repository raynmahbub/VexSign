//
//  MissingFeatureTests.swift
//  VexSignTests
//
//  Covers the logic behind the features that were added on top of the signing
//  core: PPQ/PPQLess classification, the JIT entitlement builder, the batch
//  certificate result mapping, direct-install verification, App Store lookups,
//  the IPSW catalog models, the widget payload and the immutable tab structure.
//
//  Everything here is pure (no network, no device), so it runs on any host.
//

import XCTest
@testable import VexSign

final class MissingFeatureTests: XCTestCase {

	// MARK: - Helpers

	/// Writes a provisioning-profile plist the way `CertificateReader` expects it.
	private func profile(
		entitlements: [String: Any]? = nil,
		ppqCheck: Bool? = nil,
		provisionsAllDevices: Bool? = nil,
		provisionedDevices: [String]? = nil
	) throws -> Certificate {
		var payload: [String: Any] = [
			"AppIDName": "Test App",
			"CreationDate": Date(timeIntervalSince1970: 0),
			"Platform": ["iOS"],
			"ExpirationDate": Date(timeIntervalSince1970: 2_000_000_000),
			"Name": "Test Profile",
			"TeamIdentifier": ["TESTTEAM"],
			"TeamName": "Test Team",
			"TimeToLive": 365,
			"UUID": "test-profile",
			"Version": 1
		]
		if let entitlements { payload["Entitlements"] = entitlements }
		if let ppqCheck { payload["PPQCheck"] = ppqCheck }
		if let provisionsAllDevices { payload["ProvisionsAllDevices"] = provisionsAllDevices }
		if let provisionedDevices { payload["ProvisionedDevices"] = provisionedDevices }

		let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("\(UUID().uuidString).mobileprovision")
		try data.write(to: url)
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }

		let decoded = CertificateReader(url).decoded
		return try XCTUnwrap(decoded, "CertificateReader could not decode the test profile")
	}

	private func temporaryFile(_ data: Data) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try data.write(to: url)
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		return url
	}

	// MARK: - PPQ / PPQLess

	func testDevelopmentProfileIsPPQAndSupportsJIT() throws {
		let certificate = try profile(entitlements: ["get-task-allow": true, "application-identifier": "TESTTEAM.*"])

		XCTAssertEqual(certificate.profileType, .development)
		XCTAssertFalse(certificate.isPPQLess, "Development profiles are revocable through PPQ")
		XCTAssertTrue(certificate.isPPQTracked)
		XCTAssertTrue(certificate.supportsJIT, "JIT needs get-task-allow, which only development profiles carry")
	}

	func testAdHocProfileIsPPQLess() throws {
		let certificate = try profile(
			entitlements: ["application-identifier": "TESTTEAM.com.example.app"],
			provisionedDevices: ["00008030-001A2C3D4E5F6789"]
		)

		XCTAssertEqual(certificate.profileType, .adHoc)
		XCTAssertTrue(certificate.isPPQLess)
		XCTAssertFalse(certificate.supportsJIT)
	}

	func testEnterpriseProfileIsPPQLess() throws {
		let certificate = try profile(
			entitlements: ["application-identifier": "TESTTEAM.*"],
			provisionsAllDevices: true
		)

		XCTAssertEqual(certificate.profileType, .enterprise)
		XCTAssertTrue(certificate.isPPQLess)
	}

	func testAppStoreDistributionProfileIsPPQLess() throws {
		let certificate = try profile(entitlements: ["application-identifier": "TESTTEAM.com.example.app"])

		XCTAssertEqual(certificate.profileType, .distribution)
		XCTAssertTrue(certificate.isPPQLess)
	}

	func testPPQCheckFlagOverridesDistributionProfile() throws {
		let certificate = try profile(
			entitlements: ["application-identifier": "TESTTEAM.com.example.app"],
			ppqCheck: true
		)

		XCTAssertTrue(certificate.declaresPPQCheck)
		XCTAssertFalse(certificate.isPPQLess, "A profile that declares PPQCheck is tracked even when it looks like distribution")
		XCTAssertTrue(certificate.supportsJIT)
	}

	func testSpecialAccessEntitlementMarksProfileAsPPQ() throws {
		let certificate = try profile(entitlements: [
			"application-identifier": "TESTTEAM.com.example.app",
			"com.apple.developer.ios-special-access": true
		])

		XCTAssertTrue(certificate.hasSpecialAccessEntitlement)
		XCTAssertFalse(certificate.isPPQLess)
	}

	func testProfileWithoutEntitlementsIsUnknownAndNeverPPQLess() throws {
		let certificate = try profile()

		XCTAssertEqual(certificate.profileType, .unknown)
		XCTAssertFalse(certificate.isPPQLess, "An unreadable profile must not claim PPQLess safety")
	}

	// MARK: - JIT entitlements

	func testEntitlementBuilderAddsJITOnlyWhenCertificateSupportsIt() {
		let base: [String: Any] = ["application-identifier": "TESTTEAM.com.example.app"]

		let enabled = EntitlementBuilder.entitlements(base: base, enableJIT: true, supportsJIT: true)
		for key in EntitlementBuilder.jitEntitlementKeys {
			XCTAssertEqual(enabled[key] as? Bool, true, "Missing \(key)")
		}
		XCTAssertEqual(enabled["application-identifier"] as? String, "TESTTEAM.com.example.app")

		let ppqless = EntitlementBuilder.entitlements(base: base, enableJIT: true, supportsJIT: false)
		for key in EntitlementBuilder.jitEntitlementKeys {
			XCTAssertNil(ppqless[key], "\(key) must not be granted to a PPQLess certificate")
		}

		let disabled = EntitlementBuilder.entitlements(base: base, enableJIT: false, supportsJIT: true)
		XCTAssertNil(disabled["dynamic-codesigning"])
	}

	func testEntitlementBuilderReportsWhetherItWouldAddJIT() {
		let base: [String: Any] = ["application-identifier": "TESTTEAM.com.example.app"]
		XCTAssertTrue(EntitlementBuilder.addsJIT(base: base, enableJIT: true, supportsJIT: true))
		XCTAssertFalse(EntitlementBuilder.addsJIT(base: base, enableJIT: false, supportsJIT: true))
		XCTAssertFalse(EntitlementBuilder.addsJIT(base: base, enableJIT: true, supportsJIT: false))

		// Already present: nothing left to add.
		let withJIT: [String: Any] = ["dynamic-codesigning": true,
									  "com.apple.security.cs.allow-jit": true,
									  "com.apple.security.cs.allow-unsigned-executable-memory": true]
		XCTAssertFalse(EntitlementBuilder.addsJIT(base: withJIT, enableJIT: true, supportsJIT: true))
	}

	func testEntitlementBuilderWritesReadablePlist() throws {
		let url = try temporaryFile(Data()).deletingLastPathComponent()
			.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }

		let written = try EntitlementBuilder.write(
			EntitlementBuilder.entitlements(base: ["application-identifier": "TESTTEAM.com.example.app"],
											enableJIT: true, supportsJIT: true),
			to: url
		)

		let dictionary = try XCTUnwrap(NSDictionary(contentsOf: written) as? [String: Any])
		XCTAssertEqual(dictionary["dynamic-codesigning"] as? Bool, true)
		XCTAssertEqual(dictionary["application-identifier"] as? String, "TESTTEAM.com.example.app")
	}

	// MARK: - Batch certificate results

	func testCertCheckResultStatusMapping() {
		let now = Date()

		let revoked = CertCheckResult.make(id: "a", name: "A", teamID: "T", expiryDate: now.addingTimeInterval(86_400 * 30),
										   isRevoked: true, isPPQLess: false, revocationKnown: true)
		XCTAssertEqual(revoked.status, .revoked)
		XCTAssertNotEqual(revoked.supportsJIT, revoked.isPPQLess, "JIT support is the inverse of PPQLess")

		let expired = CertCheckResult.make(id: "b", name: "B", teamID: "T", expiryDate: now.addingTimeInterval(-60),
										   isRevoked: false, isPPQLess: true, revocationKnown: true)
		XCTAssertEqual(expired.status, .expired)
		XCTAssertFalse(expired.supportsJIT)

		// Half a day inside the three-day window: `daysRemaining` counts whole days
		// against the wall clock, so an expiry of exactly `now + 3 days` is already
		// 2.9999 days away by the time `make` reads `Date()` and floors to 2.
		let expiring = CertCheckResult.make(id: "c", name: "C", teamID: "T", expiryDate: now.addingTimeInterval(86_400 * 3 + 43_200),
											isRevoked: false, isPPQLess: false, revocationKnown: true)
		XCTAssertEqual(expiring.status, .expiringSoon)
		XCTAssertEqual(expiring.daysRemaining, 3)

		let valid = CertCheckResult.make(id: "d", name: "D", teamID: "T", expiryDate: now.addingTimeInterval(86_400 * 90),
										 isRevoked: false, isPPQLess: true, revocationKnown: true)
		XCTAssertEqual(valid.status, .valid)
		XCTAssertFalse(valid.supportsJIT, "PPQLess certificates cannot carry JIT")

		let unreadable = CertCheckResult.make(id: "e", name: "E", teamID: "T", expiryDate: nil,
											  isRevoked: false, isPPQLess: false, revocationKnown: false)
		XCTAssertEqual(unreadable.status, .unreadable)

		// In date with no revocation answer is not a checked certificate.
		let notChecked = CertCheckResult.make(id: "f", name: "F", teamID: "T", expiryDate: now.addingTimeInterval(86_400 * 90),
											  isRevoked: false, isPPQLess: false, revocationKnown: false)
		XCTAssertEqual(notChecked.status, .notChecked)
		XCTAssertNotEqual(notChecked.statusTitle, valid.statusTitle)

		// A date problem is still reported when revocation is unknown.
		let expiredUnchecked = CertCheckResult.make(id: "g", name: "G", teamID: "T", expiryDate: now.addingTimeInterval(-60),
													isRevoked: false, isPPQLess: false, revocationKnown: false)
		XCTAssertEqual(expiredUnchecked.status, .expired)
	}

	// MARK: - Direct install

	func testDirectInstallVerificationReportsEveryMissingPiece() {
		let nothing = DirectInstallVerification(bundlePath: nil, hasSignatureDirectory: false,
												hasSignedExecutable: false, unsignedNestedBundles: [])
		XCTAssertFalse(nothing.isSigned)
		XCTAssertEqual(nothing.issues.count, 1)

		let unsigned = DirectInstallVerification(bundlePath: "/tmp/App.app", hasSignatureDirectory: false,
												 hasSignedExecutable: false, unsignedNestedBundles: ["Plugin.appex"])
		XCTAssertFalse(unsigned.isSigned)
		XCTAssertEqual(unsigned.issues.count, 3, "Signature directory, executable and nested bundle")

		let signed = DirectInstallVerification(bundlePath: "/tmp/App.app", hasSignatureDirectory: true,
											   hasSignedExecutable: true, unsignedNestedBundles: [])
		XCTAssertTrue(signed.isSigned)
		XCTAssertTrue(signed.issues.isEmpty)
	}

	func testDirectInstallRejectsMissingBundle() {
		let verification = DirectInstaller.verify(directory: FileManager.default.temporaryDirectory
			.appendingPathComponent("does-not-exist-\(UUID().uuidString)"))
		XCTAssertNil(verification.bundlePath)
		XCTAssertFalse(verification.isSigned)
	}

	// MARK: - App Cloner suggestions

	func testCloneBundleIDSuggestionsAreValid() {
		XCTAssertTrue(AppCloneSheet.isValidBundleID("com.vexsign.cloned.com.example.app"))
		XCTAssertTrue(AppCloneSheet.isValidBundleID("com.example.app"))
		XCTAssertFalse(AppCloneSheet.isValidBundleID("example"))
		XCTAssertFalse(AppCloneSheet.isValidBundleID("com.example..app"))
		XCTAssertFalse(AppCloneSheet.isValidBundleID("com.example.app "))
		XCTAssertFalse(AppCloneSheet.isValidBundleID(""))
		XCTAssertTrue(AppCloneSheet.suggestedBundleID(for: _TestApp(identifier: "com.example.app"))
			.hasPrefix(AppCloneSheet.suggestedPrefix))
	}

	// MARK: - App Store tracking

	func testAppStoreLookupURLCarriesBundleID() throws {
		let url = try XCTUnwrap(AppStoreTracker.requestURL(for: "com.example.app"))
		let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

		XCTAssertEqual(url.absoluteString.hasPrefix(AppStoreTracker.lookupEndpoint), true)
		XCTAssertEqual(query.first(where: { $0.name == "bundleId" })?.value, "com.example.app")
		XCTAssertNil(AppStoreTracker.requestURL(for: "   "))
	}

	func testAppStoreDecoding() throws {
		let payload = """
		{"resultCount":1,"results":[{"trackName":"Example","bundleId":"com.example.app",
		"version":"2.1.0","trackViewUrl":"https://apps.apple.com/app/id1",
		"currentVersionReleaseDate":"2026-01-02T03:04:05Z"}]}
		"""
		let info = try XCTUnwrap(AppStoreTracker.decode(Data(payload.utf8)))
		XCTAssertEqual(info.name, "Example")
		XCTAssertEqual(info.bundleID, "com.example.app")
		XCTAssertEqual(info.version, "2.1.0")
		XCTAssertNotNil(info.releaseDate)

		let empty = try AppStoreTracker.decode(Data(#"{"resultCount":0,"results":[]}"#.utf8))
		XCTAssertNil(empty, "No results means no App Store listing")

		XCTAssertThrowsError(try AppStoreTracker.decode(Data("not json".utf8)))
	}

	func testAppStoreVersionComparisonUsesTheUpdateCheckerRules() {
		XCTAssertTrue(AppStoreTracker.hasUpdate(installedVersion: "2.1.0", latestVersion: "2.2"))
		XCTAssertFalse(AppStoreTracker.hasUpdate(installedVersion: "2.2", latestVersion: "2.1.0"))
		XCTAssertFalse(AppStoreTracker.hasUpdate(installedVersion: nil, latestVersion: "2.2"))
	}

	// MARK: - IPSW catalog

	func testIPSWDeviceAndFirmwareDecoding() throws {
		let devices = """
		[{"name":"iPhone 15 Pro","identifier":"iPhone16,1","boardconfig":"D83AP","platform":"ios"},
		 {"name":"iPad Pro","identifier":"iPad14,5"}]
		"""
		let parsedDevices = try IPSWBrowser.decodeDevices(Data(devices.utf8))
		XCTAssertEqual(parsedDevices.count, 2)
		XCTAssertEqual(parsedDevices.first?.identifier, "iPhone16,1")
		XCTAssertEqual(parsedDevices.first?.id, "iPhone16,1")

		let firmwares = """
		{"name":"iPhone 15 Pro","identifier":"iPhone16,1","firmwares":[
			{"identifier":"iPhone16,1","version":"17.0","buildid":"21A329","filesize":6543210000,
			 "url":"https://updates.cdn-apple.com/x.ipsw","releasedate":"2023-09-18T17:00:00Z","signed":false},
			{"identifier":"iPhone16,1","version":"18.1","buildid":"22B83","filesize":7000000000,
			 "url":"https://updates.cdn-apple.com/y.ipsw","releasedate":"2024-10-28T17:00:00Z","signed":true}]}
		"""
		let parsedFirmwares = try IPSWBrowser.decodeFirmwares(Data(firmwares.utf8))
		XCTAssertEqual(parsedFirmwares.count, 2)
		XCTAssertEqual(parsedFirmwares.last?.filename, "iPhone16,1_18.1_22B83.ipsw")
		XCTAssertTrue(parsedFirmwares.last?.isStillSigned == true)
		XCTAssertFalse(parsedFirmwares.first?.isStillSigned == true)
		XCTAssertNotNil(parsedFirmwares.first?.downloadURL)

		XCTAssertEqual(try IPSWBrowser.decodeFirmwares(Data(#"{"name":"X","identifier":"Y"}"#.utf8)).count, 0)
	}

	func testIPSWCatalogURLs() throws {
		let devicesURL = try XCTUnwrap(IPSWBrowser.devicesURL())
		XCTAssertTrue(devicesURL.absoluteString.hasSuffix("/devices"))

		let firmwaresURL = try XCTUnwrap(IPSWBrowser.firmwaresURL(for: "iPhone16,1"))
		XCTAssertTrue(firmwaresURL.absoluteString.contains("/device/iPhone16,1"))
		XCTAssertTrue(firmwaresURL.absoluteString.contains("type=ipsw"))
		XCTAssertNil(IPSWBrowser.firmwaresURL(for: "  "))
	}

	func testIPSWVersionOrdering() {
		XCTAssertTrue(IPSWBrowser._versionCompare("18.1", "17.5.2"))
		XCTAssertFalse(IPSWBrowser._versionCompare("17.5.2", "18.1"))
		XCTAssertFalse(IPSWBrowser._versionCompare("18.1", "18.1"))
		XCTAssertTrue(IPSWBrowser._versionCompare("18.1.1", "18.1"))
	}

	// MARK: - Widget payload

	func testWidgetPayloadRoundTripsThroughTheAppGroup() throws {
		let payload = WidgetStatusPayload(
			certDaysRemaining: 12,
			certName: "Test Cert",
			certRevoked: false,
			pendingUpdates: 4,
			installedCount: 9,
			signedCount: 5,
			availableBytes: 1_000,
			lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
		)

		let data = try JSONEncoder().encode(payload)
		let decoded = try JSONDecoder().decode(WidgetStatusPayload.self, from: data)
		XCTAssertEqual(decoded, payload)

		// The widget renders from these keys, so they are part of the contract.
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))
		for key in ["certDaysRemaining", "certName", "certRevoked", "pendingUpdates",
					"installedCount", "signedCount", "lastUpdated"] {
			XCTAssertTrue(json.contains(key), "Payload lost the \(key) key")
		}

		XCTAssertEqual(WidgetStatusPayload.placeholder.certLabel, "30d")
		// Twelve days is inside the month window, so the badge warns rather than
		// reassuring; green is reserved for a month or more.
		XCTAssertEqual(payload.certTint, .orange)
		XCTAssertEqual(WidgetStatusPayload.placeholder.certTint, .green)
		XCTAssertEqual(WidgetStatusPayload(certDaysRemaining: 3, certName: nil, certRevoked: false,
										   pendingUpdates: 0, installedCount: 0, signedCount: 0,
										   availableBytes: nil, lastUpdated: Date()).certTint, .red)
		XCTAssertEqual(WidgetStatusPayload(certDaysRemaining: nil, certName: nil, certRevoked: true,
										   pendingUpdates: 0, installedCount: 0, signedCount: 0,
										   availableBytes: nil, lastUpdated: Date()).certTint, .red)
	}

	// MARK: - Tab structure

	func testNavigatorCanHideAndReorderDestinationsButKeepsRecoveryTabs() throws {
		let name = "VexSignNavigatorTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
		defer { defaults.removePersistentDomain(forName: name) }
		let preferences = TabBarPreferences(defaults: defaults)

		XCTAssertEqual(preferences.visibleTabs, [.home, .appStore, .library, .downloads, .settings])
		XCTAssertEqual(TabBarPreferences.requiredTabs, [.home, .settings])
		XCTAssertTrue(TabBarPreferences.secondaryTabs.contains(.sources))

		preferences.setHidden(.library, true)
		XCTAssertFalse(preferences.visibleTabs.contains(.library))
		XCTAssertTrue(preferences.visibleTabs.contains(.home))
		XCTAssertTrue(preferences.visibleTabs.contains(.settings))
		XCTAssertFalse(preferences.isHideable(.home))
		XCTAssertFalse(preferences.isHideable(.settings))

		preferences.defaultLaunch = .appStore
		preferences.setHidden(.appStore, true)
		XCTAssertEqual(preferences.defaultLaunch, .home, "A hidden launch tab falls back to Home")
		preferences.setHidden(.home, true)
		preferences.setHidden(.settings, true)
		XCTAssertTrue(preferences.visibleTabs.contains(.home))
		XCTAssertTrue(preferences.visibleTabs.contains(.settings))

		preferences.setHidden(.library, false)
		let oldOrder = preferences.orderedTabs
		preferences.move(from: IndexSet(integer: 0), to: oldOrder.count)
		XCTAssertNotEqual(preferences.orderedTabs, oldOrder)
		XCTAssertEqual(Set(preferences.orderedTabs), Set(TabEnum.allCases))

		let restored = TabBarPreferences(defaults: defaults)
		XCTAssertEqual(restored.orderedTabs, preferences.orderedTabs)
		XCTAssertFalse(restored.visibleTabs.contains(.appStore))
	}

	func testLegacyDestinationsCanStillBeShownAndHidden() throws {
		let name = "VexSignNavigatorTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
		defer { defaults.removePersistentDomain(forName: name) }
		let preferences = TabBarPreferences(defaults: defaults)

		preferences.setHidden(.sources, false)
		XCTAssertTrue(preferences.visibleTabs.contains(.sources))
		preferences.setHidden(.sources, true)
		XCTAssertTrue(preferences.isHidden(.sources))
		XCTAssertFalse(preferences.visibleTabs.contains(.sources))
	}

	// MARK: - Live Activity & Legacy Refresh Migrations

	func testMigrateLegacyRefreshPreferencesPromotesWifiSettingOnceAndClearsDeadKeys() throws {
		let name = "VexSignLegacyRefreshTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
		defer { defaults.removePersistentDomain(forName: name) }

		defaults.set("Wi-Fi", forKey: "VexSign.downloadsNetworkOption")
		defaults.set(false, forKey: "VexSign.bgRefreshEnabled")
		defaults.set(false, forKey: "VexSign.autoCheckAppUpdates")
		defaults.set("15m", forKey: "VexSign.refreshIntervalString")
		defaults.set("Wi-Fi", forKey: "VexSign.refreshNetworkOption")

		DownloadPreferences.migrateLegacyRefreshPreferences(defaults: defaults)

		XCTAssertTrue(defaults.bool(forKey: DownloadPreferences.wifiOnlyKey))
		XCTAssertNil(defaults.object(forKey: "VexSign.downloadsNetworkOption"))
		XCTAssertNil(defaults.object(forKey: "VexSign.bgRefreshEnabled"))
		XCTAssertNil(defaults.object(forKey: "VexSign.autoCheckAppUpdates"))
		XCTAssertNil(defaults.object(forKey: "VexSign.refreshIntervalString"))
		XCTAssertNil(defaults.object(forKey: "VexSign.refreshNetworkOption"))

		// Must not overwrite an explicit user preference once set.
		defaults.set(false, forKey: DownloadPreferences.wifiOnlyKey)
		defaults.set("Wi-Fi", forKey: "VexSign.downloadsNetworkOption")
		DownloadPreferences.migrateLegacyRefreshPreferences(defaults: defaults)
		XCTAssertFalse(defaults.bool(forKey: DownloadPreferences.wifiOnlyKey))
		XCTAssertNil(defaults.object(forKey: "VexSign.downloadsNetworkOption"))
	}

	// MARK: - Fixtures

	private struct _TestApp: AppInfoPresentable {
		var identifier: String?
		let name: String? = "Example"
		let version: String? = "1.0"
		let originalIdentifier: String? = nil
		let date: Date? = nil
		let icon: String? = nil
		let uuid: String? = "test-uuid"
		let isSigned: Bool = false
		var appDescription: String?
	}
}
