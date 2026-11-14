//
//  CloudSigningContractTests.swift
//  VexSignTests
//
//  The iOS side of the cloud-signing contract. Every fixture here is a body the service's own
//  schema (`Services/CloudSigning/cloud-signing/openapi.json`) says it sends; `Tools/Development/test_cloud_signing_contract.py`
//  checks that the keys in these fixtures still match that document, so a rename on either side
//  fails a test rather than an upload.
//
//  These are pure decoding and policy tests: no URLSession, no network, no service.
//

import XCTest
@testable import VexSign

final class CloudSigningContractTests: XCTestCase {
	private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
		try JSONDecoder().decode(type, from: Data(json.utf8))
	}

	// MARK: - Accepted submission

	func testTheDocumentedJobAcceptedBodyDecodes() throws {
		// `JobAccepted` in openapi.json: {id, state}.
		let accepted = try decode(CloudJobAccepted.self, #"{"id":"6f1d1a3e-1111-4222-8333-444455556666","state":"queued"}"#)
		XCTAssertEqual(accepted.id, "6f1d1a3e-1111-4222-8333-444455556666")
		XCTAssertEqual(accepted.state, "queued")
	}

	func testASubmissionWithoutAJobIDIsNotAccepted() {
		// The old model expected `jobId`, which is what the service has never sent. A body that
		// lacks the documented `id` must fail rather than yield an empty job identifier.
		XCTAssertThrowsError(try decode(CloudJobAccepted.self, #"{"jobId":"6f1d1a3e","state":"queued"}"#))
	}

	// MARK: - Job view

	private let completedSignJob = #"""
	{
	  "id": "6f1d1a3e-1111-4222-8333-444455556666",
	  "kind": "sign",
	  "state": "completed",
	  "result": {
	    "name": "Example",
	    "bundleIdentifier": "com.example.app",
	    "version": "1.4.0",
	    "changelog": "",
	    "screenshotURLs": []
	  },
	  "error_code": null,
	  "output_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	  "created_at": "2026-01-02T03:04:05.123Z",
	  "finished_at": "2026-01-02T03:05:05.000Z",
	  "installURL": "https://signing.example.com/install/6f1d1a3e-1111-4222-8333-444455556666?token=1767225600.abc"
	}
	"""#

	func testTheDocumentedCompletedSignJobDecodes() throws {
		let job = try decode(CloudJob.self, completedSignJob)

		XCTAssertEqual(job.kind, "sign")
		XCTAssertEqual(job.state, "completed")
		XCTAssertTrue(job.isFinished)
		XCTAssertTrue(job.isSucceeded)
		XCTAssertNil(job.errorCode)
		XCTAssertEqual(job.outputSHA256?.count, 64)
		XCTAssertEqual(job.result?.bundleIdentifier, "com.example.app")
		XCTAssertEqual(job.result?.isCertificateCheck, false)
		XCTAssertEqual(
			job.installURL?.absoluteString,
			"https://signing.example.com/install/6f1d1a3e-1111-4222-8333-444455556666?token=1767225600.abc"
		)
	}

	func testTimestampsParseWithAndWithoutFractionalSeconds() throws {
		let job = try decode(CloudJob.self, completedSignJob)
		// 2026-01-02T03:04:05.123Z
		XCTAssertEqual(job.createdAt?.timeIntervalSince1970 ?? 0, 1_767_323_045.123, accuracy: 0.01)
		XCTAssertNotNil(job.finishedAt)

		let plain = try decode(CloudJob.self, #"{"id":"i","kind":"sign","state":"running","result":null,"error_code":null,"output_sha256":null,"created_at":"2026-01-02T03:04:05Z","finished_at":null}"#)
		XCTAssertEqual(plain.createdAt?.timeIntervalSince1970, 1_767_323_045)
		XCTAssertNil(plain.finishedAt)
		XCTAssertFalse(plain.isFinished)
	}

	func testACertificateCheckResultIsDistinguishedFromAnArtifact() throws {
		let job = try decode(CloudJob.self, #"""
		{"id":"i","kind":"check-cert","state":"completed","result":{"status":"revoked","checkedAt":"2026-01-02T03:04:05.000Z","teamID":"ABCDE12345","teamName":"Example","expiresAt":"2027-01-02T03:04:05.000Z","detail":"Revoked by Apple"},"error_code":null,"output_sha256":null,"created_at":"2026-01-02T03:04:05.000Z","finished_at":"2026-01-02T03:05:05.000Z"}
		"""#)
		XCTAssertEqual(job.result?.isCertificateCheck, true)
		XCTAssertEqual(job.result?.status, "revoked")
		XCTAssertEqual(job.result?.teamID, "ABCDE12345")
		// A certificate check produces no artifact, so it carries no install link.
		XCTAssertNil(job.installURL)
	}

	func testAFailedJobKeepsItsErrorCodeAndNoInstallLink() throws {
		let job = try decode(CloudJob.self, #"{"id":"i","kind":"sign","state":"failed","result":null,"error_code":"SIGNER_EXIT_1","output_sha256":null,"created_at":"2026-01-02T03:04:05.000Z","finished_at":"2026-01-02T03:05:05.000Z"}"#)
		XCTAssertTrue(job.isFinished)
		XCTAssertFalse(job.isSucceeded)
		XCTAssertEqual(job.errorCode, "SIGNER_EXIT_1")
		XCTAssertNil(job.installURL)
	}

	func testAnUnknownStateOrFieldDoesNotBreakAnInFlightJob() throws {
		// A state added by a newer service must still decode: polling an unknown state is better
		// than losing the job handle.
		let job = try decode(CloudJob.self, #"{"id":"i","kind":"sign","state":"awaiting-engine","result":null,"error_code":null,"output_sha256":null,"created_at":"2026-01-02T03:04:05.000Z","finished_at":null,"some_future_field":"ignored"}"#)
		XCTAssertEqual(job.state, "awaiting-engine")
		XCTAssertFalse(job.isFinished)
	}

	// MARK: - Error classification

	private func error(status: Int, body: String = #"{"error":"rejected","requestId":"req-1"}"#) -> CloudServiceError {
		CloudServiceError.from(status: status, body: Data(body.utf8))
	}

	func testHTTPStatusesMapToTheirClassifiedKinds() {
		XCTAssertEqual(error(status: 401).kind, .unauthorized)
		XCTAssertEqual(error(status: 403).kind, .forbidden)
		XCTAssertEqual(error(status: 404).kind, .notFound)
		XCTAssertEqual(error(status: 409).kind, .conflict)
		XCTAssertEqual(error(status: 429).kind, .rateLimited)
		XCTAssertEqual(error(status: 400).kind, .rejected(status: 400))
		XCTAssertEqual(error(status: 413).kind, .rejected(status: 413))
		XCTAssertEqual(error(status: 503).kind, .server(status: 503))
	}

	func testTheServerMessageAndRequestIDSurviveForSupport() {
		let classified = error(status: 429)
		XCTAssertEqual(classified.detail, "rejected")
		XCTAssertEqual(classified.requestID, "req-1")
		XCTAssertTrue(classified.localizedDescription.contains("req-1"))
	}

	func testAnUnparseableErrorBodyStillClassifiesByStatus() {
		let classified = error(status: 500, body: "<html>gateway</html>")
		XCTAssertEqual(classified.kind, .server(status: 500))
		XCTAssertNil(classified.requestID)
	}

	func testOnlyTransientFailuresAreRetryable() {
		XCTAssertTrue(error(status: 429).isRetryable)
		XCTAssertTrue(error(status: 500).isRetryable)
		XCTAssertTrue(CloudServiceError(.unavailable(code: .timedOut)).isRetryable)
		XCTAssertTrue(CloudServiceError(.unavailable(code: .networkConnectionLost)).isRetryable)
		XCTAssertFalse(error(status: 401).isRetryable)
		XCTAssertFalse(error(status: 409).isRetryable)
		XCTAssertFalse(CloudServiceError(.unavailable(code: .cancelled)).isRetryable)
		XCTAssertFalse(CloudServiceError(.malformedResponse).isRetryable)
	}

	// MARK: - Retry policy

	func testRetryDelaysGrowExponentiallyAndAreCapped() {
		let policy = CloudRetryPolicy(maxAttempts: 5, baseDelay: 0.5, maximumDelay: 2)
		// The midpoint jitter (0.5) is exactly the nominal delay.
		XCTAssertEqual(policy.delay(afterAttempt: 1, jitter: 0.5), 0.5, accuracy: 0.0001)
		XCTAssertEqual(policy.delay(afterAttempt: 2, jitter: 0.5), 1.0, accuracy: 0.0001)
		XCTAssertEqual(policy.delay(afterAttempt: 3, jitter: 0.5), 2.0, accuracy: 0.0001)
		XCTAssertEqual(policy.delay(afterAttempt: 9, jitter: 0.5), 2.0, accuracy: 0.0001)
	}

	func testJitterStaysWithinTwentyFivePercentOfTheNominalDelay() {
		let policy = CloudRetryPolicy(maxAttempts: 5, baseDelay: 1, maximumDelay: 8)
		XCTAssertEqual(policy.delay(afterAttempt: 1, jitter: 0), 0.75, accuracy: 0.0001)
		XCTAssertEqual(policy.delay(afterAttempt: 1, jitter: 1), 1.25, accuracy: 0.0001)
		// Out-of-range jitter cannot produce a negative or unbounded sleep.
		XCTAssertEqual(policy.delay(afterAttempt: 1, jitter: -3), 0.75, accuracy: 0.0001)
		XCTAssertEqual(policy.delay(afterAttempt: 1, jitter: 9), 1.25, accuracy: 0.0001)
	}

	func testANonIdempotentRequestIsNeverRepeated() {
		let policy = CloudRetryPolicy(maxAttempts: 3)
		XCTAssertFalse(policy.shouldRetry(afterAttempt: 1, error: CloudServiceError(.server(status: 503)), idempotent: false))
		XCTAssertTrue(policy.shouldRetry(afterAttempt: 1, error: CloudServiceError(.server(status: 503)), idempotent: true))
	}

	func testRetriesStopAtTheAttemptLimitAndOnlyForRetryableErrors() {
		let policy = CloudRetryPolicy(maxAttempts: 3)
		XCTAssertTrue(policy.shouldRetry(afterAttempt: 1, error: error(status: 429), idempotent: true))
		XCTAssertTrue(policy.shouldRetry(afterAttempt: 2, error: error(status: 429), idempotent: true))
		XCTAssertFalse(policy.shouldRetry(afterAttempt: 3, error: error(status: 429), idempotent: true))
		XCTAssertFalse(policy.shouldRetry(afterAttempt: 1, error: error(status: 400), idempotent: true))
	}
}
