//
//  SigningIdentity.swift
//  VexSign
//
//  The certificate behind a signature, read from its DER (see docs/AUDIT_2026-10-31.md).
//
//  The library knows which certificate the user *chose* — it is on the `Signed` entity. It has
//  never known which certificate a stored bundle actually *carries*, so it could not tell a
//  home-signed app from one signed elsewhere, could not show that app's real expiry, and could
//  not warn before re-signing with a different identity (which makes iOS refuse the in-place
//  update and takes the app's keychain data with it).
//
//  This reads the certificate out of its DER encoding: SHA-256 fingerprint (the comparison key),
//  subject common name (what the warning calls it), serial and validity window (what the pill
//  counts down). No Security framework, no `SecCertificateCopyValues`, no locale-dependent
//  formatting — the same bytes give the same answer everywhere, which is also what makes it
//  testable without a device.
//

import CryptoKit
import Foundation
import NimbleExtensions

// MARK: - Identity

/// One X.509 certificate, as far as VexSign needs to describe it.
struct SigningIdentity: Identifiable, Equatable, Sendable {
	/// Lowercase hex SHA-256 of the DER encoding. The only thing identities are compared by.
	let fingerprint: String
	/// Subject common name, when the certificate has one.
	let commonName: String?
	/// Uppercase hex, the way Apple prints a serial number.
	let serial: String?
	let notBefore: Date?
	let notAfter: Date?

	var id: String { fingerprint }

	init?(_ der: Data) {
		guard let parsed = X509.parse([UInt8](der)) else { return nil }

		self.fingerprint = Self.fingerprint(of: der)
		self.commonName = parsed.commonName
		self.serial = parsed.serial
		self.notBefore = parsed.notBefore
		self.notAfter = parsed.notAfter
	}

	/// For tests and for callers that already hold a fingerprint.
	init(
		fingerprint: String,
		commonName: String? = nil,
		serial: String? = nil,
		notBefore: Date? = nil,
		notAfter: Date? = nil
	) {
		self.fingerprint = fingerprint
		self.commonName = commonName
		self.serial = serial
		self.notBefore = notBefore
		self.notAfter = notAfter
	}

	/// Lowercase hex SHA-256. Accepts a certificate that does not parse: identity is the bytes,
	/// not the fields.
	static func fingerprint(of der: Data) -> String {
		SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
	}

	/// What to call this certificate in a sentence.
	var displayName: String {
		commonName ?? serial.map { .localized("certificate %@", arguments: $0) } ?? .localized("an unnamed certificate")
	}

	/// First eight hex digits — enough to tell two fingerprints apart in a row of text.
	var shortFingerprint: String {
		String(fingerprint.prefix(8)).uppercased()
	}

	/// A certificate with no readable expiry is *not* expired: it is unknown, and the UI must not
	/// say "expired" about a date it could not read.
	func isExpired(at date: Date = Date()) -> Bool {
		guard let notAfter else { return false }
		return notAfter <= date
	}

	/// Whole days left, negative once expired. Nil when the certificate has no readable expiry.
	func daysRemaining(from date: Date = Date()) -> Int? {
		notAfter.map { Int(($0.timeIntervalSince(date) / 86_400).rounded(.down)) }
	}
}

// MARK: - X.509

/// The three fields VexSign needs, and nothing else.
///
/// Deliberately positional rather than schema-driven: `TBSCertificate` fixes the order of its
/// first six fields (version, serial, signature, issuer, validity, subject) for every version of
/// X.509, and reading them in order is both shorter and easier to audit than a name-based walk.
private enum X509 {
	struct Parsed {
		let serial: String?
		let notBefore: Date
		let notAfter: Date
		let commonName: String?
	}

	/// Object identifier 2.5.4.3 (commonName), as its DER content octets.
	private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]

	static func parse(_ bytes: [UInt8]) -> Parsed? {
		guard
			let certificate = DER.element(bytes, at: 0),
			certificate.tag == 0x30, // SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
			let parts = DER.children(bytes, in: certificate),
			let tbsElement = parts.first,
			tbsElement.tag == 0x30,
			let fields = DER.children(bytes, in: tbsElement),
			!fields.isEmpty
		else {
			return nil
		}

		var index = 0
		if fields[0].tag == 0xa0 {
			// version [0] EXPLICIT Version — absent for v1, which predates code signing.
			index = 1
		}

		// serialNumber INTEGER, signature AlgorithmIdentifier, issuer Name.
		guard index + 3 < fields.count else { return nil }
		let serialElement = fields[index]
		guard serialElement.tag == 0x02 else { return nil }
		index += 3

		let validityElement = fields[index]
		guard
			validityElement.tag == 0x30,
			let validity = DER.children(bytes, in: validityElement),
			validity.count == 2,
			let notBefore = date(validity[0], in: bytes),
			let notAfter = date(validity[1], in: bytes)
		else {
			return nil
		}
		index += 1

		guard index < fields.count else { return nil }
		let subject = fields[index]

		return Parsed(
			serial: serial(serialElement, in: bytes),
			notBefore: notBefore,
			notAfter: notAfter,
			commonName: commonName(in: subject, bytes: bytes)
		)
	}

	// MARK: Serial

	private static func serial(_ element: DER.Element, in bytes: [UInt8]) -> String? {
		var value = DER.content(of: element, in: bytes)
		guard !value.isEmpty else { return nil }

		// A leading 0x00 is the sign byte DER adds when the number's high bit is set; Apple
		// prints the number, not the padding.
		if value.count > 1, value[0] == 0x00, value[1] & 0x80 != 0 {
			value.removeFirst()
		}

		return value.map { String(format: "%02X", $0) }.joined()
	}

	// MARK: Validity

	private static func date(_ element: DER.Element, in bytes: [UInt8]) -> Date? {
		let generalized: Bool
		switch element.tag {
		case 0x17: generalized = false // UTCTime
		case 0x18: generalized = true // GeneralizedTime
		default: return nil
		}

		let content = DER.content(of: element, in: bytes)
		return time(content, generalized: generalized)
	}

	/// `YYMMDDHHMMSSZ` or `YYYYMMDDHHMMSSZ`, UTC, seconds optional. Both forms end in Z; neither
	/// carries a fraction or an offset, which is exactly why this does not use `DateFormatter`.
	private static func time(_ content: [UInt8], generalized: Bool) -> Date? {
		guard let last = content.last, last == UInt8(ascii: "Z") else { return nil }
		let digits = Array(content.dropLast())

		let yearDigits = generalized ? 4 : 2
		// YYMMDDHHMM (ten digits) is the minimum both forms allow; seconds add two more.
		guard digits.count == yearDigits + 8 || digits.count == yearDigits + 10 else { return nil }

		func number(from start: Int, length: Int) -> Int? {
			var value = 0
			for index in start..<(start + length) {
				let byte = digits[index]
				guard byte >= 48, byte <= 57 else { return nil }
				value = value * 10 + Int(byte - 48)
			}
			return value
		}

		guard
			let rawYear = number(from: 0, length: yearDigits),
			let month = number(from: yearDigits, length: 2),
			let day = number(from: yearDigits + 2, length: 2),
			let hour = number(from: yearDigits + 4, length: 2),
			let minute = number(from: yearDigits + 6, length: 2)
		else {
			return nil
		}

		let second = digits.count == yearDigits + 10 ? number(from: yearDigits + 8, length: 2) : 0
		guard let second else { return nil }

		// UTCTime is ambiguous by design: RFC 5280 says 50–99 is 19xx and 00–49 is 20xx.
		let year = generalized ? rawYear : (rawYear < 50 ? 2000 + rawYear : 1900 + rawYear)

		var components = DateComponents()
		components.year = year
		components.month = month
		components.day = day
		components.hour = hour
		components.minute = minute
		components.second = second

		return utc.date(from: components)
	}

	private static let utc: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
		return calendar
	}()

	// MARK: Subject

	/// Walks `Name ::= RDNSequence` for the common name and stops at the first one. A certificate
	/// with no CN, or with an encoding this does not know, simply has no common name.
	private static func commonName(in subject: DER.Element, bytes: [UInt8]) -> String? {
		guard let sets = DER.children(bytes, in: subject) else { return nil }

		for set in sets {
			guard let pairs = DER.children(bytes, in: set) else { continue }
			for pair in pairs {
				guard let attribute = DER.children(bytes, in: pair), attribute.count == 2 else { continue }
				guard attribute[0].tag == 0x06 else { continue }
				guard DER.content(of: attribute[0], in: bytes) == commonNameOID else { continue }
				guard let name = string(attribute[1], in: bytes) else { continue }
				return name
			}
		}

		return nil
	}

	/// The string types a CN actually uses: UTF8String, PrintableString, IA5String, BMPString.
	private static func string(_ element: DER.Element, in bytes: [UInt8]) -> String? {
		let content = DER.content(of: element, in: bytes)
		guard !content.isEmpty else { return nil }

		switch element.tag {
		case 0x0c, 0x13, 0x16:
			return String(bytes: content, encoding: .utf8)
		case 0x1e:
			// UTF-16 big endian, no BOM.
			var scalars: [UInt16] = []
			var index = 0
			while index + 1 < content.count {
				scalars.append(UInt16(content[index]) << 8 | UInt16(content[index + 1]))
				index += 2
			}
			return String(decoding: scalars, as: UTF16.self)
		default:
			return nil
		}
	}
}
