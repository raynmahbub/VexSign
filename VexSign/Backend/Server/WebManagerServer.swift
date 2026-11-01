//
//  WebManagerServer.swift
//  VexSign
//
//  On-device LAN server to push IPAs/tweaks via browser (HTTP) or mounted drive (WebDAV).
//  Reuses Vapor from the install server.
//

import Foundation
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

	static func route(_ url: URL) {
		let dest = destination(for: url)
		Task { @MainActor in
			switch dest {
			case .library:
				FR.handlePackageFile(url) { result in
					if case .failure(let error) = result {
						Logger.misc.error("Transfer import failed: \(error.localizedDescription)")
					}
					try? FileManager.default.removeItem(at: url)
				}
			case .tweaks:
				if url.pathExtension.lowercased() == "zip" {
					_routeZip(url)
				} else {
					_ = TweakManager.shared.addTweak(
						name: url.deletingPathExtension().lastPathComponent,
						from: url
					)
					try? FileManager.default.removeItem(at: url)
				}
			case .inbox:
				break
			}
		}
	}

	/// Imports injectables from a .zip; leaves it in the inbox if none found.
	@MainActor
	private static func _routeZip(_ url: URL) {
		Task {
			do {
				let result = try await TweakExtractor.extract(fromZip: url)
				// Skip artifacts inside a packaged app, else a zipped .app dumps its own frameworks in.
				let injectables = result.candidates.filter { !$0.url.path.contains(".app/") }
				await MainActor.run {
					var added = 0
					for candidate in injectables {
						if TweakManager.shared.addTweak(
							name: candidate.url.deletingPathExtension().lastPathComponent,
							from: candidate.url
						) != nil {
							added += 1
						}
					}
					try? FileManager.default.removeItem(at: result.workDir)
					if added > 0 {
						try? FileManager.default.removeItem(at: url)
						Logger.misc.info("Imported \(added) tweak(s) from \(url.lastPathComponent)")
					} else {
						Logger.misc.info("No tweaks found in \(url.lastPathComponent); left in inbox")
					}
				}
			} catch {
				Logger.misc.error("Zip tweak import failed: \(error.localizedDescription)")
			}
		}
	}
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
		self._onReceive = onReceive

		try FileManager.default.createDirectoryIfNeeded(at: inbox)

		let app = try _setup()
		self._app = app

		if let auth = _auth {
			app.middleware.use(
				WebManagerAuthMiddleware(username: auth.username, password: auth.password, token: token)
			)
		}
		// After the Basic middleware: the sensitive gate only has to decide about
		// what Basic auth does not cover.
		app.middleware.use(WebManagerSensitiveAccessMiddleware(hasBasicAuth: _auth != nil, token: token))

		_configureHTTP(app)
		_configureWebDAV(app)

		try app.server.start()
		_needsShutdown = true
		Logger.misc.info("WebManagerServer started on port \(port)")
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
				let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
				guard size > 0 else { return }

				if WebManagerRouter.destination(for: url) != .inbox {
					WebManagerRouter.route(Self.stagedCopy(of: url) ?? url)
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
		do {
			try fm.createDirectoryIfNeeded(at: dir)
			try fm.copyItem(at: url, to: dest)
			return dest
		} catch {
			return nil
		}
	}

	func shutdown() {
		guard _needsShutdown else { return }
		_needsShutdown = false
		_debounceQueue.async {
			self._pendingRoutes.values.forEach { $0.cancel() }
			self._pendingRoutes.removeAll()
		}
		_app?.server.shutdown()
		_app?.shutdown()
		_app = nil
	}

	// MARK: Setup

	private func _setup() throws -> Application {
		// Reuse ServerInstaller.env — a second LoggingSystem bootstrap would crash.
		let app = Application(ServerInstaller.env)
		app.threadPool = .init(numberOfThreads: 2)
		app.http.server.configuration.hostname = bindHost
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname(bindHost, port: port)
		app.http.server.configuration.port = port
		// Collected bodies only. Uploads, `/api/sign` and WebDAV PUTs use
		// `body: .stream` and go straight to disk, while `POST /api/certs` collects a
		// multipart p12 + profile - a 2 GB default let that endpoint allocate
		// gigabytes from one request.
		app.routes.defaultMaxBodySize = "32mb"
		app.routes.caseInsensitive = true
		return app
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

	func sanitizedFilename(_ name: String) -> String {
		let decoded = name.removingPercentEncoding ?? name
		let last = (decoded as NSString).lastPathComponent
		let cleaned = last.replacingOccurrences(of: "/", with: "_")
		return cleaned.isEmpty ? "upload-\(UUID().uuidString).bin" : cleaned
	}

	/// Streams a request body to a file, then optionally routes + reports it.
	func streamToFile(
		_ request: Request,
		destination: URL,
		route: Bool,
		keepOriginal: Bool = false,
		report: Bool = true,
		successStatus: HTTPResponseStatus
	) -> EventLoopFuture<Response> {
		let fm = FileManager.default
		try? fm.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
		try? fm.removeItem(at: destination)

		guard fm.createFile(atPath: destination.path, contents: nil) else {
			return request.eventLoop.makeSucceededFuture(Response(status: .internalServerError))
		}

		let handle: FileHandle
		do {
			handle = try FileHandle(forWritingTo: destination)
		} catch {
			return request.eventLoop.makeSucceededFuture(Response(status: .internalServerError))
		}

		let promise = request.eventLoop.makePromise(of: Response.self)

		request.body.drain { part in
			switch part {
			case .buffer(let buffer):
				do {
					try handle.write(contentsOf: Data(buffer.readableBytesView))
				} catch {
					try? handle.close()
					promise.fail(error)
				}
				return request.eventLoop.makeSucceededFuture(())
			case .error(let error):
				try? handle.close()
				try? fm.removeItem(at: destination)
				promise.fail(error)
				return request.eventLoop.makeSucceededFuture(())
			case .end:
				try? handle.close()
				if report { self._onReceive(destination.lastPathComponent) }
				if route {
					if keepOriginal {
						// WebDAV: import a copy so the file stays visible on the mounted drive.
						WebManagerRouter.route(Self.stagedCopy(of: destination) ?? destination)
					} else {
						WebManagerRouter.route(destination)
					}
				}
				promise.succeed(Response(status: successStatus))
				return request.eventLoop.makeSucceededFuture(())
			}
		}

		return promise.futureResult
	}
}
