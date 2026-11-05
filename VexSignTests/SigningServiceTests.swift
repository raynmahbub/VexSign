//
//  SigningServiceTests.swift
//  VexSignTests
//
//  Covers the signing run's contract: stages are reported in the
//  order they happen, every run ends with exactly one terminal event, and a cancelled run is
//  reported as cancelled rather than failed.
//
//  The pipeline itself needs zsign, a certificate and a real bundle, so these tests drive the
//  service through `SigningWork` fakes. That is the point of the seam: ordering, ownership and
//  cancellation are the service's job, not the pipeline's.
//

import CoreData
import XCTest
@testable import VexSign

final class SigningServiceTests: XCTestCase {
	/// `Storage` is queue-bound, so the store is created on the main actor, lazily, and thrown
	/// away after each test — the way `StorageConcurrencyTests` keeps its fixture around.
	private nonisolated(unsafe) static var storage: Storage?

	override func tearDown() {
		Self.storage = nil
		super.tearDown()
	}

	// MARK: - Events

	@MainActor
	func testStagesArriveInOrderAndTheRunFinishes() async throws {
		let signed = _signed()
		let service = SigningService(work: _FakeWork(.succeed(signed, [.copying, .modifying, .signing])))

		let events = await _collect(service, request: _request(signed))

		XCTAssertEqual(_stages(events), [.copying, .modifying, .signing], "Stages must keep pipeline order")
		XCTAssertEqual(_terminalCount(events), 1, "A run reports exactly one terminal event")

		guard case .finished(let result)? = events.last else {
			return XCTFail("Last event should be .finished, got \(String(describing: events.last))")
		}
		XCTAssertEqual(result.uuid, signed.uuid)
	}

	@MainActor
	func testAFailureIsReportedAsFailed() async throws {
		let signed = _signed()
		let service = SigningService(work: _FakeWork(.fail(signed, [.copying], _TestError.boom)))

		let events = await _collect(service, request: _request(signed))

		guard case .failed(let error)? = events.last else {
			return XCTFail("Last event should be .failed, got \(String(describing: events.last))")
		}
		XCTAssertTrue(error is _TestError)
		XCTAssertEqual(_terminalCount(events), 1)
	}

	/// A pipeline that gives up on its own — the shape `Task.checkCancellation()` produces.
	@MainActor
	func testACancellationErrorIsReportedAsCancelledNotFailed() async throws {
		let signed = _signed()
		let service = SigningService(work: _FakeWork(.fail(signed, [.copying], CancellationError())))

		let events = await _collect(service, request: _request(signed))

		guard case .cancelled? = events.last else {
			return XCTFail("Last event should be .cancelled, got \(String(describing: events.last))")
		}
		XCTAssertEqual(_terminalCount(events), 1)
	}

	// MARK: - Ownership

	@MainActor
	func testTheRunIsReleasedOnceItHasFinished() async throws {
		let signed = _signed()
		let service = SigningService(work: _FakeWork(.succeed(signed, [.copying])))
		let request = _request(signed, id: "fixed")

		_ = service.sign(request) { _ in }
		try await _wait("the run to finish") { !service.isSigning }

		XCTAssertFalse(service.isSigning)

		let again = service.sign(request) { _ in }
		XCTAssertNotNil(again, "The same app can be signed again afterwards")
	}

	@MainActor
	func testASecondStartForTheSameRequestIsRejected() async throws {
		let signed = _signed()
		let service = SigningService(work: _FakeWork(.waitForCancel([.copying])))
		let request = _request(signed, id: "busy")

		var events: [SigningEvent] = []
		let first = service.sign(request) { events.append($0) }
		XCTAssertNotNil(first)
		try await _wait("the first stage") { !events.isEmpty }

		let second = service.sign(request) { _ in }
		XCTAssertNil(second, "Two runs for one app would fight over the same work directory")

		service.cancel(request.id)
		try await _wait("the run to stop") { events.contains { $0.isTerminal } }
	}

	// MARK: - Cancellation

	@MainActor
	func testCancellingStopsTheRunThatIsInFlight() async throws {
		let signed = _signed()
		let service = SigningService(work: _FakeWork(.waitForCancel([.copying, .signing])))

		var events: [SigningEvent] = []
		let request = _request(signed)
		let started = service.sign(request) { events.append($0) }
		XCTAssertNotNil(started)
		try await _wait("the run to reach signing") {
			_stages(events).contains(.signing)
		}

		service.cancel(request.id)

		try await _wait("the run to report cancellation") { events.contains { $0.isTerminal } }
		guard case .cancelled? = events.last else {
			return XCTFail("Last event should be .cancelled, got \(String(describing: events.last))")
		}
		XCTAssertFalse(service.isSigning)
	}

	@MainActor
	func testCancelAllStopsEveryRunInFlight() async throws {
		let service = SigningService(work: _FakeWork(.waitForCancel([.copying])))

		var first: [SigningEvent] = []
		var second: [SigningEvent] = []
		let a = _request(_signed("A"), id: "a")
		let b = _request(_signed("B"), id: "b")

		let runA = service.sign(a) { first.append($0) }
		let runB = service.sign(b) { second.append($0) }
		XCTAssertNotNil(runA)
		XCTAssertNotNil(runB)

		try await _wait("both runs to start") { !first.isEmpty && !second.isEmpty }

		service.cancelAll()

		try await _wait("both runs to stop") {
			first.contains { $0.isTerminal } && second.contains { $0.isTerminal }
		}
		XCTAssertTrue(first.last?.isTerminal ?? false)
		XCTAssertTrue(second.last?.isTerminal ?? false)
		XCTAssertFalse(service.isSigning)
	}

	// MARK: - Helpers

	@MainActor
	private func _signed(_ name: String = "Fixture") -> Signed {
		let storage = Self.storage ?? Storage(inMemory: true)
		Self.storage = storage

		let signed = Signed(context: storage.context)
		signed.name = name
		signed.uuid = UUID().uuidString
		return signed
	}

	@MainActor
	private func _request(_ app: Signed, id: String = UUID().uuidString) -> SigningRequest {
		SigningRequest(id: id, app: app, options: Options.defaultOptions, icon: nil, certificate: nil)
	}

	/// Starts a run and waits for its terminal event.
	@MainActor
	private func _collect(_ service: SigningService, request: SigningRequest) async -> [SigningEvent] {
		var events: [SigningEvent] = []
		service.sign(request) { events.append($0) }
		try? await _wait("the terminal event") { events.contains { $0.isTerminal } }
		return events
	}

	@MainActor
	private func _wait(
		_ what: String,
		timeout: TimeInterval = 5,
		until condition: () -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition() {
			if Date() > deadline {
				XCTFail("Timed out waiting for \(what)")
				return
			}
			try await Task.sleep(nanoseconds: 20_000_000)
		}
	}

	private func _stages(_ events: [SigningEvent]) -> [SigningStage] {
		events.compactMap {
			guard case .stage(let stage) = $0 else { return nil }
			return stage
		}
	}

	private func _terminalCount(_ events: [SigningEvent]) -> Int {
		events.filter(\.isTerminal).count
	}
}

// MARK: - Fakes

private enum _TestError: Error {
	case boom
}

private final class _FakeWork: SigningWork {
	enum Behaviour {
		case succeed(Signed, [SigningStage])
		case fail(Signed, [SigningStage], Error)
		/// Reports `.copying` (and anything else asked for) then sleeps until cancelled, which is
		/// what a real pipeline looks like while zsign is running.
		case waitForCancel([SigningStage])
	}

	private let _behaviour: Behaviour

	init(_ behaviour: Behaviour) {
		self._behaviour = behaviour
	}

	func run(_ request: SigningRequest, reporting: @escaping (SigningStage) -> Void) async -> Result<Signed, Error> {
		switch _behaviour {
		case .succeed(let signed, let stages):
			for stage in stages {
				reporting(stage)
			}
			return .success(signed)

		case .fail(_, let stages, let error):
			for stage in stages {
				reporting(stage)
			}
			return .failure(error)

		case .waitForCancel(let stages):
			for stage in stages {
				reporting(stage)
			}
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 10_000_000)
			}

			// Report the way the real pipeline does, so the service maps it onto `.cancelled`
			// rather than `.failed`.
			return .failure(CancellationError())
		}
	}
}
