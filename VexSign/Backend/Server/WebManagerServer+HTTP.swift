//
//  WebManagerServer+HTTP.swift
//  VexSign
//
//  Browser page (served from WebManager.html), uploads, inbox files, and
//  certificate / app management for the HTTP interface.
//

import Foundation
import OSLog
import Vapor
import Zip

private struct WebManagerFileInfo: Content {
	let name: String
	let size: Int
}

private struct CertInfo: Content {
	let uuid: String
	let name: String
	let expiration: String
	let added: String
	let ts: Double
	let revoked: Bool
	let isDefault: Bool
}

private struct AppInfo: Content {
	let uuid: String
	let name: String
	let version: String
	let identifier: String
	let added: String
	let ts: Double
	let size: Int
	let signed: Bool
}

private struct TweakInfo: Content {
	let id: String
	let name: String
	let files: Int
	let added: String
	let ts: Double
	let size: Int
}

private struct CompressionOption: Content {
	let value: Int
	let label: String
}

private struct CertUpload: Content {
	var p12: File
	var provision: File
	var password: String
	var nickname: String?
}

extension WebManagerServer {
	func _configureHTTP(_ app: Application) {
		app.get { _ -> Response in
			var headers = HTTPHeaders()
			headers.contentType = .html
			return Response(status: .ok, headers: headers, body: .init(string: Self.pageHTML))
		}

		// POST /upload/<filename> — body is raw file bytes
		app.on(.POST, "upload", ":name", body: .stream) { [weak self] req -> EventLoopFuture<Response> in
			guard let self else {
				return req.eventLoop.makeSucceededFuture(Response(status: .internalServerError))
			}
			guard let name = self.sanitizedFilename(req.parameters.get("name") ?? "upload.bin") else {
				return req.eventLoop.makeSucceededFuture(Response(status: .badRequest))
			}
			let destination = self.inbox.appendingPathComponent(name)
			return self.streamToFile(req, destination: destination, route: true, successStatus: .ok)
		}

		app.get("api", "files") { [weak self] _ -> Response in
			guard let self else { return Response(status: .internalServerError) }
			return Self.json(self._inboxFiles())
		}

		app.get("download", ":name") { [weak self] req async throws -> Response in
			guard let self, let raw = req.parameters.get("name"),
				let name = self.sanitizedFilename(raw) else { return Response(status: .badRequest) }
			let url = self.inbox.appendingPathComponent(name)
			guard FileManager.default.fileExists(atPath: url.path) else { return Response(status: .notFound) }
			let response = try await req.fileio.asyncStreamFile(at: url.path)
			response.headers.replaceOrAdd(name: .contentDisposition, value: WebManagerFilenamePolicy.contentDisposition(filename: name))
			return response
		}

		app.on(.DELETE, "api", "files", ":name") { [weak self] req -> Response in
			guard let self, let raw = req.parameters.get("name"),
				let name = self.sanitizedFilename(raw) else { return Response(status: .badRequest) }
			switch WebManagerDeletion.delete(self.inbox.appendingPathComponent(name)) {
			case .removed: return Response(status: .noContent)
			case .missing: return Response(status: .notFound)
			case .failed: return Response(status: .conflict)
			}
		}

		_configureCertificates(app)
		_configureApps(app)
		_configureTweaks(app)
		_configureAPI(app)
	}

	// MARK: - Tweaks

	private func _configureTweaks(_ app: Application) {
		app.get("api", "tweaks") { _ async -> Response in
			let infos = await MainActor.run {
				TweakManager.shared.tweaks.filter(\.isEnabled).map { tweak in
					let size = tweak.activeVersion.map { version in
						TweakManager.shared.fileURLs(forTweak: tweak.id, version: version)
							.reduce(0) { $0 + Self.fileSize($1) }
					} ?? 0
					return TweakInfo(
						id: tweak.id.uuidString,
						name: tweak.name,
						files: tweak.activeVersion?.components.count ?? 0,
						added: Self.dateString(tweak.dateAdded),
						ts: tweak.dateAdded.timeIntervalSince1970,
						size: size
					)
				}
			}
			return Self.json(infos)
		}

		app.get("api", "tweaks", ":id", "download") { req async throws -> Response in
			guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else { return Response(status: .badRequest) }
			let url: URL? = await MainActor.run {
				guard
					let tweak = TweakManager.shared.tweaks.first(where: { $0.id == id }),
					tweak.isEnabled,
					let version = tweak.activeVersion
				else { return nil }
				return TweakManager.shared.exportableURL(for: tweak, version: version)
			}
			guard let url else { return Response(status: .notFound) }
			return try await Self.download(req, file: url, as: url.lastPathComponent)
		}

		app.on(.DELETE, "api", "tweaks", ":id") { req async -> Response in
			guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else { return Response(status: .badRequest) }
			await MainActor.run { TweakManager.shared.deleteTweak(id) }
			return Response(status: .noContent)
		}
	}

	// MARK: - Certificates

	private func _configureCertificates(_ app: Application) {
		app.get("api", "certs") { _ async -> Response in
			let infos = await MainActor.run {
				Storage.shared.getAllCertificates().map { cert in
					let name = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? "Certificate"
					return CertInfo(
						uuid: cert.uuid ?? "",
						name: name,
						expiration: Self.dateString(cert.expiration),
						added: Self.dateString(cert.date),
						ts: cert.date?.timeIntervalSince1970 ?? 0,
						revoked: cert.revoked,
						isDefault: cert.isDefault
					)
				}
			}
			return Self.json(infos)
		}

		app.get("api", "certs", ":uuid", "download") { [weak self] req async throws -> Response in
			guard let self else { return Response(status: .internalServerError) }
			// The archive contains the private key and its password file, so it stays
			// off unless the user turned it on in Settings → Web Manager.
			guard self.allowsCertificateExport else {
				return Self.text(
					"Certificate download is turned off. Enable it in VexSign → Settings → Web Manager.",
					.forbidden
				)
			}
guard let uuid = req.parameters.get("uuid") else { return Response(status: .badRequest) }
            let workLease: AppOperationRegistry.Lease
            do { workLease = try AppOperationRegistry.shared.acquireTemporaryWork() }
            catch { return Self.text("Cleanup is in progress. Retry the download.", .serviceUnavailable) }
            defer { withExtendedLifetime(workLease) {} }
            let zipURL: URL? = await MainActor.run {
				guard let cert = Storage.shared.getAllCertificates().first(where: { $0.uuid == uuid }) else { return nil }
				return CertificateExporter.makeZip(for: cert)
			}
			guard let zipURL else { return Response(status: .notFound) }
			return try await Self.downloadTemporary(req, file: zipURL, as: zipURL.lastPathComponent, lease: workLease)
		}

app.on(.POST, "api", "certs") { req async -> Response in
            let workLease: AppOperationRegistry.Lease
            do { workLease = try AppOperationRegistry.shared.acquireTemporaryWork() }
            catch { return Self.text("Cleanup is in progress. Retry the upload.", .serviceUnavailable) }
            defer { withExtendedLifetime(workLease) {} }
            let upload: CertUpload
			do { upload = try req.content.decode(CertUpload.self) } catch { return Self.text("Invalid upload.", .badRequest) }

			let dir = FileManager.default.uniqueTemporaryDirectory("CertUpload")
			let p12URL = dir.appendingPathComponent("certificate.p12")
			let provURL = dir.appendingPathComponent("certificate.mobileprovision")
			defer { try? FileManager.default.removeItem(at: dir) } // try? ok: defer cleanup of a scratch directory on every exit path, including the throwing ones

			do {
				try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
				try Data(buffer: upload.p12.data).write(to: p12URL)
				try Data(buffer: upload.provision.data).write(to: provURL)
			} catch {
				return Self.text("Could not save the uploaded files.", .internalServerError)
			}

			guard FR.checkPasswordForCertificate(for: p12URL, with: upload.password, using: provURL) else {
				return Self.text("Wrong password, or the certificate and provisioning profile don't match.", .badRequest)
			}

			let nickname = (upload.nickname?.isEmpty == false) ? upload.nickname! : ""
			do {
				try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
					DispatchQueue.main.async {
						FR.handleCertificateFiles(p12URL: p12URL, provisionURL: provURL, p12Password: upload.password, certificateName: nickname) { error in
							if let error { cont.resume(throwing: error) } else { cont.resume() }
						}
					}
				}
			} catch {
				return Self.text("Import failed: \(error.localizedDescription)", .internalServerError)
			}
			return Response(status: .ok)
		}

		app.on(.DELETE, "api", "certs", ":uuid") { req async -> Response in
			guard let uuid = req.parameters.get("uuid") else { return Response(status: .badRequest) }
			await MainActor.run {
				if let cert = Storage.shared.getAllCertificates().first(where: { $0.uuid == uuid }) {
					Storage.shared.deleteCertificate(for: cert)
				}
			}
			return Response(status: .noContent)
		}
	}

	// MARK: - Apps

	private func _configureApps(_ app: Application) {
		app.get("api", "apps") { _ async -> Response in
			let infos = await MainActor.run {
				Storage.shared.getAllApps().map {
					AppInfo(
						uuid: $0.uuid ?? "",
						name: $0.name ?? "App",
						version: $0.version ?? "",
						identifier: $0.identifier ?? "",
						added: Self.dateString($0.date),
						ts: $0.date?.timeIntervalSince1970 ?? 0,
						size: Self.dirSize(Storage.shared.getAppDirectory(for: $0)),
						signed: $0.isSigned
					)
				}
			}
			return Self.json(infos)
		}

		app.get("api", "compression") { _ -> Response in
			let options = ZipCompression.allCases.enumerated().map { CompressionOption(value: $0.offset, label: $0.element.label) }
			return Self.json(options)
		}

app.get("api", "apps", ":uuid", "download") { req async throws -> Response in
            guard let uuid = req.parameters.get("uuid") else { return Response(status: .badRequest) }
            let workLease: AppOperationRegistry.Lease
            do { workLease = try AppOperationRegistry.shared.acquireTemporaryWork() }
            error { return Self.text("Cleanup is in progress. Retry the download.", .serviceUnavailable) }
            defer { withExtendedLifetime(workLease) {} }
            let info: (dir: URL, name: String, version: String, lease: AppOperationRegistry.Lease)?
            do {
                info = try await MainActor.run {
                    guard let target = Storage.shared.app(withUuid: uuid),
                          let dir = Storage.shared.getAppDirectory(for: target) else { return nil }
                    let lease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(target))
                    return (dir, target.name ?? "App", target.version ?? "", lease)
                }
            } catch { return Self.text("The app is in use. Retry the download.", .conflict) }
			guard let info else { return Response(status: .notFound) }
            defer { withExtendedLifetime(info.lease) {} }

			let level = (try? req.query.get(Int.self, at: "compression")) ?? ArchiveHandler.getCompressionLevel() // try? ok: an absent or non-integer query parameter falls back to the user's compression preference
			let compression = ZipCompression.allCases[safe: level] ?? .DefaultCompression
			let filename = IPAExportNaming.stem(name: info.name, version: info.version) + ".ipa"
			let ipaURL = FileManager.default.temporaryDirectory
				.appendingPathComponent("AppExport_\(UUID().uuidString)", isDirectory: true)
				.appendingPathComponent(filename)

			do {
				try FileManager.default.createDirectoryIfNeeded(at: ipaURL.deletingLastPathComponent())
				try await Task.detached(priority: .userInitiated) {
					try AppArchiver.archive(appDir: info.dir, to: ipaURL, compression: compression)
				}.value
			} catch {
                do { try FileManager.default.removeItem(at: ipaURL.deletingLastPathComponent()) }
                catch { Logger.misc.error("Web export cleanup failed: \(error.localizedDescription)") }
				return Self.text("Could not package the app.", .internalServerError)
			}
			return try await Self.downloadTemporary(req, file: ipaURL, as: filename, lease: workLease)
		}

		app.on(.DELETE, "api", "apps", ":uuid") { req async -> Response in
			guard let uuid = req.parameters.get("uuid") else { return Response(status: .badRequest) }
			await MainActor.run {
				if let target = Storage.shared.app(withUuid: uuid) {
					Storage.shared.deleteApp(for: target)
				}
			}
			return Response(status: .noContent)
		}
	}

	// MARK: - Helpers

	private func _inboxFiles() -> [WebManagerFileInfo] {
		let fm = FileManager.default
		let contents: [URL]
		do {
			contents = try fm.contentsOfDirectory(
				at: inbox,
				includingPropertiesForKeys: [.fileSizeKey],
				options: [.skipsHiddenFiles]
			)
		} catch {
			// The list is still empty, but the log distinguishes "no files" from
			// "could not read the inbox" — the UI showed the same thing for both.
			Logger.misc.error("Web manager: could not list the inbox: \(error.localizedDescription)")
			return []
		}

		return contents
			.filter { !$0.hasDirectoryPath }
			.map { url in
				let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 // try? ok: display-only file size; an unreadable file still gets a row, with size 0
				return WebManagerFileInfo(name: url.lastPathComponent, size: size)
			}
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	private static func json<T: Content>(_ value: T) -> Response {
		let data = (try? JSONEncoder().encode(value)) ?? Data("[]".utf8) // try? ok: encoding a fixed response shape; [] keeps the JSON contract if it ever fails
		var headers = HTTPHeaders()
		headers.contentType = .json
		return Response(status: .ok, headers: headers, body: .init(data: data))
	}

	private static func text(_ message: String, _ status: HTTPResponseStatus) -> Response {
		Response(status: status, body: .init(string: message))
	}

	private static func download(_ req: Request, file: URL, as filename: String) async throws -> Response {
		let response = try await req.fileio.asyncStreamFile(at: file.path)
		response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
		return response
	}

    /// The lease survives response construction and ends only when Vapor finishes
    /// sending the file; only these server-created scratch directories are removed.
    private static func downloadTemporary(_ req: Request, file: URL, as filename: String,
                                          lease: AppOperationRegistry.Lease) async throws -> Response {
        let directory = file.deletingLastPathComponent()
        do {
            let response = try await req.fileio.asyncStreamFile(at: file.path) { _ in
                defer { withExtendedLifetime(lease) {} }
                do { try FileManager.default.removeItem(at: directory) }
                catch { Logger.misc.error("Web export cleanup failed: \(error.localizedDescription)") }
            }
            response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
            return response
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Logger.misc.error("Web export cleanup failed: \(error.localizedDescription)") }
            throw error
        }
    }

	private static func dateString(_ date: Date?) -> String {
		guard let date else { return "—" }
		let f = DateFormatter()
		f.dateStyle = .medium
		return f.string(from: date)
	}

	private static func fileSize(_ url: URL) -> Int {
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
		if isDir.boolValue { return dirSize(url) }
		return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 // try? ok: size helper; a file that cannot be statted reports 0
	}

	private static func dirSize(_ url: URL?) -> Int {
		guard let url, let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
		var total = 0
		for case let f as URL in en where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { // try? ok: an entry that cannot be statted is not counted as a regular file
			total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 // try? ok: size accounting only; an unreadable entry contributes 0
		}
		return total
	}

	private static let pageHTML: String = {
		guard
			let url = Bundle.main.url(forResource: "WebManager", withExtension: "html"),
			let html = try? String(contentsOf: url, encoding: .utf8) // try? ok: a missing or unreadable bundled page falls back to the inline heading below
		else { return "<h1>VexSign Web Manager</h1>" }
		return html
	}()
}
