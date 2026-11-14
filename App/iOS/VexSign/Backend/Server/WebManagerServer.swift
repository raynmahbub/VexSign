//
//  WebManagerServer.swift
//  VexSign
//
//  On-device LAN server to push IPAs/tweaks via a TLS-protected browser or WebDAV.
//  Reuses Vapor from the install server.
//

import Foundation
import Darwin
import Vapor
import OSLog

// MARK: - Auth middleware
struct WebManagerAuthMiddleware: AsyncMiddleware {
	let username: String
	let password: String
	/// A second credential accepted on every route. The Apple TV and Vision
	/// companions, and any script, hold this instead of an account password, so a
	/// token is as powerful as the password by design — the UI says so.
	let token: String?

	func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
		guard !username.isEmpty, !password.isEmpty else {
			return Self.unauthorized()
		}

		if
			let basic = request.headers.basicAuthorization,
			Self.constantTimeEquals(basic.username, username),
			Self.constantTimeEquals(basic.password, password) {
			return try await next.respond(to: request)
		}

		if let token, !token.isEmpty {
			let provided = request.headers.first(name: WebManagerAccessPolicy.tokenHeader)
			if WebManagerAccessPolicy.tokenMatches(expected: token, provided: provided) {
				return try await next.respond(to: request)
			}
		}

		return Self.unauthorized()
	}

	private static func unauthorized() -> Response {
		var headers = HTTPHeaders()
		headers.replaceOrAdd(name: .wwwAuthenticate, value: "Basic realm=\"VexSign Web Manager\"")
		return Response(status: .unauthorized, headers: headers)
	}

	/// Constant-time compare so a wrong guess cannot be timed character-by-character.
	static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
		let lhs = Array(a.utf8), rhs = Array(b.utf8)
		guard lhs.count == rhs.count else { return false }
		guard !lhs.isEmpty else { return true }
		var diff = 0
		for i in 0..<lhs.count {
			diff |= Int(lhs[i]) ^ Int(rhs[i])
		}
		return diff == 0
	}
}

/// Gate for the endpoints that expose signing identity or destroy content.
///
/// Registered after the Basic-auth middleware, so a configured password has already
/// been checked by the time a request arrives here. It covers what Basic auth does
/// not: a server running *without* a password (loopback only) still must not hand
/// out certificates or delete library rows to whatever is on the machine, and a
/// configured API token has to be presented on these routes.
struct WebManagerSensitiveAccessMiddleware: AsyncMiddleware {
	let hasBasicAuth: Bool
	let token: String?

	func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
		guard WebManagerAccessPolicy.requiresSensitiveAccess(
			path: request.url.path,
			isDestructive: request.method == .DELETE
		) else {
			return try await next.respond(to: request)
		}

		if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let provided = request.headers.first(name: WebManagerAccessPolicy.tokenHeader)
			guard WebManagerAccessPolicy.tokenMatches(expected: token, provided: provided) else {
				return Self.reject("Missing or wrong X-VexSign-Token.", status: .unauthorized)
			}
			return try await next.respond(to: request)
		}

		guard hasBasicAuth else {
			return Self.reject(
				"This endpoint needs a password or an API token. Set one in VexSign → Settings → Web Manager.",
				status: .unauthorized
			)
		}

		return try await next.respond(to: request)
	}

	private static func reject(_ message: String, status: HTTPResponseStatus) -> Response {
		Response(status: status, body: .init(string: message))
	}
}

// MARK: - Routing
enum WebManagerRouter {
	enum Destination: String {
		case library
		case tweaks
		case inbox       // unrecognised
	}

	static func destination(for url: URL) -> Destination {
		switch url.pathExtension.lowercased() {
		case "ipa", "tipa": return .library
		// .zip unpacked and scanned for injectables — only way to send a .framework dir over the wire.
		case "dylib", "deb", "framework", "bundle", "zip": return .tweaks
		default: return .inbox
		}
	}

    /// `lease` spans staging and the asynchronous importer. WebDAV copies own
    /// only their scratch directory; an inbox transfer is removed only on success.
    static func route(_ url: URL, lease: AppOperationRegistry.Lease, stagedDirectory: URL? = nil) {
        let dest = destination(for: url)
        Task { @MainActor in
            switch dest {
            case .library:
                PackageImportService.importPackage(url) { result in
                    defer { withExtendedLifetime(lease) {} }
                    switch result {
                    case .success:
                        finish(url, stagedDirectory: stagedDirectory)
                    case .failure(let error):
                        Logger.misc.error("Transfer import failed; original retained: \(error.localizedDescription)")
                        finish(url, stagedDirectory: stagedDirectory)
                    }
                }
            case .tweaks:
                if url.pathExtension.lowercased() == "zip" {
                    routeZip(url, lease: lease, stagedDirectory: stagedDirectory)
                } else {
                    defer { withExtendedLifetime(lease) {} }
                    let imported = TweakManager.shared.addTweak(
                        name: url.deletingPathExtension().lastPathComponent, from: url) != nil
                    if !imported { Logger.misc.error("Tweak transfer import failed; original retained.") }
                    finish(url, stagedDirectory: stagedDirectory)
                }
            case .inbox:
                withExtendedLifetime(lease) {}
            }
        }
    }

    static func finish(_ url: URL, stagedDirectory: URL?) {
        // The inbox is user-owned; even a successful import is not permission
        // to delete a possibly replaced original. Only discard our staged copy.
        guard let target = stagedDirectory,
              url.deletingLastPathComponent().standardizedFileURL == target.standardizedFileURL else { return }
        do { try FileManager.default.removeItem(at: target) }
        catch { Logger.misc.error("Transfer cleanup failed: \(error.localizedDescription)") }
    }

    @MainActor
    private static func routeZip(_ url: URL, lease: AppOperationRegistry.Lease, stagedDirectory: URL?) {
        Task {
            defer { withExtendedLifetime(lease) {} }
            do {
                let result = try await TweakExtractor.extract(fromZip: url)
                let injectables = result.candidates.filter { !$0.url.path.contains(".app/") }
                var added = 0
                for candidate in injectables {
                    if TweakManager.shared.addTweak(
                        name: candidate.url.deletingPathExtension().lastPathComponent,
                        from: candidate.url) != nil { added += 1 }
                }
                do { try FileManager.default.removeItem(at: result.workDir) }
                catch { Logger.misc.error("Tweak extraction cleanup failed: \(error.localizedDescription)") }
                finish(url, stagedDirectory: stagedDirectory)
                if added > 0 {
                    Logger.misc.info("Imported \(added) tweak(s) from \(url.lastPathComponent)")
                } else {
                    Logger.misc.info("No tweaks found in \(url.lastPathComponent); original retained")
                }
            } catch {
                finish(url, stagedDirectory: stagedDirectory)
                Logger.misc.error("Zip tweak import failed; original retained: \(error.localizedDescription)")
            }
        }
    }

}

enum WebManagerFileTransaction {
    static func rename(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { old in
            destination.path.withCString { new in Darwin.rename(old, new) }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Copies into a private sibling directory before atomic publication. A move
    /// renames directly. Unsupported replacement (e.g. a nonempty directory)
    /// fails without removing either side.
    static func transfer(_ source: URL, to destination: URL, move: Bool,
                         copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
                         publish: (URL, URL) throws -> Void = WebManagerFileTransaction.rename) throws {
        let from = source.standardizedFileURL.path
        let to = destination.standardizedFileURL.path
        guard from != to, !to.hasPrefix(from + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        if move {
            try publish(source, destination)
            return
        }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".vexcopy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            do { try fm.removeItem(at: staging) }
            catch { Logger.misc.error("WebDAV copy cleanup failed: \(error.localizedDescription)") }
        }
        let prepared = staging.appendingPathComponent("item")
        try copy(source, prepared)
        try publish(prepared, destination)
    }
}

/// A streamed upload is written beside its destination and atomically renamed
/// only after all bytes have been written and closed. Abort never touches the
/// existing destination. The drain callback serializes access on its event loop.
final class WebManagerUploadFile {
    private let destination: URL
    private let temporary: URL
    private var handle: FileHandle?
    private var committed = false
    private var ownsTemporary = false
    private let replace: (URL, URL) throws -> Void

    init(destination: URL, replace: @escaping (URL, URL) throws -> Void = WebManagerFileTransaction.rename) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.destination = destination
        self.temporary = destination.deletingLastPathComponent().appendingPathComponent(".vexupload-\(UUID().uuidString).partial")
        self.replace = replace
        let descriptor = temporary.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600)) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.ownsTemporary = true
    }

    func write(_ data: Data) throws {
        guard let handle, !committed else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
    }

    func commit() throws {
        guard let handle, !committed else { throw CocoaError(.fileWriteUnknown) }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        try replace(temporary, destination)
        committed = true
    }

    func abort() {
        if let handle {
            do { try handle.close() }
            catch { Logger.misc.error("Web upload close failed: \(error.localizedDescription)") }
            self.handle = nil
        }
        guard ownsTemporary, !committed, FileManager.default.fileExists(atPath: temporary.path) else { return }
        do { try FileManager.default.removeItem(at: temporary) }
        catch { Logger.misc.error("Web upload staging cleanup failed: \(error.localizedDescription)") }
    }

    deinit { abort() }
}

// MARK: - Server
final class WebManagerServer {
	struct Auth {
		let username: String
		let password: String
	}

	let port: Int
	let inbox: URL
	/// Interface actually bound, resolved by `WebManagerAccessPolicy`.
	let bindHost: String
	/// Whether `GET /api/certs/:uuid/download` is reachable at all.
	let allowsCertificateExport: Bool

	private let _auth: Auth?
	private let _onReceive: (String) -> Void
	private let _token: String?
	private var _app: Application?
	private var _needsShutdown = false

	init(
		port: Int,
		auth: Auth?,
		bindMode: WebManagerBindMode = .localNetwork,
		token: String? = nil,
		allowsCertificateExport: Bool = false,
		onReceive: @escaping (String) -> Void
	) throws {
		self.port = port
		self.inbox = FileManager.default.webManagerInbox
		self.bindHost = WebManagerAccessPolicy.bindHost(bindMode)
		self.allowsCertificateExport = allowsCertificateExport
		self._auth = auth
		self._token = token
		self._onReceive = onReceive
		try FileManager.default.createDirectoryIfNeeded(at: inbox)
	}

	func start() async throws {
		guard _app == nil else { return }
		let app = try await _setup()
		_app = app
		_needsShutdown = true

		if let auth = _auth {
			app.middleware.use(
				WebManagerAuthMiddleware(username: auth.username, password: auth.password, token: _token)
			)
		}
		// After the Basic middleware: the sensitive gate only has to decide about
		// what Basic auth does not cover.
		app.middleware.use(WebManagerSensitiveAccessMiddleware(hasBasicAuth: _auth != nil, token: _token))
		_configureHTTP(app)
		_configureWebDAV(app)

		do {
			// Vapor's listener start is synchronous; only creation and shutdown have
			// async variants.
			try app.server.start()
			try Task.checkCancellation()
			Logger.misc.info("WebManagerServer started on port \(self.port)")
		} catch {
			await shutdownAsync()
			throw error
		}
	}

	deinit { shutdown() }

	func reportReceived(_ name: String) {
		_onReceive(name)
	}

	// MARK: - Debounced routing (WebDAV)
	// Windows writes in stages (0-byte PUT, then full PUT, sometimes temp+MOVE). Debounce per
	// path so each write reschedules one import ~1.5s later and only the final file is imported.
	private let _debounceQueue = DispatchQueue(label: "vexsign.filetransfer.debounce")
	private var _pendingRoutes: [String: DispatchWorkItem] = [:]

	func scheduleDebouncedRoute(forPath path: String, url: URL) {
		_debounceQueue.async {
			self._pendingRoutes[path]?.cancel()

			let work = DispatchWorkItem { [weak self] in
				guard let self = self else { return }
				self._debounceQueue.async { self._pendingRoutes[path] = nil }

				// Skip the 0-byte transient.
				let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 // try? ok: display-only file size in the file listing
				guard size > 0 else { return }

                if WebManagerRouter.destination(for: url) != .inbox {
                    do {
                        let lease = try AppOperationRegistry.shared.acquireTemporaryWork()
                        if let staged = Self.stagedCopy(of: url) {
                            WebManagerRouter.route(staged, lease: lease, stagedDirectory: staged.deletingLastPathComponent())
                        } else {
                            Logger.misc.error("Could not stage WebDAV import; original retained in inbox.")
                        }
                    } catch {
                        Logger.misc.error("Could not start WebDAV import; original retained: \(error.localizedDescription)")
                    }
                }
				self.reportReceived(url.lastPathComponent)
			}

			self._pendingRoutes[path] = work
			self._debounceQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
		}
	}

	/// Copies into a fresh temp dir keeping the original name, so importers read it from lastPathComponent.
	static func stagedCopy(of url: URL) -> URL? {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let dest = dir.appendingPathComponent(url.lastPathComponent)
        var created = false
		do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            created = true
			try fm.copyItem(at: url, to: dest)
			return dest
		} catch {
            if created {
                do { try fm.removeItem(at: dir) }
                catch { Logger.misc.error("WebDAV staging cleanup failed: \(error.localizedDescription)") }
            }
			return nil
		}
	}

	/// Synchronous teardown for `deinit` and the settings UI. Vapor marks the
	/// application/server shutdown calls `noasync`, so async callers must use
	/// `shutdownAsync()` instead.
	func shutdown() {
		guard _needsShutdown, let app = _app else { return }
		_needsShutdown = false
		_app = nil
		_cancelPendingRoutes()
		app.server.shutdown()
		app.shutdown()
	}

	func shutdownAsync() async {
		guard _needsShutdown, let app = _app else { return }
		_needsShutdown = false
		_app = nil
		_cancelPendingRoutes()
		await app.server.shutdown()
		do {
			try await app.asyncShutdown()
		} catch {
			Logger.misc.error("WebManagerServer shutdown failed: \(error.localizedDescription)")
		}
	}

	private func _cancelPendingRoutes() {
		_debounceQueue.async {
			self._pendingRoutes.values.forEach { $0.cancel() }
			self._pendingRoutes.removeAll()
		}
	}

	// MARK: Setup

	private func _setup() async throws -> Application {
		// Reuse ServerInstaller.env — a second LoggingSystem bootstrap would crash.
		// The Web Manager is always HTTPS. Its self-managed leaf includes the LAN
		// address (when exposed) and loopback names; a missing identity is fatal.
		let advertisedHost = bindHost == "0.0.0.0"
			? (ServerInstaller.getLocalAddress() ?? "127.0.0.1")
			: bindHost
		let tls = try ServerInstaller.webManagerTLSConfiguration(
			serverNames: [advertisedHost, "127.0.0.1", "localhost"]
		)

		// Streaming uploads still bypass this collected-body cap, as before.
		return try await ServerApplicationFactory.make(environment: ServerInstaller.env, threads: 2,
			hostname: bindHost, bindHost: bindHost, port: port, transport: .https(tls),
			bodyLimit: "32mb", caseInsensitive: true)
	}

	// MARK: Shared helpers (used by +HTTP and +WebDAV)

	/// Maps a request path to a URL inside the inbox; nil on traversal attempts.
	func resolve(_ path: String) -> URL? {
		let decoded = path.removingPercentEncoding ?? path
		let components = decoded
			.split(separator: "/", omittingEmptySubsequences: true)
			.map(String.init)

		guard !components.contains("..") else { return nil }

		var url = inbox
		for component in components {
			url.appendPathComponent(component)
		}
		return url
	}

	func sanitizedFilename(_ name: String) -> String? {
		WebManagerFilenamePolicy.filename(name)
	}

	/// Streams a request body to a file, then optionally routes + reports it.
	func streamToFile(
		_ request: Request,
		destination: URL,
		route: Bool,
		report: Bool = true,
		successStatus: HTTPResponseStatus
	) -> EventLoopFuture<Response> {
        let workLease: AppOperationRegistry.Lease
        do { workLease = try AppOperationRegistry.shared.acquireTemporaryWork() }
        catch {
            return request.eventLoop.makeSucceededFuture(Response(status: .serviceUnavailable,
                body: .init(string: "Cleanup is in progress. Retry the upload.")))
        }
        let upload: WebManagerUploadFile
        do { upload = try WebManagerUploadFile(destination: destination) }
        catch {
            Logger.misc.error("Web upload could not start: \(error.localizedDescription)")
            return request.eventLoop.makeSucceededFuture(Response(status: .internalServerError))
        }
        let promise = request.eventLoop.makePromise(of: Response.self)
        var finished = false

        request.body.drain { part in
            defer { withExtendedLifetime(workLease) {} }
            guard !finished else { return request.eventLoop.makeSucceededFuture(()) }
            switch part {
            case .buffer(let buffer):
                do { try upload.write(Data(buffer.readableBytesView)) }
                catch {
                    finished = true
                    upload.abort()
                    promise.fail(error)
                }
            case .error(let error):
                finished = true
                upload.abort()
                promise.fail(error)
            case .end:
                finished = true
                do {
                    try upload.commit()
                } catch {
                    upload.abort()
                    promise.fail(error)
                    return request.eventLoop.makeSucceededFuture(())
                }
                if report { self._onReceive(destination.lastPathComponent) }
                if route, WebManagerRouter.destination(for: destination) != .inbox {
                    if let staged = Self.stagedCopy(of: destination) {
                        WebManagerRouter.route(staged, lease: workLease, stagedDirectory: staged.deletingLastPathComponent())
                    } else {
                        Logger.misc.error("Could not stage transfer; original retained in inbox.")
                    }
                }
                promise.succeed(Response(status: successStatus))
            }
            return request.eventLoop.makeSucceededFuture(())
        }

		return promise.futureResult
	}
}
