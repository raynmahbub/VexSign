//
//  AppStoreTrackerTransportTests.swift
//  VexSignTests
//
//  The lookup used to buffer whatever the endpoint returned and check the size
//  afterwards. These tests go through `latest(for:session:)`, so the wire path — not
//  just the decoder — is what is asserted.
//

import XCTest
@testable import VexSign

final class AppStoreTrackerTransportTests: XCTestCase {
	private var session: URLSession!

	override func setUp() {
		super.setUp()
		StubHTTPProtocol.status = 200
		session = StubHTTPProtocol.makeSession()
	}

	override func tearDown() {
		session.invalidateAndCancel()
		session = nil
		StubHTTPProtocol.body = Data()
		super.tearDown()
	}

	func testALookupBodyOverTheCapBecomesATransportFailure() async {
		StubHTTPProtocol.body = Data(repeating: 0x20, count: Int(AppStoreTracker.maximumResponseBytes) + 1)

		do {
			_ = try await AppStoreTracker.latest(for: "com.example.app", session: session)
			XCTFail("a body past the cap must never reach the decoder")
		} catch let error as AppStoreTracker.TrackerError {
			guard case .transport = error else {
				return XCTFail("expected a transport failure, got \(error)")
			}
		} catch {
			XCTFail("unexpected error: \(error)")
		}
	}

	func testALookupResponseIsDecodedThroughTheSession() async throws {
		StubHTTPProtocol.body = Data("""
		{"resultCount":1,"results":[{"trackName":"Example","bundleId":"com.example.app","version":"2.4.0","trackViewUrl":"https://apps.apple.com/app/id1"}]}
		""".utf8)

		let info = try await AppStoreTracker.latest(for: "com.example.app", session: session)

		XCTAssertEqual(info?.name, "Example")
		XCTAssertEqual(info?.version, "2.4.0")
		XCTAssertEqual(info?.bundleID, "com.example.app")
	}

	func testAnEmptyLookupIsNotAnError() async throws {
		StubHTTPProtocol.body = Data(#"{"resultCount":0,"results":[]}"#.utf8)

		let info = try await AppStoreTracker.latest(for: "com.example.missing", session: session)
		XCTAssertNil(info, "a sideload-only app is simply not listed")
	}
}
