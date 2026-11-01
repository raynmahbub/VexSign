//
//  WebManagerServer+API.swift
//  VexSign
//
//  Automation surface on the existing Web Manager server: a small REST API next to
//  the browser UI and WebDAV share. Everything is JSON unless it streams a file.
//
//      GET  /api/status     certificate state, library + update counts
//      GET  /api/library    every app in the library
//      GET  /api/updates    apps a source has a newer version of
//      POST /api/sign       upload an IPA, sign it with the default certificate,
//                           stream the signed IPA back
//      POST /api/cleanup    run the cleanup sweep, report the bytes reclaimed
//      POST /api/widget     rewrite the Home Screen widget payload
//
//  Auth: the whole server sits behind the Basic-auth middleware when a password is
//  configured, and `WebManagerSensitiveAccessMiddleware` adds a second gate to the
//  endpoints that expose signing identity or destroy content (`/api/sign`, every
//  `/api/certs*` route, every DELETE). There a configured API token is mandatory;
//  without a token the route requires Basic auth, and is refused outright when the
//  server runs without a password.
//

import Foundation
import Vapor
import OSLog

// MARK: - Payloads

private struct APIStatus: Content {
	let certValid: Bool
	let certName: String?
	let certExpiry: String?
	let certDaysRemaining: Int?
	let certRevoked: Bool
	let certPPQLess: Bool?
	let installedApps: Int
	let signedApps: Int
	let pendingUpdates: Int
	let storageFree: Int64?
}

private struct APILibraryEntry: Content {
	let name: String
	let bundleID: String
	let version: String
	let size: Int
	let signed: Bool
}

private struct APIUpdateEntry: Content {
	let name: String
	let bundleID: String
	let installedVersion: String?
	let availableVersion: String?
}

private struct APISignResponse: Content {
	let name: String
	let bundleID: String
	let version: String
	let ipa: String
}

private struct APICleanupResponse: Content {
	let freedBytes: Int64
	let removedApps: [String]
}

private struct APIError: Content {
	let error: String
}

// MARK: - Routes

extension WebManagerServer {
	/// Registers the automation endpoints. Called from `_configureHTTP`.
	func _configureAPI(_ app: Application) {
		app.get("api", "status") { _ async -> Response in
			let status: APIStatus = await MainActor.run {
				let certificates = Storage.shared.getAllCertificates()
				let active = certificates.first(where: { $0.isDefault })
					?? certificates.first(where: { !$0.revoked })
					?? certificates.first

				let apps = Storage.shared.getAllApps()

				return APIStatus(
					certValid: Self._certificateIsValid(active),
					certName: active.flatMap { $0.nickname ?? Storage.shared.getProvisionFileDecoded(for: $0)?.Name },
					certExpiry: active?.expiration?.ISO8601Format(),
					certDaysRemaining: active?.expiration.map { Int(floor($0.timeIntervalSinceNow / 86_400)) },
					certRevoked: active?.revoked ?? false,
					certPPQLess: active?.isPPQLess,
					installedApps: apps.count,
					signedApps: apps.filter { $0.isSigned }.count,
					pendingUpdates: AppUpdateChecker.shared.updateCount,
					storageFree: FileManager.default.availableImportantCapacity(at: URL.documentsDirectory)
				)
			}
			return Self.apiJSON(status)
		}

		app.get("api", "library") { _ async -> Response in
			let entries: [APILibraryEntry] = await MainActor.run {
				Storage.shared.getAllApps().map { app in
					APILibraryEntry(
						name: app.name ?? "App",
						bundleID: app.identifier ?? "",
						version: app.version ?? "",
						size: Self.apiDirectorySize(Storage.shared.getAppDirectory(for: app)),
						signed: app.isSigned
					)
				}
			}
			return Self.apiJSON(entries)
		}

		app.get("api", "updates") { _ async -> Response in
			let entries: [APIUpdateEntry] = await MainActor.run {
				AppStoreUpdateTracker.shared.infos.compactMap { bundleID, info in
					guard let app = Storage.shared.getAllApps().first(where: { $0.identifier == bundleID }) else {
						return nil
					}
					return APIUpdateEntry(
						name: app.name ?? info.name,
						bundleID: bundleID,
						installedVersion: app.version,
						availableVersion: info.version
					)
				}
			}
			return Self.apiJSON(entries)
		}

		app.post("api", "cleanup") { _ async -> Response in
			let summary: CleanupSummary = await MainActor.run {
				CleanupManager.shared.cleanNow()
			}
			await MainActor.run { WidgetStatusPublisher.publish() }
			return Self.apiJSON(APICleanupResponse(freedBytes: summary.freedBytes, removedApps: summary.removedApps))
		}

		app.post("api", "widget") { _ async -> Response in
			await MainActor.run { WidgetStatusPublisher.publish() }
			let payload = await MainActor.run { WidgetStatusPublisher.currentPayload() }
			return Self.apiJSON(payload)
		}

		// POST /api/sign — raw IPA bytes in the request body (same convention as
		// POST /upload/<name>, so `curl --data-binary` works without multipart).
		app.on(.POST, "api", "sign", body: .stream) { [weak self] req -> EventLoopFuture<Response> in
			guard let self else {
				return req.eventLoop.makeSucceededFuture(Response(status: .internalServerError))
			}

			let staging = FileManager.default.uniqueTemporaryDirectory("APISign")
			let ipaURL = staging.appendingPathComponent("upload.ipa")
			let promise = req.eventLoop.makePromise(of: Response.self)

			let streamed = self.streamToFile(req, destination: ipaURL, route: false, report: false, successStatus: .ok)
			streamed.whenSuccess { _ in
				Task { @MainActor in
					let response = await self._signAndPackage(request: req, ipaURL: ipaURL, staging: staging)
					promise.succeed(response)
				}
			}
			streamed.whenFailure { error in
				try? FileManager.default.removeItem(at: staging)
				promise.fail(error)
			}

			return promise.futureResult
		}
	}

	// MARK: Signing

	/// Imports the upload, signs it with the default certificate and packages the
	/// result as an IPA. Main actor because the library lives in CoreData.
	@MainActor
	private func _signAndPackage(request: Request, ipaURL: URL, staging: URL) async -> Response {
		do {
			guard AutoSignManager.canSign else {
				try? FileManager.default.removeItem(at: staging)
				return Response(
					status: .preconditionFailed,
					body: .init(string: "No certificate available. Import one in Settings → Certificates.")
				)
			}

			let imported: (app: AppInfoPresentable?, error: Error?) = await withCheckedContinuation { continuation in
				FR.handlePackageFile(ipaURL) { result in
					switch result {
					case .success(let app): continuation.resume(returning: (app, nil))
					case .failure(let error): continuation.resume(returning: (nil, error))
					}
				}
			}

			guard let app = imported.app else {
				try? FileManager.default.removeItem(at: staging)
				return Response(
					status: .unprocessableEntity,
					body: .init(string: imported.error?.localizedDescription ?? "Could not read that IPA.")
				)
			}

			let signed: Signed
			switch await AutoSignManager.shared.sign(app) {
			case .success(let result): signed = result
			case .failure(let error):
				try? FileManager.default.removeItem(at: staging)
				return Response(status: .internalServerError, body: .init(string: error.localizedDescription))
			}

			guard let directory = Storage.shared.getAppDirectory(for: signed) else {
				try? FileManager.default.removeItem(at: staging)
				return Response(status: .internalServerError, body: .init(string: "Signed app disappeared before it could be packaged."))
			}

			let output = staging.appendingPathComponent("signed.ipa")
			do {
				try await Task.detached(priority: .userInitiated) {
					try AppArchiver.archive(appDir: directory, to: output, compression: .DefaultCompression)
				}.value
			} catch {
				try? FileManager.default.removeItem(at: staging)
				return Response(status: .internalServerError, body: .init(string: error.localizedDescription))
			}

			// Stream the signed package back without loading multi-GB archives into RAM.
			let response = request.fileio.streamFile(at: output.path) { _ in
				try? FileManager.default.removeItem(at: staging)
			}
			response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(output.lastPathComponent)\"")
			let body = APISignResponse(
				name: signed.name ?? "App",
				bundleID: signed.identifier ?? "",
				version: signed.version ?? "",
				ipa: output.lastPathComponent
			)
			let encoded = (try? JSONEncoder().encode(body)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
			response.headers.replaceOrAdd(name: "X-VexSign-Signed-App", value: encoded)
			return response
		} catch {
			try? FileManager.default.removeItem(at: staging)
			return Response(status: .internalServerError, body: .init(string: error.localizedDescription))
		}
	}

	// MARK: Helpers

	private static func _certificateIsValid(_ certificate: CertificatePair?) -> Bool {
		guard let certificate, certificate.revoked != true else { return false }
		guard let expiry = certificate.expiration else { return false }
		return expiry > Date()
	}

	private static func apiJSON<T: Encodable>(_ value: T) -> Response {
		let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
		var headers = HTTPHeaders()
		headers.contentType = .json
		return Response(status: .ok, headers: headers, body: .init(data: data))
	}

	private static func apiDownload(_ url: URL, as filename: String) -> Response {
		let handle = try? FileHandle(forReadingFrom: url)
		var headers = HTTPHeaders()
		headers.contentType = .binary
		headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")

		if let handle, let data = try? handle.readDataToEndOfFile() {
			try? handle.close()
			return Response(status: .ok, headers: headers, body: .init(data: data))
		}
		return Response(status: .internalServerError, body: .init(string: "Could not read the signed IPA."))
	}

	private static func apiDirectorySize(_ url: URL?) -> Int {
		guard let url else { return 0 }
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return 0 }

		guard let enumerator = FileManager.default.enumerator(
			at: url,
			includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
		) else { return 0 }

		var total = 0
		for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
			total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		}
		return total
	}
}
