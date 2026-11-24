//
//  BoundedResponseFetchTests.swift
//  VexSignTests
//
//  The helper exists for one property: a caller's cap is enforced while the body is
//  arriving, not after it is all in memory. These tests are the only place that
//  property is observed from outside — the seven call sites all sit on a network.
//

import XCTest
@testable import VexSign

final class BoundedResponseFetchTests: XCTestCase {
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

	private func request() throws -> URLRequest {
		URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/metadata.json")))
	}

	func testABodyAtTheLimitIsReturnedWithItsResponse() async throws {
		StubHTTPProtocol.body = Data(repeating: 0x41, count: 1_024)

		let (data, response) = try await BoundedResponseFetch.fetch(
			try request(),
			maximumBytes: 1_024,
			session: session
		)

		XCTAssertEqual(data.count, 1_024)
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
	}

	func testABodyOverTheLimitIsRefused() async throws {
		StubHTTPProtocol.body = Data(repeating: 0x41, count: 4_096)

		do {
			_ = try await BoundedResponseFetch.fetch(try request(), maximumBytes: 1_024, session: session)
			XCTFail("a body past the cap must not be handed back")
		} catch let failure as BoundedResponseFetch.Failure {
			XCTAssertEqual(failure, .tooLarge(limitBytes: 1_024))
		}
	}

	func testAnEmptyBodyIsHandedBackRatherThanThrowing() async throws {
		// Callers decide what an empty body means (JSON decoding rejects it); the helper
		// only bounds the size.
		StubHTTPProtocol.body = Data()

		let (data, _) = try await BoundedResponseFetch.fetch(try request(), maximumBytes: 1_024, session: session)
		XCTAssertTrue(data.isEmpty)
	}

	func testANonSuccessStatusIsHandedBackForTheCallerToJudge() async throws {
		// `TransferSecuritySession` rejects non-2xx; the metadata callers each have their own
		// status handling, so the cap helper must not invent one.
		StubHTTPProtocol.status = 404
		StubHTTPProtocol.body = Data("{}".utf8)

		let (data, response) = try await BoundedResponseFetch.fetch(try request(), maximumBytes: 1_024, session: session)
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
		XCTAssertEqual(data, Data("{}".utf8))
	}
}
