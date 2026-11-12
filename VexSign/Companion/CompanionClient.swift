//
//  CompanionClient.swift
//  VexSign
//
//  Reads a companion snapshot from the iPhone's Web Manager. HTTPS is mandatory
//  by default: the platform validates the Web Manager's host certificate against
//  a device CA whose SHA-256 fingerprint the user compares out of band. The
//  accepted CA is kept in Keychain. HTTP is possible only after an explicit opt-in
//  for a local-network address; it is never used as a fallback. Redirects are
//  refused so URLSession cannot forward credentials to another request target.
//
//  Foundation/Security/CryptoKit only, shared by the tvOS and visionOS apps.
//

import CryptoKit
import Foundation
import Security

/// Failure of the status request (which is required to identify the phone) or of
/// an individual library/update request. Endpoint failures are retained as values
/// in `CompanionSnapshotResult`, rather than being converted to empty arrays.
enum CompanionClientError: LocalizedError, Equatable {
	case missingAddress
	case invalidAddress
	case insecureTransport
	case certificatePairingRequired
	case invalidCertificateFingerprint
	case certificateFingerprintMismatch
	case certificateChanged
	case certificateChangeRequiresExplicitForget
	case invalidServerCertificate
	case invalidStoredTrust
	case certificateTrustStorageFailed
	case unsafeRedirect
	case unreachable(String)
	case timedOut
	case unauthorized
	case httpStatus(Int)
	case decoding(String)

	var errorDescription: String? {
		switch self {
		case .missingAddress:
			return "No iPhone address is set. Enter the HTTPS Web Manager URL shown in VexSign → Settings → Web Manager."
		case .invalidAddress:
			return "That address is not a valid HTTP or HTTPS URL."
		case .insecureTransport:
			return "Plain HTTP is allowed only after opting in for a local-network address. Credentials and data are sent without encryption."
		case .certificatePairingRequired:
			return "This HTTPS address is not paired yet. Compare the device CA SHA-256 fingerprint shown in iPhone Settings → Web Manager, enter it above, then connect."
		case .invalidCertificateFingerprint:
			return "Enter the complete 64-character hexadecimal SHA-256 fingerprint shown on the iPhone."
		case .certificateFingerprintMismatch:
			return "The server certificate does not match the fingerprint shown on the iPhone. No credentials were sent. Check the address and fingerprint."
		case .certificateChanged:
			return "The server certificate no longer matches the saved trusted-device CA. Verify the new fingerprint on the iPhone before changing trust. No credentials were sent."
		case .certificateChangeRequiresExplicitForget:
			return "This fingerprint differs from the saved trust. Use “Forget Trusted Certificate” only after checking the new fingerprint on the iPhone, then pair again."
		case .invalidServerCertificate:
			return "The server certificate is invalid, expired, or does not match this address. No credentials were sent."
		case .invalidStoredTrust:
			return "The saved certificate trust record is invalid. It was not replaced; forget it explicitly and pair again."
		case .certificateTrustStorageFailed:
			return "Keychain could not read or save the trusted certificate. Unlock the device and try again; no new trust was accepted."
		case .unsafeRedirect:
			return "The iPhone returned an unsafe redirect. Re-enter the trusted Web Manager address."
		case .unreachable(let detail):
			return "Could not reach the iPhone: \(detail)"
		case .timedOut:
			return "The iPhone did not respond before the request timed out."
		case .unauthorized:
			return "Authentication failed. Check the Web Manager username, password and API token."
		case .httpStatus(let status):
			return "The iPhone returned HTTP \(status). Try again later."
		case .decoding(let detail):
			return "The iPhone replied with something unexpected: \(detail)"
		}
	}

	var isAuthenticationFailure: Bool {
		self == .unauthorized
	}
}

/// A successful status response plus independently observable endpoint outcomes.
/// `success([])` is a real, successfully-loaded empty collection; `.failure` is
/// never treated as empty data.
struct CompanionSnapshotResult: Equatable {
	var status: CompanionStatus
	var library: Result<[CompanionLibraryEntry], CompanionClientError>
	var updates: Result<[CompanionUpdateEntry], CompanionClientError>
	var generatedAt: Date
}

/// A Keychain-persisted trust anchor accepted only after its fingerprint matches
/// the value entered from the iPhone's Web Manager settings.
enum CompanionCertificateTrust {
	struct Pin: Codable, Equatable {
		var certificate: Data
		var fingerprint: String
	}

	private static let _service = "com.vexsign.companion.tls-trust.v1"
	private static let _accountPrefix = "companion.tls."

	static func fingerprint(_ certificate: Data) -> String {
		SHA256.hash(data: certificate)
			.map { String(format: "%02X", Int($0)) }
			.joined(separator: ":")
	}

	/// Canonical uppercase hex without separators; rejects anything other than a
	/// full SHA-256 digest. Empty text means that the user has not entered one.
	static func normalizedFingerprint(_ raw: String) -> String? {
		let compact = raw.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
		guard compact.utf8.count == 64 else { return nil }
		let uppercased = compact.uppercased()
		guard uppercased.utf8.allSatisfy({
			($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70)
		}) else { return nil }
		return uppercased
	}

	static func enteredFingerprint(_ raw: String?) throws -> String? {
		guard let raw else { return nil }
		if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
		guard let normalized = normalizedFingerprint(raw) else {
			throw CompanionClientError.invalidCertificateFingerprint
		}
		return normalized
	}

	static func expectedFingerprint(for pinned: Pin?, entered raw: String?) throws -> String? {
		let entered = try enteredFingerprint(raw)
		if let pinned {
			guard let saved = normalizedFingerprint(pinned.fingerprint) else {
				throw CompanionClientError.invalidStoredTrust
			}
			if let entered, saved != entered {
				throw CompanionClientError.certificateChangeRequiresExplicitForget
			}
			return nil
		}
		guard let entered else { throw CompanionClientError.certificatePairingRequired }
		return entered
	}

	static func load(for url: URL) throws -> Pin? {
		guard let account = _account(for: url) else { throw CompanionClientError.invalidAddress }
		let encoded: Data?
		do {
			encoded = try SecureSecretStore.read(account, service: _service)
		} catch {
			throw CompanionClientError.certificateTrustStorageFailed
		}
		guard let encoded else { return nil }

		let pin: Pin
		do {
			pin = try JSONDecoder().decode(Pin.self, from: encoded)
		} catch {
			throw CompanionClientError.invalidStoredTrust
		}
		let actualFingerprint = normalizedFingerprint(fingerprint(pin.certificate))
		guard let savedFingerprint = normalizedFingerprint(pin.fingerprint),
			  let actualFingerprint,
			  savedFingerprint == actualFingerprint,
			  SecCertificateCreateWithData(nil, pin.certificate as CFData) != nil else {
			throw CompanionClientError.invalidStoredTrust
		}
		return pin
	}

	static func forget(for url: URL) throws {
		guard let account = _account(for: url) else { throw CompanionClientError.invalidAddress }
		do {
			try SecureSecretStore.delete(account, service: _service)
		} catch {
			throw CompanionClientError.certificateTrustStorageFailed
		}
	}

	/// Re-evaluates the received chain with the selected certificate as the only
	/// trust anchor and an SSL hostname policy. This retains platform validation of
	/// signatures, validity dates, EKU and DNS/IP name matching while limiting trust
	/// to the exact out-of-band-paired device CA.
	static func validate(
		serverTrust: SecTrust,
		host: String,
		pinned: Pin?,
		expectedFingerprint: String?
	) throws -> Data {
		let anchorData: Data
		if let pinned {
			let actual = normalizedFingerprint(fingerprint(pinned.certificate))
			guard let saved = normalizedFingerprint(pinned.fingerprint),
				  let actual,
				  saved == actual,
				  SecCertificateCreateWithData(nil, pinned.certificate as CFData) != nil else {
				throw CompanionClientError.invalidStoredTrust
			}
			anchorData = pinned.certificate
		} else {
			guard let expectedFingerprint,
				  let expected = normalizedFingerprint(expectedFingerprint) else {
				throw CompanionClientError.certificatePairingRequired
			}
			let peerCertificates = _peerCertificates(in: serverTrust)
			guard let matching = peerCertificates.first(where: { certificate in
				let data = SecCertificateCopyData(certificate) as Data
				return normalizedFingerprint(fingerprint(data)) == expected
			}) else {
				throw CompanionClientError.certificateFingerprintMismatch
			}
			anchorData = SecCertificateCopyData(matching) as Data
		}

		guard let anchor = SecCertificateCreateWithData(nil, anchorData as CFData) else {
			throw CompanionClientError.invalidServerCertificate
		}
		let policy = SecPolicyCreateSSL(true, host as CFString)
		guard SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray) == errSecSuccess,
			  SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess,
			  SecTrustSetPolicies(serverTrust, policy) == errSecSuccess,
			  SecTrustSetNetworkFetchAllowed(serverTrust, false) == errSecSuccess else {
			throw CompanionClientError.invalidServerCertificate
		}

		var evaluationError: CFError?
		guard SecTrustEvaluateWithError(serverTrust, &evaluationError) else {
			if pinned != nil { throw CompanionClientError.certificateChanged }
			throw CompanionClientError.invalidServerCertificate
		}
		return anchorData
	}

	/// The first accepted pin is add-only. A concurrent or existing pin can never
	/// be overwritten by a different certificate during pairing.
	static func saveNew(_ certificate: Data, for url: URL, expectedFingerprint: String) throws {
		guard let account = _account(for: url),
			  let expected = normalizedFingerprint(expectedFingerprint),
			  normalizedFingerprint(fingerprint(certificate)) == expected,
			  SecCertificateCreateWithData(nil, certificate as CFData) != nil else {
			throw CompanionClientError.certificateFingerprintMismatch
		}

		let pin = Pin(certificate: certificate, fingerprint: fingerprint(certificate))
		let encoded: Data
		do {
			encoded = try JSONEncoder().encode(pin)
		} catch {
			throw CompanionClientError.certificateTrustStorageFailed
		}

		do {
			try SecureSecretStore.writeIfAbsent(encoded, account: account, service: _service)
		} catch let failure as SecureSecretStore.Failure where failure.status == errSecDuplicateItem {
			guard let concurrentPin = try load(for: url) else {
				throw CompanionClientError.invalidStoredTrust
			}
			guard concurrentPin.certificate == certificate,
				  normalizedFingerprint(concurrentPin.fingerprint) == expected else {
				throw CompanionClientError.certificateChanged
			}
		} catch {
			throw CompanionClientError.certificateTrustStorageFailed
		}
	}

	private static func _peerCertificates(in trust: SecTrust) -> [SecCertificate] {
		(SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
	}

	private static func _account(for url: URL) -> String? {
		guard url.scheme?.lowercased() == "https",
			  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
		let port = url.port ?? 443
		let origin = "https|\(host)|\(port)"
		let digest = SHA256.hash(data: Data(origin.utf8))
		let suffix = digest.map { String(format: "%02x", Int($0)) }.joined()
		return _accountPrefix + suffix
	}
}

/// Validates that the response came from the exact requested URL. Redirects are
/// refused outright because URLSession can forward Authorization headers.
enum CompanionRedirectPolicy {
	static func permits(from source: URL?, to destination: URL?) -> Bool {
		guard let source, let destination else { return false }
		return source.absoluteString == destination.absoluteString
	}
}

/// Session delegate that applies the same strict redirect rule and performs
/// certificate-fingerprint pairing without allowing credentials onto an
/// unverified connection.
private final class CompanionURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
	private let _origin: URL
	private let _pinned: CompanionCertificateTrust.Pin?
	private let _expectedFingerprint: String?
	private let _stateLock = NSLock()
	private var _recordedFailure: CompanionClientError?

	init(origin: URL, pinned: CompanionCertificateTrust.Pin?, expectedFingerprint: String?) {
		self._origin = origin
		self._pinned = pinned
		self._expectedFingerprint = expectedFingerprint
	}

	var recordedFailure: CompanionClientError? {
		_stateLock.lock()
		defer { _stateLock.unlock() }
		return _recordedFailure
	}

	func urlSession(
		_ session: URLSession,
		didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
	) {
		guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
			  let serverTrust = challenge.protectionSpace.serverTrust else {
			completionHandler(.performDefaultHandling, nil)
			return
		}

		guard _challengeMatchesOrigin(challenge.protectionSpace) else {
			_record(.unsafeRedirect)
			completionHandler(.cancelAuthenticationChallenge, nil)
			return
		}

		do {
			let host = challenge.protectionSpace.host
			let acceptedCertificate = try CompanionCertificateTrust.validate(
				serverTrust: serverTrust,
				host: host,
				pinned: _pinned,
				expectedFingerprint: _expectedFingerprint
			)
			if _pinned == nil {
				guard let expected = _expectedFingerprint else {
					throw CompanionClientError.certificatePairingRequired
				}
				try CompanionCertificateTrust.saveNew(
					acceptedCertificate,
					for: _origin,
					expectedFingerprint: expected
				)
			}
			completionHandler(.useCredential, URLCredential(trust: serverTrust))
		} catch let error as CompanionClientError {
			_record(error)
			completionHandler(.cancelAuthenticationChallenge, nil)
		} catch {
			_record(.certificateTrustStorageFailed)
			completionHandler(.cancelAuthenticationChallenge, nil)
		}
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		// The Web Manager's three API endpoints are direct responses. Reject every
		// redirect, even a same-origin one, before URLSession can reuse credential headers.
		_record(.unsafeRedirect)
		completionHandler(nil)
	}

	private func _challengeMatchesOrigin(_ protectionSpace: URLProtectionSpace) -> Bool {
		guard let originHost = _origin.host?.lowercased() else { return false }
		let originPort = _origin.port ?? 443
		return protectionSpace.host.lowercased() == originHost && protectionSpace.port == originPort
	}

	private func _record(_ error: CompanionClientError) {
		_stateLock.lock()
		_recordedFailure = error
		_stateLock.unlock()
	}
}

/// One-shot reader for the Web Manager API. No caching or retries: companions
/// refresh on demand and on a timer, and show their last good state meanwhile.
struct CompanionClient {
	typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

	var address: String
	var username: String?
	var password: String?
	var apiToken: String?
	var allowInsecureHTTP: Bool
	var allowsInsecureHTTP: Bool {
		get { allowInsecureHTTP }
		set { allowInsecureHTTP = newValue }
	}
	var pairingFingerprint: String?

	private static let _timeout: TimeInterval = 12
	private let _dataLoader: DataLoader

	init(
		address: String,
		username: String?,
		password: String?,
		apiToken: String?,
		allowInsecureHTTP: Bool = false,
		pairingFingerprint: String? = nil,
		dataLoader: DataLoader? = nil
	) {
		self.address = address
		self.username = username
		self.password = password
		self.apiToken = apiToken
		self.allowInsecureHTTP = allowInsecureHTTP
		self.pairingFingerprint = pairingFingerprint
		if let dataLoader {
			self._dataLoader = dataLoader
		} else {
			self._dataLoader = { request in
				try await Self._defaultDataLoader(request, pairingFingerprint: pairingFingerprint)
			}
		}
	}

	/// Compatibility spelling retained for callers on the earlier PR version.
	init(
		address: String,
		username: String?,
		password: String?,
		apiToken: String?,
		allowsInsecureHTTP: Bool,
		pairingFingerprint: String? = nil,
		dataLoader: DataLoader? = nil
	) {
		self.init(
			address: address,
			username: username,
			password: password,
			apiToken: apiToken,
			allowInsecureHTTP: allowsInsecureHTTP,
			pairingFingerprint: pairingFingerprint,
			dataLoader: dataLoader
		)
	}

	func snapshot() async throws -> CompanionSnapshotResult {
		let status = try await _get("api/status", as: CompanionStatus.self)
		let library = await _result("api/library", as: [CompanionLibraryEntry].self)
		let updates = await _result("api/updates", as: [CompanionUpdateEntry].self)

		return CompanionSnapshotResult(
			status: status,
			library: library,
			updates: updates,
			generatedAt: Date()
		)
	}

	// MARK: - Request

	static func baseURL(from address: String) throws -> URL {
		let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw CompanionClientError.missingAddress }

		// A bare host is HTTPS by default. There is deliberately no retry or
		// fallback to HTTP if TLS validation or the HTTPS connection fails.
		let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
		guard
			let components = URLComponents(string: normalized),
			let scheme = components.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let host = components.host,
			!host.isEmpty,
			components.user == nil,
			components.password == nil,
			components.query == nil,
			components.fragment == nil,
			let url = components.url
		else {
			throw CompanionClientError.invalidAddress
		}
		return url
	}

	/// Resolve an address without allowing an unencrypted public-network request.
	/// HTTPS remains the default and is never downgraded after a TLS failure.
	static func transport(for rawAddress: String, allowInsecureHTTP: Bool) throws -> URL {
		let url = try baseURL(from: rawAddress)
		guard url.scheme?.lowercased() == "http" else { return url }
		guard allowInsecureHTTP, let host = url.host, isLocalNetworkHost(host) else {
			throw CompanionClientError.insecureTransport
		}
		return url
	}

	/// Local-network classification for the HTTP opt-in. Public IPs and hostnames
	/// remain disallowed even when the user enables unencrypted transport.
	static func isLocalNetworkHost(_ rawHost: String) -> Bool {
		let bracketless = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
		let host = bracketless.hasSuffix(".") ? String(bracketless.dropLast()) : bracketless
		if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }

		if host.contains(":") {
			return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8")
				|| host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
		}

		let parts = host.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 4,
			  let first = Int(parts[0]),
			  let second = Int(parts[1]),
			  parts.allSatisfy({ part in
				  !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
					  && Int(part).map { (0...255).contains($0) } == true
			  }) else {
			return false
		}
		switch (first, second) {
		case (127, _), (10, _), (192, 168), (172, 16...31), (169, 254): return true
		default: return false
		}
	}

	private func _result<T: Decodable>(_ path: String, as type: T.Type) async -> Result<T, CompanionClientError> {
		do {
			return .success(try await _get(path, as: type))
		} catch let error as CompanionClientError {
			return .failure(error)
		} catch {
			return .failure(.unreachable(error.localizedDescription))
		}
	}

	private func _get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
		let base = try Self.transport(for: address, allowInsecureHTTP: allowInsecureHTTP)
		let url = base.appendingPathComponent(path)
		var request = URLRequest(url: url)
		request.timeoutInterval = Self._timeout
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		if let token = apiToken?.trimmingCharacters(in: .whitespaces), !token.isEmpty {
			request.setValue(token, forHTTPHeaderField: "X-VexSign-Token")
		}
		if let username, let password, !username.isEmpty {
			let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
			request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
		}

		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await _dataLoader(request)
		} catch let error as CompanionClientError {
			throw error
		} catch let error as URLError where error.code == .timedOut {
			throw CompanionClientError.timedOut
		} catch {
			throw CompanionClientError.unreachable(error.localizedDescription)
		}

		guard let http = response as? HTTPURLResponse else {
			throw CompanionClientError.unreachable("no HTTP response")
		}
		guard CompanionRedirectPolicy.permits(from: url, to: http.url),
			  !(300..<400).contains(http.statusCode) else {
			throw CompanionClientError.unsafeRedirect
		}
		guard http.statusCode != 401 && http.statusCode != 403 else {
			throw CompanionClientError.unauthorized
		}
		guard (200..<300).contains(http.statusCode) else {
			throw CompanionClientError.httpStatus(http.statusCode)
		}

		do {
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			throw CompanionClientError.decoding(error.localizedDescription)
		}
	}

	private static func _defaultDataLoader(
		_ request: URLRequest,
		pairingFingerprint: String?
	) async throws -> (Data, URLResponse) {
		guard let url = request.url else { throw CompanionClientError.invalidAddress }
		let scheme = url.scheme?.lowercased()
		var pinned: CompanionCertificateTrust.Pin?
		var expectedFingerprint: String?

		if scheme == "https" {
			pinned = try CompanionCertificateTrust.load(for: url)
			expectedFingerprint = try CompanionCertificateTrust.expectedFingerprint(
				for: pinned,
				entered: pairingFingerprint
			)
		} else if scheme != "http" {
			throw CompanionClientError.invalidAddress
		}

		let delegate = CompanionURLSessionDelegate(
			origin: url,
			pinned: pinned,
			expectedFingerprint: expectedFingerprint
		)
		let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
		defer { session.invalidateAndCancel() }
		do {
			let response = try await session.data(for: request)
			if let failure = delegate.recordedFailure { throw failure }
			return response
		} catch {
			if let failure = delegate.recordedFailure { throw failure }
			throw error
		}
	}
}
