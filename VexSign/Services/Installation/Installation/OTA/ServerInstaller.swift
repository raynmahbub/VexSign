//
//  Server.swift
//  vexsign
//
//  Created by VexSign Contributors on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR VEXSIGN
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift
import NimbleExtensions

// Successful response bodies establish delivery coverage, not installation. iOS may
// fetch an IPA in several (possibly overlapping or out-of-order) HTTP ranges.
struct OTAPayloadCoverage {
    private var size: Int64?
    private var ranges: [Range<Int64>] = []
    private var isComplete = false
    private static let maxDisjointRanges = 4096

    /// Bytes in successfully completed responses, without double-counting retries
    /// or overlaps. This is transfer progress, not device installation evidence.
    var fractionDelivered: Double {
        guard let size, size > 0 else { return 0 }
        let covered = ranges.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        return Double(covered) / Double(size)
    }

    mutating func recordSuccessfulResponse(rangeHeader: String?, fileSize: Int64) -> Bool {
        guard !isComplete, fileSize > 0, size == nil || size == fileSize,
              let range = Self.responseRange(rangeHeader, fileSize: fileSize) else { return false }
        size = fileSize
        ranges.append(range)
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int64>] = []
        for current in ranges {
            if let last = merged.last, current.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, current.upperBound)
            } else {
                merged.append(current)
            }
        }
        // A hostile client must not force unbounded bookkeeping. Failing closed
        // leaves the normal monitoring deadline responsible for the outcome.
        if merged.count > Self.maxDisjointRanges { ranges = []; return false }
        ranges = merged
        isComplete = merged.count == 1 && merged[0].lowerBound == 0 && merged[0].upperBound == fileSize
        return isComplete
    }

    private static func responseRange(_ header: String?, fileSize: Int64) -> Range<Int64>? {
        guard let header else { return 0..<fileSize }
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let count = Int64(parts[1]), count > 0, count <= fileSize else { return nil }
            return (fileSize - count)..<fileSize
        }
        guard let start = Int64(parts[0]), start >= 0, start < fileSize else { return nil }
        if parts[1].isEmpty { return start..<fileSize }
        guard let end = Int64(parts[1]), end >= start, end < fileSize else { return nil }
        return start..<(end + 1)
    }
}

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let installToken = WebManagerAccessPolicy.generateToken()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	private let _serverMethod: Int
	private let _localhostOnly: Bool

    @MainActor private var payloadCoverage = OTAPayloadCoverage()
    var packageArchive: InstallationArchive?
	var packageUrl: URL?
	var manifestUrl: URL?
	private(set) var startupError: Error?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	private var backgroundTaskManager: BackgroundTaskManager?

	init(
		app: AppInfoPresentable,
		viewModel: InstallerStatusViewModel,
		serverMethod: Int? = nil,
		localhostOnly: Bool? = nil
	) {
		self._serverMethod = serverMethod ?? UserDefaults.standard.integer(forKey: "VexSign.serverMethod")
		self._localhostOnly = localhostOnly ?? UserDefaults.standard.bool(forKey: "VexSign.ipFix")
		self.app = app
		self.viewModel = viewModel

		let mode = getServerMethod() == 1 ? "semi-local" : "fully-local"
		FileLogger.log("installer prepared: mode=\(mode) host=\(sni()) port=\(port) ipFix=\(getIPFix())", category: "install")
	}

	func start() async {
		guard _server == nil, startupError == nil else { return }
		do {
			let server = try await setupApp(port: port)
			_server = server
			_needsShutdown = true
            try Task.checkCancellation()
			_configureRoutes()
			// Vapor's listener start is synchronous; only creation and shutdown have
			// async variants.
			try server.server.start()
			FileLogger.log("server listening on \(sni()):\(port)", category: "install")
		} catch {
			FileLogger.error("server failed to start: \(error)", category: "install")
			startupError = error
			await _shutdownServerAsync()
		}
	}
	
    /// Stop accepting requests without blocking the main actor in synchronous deinit.
    /// In-flight response completions independently retain their archive lease.
    func stop() async {
        await _shutdownServerAsync()
        backgroundTaskManager?.stop()
        backgroundTaskManager = nil
    }

	deinit {
		_shutdownServer()
		backgroundTaskManager?.stop()
	}
	
	private func _configureRoutes() {
		_server?.get("**") { [weak self] req async throws -> Response in
			guard let self else { return Response(status: .badGateway) }

			switch req.url.path {
			case plistEndpoint.path:
				FileLogger.log("request: \(req.method.rawValue) /<session>.plist", category: "install")
				let manifestData: Data
				do {
					manifestData = try self.buildInstallManifestData()
				} catch {
					FileLogger.error("manifest serialization failed: \(error.localizedDescription)", category: "install")
					return Response(status: .internalServerError)
				}
				self._updateStatus(.sendingManifest)
				if self.backgroundTaskManager == nil {
					self.backgroundTaskManager = BackgroundTaskManager(
						taskName: "ServerInstaller",
						expirationTitle: "Installation continuing",
						expirationBody: "Keep the app open to complete the installation"
					)
					self.backgroundTaskManager?.start()
				}
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml"
				], body: .init(data: manifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png"
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png"
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				FileLogger.log("request: \(req.method.rawValue) /<session>.ipa", category: "install")
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}

                let rangeHeader = req.headers.first(name: .range)
                let fileSize = (try? packageUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) // try? ok: unavailable size cannot prove complete delivery
				let response = try await req.fileio.asyncStreamFile(
					at: packageUrl.path
                ) { [archive = self.packageArchive] result in
                    // Vapor retains this completion until the body finishes or fails.
                    defer { withExtendedLifetime(archive) {} }
					// The stream completion is @Sendable and runs off the main actor, so
					// status changes have to hop back explicitly.
					switch result {
					case .success:
						Task { @MainActor [weak self] in
                            guard let self, let fileSize else { return }
                            let completed = self.payloadCoverage.recordSuccessfulResponse(rangeHeader: rangeHeader, fileSize: fileSize)
                            // Unlike the upstream progress callback, count only fully
                            // delivered response ranges and merge overlaps; a failed
                            // stream must never advance the delivery completion gate.
                            self.viewModel.uploadProgress = self.payloadCoverage.fractionDelivered
                            if completed { self._updateStatus(.installing) }
						}
					case .failure(let error):
						Task { @MainActor [weak self] in
							self?._updateStatus(.broken(error))
							self?.backgroundTaskManager?.stop()
							self?.backgroundTaskManager = nil
						}
					}
				}
                // Vapor may return a bodyless 304. A cache response is not a
                // newly started payload transfer and must not start its deadline.
                if response.status == .ok || response.status == .partialContent {
                    self._updateStatus(.sendingPayload)
                }
                return response
			case "/healthz":
				return Response(status: .ok)
			case "/install":
				let providedToken = (try? req.query.get(String.self, at: "token")) ?? "" // try? ok: missing/malformed query token is treated as empty and rejected below
				guard !providedToken.isEmpty,
					  WebManagerAuthMiddleware.constantTimeEquals(providedToken, self.installToken) else {
					return Response(status: .forbidden)
				}
				FileLogger.log("request: \(req.method.rawValue) /install", category: "install")
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html; charset=utf-8")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	// installd fails silently when unreachable, so prove it first — but not for Semi Local, where probing a LAN address would prompt for local network access.
	func selfCheck() async -> Error? {
		guard getServerMethod() != 1 else { return nil }

		let host = sni()
		let addresses = Self.resolve(host)
		FileLogger.log("\(host) resolves to \(addresses.isEmpty ? "nothing" : addresses.joined(separator: ", "))", category: "install")

		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = host
		comps.port = port
		comps.path = "/healthz"

		guard let url = comps.url else { return LocalInstallError.invalidHostname }

		do {
			// Status only. `bytes(for:)` returns as soon as the headers are in and hands back a
			// body stream that is cancelled when it is dropped; `data(for:)` buffered whatever a
			// user-supplied host chose to answer `/healthz` with before anything looked at it.
			let (_, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 10))
			guard (response as? HTTPURLResponse)?.statusCode == 200 else {
				throw LocalInstallError.unreachable
			}
			FileLogger.log("self check reached the server: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", category: "install")
			return nil
		} catch {
			FileLogger.error("self check could not reach \(url.logSafeDescription): \(error.localizedDescription)", category: "install")
			return error
		}
	}
	
	/// Synchronous teardown for `deinit`, where awaiting is impossible.
	/// Vapor marks these calls `noasync`; the async twin below is used from
	/// `start()` so the server is never torn down from an async context.
	private func _shutdownServer() {
		guard _needsShutdown, let server = _server else { return }

		_needsShutdown = false
		_server = nil
		server.server.shutdown()
		server.shutdown()
	}

	private func _shutdownServerAsync() async {
		guard _needsShutdown, let server = _server else { return }

		_needsShutdown = false
		_server = nil
		await server.server.shutdown()
		do {
			try await server.asyncShutdown()
		} catch {
			FileLogger.error("server shutdown failed: \(error)", category: "install")
		}
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.updateTransportStatus(newStatus)
		}
	}

	func getServerMethod() -> Int {
		_serverMethod
	}

	func getIPFix() -> Bool {
		_localhostOnly
	}
}

// Keep Fully Local genuinely local: never disable TLS trust or silently send a
// manifest to a remote service. The queue offers an explicit Semi Local retry.
extension ServerInstaller {
	enum LocalInstallError: LocalizedError {
		case missingTLS
		case invalidHostname
		case invalidManifestMetadata
		case unreachable
		case unavailable(Error)

		var errorDescription: String? {
			switch self {
			case .missingTLS:
				return .localized("The device-local HTTPS identity is unavailable. Open Settings → Installation → Server & SSL, check the local identity, then export and trust its Root CA profile.")
			case .invalidHostname:
				return .localized("The local HTTPS hostname is missing or invalid. Check the device identity in Settings → Installation → Server & SSL.")
			case .invalidManifestMetadata:
				return "The signed application metadata is incomplete (missing bundle identifier)."
			case .unreachable:
				return .localized("The local HTTPS server did not respond successfully.")
			case .unavailable(let error):
				return .localized("Fully Local could not verify the local HTTPS connection. In Settings → Installation → Server & SSL, export the Root CA profile and install it in system Settings. Then enable Full Trust under General → About → Certificate Trust Settings and retry. Do not replace the CA for a trust-only error. Semi Local is an optional online manifest-service fallback; the IPA stays on your device.")
					+ "\n\n" + error.localizedDescription
			}
		}
	}
}
