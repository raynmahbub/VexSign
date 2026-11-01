//
//  ASN1.swift
//  VexSign
//
//  the two hundred lines of DER that OCSP needs, and nothing more.
//
//  `Utilities/Signing/DER.swift` already parses DER, but as offsets into a `[UInt8]` — the shape
//  that suits walking a large CMS blob without copying it. An OCSP message is the other case: built
//  by this app, small, and read as a tree. Rather than bend the certificate reader into a writer,
//  this is the message-shaped half: `ASN1.Element` owns its content and its children, and the same
//  enum encodes. Two readers is one more than ideal; two *shapes* for two genuinely different jobs
//  is better than one shape that fits neither.
//
//  VexSign removed a *remote* revocation checker in because it asked a third party "is this
//  revoked?" and believed the answer. What belongs in its place is evidence the device can check
//  itself: build the OCSP request, read the responder's signed answer, and show it. This file is the
//  encoding layer for that — hand-written because a DER library is a dependency, and the audit's
//  rule is that a security toggle may not pull one in.
//

import Foundation

enum ASN1 {
	/// One tag-length-value. `children` is parsed only for constructed tags (`tag & 0x20`).
	struct Element {
		let tag: UInt8
		let content: Data
		let children: [Element]

		var isConstructed: Bool { tag & 0x20 != 0 }

		/// The number of a context-specific tag (`0xA0` → 0, `0x81` → 1), else nil.
		var contextNumber: Int? {
			guard tag & 0xC0 == 0x80 else { return nil }
			return Int(tag & 0x1F)
		}

		func child(tag wanted: UInt8) -> Element? {
			children.first { $0.tag == wanted }
		}

		func child(context number: Int) -> Element? {
			children.first { $0.contextNumber == number }
		}
	}

	// MARK: - Parsing

	/// Nesting past this is refused. An OCSP response is a handful of levels deep; a document that
	/// is deeper than this is either broken or built to exhaust the stack, and the parser reads bytes
	/// that arrived over the network.
	static let maximumDepth = 24

	/// Parses exactly one element, which must consume the whole input.
	static func parse(_ data: Data) -> Element? {
		guard let (element, consumed) = parseElement(data, at: 0, limit: data.count, depth: 0), consumed == data.count else {
			return nil
		}
		return element
	}

	/// Parses a run of elements (the contents of a SEQUENCE).
	static func parseAll(_ data: Data, depth: Int = 0) -> [Element]? {
		guard depth <= maximumDepth else { return nil }

		var elements: [Element] = []
		var offset = 0
		while offset < data.count {
			guard let (element, consumed) = parseElement(data, at: offset, limit: data.count, depth: depth) else {
				return nil
			}
			elements.append(element)
			offset = consumed
		}
		return elements
	}

	private static func parseElement(_ data: Data, at offset: Int, limit: Int, depth: Int) -> (Element, Int)? {
		guard depth <= maximumDepth else { return nil }
		guard offset + 2 <= limit else { return nil }

		let tag = data[offset]
		var cursor = offset + 1

		let first = Int(data[cursor])
		cursor += 1

		let length: Int
		if first & 0x80 == 0 {
			length = first
		} else {
			let byteCount = first & 0x7F
			// 0 is "indefinite", which DER forbids; more than 3 length bytes is not a real OCSP response.
			guard byteCount > 0, byteCount <= 3, cursor + byteCount <= limit else { return nil }

			var value = 0
			for _ in 0..<byteCount {
				value = (value << 8) | Int(data[cursor])
				cursor += 1
			}
			length = value
		}

		guard length >= 0, cursor + length <= limit else { return nil }

		let content = data.subdata(in: cursor..<(cursor + length))
		let end = cursor + length

		let children = (tag & 0x20) != 0 ? (parseAll(content, depth: depth + 1) ?? []) : []
		return (Element(tag: tag, content: content, children: children), end)
	}

	// MARK: - Encoding

	static let tagInteger: UInt8 = 0x02
	static let tagBitString: UInt8 = 0x03
	static let tagOctetString: UInt8 = 0x04
	static let tagNull: UInt8 = 0x05
	static let tagOID: UInt8 = 0x06
	static let tagEnumerated: UInt8 = 0x0A
	static let tagSequence: UInt8 = 0x30
	static let tagGeneralizedTime: UInt8 = 0x18

	static func tlv(_ tag: UInt8, _ content: Data) -> Data {
		var out = Data([tag])
		out.append(lengthBytes(content.count))
		out.append(content)
		return out
	}

	static func lengthBytes(_ length: Int) -> Data {
		if length < 0x80 {
			return Data([UInt8(length)])
		}
		var value = length
		var bytes: [UInt8] = []
		while value > 0 {
			bytes.insert(UInt8(value & 0xFF), at: 0)
			value >>= 8
		}
		return Data([0x80 | UInt8(bytes.count)] + bytes)
	}

	static func sequence(_ parts: [Data]) -> Data {
		tlv(tagSequence, parts.reduce(into: Data()) { $0.append($1) })
	}

	static func octetString(_ data: Data) -> Data {
		tlv(tagOctetString, data)
	}

	static func null() -> Data {
		tlv(tagNull, Data())
	}

	/// A positive INTEGER from big-endian magnitude bytes, with the leading zero DER requires when
	/// the high bit is set.
	static func integer(magnitude: Data) -> Data {
		var bytes = Data(magnitude.drop(while: { $0 == 0 }))
		if bytes.isEmpty {
			bytes = Data([0])
		} else if bytes[0] & 0x80 != 0 {
			bytes.insert(0, at: 0)
		}
		return tlv(tagInteger, bytes)
	}

	static func integer(_ value: Int) -> Data {
		guard value > 0 else { return integer(magnitude: Data([0])) }
		var bytes: [UInt8] = []
		var remaining = value
		while remaining > 0 {
			bytes.insert(UInt8(remaining & 0xFF), at: 0)
			remaining >>= 8
		}
		return integer(magnitude: Data(bytes))
	}

	/// A pre-encoded OID body, e.g. SHA-1 = `2B 0E 03 02 1A` for `1.3.14.3.2.26`.
	static func oid(_ body: [UInt8]) -> Data {
		tlv(tagOID, Data(body))
	}

	static func explicit(_ number: Int, _ inner: Data) -> Data {
		tlv(0xA0 | UInt8(number), inner)
	}

	static func implicit(_ number: Int, _ content: Data = Data()) -> Data {
		tlv(0x80 | UInt8(number), content)
	}

	static func bitString(_ data: Data, unusedBits: UInt8 = 0) -> Data {
		var content = Data([unusedBits])
		content.append(data)
		return tlv(tagBitString, content)
	}

	// MARK: - Time

	private static let generalizedFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "yyyyMMddHHmmss'Z'"
		return formatter
	}()

	static func generalizedTime(_ date: Date) -> Data {
		tlv(tagGeneralizedTime, Data(generalizedFormatter.string(from: date).utf8))
	}

	static func parseGeneralizedTime(_ element: Element) -> Date? {
		guard element.tag == tagGeneralizedTime, let text = String(data: element.content, encoding: .utf8) else {
			return nil
		}
		// Some responders keep fractional seconds; the formatter above is the common case.
		let trimmed = text.contains(".")
			? String(text[text.startIndex..<(text.firstIndex(of: ".") ?? text.endIndex)]) + "Z"
			: text
		return generalizedFormatter.date(from: trimmed)
	}

	// MARK: - Common OIDs

	enum OID {
		/// 1.3.14.3.2.26 — SHA-1. OCSP CertID normally uses it; that is not a choice this app makes.
		static let sha1: [UInt8] = [0x2B, 0x0E, 0x03, 0x02, 0x1A]
		/// 1.3.6.1.5.5.7.48.1.1 — id-pkix-ocsp-basic.
		static let ocspBasic: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01, 0x01]
		/// 1.2.840.113549.1.1.11 — sha256WithRSAEncryption.
		static let sha256WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
		/// 1.2.840.113549.1.1.5 — sha1WithRSAEncryption.
		static let sha1WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05]
		/// 1.2.840.10045.4.3.2 — ecdsa-with-SHA256.
		static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
		/// 1.2.840.10045.4.3.3 — ecdsa-with-SHA384.
		static let ecdsaWithSHA384: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03]
	}
}
