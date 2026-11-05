//
//  LocalTLSIdentity.swift
//  VexSign
//
//  The identity the local install server serves HTTPS with.
//
//  Current identities are generated locally by DeviceTLSIdentity and cached in
//  protected Application Support for NIOSSL. No bundle/download fallback is used.
//  Digest/PEM helpers remain useful for diagnostics and certificate parsing tests.
//

import CryptoKit
import Foundation
import NimbleExtensions
import Security

enum LocalTLSIdentity {
	// MARK: - Model

	/// Where the identity on disk came from.
	enum Source: String {
		/// The device-specific identity cached from the Keychain.
		case installed
		/// The app bundle: whatever the build produced.
		case bundled

		var title: String {
			switch self {
			case .installed:
				.localized("Device-local identity")
			case .bundled:
				.localized("Bundled identity")
			}
		}
	}

	/// What kind of identity the build shipped. Only the bundled case has a marker.
	enum Mode: String {
		case development
		case release
		case unknown

		var title: String {
			switch self {
			case .development:
				.localized("Development (self-signed)")
			case .release:
				.localized("Release")
			case .unknown:
				.localized("Unknown")
			}
		}
	}

	/// What the build wrote next to the identity files (`deps/tls-identity.txt`).
	struct Marker: Equatable {
		var mode: Mode
		var commonName: String?
		var digest: String?
	}

	/// A readable description of the identity in use.
	struct Summary {
		var source: Source
		var mode: Mode
		var commonName: String
		/// `nil` when the leaf's validity could not be read.
		var expiresAt: Date?
		/// SHA-256 of the leaf certificate, so two devices can compare identities.
		var fingerprint: String
		/// SHA-256 over the three identity files (the value `make deps-release` pins).
		var digest: String

		var expiryDescription: String {
			guard let expiresAt else { return .localized("validity unknown") }
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .none
			return .localized("expires %@", arguments: formatter.string(from: expiresAt))
		}

		/// One line for a settings footer: source, mode, hostname, expiry.
		///
		/// The mode only exists for the bundled identity (it comes from the marker the
		/// build wrote); saying "Unknown" about a downloaded one would be noise.
		var detail: String {
			if source == .installed {
				return .localized(
					"%@ · %@ · %@",
					arguments: source.title,
					commonName,
					expiryDescription
				)
			}

			return .localized(
				"%@ · %@ · %@ · %@",
				arguments: source.title,
				mode.title,
				commonName,
				expiryDescription
			)
		}
	}

	// MARK: - Failures

	enum Failure: LocalizedError {
		case missingFiles
		case noCertificates
		case keyMissing
		case hostnameInvalid(String)
		case leafExpired

		var errorDescription: String? {
			switch self {
			case .missingFiles:
				.localized("The certificate or key file is missing.")
			case .noCertificates:
				.localized("The certificate could not be read. Nothing was replaced.")
			case .keyMissing:
				.localized("The private key is missing or empty. Nothing was replaced.")
			case .hostnameInvalid(let name):
				.localized("“%@” is not a usable hostname for the local server. Nothing was replaced.", arguments: name)
			case .leafExpired:
				.localized("The certificate has already expired. Nothing was replaced.")
			}
		}
	}

	// MARK: - Digest

	/// SHA-256 over the three identity files, trimmed and joined with newlines.
	///
	/// This is the rule `tools/tls-pack-digest.py` checks for offline fixtures and
	/// the one `VexSignTests/LocalTLSIdentityTests.swift` holds both implementations to.
	static func packDigest(pem: String, cert: String, commonName: String) -> String {
		let joined = [pem, cert, commonName]
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.joined(separator: "\n")
		let digest = SHA256.hash(data: Data(joined.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}

	// MARK: - Marker

	/// Parses `deps/tls-identity.txt`. Unknown keys are ignored; a missing `mode` is a
	/// marker that says nothing, so it is rejected rather than guessed at.
	static func parseMarker(_ text: String) -> Marker? {
		var mode: Mode?
		var commonName: String?
		var digest: String?

		for line in text.split(whereSeparator: \.isNewline) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
				continue
			}

			let key = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
			let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
			guard !value.isEmpty else { continue }

			switch key {
			case "mode":
				// A value we do not know still says which mode was *not* used: the
				// build wrote a marker, so report Unknown instead of throwing the
				// whole file away. A marker with no `mode=` line stays unreadable.
				mode = Mode(rawValue: value) ?? .unknown
			case "cn":
				commonName = value
			case "digest":
				// Both `sha256:<hex>` and `<hex>` are written by different tools.
				digest = value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : value
			default:
				continue
			}
		}

		guard let mode else { return nil }
		return Marker(mode: mode, commonName: commonName, digest: digest)
	}

	// MARK: - Certificates

	/// DER for every certificate in a PEM bundle, in file order.
	static func certificateDERs(fromPEM pem: String) -> [Data] {
		let begin = "-----BEGIN CERTIFICATE-----"
		let end = "-----END CERTIFICATE-----"

		var certificates: [Data] = []
		var scanner = pem

		while let beginRange = scanner.range(of: begin),
			  let endRange = scanner.range(of: end, range: beginRange.upperBound..<scanner.endIndex) {
			let base64 = scanner[beginRange.upperBound..<endRange.lowerBound]
				.components(separatedBy: .whitespacesAndNewlines)
				.joined()
			if let der = Data(base64Encoded: base64) {
				certificates.append(der)
			}
			scanner = String(scanner[endRange.upperBound...])
		}

		return certificates
	}

	/// The `notAfter` of the first certificate, when it can be read.
	///
	/// Reuses the DER walk `CertificateInspector` already does — `SecCertificateCopyValues`
	/// is not available on iOS.
	static func leafExpiry(fromPEM pem: String) -> Date? {
		guard let der = certificateDERs(fromPEM: pem).first,
			  let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
			return nil
		}

		return CertificateInspector.notAfter(certificate)
	}

	/// SHA-256 of the leaf certificate.
	static func leafFingerprint(fromPEM pem: String) -> String {
		guard let der = certificateDERs(fromPEM: pem).first else { return "" }
		return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
	}

	// MARK: - Validation

	/// Checks that fetched material could work before it replaces anything on disk.
	///
	/// Deliberately not a digest check: the project's certificate rotates, and a digest
	/// pinned into an old build would reject every legitimate refresh. The digest is a
	/// *build* control (`make deps-release`); at runtime the questions are different —
	/// can the chain be read, does the key exist, is the hostname usable, is it current.
	@discardableResult
	static func validate(pem: String, cert: String, commonName: String) throws -> Date? {
		guard !cert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			  !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw Failure.missingFiles
		}

		guard ServerInstaller.normalizedHostname(commonName) != nil else {
			throw Failure.hostnameInvalid(commonName)
		}

		guard pem.contains("-----BEGIN") && pem.contains("PRIVATE KEY-----") else {
			throw Failure.keyMissing
		}

		let certificates = certificateDERs(fromPEM: cert)
		guard !certificates.isEmpty,
			  certificates.allSatisfy({ SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else {
			throw Failure.noCertificates
		}

		let expiry = leafExpiry(fromPEM: cert)
		if let expiry, expiry < Date() {
			throw Failure.leafExpired
		}

		return expiry
	}

    /// Uses the SYSTEM trust store, including a user-installed and fully trusted
    /// CA profile. Never adds our own CA as a trust anchor to bypass user consent.
    static func isSystemTrusted() -> Bool {
        guard let url = ServerInstaller.getUrl("server", ext: "crt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try? ok: inaccessible identity is not trusted.
        let certificates = certificateDERs(fromPEM: text).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray,
                SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

	// MARK: - Current identity

	/// The identity the server would load right now, or nil when there is none.
	static func current() -> Summary? {
		guard let certURL = ServerInstaller.getUrl("server", ext: "crt"),
			  let keyURL = ServerInstaller.getUrl("server", ext: "pem"),
			  let cert = try? String(contentsOf: certURL, encoding: .utf8),
			  let pem = try? String(contentsOf: keyURL, encoding: .utf8),
			  let commonName = ServerInstaller.readCommonName() else {
			return nil
		}

		let source: Source = .installed
		let marker = source == .bundled ? bundledMarker() : nil

		return Summary(
			source: source,
			mode: marker?.mode ?? .unknown,
			commonName: commonName,
			expiresAt: leafExpiry(fromPEM: cert),
			fingerprint: leafFingerprint(fromPEM: cert),
			digest: packDigest(pem: pem, cert: cert, commonName: commonName)
		)
	}

	/// The marker the build shipped, if any.
	static func bundledMarker() -> Marker? {
		guard let url = Bundle.main.url(forResource: "tls-identity", withExtension: "txt"),
			  let text = try? String(contentsOf: url, encoding: .utf8) else {
			return nil
		}
		return parseMarker(text)
	}
}
