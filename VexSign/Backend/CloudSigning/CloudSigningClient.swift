//
//  CloudSigningClient.swift
//  VexSign
//
//  Native iOS bridge to the fastify/Postgres/BullMQ cloud-signing microservice.
//
//  The transport, not the product. Remote signing itself is refused on this build
//  (`privateKeyUploadDisabled`): sending a p12 and its password to a cluster needs a consent
//  surface that does not exist yet. What is exercised in practice is the health check and the
//  uploader.
//
//  Every shape below is taken from `cloud-signing/openapi.json`, which the service regenerates
//  from its zod schemas and CI diffs, so it is the contract rather than a description of one.
//  Three of the previous models were guessed and none of them could decode a real response:
//  `POST /api/sign` answers `202 {id,state}` (not `{jobId}`), `GET /api/jobs/{id}` answers
//  `{id,kind,state,result,error_code,output_sha256,created_at,finished_at,installURL?}` (not
//  `{status,progress,step,downloadUrl,error}`), and `/api/sign` requires an `Idempotency-Key`
//  header this client never sent.
//

import Foundation
import UIKit
import OSLog
import NimbleExtensions

// MARK: - Models

enum CloudArtifactKind: String, Codable, Equatable, Sendable {
	case ipa
	case p12
	case provision
}

/// The `201` body of `POST /api/upload`.
///
/// It used to be `{id,key,size}` here, which the service has never returned: a successful upload
/// would have failed to decode. `sha256` is the service's own digest of what it stored, and
/// `bytes` is the size it received — the two things a client can check without a second upload.
struct CloudUploadResponse: Codable, Sendable {
	let id: String
	let kind: CloudArtifactKind
	let bytes: Int
	let sha256: String
}

struct CloudSignRequest: Codable, Sendable {
	let ipaId: String
	let p12Id: String
	let provisionId: String
	let password: String
	let webhook: String?
}

/// The `202` body of `POST /api/sign` and `POST /api/check-cert` (`JobAccepted`).
///
/// The job identifier is `id`. It was `jobId` here, a field the service has never sent, so every
/// accepted submission failed to decode — and the failure arrived as "signing submission failed"
/// with no job to poll.
struct CloudJobAccepted: Decodable, Sendable {
	let id: String
	let state: String
}

/// The `result` column of a finished job.
///
/// A signing job writes artifact metadata; a certificate check writes an OCSP-style verdict. One
/// flat, all-optional model covers both without a decode attempt guessing which is which: a
/// certificate result is the only one that carries `status`.
struct CloudJobResult: Decodable, Equatable, Sendable {
	let name: String?
	let bundleIdentifier: String?
	let version: String?
	let status: String?
	let teamID: String?
	let teamName: String?
	let expiresAt: String?
	let detail: String?

	var isCertificateCheck: Bool { status != nil }
}

/// `GET /api/jobs/{id}` — `JobView` in the service contract.
///
/// The wire format is snake_case because it mirrors the row; only `installURL` is camel case.
/// `state` stays a `String`: a state this build does not know must not make an in-flight job
/// undecodable, and the accessors below decide what it means.
struct CloudJob: Decodable, Equatable, Sendable {
	let id: String
	let kind: String
	let state: String
	let errorCode: String?
	let outputSHA256: String?
	let installURLString: String?
	let createdAtString: String?
	let finishedAtString: String?
	let result: CloudJobResult?

	enum CodingKeys: String, CodingKey {
		case id
		case kind
		case state
		case result
		case errorCode = "error_code"
		case outputSHA256 = "output_sha256"
		case installURLString = "installURL"
		case createdAtString = "created_at"
		case finishedAtString = "finished_at"
	}

	/// A capability that expires in 24 hours. Never log or persist it: it authorises a download
	/// without a bearer token.
	var installURL: URL? { installURLString.flatMap { URL(string: $0) } }

	var isFinished: Bool { state == "completed" || state == "failed" }
	var isSucceeded: Bool { state == "completed" }

	var createdAt: Date? { CloudTimestamp.date(from: createdAtString) }
	var finishedAt: Date? { CloudTimestamp.date(from: finishedAtString) }
}

/// Parses the service's ISO-8601 timestamps, with or without fractional seconds.
///
/// `JSONDecoder.DateDecodingStrategy.iso8601` accepts only the form without them, and the service
/// emits both (`Date#toISOString()` has milliseconds; a database default may not). A timestamp
/// that cannot be parsed is a display problem, not a reason to lose the job, so the wire value
/// stays a `String` and this is applied when it is read.
enum CloudTimestamp {
	static func date(from string: String?) -> Date? {
		guard let string else { return nil }
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		if let date = formatter.date(from: string) { return date }
		formatter.formatOptions = [.withInternetDateTime]
		return formatter.date(from: string)
	}
}

/// The `Error` schema every failure response uses: `{error, requestId}`.
struct CloudServiceErrorBody: Decodable, Sendable {
	let error: String?
	let requestId: String?
}

/// A classified service failure.
///
/// The previous code turned every non-2xx into an `NSError` whose `userInfo` held the raw body,
/// so a 429 and a 401 looked identical and nothing could decide whether to retry. `requestId` is
/// kept because it is the only thing that ties a user's report to a server-side log entry.
struct CloudServiceError: LocalizedError, Equatable {
	enum Kind: Equatable, Sendable {
		/// The bearer token was not accepted. The service verifies RS256 tokens issued by its
		/// configured identity provider, with scope `signing:write` and a lifetime of at most an
		/// hour; it does not mint or exchange tokens.
		case unauthorized
		/// Authenticated, but the token lacks `signing:write`.
		case forbidden
		case notFound
		/// The same idempotency key was reused for a different request.
		case conflict
		case rateLimited
		/// A 4xx that is not one of the shapes above (bad input, too large, webhook not allowed).
		case rejected(status: Int)
		case server(status: Int)
		/// Round-trip with the service never completed.
		case unavailable(code: URLError.Code)
		/// A 2xx body that did not match the contract, or an upload whose size was not preserved.
		case malformedResponse
	}

	let kind: Kind
	let detail: String?
	let requestID: String?

	init(_ kind: Kind, detail: String? = nil, requestID: String? = nil) {
		self.kind = kind
		self.detail = detail
		self.requestID = requestID
	}

	/// Whether the same request, sent again, could plausibly succeed.
	///
	/// Deliberately conservative: 4xx means the request itself is wrong, and a 5xx or a dropped
	/// connection is the case a bounded retry exists for.
	var isRetryable: Bool {
		switch kind {
		case .rateLimited:
			return true
		case .server(_):
			return true
		case .unavailable(let code):
			switch code {
			case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
				return true
			default:
				return false
			}
		case .rejected(_):
			return false
		case .unauthorized, .forbidden, .notFound, .conflict, .malformedResponse:
			return false
		}
	}

	var errorDescription: String? {
		let base: String
		switch kind {
		case .unauthorized:
			base = "The cloud service rejected the token. It needs a signed-in token with the signing scope."
		case .forbidden:
			base = "The token is valid but is not allowed to sign."
		case .notFound:
			base = "The cloud service could not find that job or asset."
		case .conflict:
			base = "That request was already submitted with different details."
		case .rateLimited:
			base = "The cloud service is rate limiting requests. Try again shortly."
		case .rejected(let status):
			base = "The cloud service rejected the request (HTTP \(status))."
		case .server(let status):
			base = "The cloud service failed while handling the request (HTTP \(status))."
		case .unavailable(_):
			base = "Could not reach the cloud service. Check the connection and try again."
		case .malformedResponse:
			base = "The cloud service answered in a form this version does not understand."
		}
		if let requestID, !requestID.isEmpty {
			return "\(base) Reference: \(requestID)"
		}
		return base
	}

	/// Maps a non-2xx response onto the classified cases, keeping the server's own message.
	static func from(status: Int, body: Data) -> CloudServiceError {
		let decoded = try? JSONDecoder().decode(CloudServiceErrorBody.self, from: body) // try? ok: the status alone classifies the failure
		let requestID = decoded?.requestId
		let detail = decoded?.error
		switch status {
		case 401: return CloudServiceError(.unauthorized, detail: detail, requestID: requestID)
		case 403: return CloudServiceError(.forbidden, detail: detail, requestID: requestID)
		case 404: return CloudServiceError(.notFound, detail: detail, requestID: requestID)
		case 409: return CloudServiceError(.conflict, detail: detail, requestID: requestID)
		case 429: return CloudServiceError(.rateLimited, detail: detail, requestID: requestID)
		case 500...599: return CloudServiceError(.server(status: status), detail: detail, requestID: requestID)
		default: return CloudServiceError(.rejected(status: status), detail: detail, requestID: requestID)
		}
	}
}

/// Bounded retry for a request that is safe to repeat.
///
/// `attempt` is 1-based *after* the first failure. Delays grow exponentially to a cap, and the
/// jitter factor widens them by ±25% so a fleet of clients does not return in lockstep. Pure, and
/// the caller passes the jitter in, so a test can pin the exact schedule.
struct CloudRetryPolicy: Equatable {
	var maxAttempts: Int
	var baseDelay: TimeInterval
	var maximumDelay: TimeInterval

	init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maximumDelay: TimeInterval = 4) {
		self.maxAttempts = maxAttempts
		self.baseDelay = baseDelay
		self.maximumDelay = maximumDelay
	}

	func delay(afterAttempt attempt: Int, jitter: Double) -> TimeInterval {
		let exponent = Double(max(0, attempt - 1))
		let capped = min(maximumDelay, baseDelay * pow(2, exponent))
		let clamped = min(max(0, jitter), 1)
		return capped * (0.75 + 0.5 * clamped)
	}

	/// Only idempotent requests may be repeated, and only for a retryable classification.
	func shouldRetry(afterAttempt attempt: Int, error: CloudServiceError, idempotent: Bool) -> Bool {
		guard idempotent, attempt < maxAttempts else { return false }
		return error.isRetryable
	}
}

/// Refusals that are policy, not transport failures.
enum CloudSigningError: LocalizedError, Equatable {
	/// A p12 is a private key. Sending it to a signing cluster is a product
	/// decision that needs its own consent surface, so the client refuses
	/// until that exists — the certificate checker that used to do this from
	/// behind a checkbox was removed.
	case privateKeyUploadDisabled

	var errorDescription: String? {
		switch self {
		case .privateKeyUploadDisabled:
			String.localized("Cloud signing is not enabled for private keys. Sign on this device.")
		}
	}
}

// MARK: - Client

@MainActor
final class CloudSigningClient: ObservableObject {
	static let shared = CloudSigningClient()

	@Published var isEnabled: Bool {
		didSet { UserDefaults.standard.set(isEnabled, forKey: "VexSign.cloudSigningEnabled") }
	}
	@Published var serverURLString: String {
		didSet { UserDefaults.standard.set(serverURLString, forKey: "VexSign.cloudSigningServerURL") }
	}
	/// A bearer token is a credential, so it is Keychain-only.
	///
	/// It used to live in `UserDefaults`, where it was readable in every backup and preferences
	/// dump alongside non-secret settings. `SecureSecretStore` stores it with
	/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and the earlier plaintext value is
	/// migrated once and then removed — the removal only happens after the Keychain write
	/// succeeded, so an upgrade that fails leaves the old copy usable rather than losing the token.
	///
	/// Send it as `Authorization: Bearer` only. It used to be sent a second time as `x-api-key`,
	/// which the service does not read and does not redact from its access log.
	@Published var apiKey: String {
		didSet { Self.storeAPIKey(apiKey) }
	}
	@Published var isTesting = false
	@Published var lastTestResult: String?
	@Published var activeJobs: [CloudJob] = []

	/// How long a JSON round-trip may take before it is treated as a timeout.
	// `nonisolated` because it is read from a default-argument expression, which is
	// evaluated outside the actor.
	private nonisolated static let requestTimeout: TimeInterval = 30

	/// Uploads get their own session: a 2 GiB archive over a slow link needs a resource timeout
	/// measured in minutes, and `waitsForConnectivity` keeps a request queued instead of failing
	/// while the radio comes back.
	private lazy var uploadSession: URLSession = {
		let configuration = URLSessionConfiguration.default
		configuration.timeoutIntervalForRequest = 60
		configuration.timeoutIntervalForResource = 3600
		configuration.waitsForConnectivity = true
		return URLSession(configuration: configuration)
	}()

	init() {
		self.isEnabled = UserDefaults.standard.bool(forKey: "VexSign.cloudSigningEnabled")
		self.serverURLString = UserDefaults.standard.string(forKey: "VexSign.cloudSigningServerURL") ?? "https://cloud.vexsign.app"
		self.apiKey = Self.loadAPIKey()
	}

	// MARK: - Credential storage

	/// The Keychain account the token lives under, and the preferences key earlier builds wrote.
	private static let _apiKeyAccount = "cloudSigning.apiKey"
	private static let _legacyAPIKeyDefaultsKey = "VexSign.cloudSigningKey"

	private static func loadAPIKey() -> String {
		do {
			return try SecureSecretStore.migrateDefaults(_legacyAPIKeyDefaultsKey, account: _apiKeyAccount)
		} catch {
			// A locked Keychain must not look like an empty token: the plaintext copy is still
			// there, and the next launch will migrate it.
			Logger.misc.error("Cloud signing token is unavailable until the Keychain is unlocked.")
			return UserDefaults.standard.string(forKey: _legacyAPIKeyDefaultsKey) ?? ""
		}
	}

	private static func storeAPIKey(_ value: String) {
		do {
			if value.isEmpty {
				try SecureSecretStore.delete(_apiKeyAccount)
			} else {
				try SecureSecretStore.write(Data(value.utf8), account: _apiKeyAccount)
			}
		} catch {
			// Reported rather than silently dropped: the token in memory still works for this run.
			Logger.misc.error("Cloud signing token could not be stored in the Keychain.")
		}
	}

	private var baseURL: URL? {
		var str = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
		while str.hasSuffix("/") { str.removeLast() }
		return URL(string: str)
	}

	// MARK: - Requests

	private func _request(url: URL, method: String, authorised: Bool, timeout: TimeInterval = CloudSigningClient.requestTimeout) -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.timeoutInterval = timeout
		request.cachePolicy = .reloadIgnoringLocalCacheData
		if authorised, !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		}
		return request
	}

	/// Sends a JSON request and either returns the body of a 2xx or throws a classified error.
	private func _send(_ request: URLRequest, using session: URLSession = .shared) async throws -> Data {
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch let error as URLError {
			throw CloudServiceError(.unavailable(code: error.code))
		}
		guard let http = response as? HTTPURLResponse else {
			throw CloudServiceError(.malformedResponse)
		}
		guard (200...299).contains(http.statusCode) else {
			throw CloudServiceError.from(status: http.statusCode, body: data)
		}
		return data
	}

	private func _decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			// The contract mismatch is logged by field name, never by value: a 2xx body can
			// contain a capability URL or an artifact name.
			Logger.misc.error("Cloud service response did not match \(String(describing: type), privacy: .public)")
			throw CloudServiceError(.malformedResponse)
		}
	}

	// MARK: - Health Check

	func checkHealth() async throws -> Bool {
		guard let base = baseURL else { throw URLError(.badURL) }
		let request = _request(url: base.appendingPathComponent("health/live"), method: "GET", authorised: false, timeout: 10)
		let data = try await _send(request)

		struct Health: Decodable { let status: String }
		let health = try? JSONDecoder().decode(Health.self, from: data) // try? ok: a reachable service answering oddly is "not healthy", not an error
		return health?.status == "ok"
	}

	// MARK: - Artifact Upload

	func upload(fileURL: URL, kind: CloudArtifactKind) async throws -> CloudUploadResponse {
		// Checked before anything else so no request body is ever built for it.
		guard kind != .p12 else { throw CloudSigningError.privateKeyUploadDisabled }
		guard let base = baseURL else { throw URLError(.badURL) }

		let boundary = CloudUploadBody.makeBoundary()
		let request = try CloudUploadBody.request(base: base, kind: kind, apiKey: apiKey, boundary: boundary)

		let bodyURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("vexsign-cloud-upload-\(UUID().uuidString).multipart")
		defer { try? FileManager.default.removeItem(at: bodyURL) } // try? ok: a leftover body file is reaped by cleanup

		// The archive is up to 2 GiB; building the body is a bulk disk copy, so it runs off the
		// main actor and never holds more than one chunk in memory.
		let filename = fileURL.lastPathComponent
		try await Task.detached(priority: .utility) {
			_ = try CloudUploadBody.write(file: fileURL, filename: filename, boundary: boundary, to: bodyURL)
		}.value

		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await uploadSession.upload(for: request, fromFile: bodyURL)
		} catch let error as URLError {
			throw CloudServiceError(.unavailable(code: error.code))
		}
		guard let http = response as? HTTPURLResponse else { throw CloudServiceError(.malformedResponse) }
		guard (200...299).contains(http.statusCode) else {
			throw CloudServiceError.from(status: http.statusCode, body: data)
		}

		let decoded = try _decode(CloudUploadResponse.self, from: data)
		// The service reports what it received. A size that differs from the archive means the
		// transfer was not faithful, and a job built on it would sign the wrong bytes — so this
		// fails here rather than at signing time.
		let localBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) // try? ok: an unreadable size only skips the check
			.flatMap { ($0[.size] as? NSNumber)?.intValue }
		if let localBytes, decoded.bytes != localBytes {
			throw CloudServiceError(.malformedResponse, detail: "Uploaded \(decoded.bytes) of \(localBytes) bytes")
		}
		guard decoded.kind == kind else {
			throw CloudServiceError(.malformedResponse, detail: "Service stored the artifact as \(decoded.kind.rawValue)")
		}
		return decoded
	}

	// MARK: - Sign Job Submission

	/// Queues a signing job.
	///
	/// `idempotencyKey` is the caller's: the service binds it to the request body and answers a
	/// repeated key with the original job (`202`) or `409` if the body differs. Passing the same
	/// key after an ambiguous failure is therefore safe; generating a new one is not. This is not
	/// retried automatically — the app submits a job once and polls it.
	func submitSignJob(
		ipaId: String,
		p12Id: String,
		provisionId: String,
		password: String,
		idempotencyKey: String = UUID().uuidString
	) async throws -> CloudJobAccepted {
		guard let base = baseURL else { throw URLError(.badURL) }
		var request = _request(url: base.appendingPathComponent("api/sign"), method: "POST", authorised: true)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")

		let payload = CloudSignRequest(ipaId: ipaId, p12Id: p12Id, provisionId: provisionId, password: password, webhook: nil)
		do {
			request.httpBody = try JSONEncoder().encode(payload)
		} catch {
			// The body is four identifiers and a password; encoding it cannot fail unless the
			// value is not encodable at all, which is a programming error, not a service one.
			throw CloudServiceError(.malformedResponse)
		}

		let data = try await _send(request)
		return try _decode(CloudJobAccepted.self, from: data)
	}

	// MARK: - Job Status

	/// Reads a job. Safe to repeat, so transient failures are retried under `policy`.
	func getJobStatus(jobId: String, policy: CloudRetryPolicy = CloudRetryPolicy()) async throws -> CloudJob {
		guard let base = baseURL else { throw URLError(.badURL) }
		let request = _request(url: base.appendingPathComponent("api/jobs/\(jobId)"), method: "GET", authorised: true)

		var attempt = 0
		while true {
			do {
				let data = try await _send(request)
				return try _decode(CloudJob.self, from: data)
			} catch let error as CloudServiceError {
				attempt += 1
				guard policy.shouldRetry(afterAttempt: attempt, error: error, idempotent: true) else { throw error }
				let delay = policy.delay(afterAttempt: attempt, jitter: Double.random(in: 0...1))
				try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			}
		}
	}

	// MARK: - End-to-End Remote Sign & Download

	/// Offloading a signature means handing the cluster the p12 **and** its
	/// password. That is a product decision with its own consent surface, and it
	/// does not exist yet, so the entry point refuses
	/// instead of silently uploading a private key.
	///
	/// The intended shape, for when is scoped: upload the IPA, upload the
	/// certificate and profile, queue `api/sign`, poll `api/jobs/:id`, download the
	/// result. The uploader below still refuses `kind: .p12` on purpose, and the
	/// downloaded artifact's digest would be checked against `output_sha256` before
	/// it is presented as signed.
	func signRemotely(ipaURL: URL, cert: CertificatePair, progress: @escaping (Double, String) -> Void) async throws -> URL {
		throw CloudSigningError.privateKeyUploadDisabled
	}

	// MARK: - Connection Test

	func testConnection() async {
		isTesting = true
		lastTestResult = nil
		defer { isTesting = false }

		do {
			let isAlive = try await checkHealth()
			if isAlive {
				lastTestResult = "Connected successfully to cloud service."
			} else {
				lastTestResult = "Service reachable, but health check returned non-OK."
			}
		} catch {
			lastTestResult = "Connection failed: \(error.localizedDescription)"
		}
	}
}
