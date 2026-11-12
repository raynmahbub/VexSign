//
//  CompanionAndWidgetTests.swift
//  VexSignTests
//
//  Covers the pure logic behind the new surfaces: the repository widget payload
//  (shared with the widget extension), the companion wire format the Apple TV /
//  Vision Pro / Watch apps speak, and the App Intent entities' resolution rules.
//
//  Everything here is pure — no network, no device, no Core Data writes — so it
//  runs on any host.
//

import XCTest
@testable import VexSign

final class CompanionAndWidgetTests: XCTestCase {

	// MARK: - Repository widget payload

	func testRepoPayloadRoundTripsThroughJSON() throws {
		let payload = WidgetRepoPayload(
			sources: [
				WidgetRepoPayload.Source(
					url: "https://example.com/source.json",
					name: "Example",
					apps: [
						WidgetRepoPayload.App(
							id: "com.example.app.https://example.com/app.ipa",
							name: "Example App",
							bundleID: "com.example.app",
							version: "1.2",
							iconFile: "abc123.png",
							hasUpdate: true
						)
					]
				)
			],
			lastUpdated: Date(timeIntervalSince1970: 1_800_000_000)
		)

		let data = try JSONEncoder().encode(payload)
		let decoded = try JSONDecoder().decode(WidgetRepoPayload.self, from: data)

		XCTAssertEqual(decoded, payload)
		XCTAssertEqual(decoded.appCount, 1)
		XCTAssertEqual(decoded.apps(in: "https://example.com/source.json").first?.name, "Example App")
		XCTAssertTrue(decoded.apps(in: "https://unknown.example").isEmpty)
		XCTAssertEqual(decoded.apps(in: nil).count, 1, "nil means every repository")
	}

	func testRepoPayloadIconNamesAreStableAndUnique() {
		let first = WidgetRepoPayload.iconFileName(for: URL(string: "https://example.com/icon.png")!)
		let again = WidgetRepoPayload.iconFileName(for: URL(string: "https://example.com/icon.png")!)
		let other = WidgetRepoPayload.iconFileName(for: URL(string: "https://example.com/other.png")!)

		XCTAssertEqual(first, again, "the same URL must map to the same cache file")
		XCTAssertNotEqual(first, other)
		XCTAssertTrue(first.hasSuffix(".png"))
		XCTAssertEqual(first.count, 64 + 4, "sha256 hex + .png")
	}

	func testRepoPayloadStaleness() {
		let fresh = WidgetRepoPayload(sources: [], lastUpdated: Date())
		let old = WidgetRepoPayload(sources: [], lastUpdated: Date().addingTimeInterval(-60 * 60 * 25))

		XCTAssertFalse(fresh.isStale)
		XCTAssertTrue(old.isStale)
	}

	func testRepoPayloadPlaceholderIsRenderable() {
		let placeholder = WidgetRepoPayload.placeholder
		XCTAssertFalse(placeholder.sources.isEmpty)
		XCTAssertFalse(placeholder.sources[0].apps.isEmpty)
		XCTAssertFalse(placeholder.isStale)
	}

	// MARK: - Companion wire format

	func testCompanionSnapshotRoundTripsThroughWatchContext() throws {
		let snapshot = CompanionSnapshot(
			status: CompanionStatus(
				certValid: true,
				certName: "Development",
				certExpiry: nil,
				certDaysRemaining: 12,
				certRevoked: false,
				certPPQLess: true,
				installedApps: 7,
				signedApps: 5,
				pendingUpdates: 2,
				storageFree: 1_000_000
			),
			library: [CompanionLibraryEntry(name: "App", bundleID: "com.example.app", version: "1.0", size: 42, signed: true)],
			updates: [CompanionUpdateEntry(name: "App", bundleID: "com.example.app", installedVersion: "1.0", availableVersion: "1.1")],
			generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
		)

		let context = snapshot.contextRepresentation
		let decoded = try XCTUnwrap(CompanionSnapshot.snapshot(from: context))

		XCTAssertEqual(decoded, snapshot)
		XCTAssertEqual(decoded.status.certLabel, "12d")
		XCTAssertEqual(decoded.status.certSummary, "Expires in 12 days")
	}

	func testCompanionSnapshotContextIsRejectableWithoutCrashing() {
		XCTAssertNil(CompanionSnapshot.snapshot(from: [:]))
		XCTAssertNil(CompanionSnapshot.snapshot(from: [CompanionSnapshot.contextKey: Data("not json".utf8)]))
		XCTAssertNil(CompanionSnapshot.snapshot(from: [CompanionSnapshot.contextKey: "wrong type"]))
	}

	func testCompanionStatusLabelsCoverEveryState() {
		func status(days: Int?, revoked: Bool = false) -> CompanionStatus {
			CompanionStatus(
				certValid: !revoked,
				certName: nil,
				certExpiry: nil,
				certDaysRemaining: days,
				certRevoked: revoked,
				certPPQLess: nil,
				installedApps: 0,
				signedApps: 0,
				pendingUpdates: 0,
				storageFree: nil
			)
		}

		XCTAssertEqual(status(days: nil).certLabel, "—")
		XCTAssertEqual(status(days: nil).certSummary, "No certificate")
		XCTAssertEqual(status(days: 0).certLabel, "0d")
		XCTAssertEqual(status(days: 0).certSummary, "Expired")
		XCTAssertEqual(status(days: 1).certSummary, "Expires tomorrow")
		XCTAssertEqual(status(days: 30).certSummary, "Expires in 30 days")
		XCTAssertEqual(status(days: 30, revoked: true).certSummary, "Revoked")
	}

	func testCompanionCommandsHaveStableRawValues() {
		// The watch sends these strings; changing one silently breaks a shipped watch app.
		XCTAssertEqual(CompanionCommand.allCases.map { $0.rawValue }, [
			"refreshSources", "checkCertificates", "updateAll", "cleanNow"
		])
		XCTAssertEqual(CompanionCommand(rawValue: "updateAll")?.title, "Update all apps")
		XCTAssertNil(CompanionCommand(rawValue: "signEverything"))
	}

	func testLibraryEntryFormatting() {
		let entry = CompanionLibraryEntry(name: "App", bundleID: "com.example.app", version: "1.0", size: 1_500_000, signed: true)
		XCTAssertFalse(entry.sizeLabel.isEmpty)
		XCTAssertEqual(entry.id, "com.example.app1.0")
	}

	// MARK: - Companion client

	func testCompanionClientRejectsEmptyAndNonHTTPAddresses() async {
		for address in ["", "   "] {
			let client = CompanionClient(address: address, username: nil, password: nil, apiToken: nil)
			do {
				_ = try await client.snapshot()
				XCTFail("an empty address must not produce a snapshot")
			} catch let error as CompanionClientError {
				XCTAssertEqual(error, .missingAddress)
			} catch {
				XCTFail("unexpected error \(error)")
			}
		}

		let invalid = CompanionClient(address: "ftp://10.0.0.5:8080", username: nil, password: nil, apiToken: nil)
		do {
			_ = try await invalid.snapshot()
			XCTFail("a non-http scheme must be refused")
		} catch let error as CompanionClientError {
			XCTAssertEqual(error, .invalidAddress)
		} catch {
			XCTFail("unexpected error \(error)")
		}
	}

	// MARK: - Companion transport policy

	/// The companion sends a Web Manager password and API token, so plaintext HTTP has to be
	/// a deliberate local-network choice rather than the default. These drive the pure policy
	/// function; no request is made.
	func testCompanionTransportDefaultsToHTTPS() throws {
		// A typed host with no scheme used to become `http://` silently.
		let bare = try CompanionClient.transport(for: "192.168.1.20:8080", allowInsecureHTTP: false)
		XCTAssertEqual(bare.scheme, "https")
		XCTAssertEqual(bare.host, "192.168.1.20")
		XCTAssertEqual(bare.port, 8080)

		let explicit = try CompanionClient.transport(for: "https://example.com/", allowInsecureHTTP: false)
		XCTAssertEqual(explicit.scheme, "https")
	}

	func testCompanionTransportRefusesPlainHTTPUnlessOptedIn() {
		XCTAssertThrowsError(try CompanionClient.transport(for: "http://192.168.1.20:8080", allowInsecureHTTP: false)) {
			XCTAssertEqual($0 as? CompanionClientError, .insecureTransport)
		}
	}

	func testCompanionTransportAllowsHTTPOnlyOnALocalNetworkOnceOptedIn() throws {
		for address in ["http://192.168.1.20:8080", "http://10.0.0.5:8080", "http://172.16.4.2:8080",
						"http://127.0.0.1:8080", "http://169.254.10.2:8080", "http://iphone.local:8080",
						"http://[fd00::1]:8080"] {
			XCTAssertNoThrow(try CompanionClient.transport(for: address, allowInsecureHTTP: true), address)
		}

		// The opt-in covers a LAN, not the public internet: a plaintext credential sent to a
		// public host is not made safer by a switch meant for a home network.
		for address in ["http://vexsign.example.com:8080", "http://8.8.8.8:8080", "http://172.32.0.1:8080"] {
			XCTAssertThrowsError(try CompanionClient.transport(for: address, allowInsecureHTTP: true), address) {
				XCTAssertEqual($0 as? CompanionClientError, .insecureTransport)
			}
		}
	}

	func testLocalNetworkClassification() {
		let local = ["localhost", "::1", "iphone.local", "192.168.0.1", "10.255.255.254",
					 "172.16.0.1", "172.31.255.254", "127.0.0.1", "169.254.1.1", "fe80::1", "fd12::1"]
		for host in local {
			XCTAssertTrue(CompanionClient.isLocalNetworkHost(host), host)
		}

		let remote = ["example.com", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1",
					  "11.0.0.1", "2001:4860:4860::8888", "192.168.1", "192.168.1.300"]
		for host in remote {
			XCTAssertFalse(CompanionClient.isLocalNetworkHost(host), host)
		}
	}

	func testCompanionTransportRejectsEmbeddedCredentialsAndBadSchemes() {
		for address in ["https://user:pass@192.168.1.20:8080", "ftp://192.168.1.20:8080",
						"https://", "   "] {
			XCTAssertThrowsError(try CompanionClient.transport(for: address, allowInsecureHTTP: true), address)
		}
	}

	func testAnHTTPSAddressIsNeverDowngradedToHTTP() {
		// Whatever the opt-in says, an explicit https address stays https. A failed connection
		// must not become a plaintext retry, which is how a downgrade attack looks.
		for allow in [true, false] {
			let url = try? CompanionClient.transport(for: "https://192.168.1.20:8080", allowInsecureHTTP: allow)
			XCTAssertEqual(url?.scheme, "https")
		}
	}

	// MARK: - Redirect and TLS-trust policy

	/// `URLSession` copies request headers onto a redirect, so following one to another host
	/// hands that host `Authorization` and `X-VexSign-Token`. Refusing is the whole point of the
	/// delegate, not a side effect of it.
	func testCompanionRefusesEveryRedirect() throws {
		let delegate = SameOriginRedirects()
		let original = URLRequest(url: try XCTUnwrap(URL(string: "https://192.168.1.20:8080/api/status")))
		let targets = [
			"https://192.168.1.20:8080/api/status/",                 // same host, trailing slash
			"http://192.168.1.20:8080/api/status",                   // scheme downgrade
			"https://evil.example.com/api/status",                   // cross-host
			"https://192.168.1.20:9090/api/status",                  // same host, different port
			"https://user:pass@192.168.1.20:8080/api/status"         // credentials in the URL
		]
		for target in targets {
			var forwarded: URLRequest?
			let response = try XCTUnwrap(HTTPURLResponse(
				url: original.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]))
			let redirected = URLRequest(url: try XCTUnwrap(URL(string: target)))

			delegate.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: original),
								willPerformHTTPRedirection: response, newRequest: redirected) { request in
				forwarded = request
			}
			XCTAssertNil(forwarded, "a redirect to \(target) must not be followed")
		}
	}

	/// The companion relies on the system trust evaluation. A permissive `didReceive challenge`
	/// handler or an ephemeral trust override would make "HTTPS" meaningless, so its absence is
	/// asserted at the source level — it cannot be tested by connecting to a bad certificate here.
	func testCompanionNeverOverridesTLSValidation() throws {
		let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("VexSign/Companion/CompanionClient.swift"))
		for forbidden in ["serverTrust", "didReceive challenge", "URLAuthenticationChallenge",
						  "SecTrustEvaluate", "SecTrustSetAnchorCertificates", "allowsAnyHTTPSCertificate"] {
			XCTAssertFalse(source.contains(forbidden),
						   "\(forbidden) would bypass certificate validation")
		}
		// A request-level delegate is present so redirects are controlled.
		XCTAssertTrue(source.contains("URLSessionTaskDelegate"))
	}

	/// The credential headers exist only for the configured peer. Nothing may be added to a
	/// redirect, and no second request may be made with the token to a different origin.
	func testCompanionBuildsCredentialHeadersOnlyForTheConfiguredOrigin() throws {
		let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("VexSign/Companion/CompanionClient.swift"))
		// One request construction site: headers cannot be re-attached somewhere else.
		XCTAssertEqual(source.components(separatedBy: "URLRequest(url:").count - 1, 1)
		XCTAssertEqual(source.components(separatedBy: "\"Authorization\"").count - 1, 1)
		XCTAssertEqual(source.components(separatedBy: "\"X-VexSign-Token\"").count - 1, 1)
	}

	// MARK: - Companion credential storage

	func testCompanionCredentialKeysAreNoLongerPreferenceBacked() throws {
		// The store must not write the password or token back into UserDefaults. The source is
		// the contract here: the values are Keychain accounts now.
		let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("VexSign/Companion/CompanionStore.swift"))
		XCTAssertTrue(source.contains("CompanionSecretStore"))
		XCTAssertTrue(source.contains("credentialIssue"), "a failed Keychain write has to be reported")
		for key in ["VexSign.companion.password", "VexSign.companion.token"] {
			// Still named, so an upgrade can migrate them — but only through `migrate`.
			XCTAssertTrue(source.contains(key), "\(key) must stay readable for migration")
		}
		// A `didSet` that stores the secret in preferences is exactly the defect.
		XCTAssertFalse(source.contains("UserDefaults.standard.set(password,"))
		XCTAssertFalse(source.contains("UserDefaults.standard.set(apiToken,"))
	}

	func testCompanionSecretAccountsAreDistinctAndStable() {
		// A rename would orphan a stored credential; a collision would make the token
		// overwrite the password.
		XCTAssertNotEqual(CompanionSecretStore.Account.password, CompanionSecretStore.Account.apiToken)
		XCTAssertEqual(CompanionSecretStore.Account.password, "webManager.password")
		XCTAssertEqual(CompanionSecretStore.Account.apiToken, "webManager.apiToken")
	}

	// MARK: - App Intent entities

	@available(iOS 17.0, *)
	func testSectionEnumMapsOnlyRealTabs() {
		XCTAssertNil(VexSignSection.ipaExplorer.tab, "the explorer is opened through AppNavigationManager, not a tab")
		XCTAssertEqual(VexSignSection.appStore.tab, .appStore)
		XCTAssertEqual(VexSignSection.library.tab, .library)
		XCTAssertEqual(VexSignSection.caseDisplayRepresentations.count, VexSignSection.allCases.count)
	}
}
