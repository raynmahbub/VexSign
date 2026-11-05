//
//  CloudSigningClient.swift
//  VexSign
//
//  Native iOS bridge to the fastify/Postgres/BullMQ cloud-signing microservice.
//  Enables offloading heavy IPA codesigning jobs and remote revocation checking to a cloud worker.
//

import Foundation
import UIKit
import NimbleExtensions

// MARK: - Models

enum CloudArtifactKind: String, Codable, Sendable {
	case ipa
	case p12
	case provision
}

struct CloudUploadResponse: Codable, Sendable {
	let id: String
	let key: String
	let size: Int
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
	@Published var apiKey: String {
		didSet { UserDefaults.standard.set(apiKey, forKey: "VexSign.cloudSigningKey") }
	}
	@Published var isTesting = false
	@Published var lastTestResult: String?
	@Published var activeJobs: [CloudJobStatus] = []

	init() {
		self.isEnabled = UserDefaults.standard.bool(forKey: "VexSign.cloudSigningEnabled")
		self.serverURLString = UserDefaults.standard.string(forKey: "VexSign.cloudSigningServerURL") ?? "https://cloud.vexsign.app"
		self.apiKey = UserDefaults.standard.string(forKey: "VexSign.cloudSigningKey") ?? ""
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
		// Checked before anything else so no request object is ever built for it.
		guard kind != .p12 else { throw CloudSigningError.privateKeyUploadDisabled }
		guard let base = baseURL else { throw URLError(.badURL) }
		let url = base.appendingPathComponent("api/upload")

		let boundary = "Boundary-\(UUID().uuidString)"
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		if !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
			request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		}

		let fileData = try Data(contentsOf: fileURL)
		let filename = fileURL.lastPathComponent

		var body = Data()
		// kind field
		body.append("--\(boundary)\r\n".data(using: .utf8)!)
		body.append("Content-Disposition: form-data; name=\"kind\"\r\n\r\n".data(using: .utf8)!)
		body.append("\(kind.rawValue)\r\n".data(using: .utf8)!)

		// file field
		body.append("--\(boundary)\r\n".data(using: .utf8)!)
		body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
		body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
		body.append(fileData)
		body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

		let (data, response) = try await URLSession.shared.upload(for: request, from: body)
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
