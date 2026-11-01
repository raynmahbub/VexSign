//
//  SourceFeedLoaderTests.swift
//  VexSignTests
//
//  Tests for fetching and decoding a repository must not happen on the main thread.
//
//  The assertion that matters is the first test's: the loader is started from the main actor, the
//  way `SourcesViewModel` starts it, and the hook records which thread the decode actually ran on.
//  The 5 MB feed is built here rather than stored, so the suite carries no fixture and no network.
//

import Foundation
import NimbleJSON
import XCTest
@testable import VexSign

final class SourceFeedLoaderTests: XCTestCase {
	private let url = URL(string: "https://example.com/repo.json")!

	// MARK: Fixtures

	/// A minimal feed that decodes: `ASRepository` needs a non-empty `apps`, and `App` requires an
	/// `iconURL` plus at least one `Version.version`.
	private static let smallFeed = Data(
		"{\"name\":\"Small\",\"apps\":[{\"name\":\"App\",\"iconURL\":\"https://example.com/i.png\",\"versions\":[{\"version\":\"1.0\"}]}]}".utf8
	)

	/// ~5 MB, the size the roadmap names: 5,000 apps with a kilobyte of padding each.
	private static func bigFeed() -> Data {
		let padding = String(repeating: "a", count: 1_000)
		var apps: [String] = []
		apps.reserveCapacity(5_000)

		for index in 0..<5_000 {
			apps.append(
				"{\"name\":\"App \(index)\",\"bundleIdentifier\":\"com.example.app\(index)\","
					+ "\"iconURL\":\"https://example.com/i.png\",\"versions\":[{\"version\":\"1.0\"}],"
					+ "\"description\":\"\(padding)\"}"
			)
		}

		let head = Data("{\"name\":\"Big\",\"apps\":[".utf8)
		let body = Data(apps.joined(separator: ",").utf8)
		let tail = Data("]}".utf8)
		return head + body + tail
	}

	private static func loader(
		returning result: Result<Data, Error>,
		recorder: MainThreadRecorder? = nil
	) -> SourceFeedLoader {
		let hook: (@Sendable (Bool) -> Void)?
		if let recorder {
			hook = { isMainThread in recorder.record(isMainThread: isMainThread) }
		} else {
			hook = nil
		}

		return SourceFeedLoader(fetcher: { _, _ in result }, willDecode: hook)
	}

	// MARK: Decode off the main thread

	func testTheDecodeRunsOffTheMainThread() async {
		let feed = Self.bigFeed()
		XCTAssertGreaterThan(feed.count, 4_500_000, "the fixture should be the size the roadmap asks about")

		let recorder = MainThreadRecorder()
		let loader = Self.loader(returning: .success(feed), recorder: recorder)

		// Started from the main actor, exactly as `SourcesViewModel.fetchSources` starts it.
		let task = Task { @MainActor in
			XCTAssertTrue(Thread.isMainThread, "the load should be started on the main thread")
			return await loader.load(url: url, headers: [:], identifier: "test")
		}
		let result = await task.value

		XCTAssertEqual(
			recorder.recorded,
			[false],
			"the payload was decoded on the main thread — that is what was"
		)

		guard case let .decoded(repository, payload) = result.outcome else {
			return XCTFail("expected a decoded repository, got \(result.outcome)")
		}
		XCTAssertEqual(repository.name, "Big")
		XCTAssertEqual(repository.apps.count, 5_000)
		XCTAssertEqual(payload.count, feed.count, "the raw payload has to survive for the snapshot cache")
	}

	// MARK: Outcomes

	func testAValidRepositoryDecodesAndKeepsItsPayload() async {
		let result = await Self.loader(returning: .success(Self.smallFeed))
			.load(url: url, headers: [:], identifier: "small")

		XCTAssertEqual(result.identifier, "small")
		guard case let .decoded(repository, payload) = result.outcome else {
			return XCTFail("expected a decoded repository, got \(result.outcome)")
		}
		XCTAssertEqual(repository.name, "Small")
		XCTAssertEqual(repository.apps.count, 1)
		XCTAssertEqual(payload, Self.smallFeed)
	}

	/// A feed that does not decode is not thrown away: the cache may still be able to serve it once
	/// the app understands the format.
	func testInvalidJSONIsReportedWithItsPayload() async {
		let payload = Data("{\"apps\":\"not an array\"}".utf8)
		let result = await Self.loader(returning: .success(payload))
			.load(url: url, headers: [:], identifier: "broken")

		guard case let .invalid(kept) = result.outcome else {
			return XCTFail("expected an invalid outcome, got \(result.outcome)")
		}
		XCTAssertEqual(kept, payload)
	}

	func testAnEmptyBodyIsAFailureRatherThanAnInvalidFeed() async {
		let result = await Self.loader(returning: .success(Data()))
			.load(url: url, headers: [:], identifier: "empty")

		guard case let .failed(message, rateLimited) = result.outcome else {
			return XCTFail("expected a failure, got \(result.outcome)")
		}
		XCTAssertFalse(message.isEmpty)
		XCTAssertFalse(rateLimited)
	}

	func testHTTP429IsFlaggedAsRateLimited() async {
		let result = await Self.loader(
			returning: .failure(NBFetchService.NBFetchServiceError.httpError(429))
		).load(url: url, headers: [:], identifier: "limited")

		guard case let .failed(_, rateLimited) = result.outcome else {
			return XCTFail("expected a failure, got \(result.outcome)")
		}
		XCTAssertTrue(rateLimited)
	}

	func testAnotherHTTPErrorIsNotRateLimited() async {
		let result = await Self.loader(
			returning: .failure(NBFetchService.NBFetchServiceError.httpError(500))
		).load(url: url, headers: [:], identifier: "server")

		guard case let .failed(message, rateLimited) = result.outcome else {
			return XCTFail("expected a failure, got \(result.outcome)")
		}
		XCTAssertFalse(rateLimited)
		XCTAssertFalse(message.isEmpty, "the health dashboard shows the real reason")
	}

	func testRateLimitClassificationIsNarrow() {
		XCTAssertTrue(SourceFeedLoader.isRateLimited(NBFetchService.NBFetchServiceError.httpError(429)))
		XCTAssertFalse(SourceFeedLoader.isRateLimited(NBFetchService.NBFetchServiceError.httpError(401)))
		XCTAssertFalse(SourceFeedLoader.isRateLimited(NBFetchService.NBFetchServiceError.noData))
		XCTAssertFalse(SourceFeedLoader.isRateLimited(URLError(.timedOut)))
	}
}

// MARK: - Recorder

/// Records which thread the loader decoded on. `willDecode` is `@Sendable` and several sources are
/// in flight at once, so the box is locked. Test-only.
private final class MainThreadRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [Bool] = []

	func record(isMainThread: Bool) {
		lock.lock()
		values.append(isMainThread)
		lock.unlock()
	}

	var recorded: [Bool] {
		lock.lock()
		defer { lock.unlock() }
		return values
	}
}
