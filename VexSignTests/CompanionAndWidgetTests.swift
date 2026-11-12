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

import Foundation
import Security
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

	func testCompanionCertificateFingerprintPairingValidatesCAChainAndHostname() throws {
		let host = "192.168.1.20"
		let identity = try DeviceTLSIdentity.generate(serverNames: ["127.0.0.1", "localhost", host])
		let expected = CompanionCertificateTrust.fingerprint(identity.rootCertificate)
		let trust = try _serverTrust(for: identity, hostname: host)

		let accepted = try CompanionCertificateTrust.validate(
			serverTrust: trust,
			host: host,
			pinned: nil,
			expectedFingerprint: expected
		)
		XCTAssertEqual(accepted, identity.rootCertificate)

		let pin = CompanionCertificateTrust.Pin(certificate: identity.rootCertificate, fingerprint: expected)
		let storedTrust = try _serverTrust(for: identity, hostname: host)
		XCTAssertEqual(
			try CompanionCertificateTrust.validate(serverTrust: storedTrust, host: host, pinned: pin, expectedFingerprint: nil),
			identity.rootCertificate
		)
	}

	func testCompanionCertificateTrustRejectsInvalidAndMismatchedCertificates() throws {
		let host = "192.168.1.20"
		let presented = try DeviceTLSIdentity.generate(serverNames: [host])
		let otherDevice = try DeviceTLSIdentity.generate(serverNames: [host])
		let wrongFingerprintTrust = try _serverTrust(for: presented, hostname: host)
		XCTAssertThrowsError(try CompanionCertificateTrust.validate(
			serverTrust: wrongFingerprintTrust,
			host: host,
			pinned: nil,
			expectedFingerprint: CompanionCertificateTrust.fingerprint(otherDevice.rootCertificate)
		)) { error in
			XCTAssertEqual(error as? CompanionClientError, .certificateFingerprintMismatch)
		}

		let wrongHostTrust = try _serverTrust(for: presented, hostname: "wrong.example.invalid")
		XCTAssertThrowsError(try CompanionCertificateTrust.validate(
			serverTrust: wrongHostTrust,
			host: "wrong.example.invalid",
			pinned: nil,
			expectedFingerprint: CompanionCertificateTrust.fingerprint(presented.rootCertificate)
		)) { error in
			XCTAssertEqual(error as? CompanionClientError, .invalidServerCertificate)
		}

		let corruptPin = CompanionCertificateTrust.Pin(certificate: Data("not a certificate".utf8), fingerprint: "00")
		let corruptTrust = try _serverTrust(for: presented, hostname: host)
		XCTAssertThrowsError(try CompanionCertificateTrust.validate(
			serverTrust: corruptTrust,
			host: host,
			pinned: corruptPin,
			expectedFingerprint: nil
		)) { error in
			XCTAssertEqual(error as? CompanionClientError, .invalidStoredTrust)
		}
	}

	func testChangedTrustedDeviceCertificateFailsClosed() throws {
		let host = "192.168.1.20"
		let original = try DeviceTLSIdentity.generate(serverNames: [host])
		let replacement = try DeviceTLSIdentity.generate(serverNames: [host])
		let pin = CompanionCertificateTrust.Pin(
			certificate: original.rootCertificate,
			fingerprint: CompanionCertificateTrust.fingerprint(original.rootCertificate)
		)
		let trust = try _serverTrust(for: replacement, hostname: host)

		XCTAssertThrowsError(try CompanionCertificateTrust.validate(
			serverTrust: trust,
			host: host,
			pinned: pin,
			expectedFingerprint: nil
		)) { error in
			XCTAssertEqual(error as? CompanionClientError, .certificateChanged)
		}
	}

	func testHTTPSPairingRequiresFingerprintAndCannotSilentlyReplaceSavedTrust() throws {
		let fingerprint = String(repeating: "AB", count: 32)
		XCTAssertThrowsError(try CompanionCertificateTrust.expectedFingerprint(for: nil, entered: nil)) { error in
			XCTAssertEqual(error as? CompanionClientError, .certificatePairingRequired)
		}
		XCTAssertEqual(
			try XCTUnwrap(CompanionCertificateTrust.expectedFingerprint(for: nil, entered: fingerprint)),
			fingerprint
		)

		let pin = CompanionCertificateTrust.Pin(certificate: Data(), fingerprint: fingerprint)
		XCTAssertNil(try CompanionCertificateTrust.expectedFingerprint(for: pin, entered: fingerprint))
		XCTAssertThrowsError(try CompanionCertificateTrust.expectedFingerprint(
			for: pin,
			entered: String(repeating: "CD", count: 32)
		)) { error in
			XCTAssertEqual(error as? CompanionClientError, .certificateChangeRequiresExplicitForget)
		}
	}

	func testFingerprintInputRequiresACompleteSHA256Digest() {
		let digest = String(repeating: "A1:", count: 31) + "A1"
		XCTAssertEqual(try XCTUnwrap(CompanionCertificateTrust.normalizedFingerprint(digest)), String(repeating: "A1", count: 32))
		XCTAssertNil(CompanionCertificateTrust.normalizedFingerprint("A1:02"))
		XCTAssertNil(CompanionCertificateTrust.normalizedFingerprint(String(repeating: "GG", count: 32)))
	}

	func testCompanionClientKeepsEmptyDataDistinctFromAnEndpointFailure() async throws {
		let fixtureStatus = CompanionStatus(
			certValid: true,
			certName: "Development",
			certExpiry: nil,
			certDaysRemaining: 10,
			certRevoked: false,
			certPPQLess: true,
			installedApps: 1,
			signedApps: 1,
			pendingUpdates: 0,
			storageFree: 500
		)
		let statusData = try JSONEncoder().encode(fixtureStatus)
		let updatesData = try JSONEncoder().encode([CompanionUpdateEntry]())
		let client = CompanionClient(
			address: "https://10.0.0.5:8080",
			username: nil,
			password: nil,
			apiToken: nil,
			dataLoader: { request in
				switch request.url?.path {
				case "/api/status":
					return (statusData, Self._response(request, statusCode: 200))
				case "/api/library":
					return (Data(), Self._response(request, statusCode: 500))
				case "/api/updates":
					return (updatesData, Self._response(request, statusCode: 200))
				default:
					throw URLError(.badURL)
				}
			}
		)

		let fetched = try await client.snapshot()
		XCTAssertEqual(fetched.status, fixtureStatus)
		XCTAssertEqual(fetched.library, .failure(.httpStatus(500)))
		XCTAssertEqual(fetched.updates, .success([]), "a successful empty list is not an endpoint failure")
	}

	func testCompanionClientReportsAuthServerAndTimeoutFailuresForEveryEndpoint() async throws {
		let failures: [CompanionClientError] = [.unauthorized, .httpStatus(500), .timedOut]
		for endpoint in ["api/status", "api/library", "api/updates"] {
			for failure in failures {
				try await _assertEndpointFailure(endpoint, failure: failure)
			}
		}
	}

	func testCompanionTransportDefaultsToHTTPSAndRequiresExplicitHTTPOptIn() async throws {
		let statusData = try JSONEncoder().encode(_fixtureStatus)
		var schemes: [String] = []
		let httpsClient = CompanionClient(
			address: "10.0.0.5:8080",
			username: nil,
			password: nil,
			apiToken: nil,
			dataLoader: { request in
				schemes.append(request.url?.scheme ?? "missing")
				let data: Data
				switch request.url?.path {
				case "/api/status": data = statusData
				case "/api/library", "/api/updates": data = try JSONEncoder().encode([String]())
				default: throw URLError(.badURL)
				}
				return (data, Self._response(request, statusCode: 200))
			}
		)
		_ = try await httpsClient.snapshot()
		XCTAssertEqual(schemes, ["https", "https", "https"])

		var madeInsecureRequest = false
		let httpClient = CompanionClient(
			address: "http://10.0.0.5:8080",
			username: "vex",
			password: "fixture-password",
			apiToken: "fixture-token",
			dataLoader: { _ in
				madeInsecureRequest = true
				throw URLError(.cannotConnectToHost)
			}
		)
		do {
			_ = try await httpClient.snapshot()
			XCTFail("plain HTTP must be rejected unless explicitly enabled")
		} catch let error as CompanionClientError {
			XCTAssertEqual(error, .insecureHTTPRequiresOptIn)
		} catch {
			XCTFail("unexpected error: \(error)")
		}
		XCTAssertFalse(madeInsecureRequest, "credentials must not reach the loader before explicit consent")

		var optedInRequestCount = 0
		let optedInHTTPClient = CompanionClient(
			address: "http://10.0.0.5:8080",
			username: "vex",
			password: "fixture-password",
			apiToken: "fixture-token",
			allowsInsecureHTTP: true,
			dataLoader: { request in
				optedInRequestCount += 1
				XCTAssertEqual(request.url?.scheme, "http")
				XCTAssertEqual(request.value(forHTTPHeaderField: "X-VexSign-Token"), "fixture-token")
				let data: Data
				switch request.url?.path {
				case "/api/status": data = statusData
				case "/api/library", "/api/updates": data = try JSONEncoder().encode([String]())
				default: throw URLError(.badURL)
				}
				return (data, Self._response(request, statusCode: 200))
			}
		)
		_ = try await optedInHTTPClient.snapshot()
		XCTAssertEqual(optedInRequestCount, 3)

		XCTAssertFalse(CompanionRedirectPolicy.permits(
			from: URL(string: "https://10.0.0.5:8080/api/status"),
			to: URL(string: "http://10.0.0.5:8080/api/status")
		))
		XCTAssertFalse(CompanionRedirectPolicy.permits(
			from: URL(string: "https://10.0.0.5:8080/api/status"),
			to: URL(string: "https://other.example/api/status")
		))
		XCTAssertFalse(CompanionRedirectPolicy.permits(
			from: URL(string: "https://10.0.0.5:8080/api/status"),
			to: URL(string: "https://10.0.0.5:8081/api/status")
		))
		XCTAssertTrue(CompanionRedirectPolicy.permits(
			from: URL(string: "https://10.0.0.5:8080/api/status"),
			to: URL(string: "https://10.0.0.5:8080/api/status?next=1")
		))

		let downgradeClient = CompanionClient(
			address: "https://10.0.0.5:8080",
			username: nil,
			password: nil,
			apiToken: nil,
			dataLoader: { request in
				let downgradedURL = URL(string: "http://10.0.0.5:8080/api/status")!
				return (statusData, Self._response(request, statusCode: 200, responseURL: downgradedURL))
			}
		)
		do {
			_ = try await downgradeClient.snapshot()
			XCTFail("an HTTPS request must reject a final HTTP response")
		} catch let error as CompanionClientError {
			XCTAssertEqual(error, .unsafeRedirect)
		} catch {
			XCTFail("unexpected error: \(error)")
		}

		let crossPortClient = CompanionClient(
			address: "https://10.0.0.5:8080",
			username: nil,
			password: nil,
			apiToken: nil,
			dataLoader: { request in
				let redirectedURL = URL(string: "https://10.0.0.5:8081/api/status")!
				return (statusData, Self._response(request, statusCode: 200, responseURL: redirectedURL))
			}
		)
		do {
			_ = try await crossPortClient.snapshot()
			XCTFail("a same-host redirect to a different port must be rejected")
		} catch let error as CompanionClientError {
			XCTAssertEqual(error, .unsafeRedirect)
		} catch {
			XCTFail("unexpected error: \(error)")
		}

		let stoppedRedirectClient = CompanionClient(
			address: "https://10.0.0.5:8080",
			username: nil,
			password: nil,
			apiToken: nil,
			dataLoader: { request in
				return (Data(), Self._response(request, statusCode: 302))
			}
		)
		do {
			_ = try await stoppedRedirectClient.snapshot()
			XCTFail("an un-followed redirect response must be reported as unsafe")
		} catch let error as CompanionClientError {
			XCTAssertEqual(error, .unsafeRedirect)
		} catch {
			XCTFail("unexpected error: \(error)")
		}
	}

	private var _fixtureStatus: CompanionStatus {
		CompanionStatus(
			certValid: true,
			certName: "Development",
			certExpiry: nil,
			certDaysRemaining: 10,
			certRevoked: false,
			certPPQLess: true,
			installedApps: 1,
			signedApps: 1,
			pendingUpdates: 0,
			storageFree: 500
		)
	}

	private func _assertEndpointFailure(_ endpoint: String, failure: CompanionClientError) async throws {
		let statusData = try JSONEncoder().encode(_fixtureStatus)
		let libraryData = try JSONEncoder().encode([CompanionLibraryEntry]())
		let updatesData = try JSONEncoder().encode([CompanionUpdateEntry]())
		var paths: [String] = []
		let client = CompanionClient(
			address: "https://10.0.0.5:8080",
			username: nil,
			password: nil,
			apiToken: nil,
			dataLoader: { request in
				let path = request.url?.path ?? ""
				paths.append(path)
				if path == "/\(endpoint)", failure == .timedOut {
					throw URLError(.timedOut)
				}
				let statusCode: Int
				if path == "/\(endpoint)" {
					statusCode = failure == .unauthorized ? 401 : 500
				} else {
					statusCode = 200
				}
				let data: Data
				switch path {
				case "/api/status": data = statusData
				case "/api/library": data = libraryData
				case "/api/updates": data = updatesData
				default: throw URLError(.badURL)
				}
				return (data, Self._response(request, statusCode: statusCode))
			}
		)

		let expectedPaths = endpoint == "api/status"
			? ["/api/status"]
			: ["/api/status", "/api/library", "/api/updates"]
		if endpoint == "api/status" {
			do {
				_ = try await client.snapshot()
				XCTFail("the status endpoint is required for a snapshot")
			} catch let error as CompanionClientError {
				XCTAssertEqual(error, failure, "status failure for \(failure)")
			} catch {
				XCTFail("unexpected error: \(error)")
			}
		} else {
			do {
				let result = try await client.snapshot()
				if endpoint == "api/library" {
					if case .failure(let error) = result.library {
						XCTAssertEqual(error, failure, "\(endpoint) failure")
					} else {
						XCTFail("\(endpoint) failure must not become empty data")
					}
				} else if case .failure(let error) = result.updates {
					XCTAssertEqual(error, failure, "\(endpoint) failure")
				} else {
					XCTFail("\(endpoint) failure must not become empty data")
				}
			} catch {
				XCTFail("a partial endpoint failure should not discard status: \(error)")
			}
		}
		XCTAssertEqual(paths, expectedPaths)
	}

	private func _serverTrust(for identity: DeviceTLSIdentity.Identity, hostname: String) throws -> SecTrust {
		let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.leafCertificate as CFData))
		let root = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.rootCertificate as CFData))
		var trust: SecTrust?
		XCTAssertEqual(SecTrustCreateWithCertificates(
			[leaf, root] as CFArray,
			SecPolicyCreateSSL(true, hostname as CFString),
			&trust
		), errSecSuccess)
		return try XCTUnwrap(trust)
	}

	private static func _response(
		_ request: URLRequest,
		statusCode: Int,
		responseURL: URL? = nil
	) -> HTTPURLResponse {
		HTTPURLResponse(url: responseURL ?? request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
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
