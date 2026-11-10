//
//  CloudSigningClient.swift
//  VexSign
//
//  Native iOS bridge to the fastify/Postgres/BullMQ cloud-signing microservice.
//  Enables offloading heavy IPA codesigning jobs and remote revocation checking to a cloud worker.
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

/// The `201` body of `POST /api/upload`, as documented in `cloud-signing/openapi.json`.
///
/// It used to be `{id,key,size}` here, which the service has never returned: a successful upload
/// would have failed to decode. `sha256` is the service's own digest of what it stored and is the
/// only thing the app can use to check that the archive arrived intact.
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

struct CloudSignResponse: Codable, Sendable {
	let jobId: String
	let idempotencyKey: String?
}

struct CloudJobStatus: Codable, Sendable {
	let id: String
	let status: String
	let progress: Double?
	let step: String?
	let downloadUrl: String?
	let installUrl: String?
	let error: String?

	var isTerminal: Bool { status == "completed" || status == "failed" }
	var isSuccess: Bool { status == "completed" }
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
	@Published var apiKey: String {
		didSet { Self.storeAPIKey(apiKey) }
	}
	@Published var isTesting = false
	@Published var lastTestResult: String?
	@Published var activeJobs: [CloudJobStatus] = []

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

	// MARK: - Health Check

	func checkHealth() async throws -> Bool {
		guard let base = baseURL else { throw URLError(.badURL) }
		let url = base.appendingPathComponent("health/live")
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.timeoutInterval = 10

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
			return false
		}

		if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		   let status = json["status"] as? String {
			return status == "ok"
		}
		return false
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

		let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
		guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
			let errText = String(data: data, encoding: .utf8) ?? "Upload failed"
			throw NSError(domain: "CloudSigningClient", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: errText])
		}

		return try JSONDecoder().decode(CloudUploadResponse.self, from: data)
	}

	// MARK: - Sign Job Submission

	func submitSignJob(ipaId: String, p12Id: String, provisionId: String, password: String) async throws -> String {
		guard let base = baseURL else { throw URLError(.badURL) }
		let url = base.appendingPathComponent("api/sign")

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		if !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
			request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		}

		let payload = CloudSignRequest(ipaId: ipaId, p12Id: p12Id, provisionId: provisionId, password: password, webhook: nil)
		request.httpBody = try JSONEncoder().encode(payload)

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
			let errText = String(data: data, encoding: .utf8) ?? "Signing submission failed"
			throw NSError(domain: "CloudSigningClient", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: errText])
		}

		let decoded = try JSONDecoder().decode(CloudSignResponse.self, from: data)
		return decoded.jobId
	}

	// MARK: - Job Status

	func getJobStatus(jobId: String) async throws -> CloudJobStatus {
		guard let base = baseURL else { throw URLError(.badURL) }
		let url = base.appendingPathComponent("api/jobs/\(jobId)")

		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		if !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
			request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		}

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
			let errText = String(data: data, encoding: .utf8) ?? "Failed to fetch job"
			throw NSError(domain: "CloudSigningClient", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: errText])
		}

		return try JSONDecoder().decode(CloudJobStatus.self, from: data)
	}

	// MARK: - End-to-End Remote Sign & Download

	/// Offloading a signature means handing the cluster the p12 **and** its
	/// password. That is a product decision with its own consent surface, and it
	/// does not exist yet, so the entry point refuses
	/// instead of silently uploading a private key.
	///
	/// The intended shape, for when is scoped: upload the IPA, upload the
	/// certificate and profile, queue `api/sign`, poll `api/jobs/:id`, download the
	/// result. The uploader below still refuses `kind: .p12` on purpose.
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
