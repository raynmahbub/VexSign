//
//  DER.swift
//  VexSign
//
//  Just enough ASN.1 DER to answer "which certificate signed this bundle".
//
//  A code signature's CMS blob is DER, and the only thing VexSign needs out of it is the set of
//  embedded certificates — plus, from each certificate, the subject's common name, the serial
//  and the validity window. That is a small, well-bounded subset: definite lengths, one tag byte,
//  and constructed elements that contain their children back to back.
//
//  Everything here reads bytes that came from a file a user imported, so every length is bounds
//  checked, indefinite lengths are refused, and nothing recurses without a limit. A parser that
//  crashes on a corrupt bundle would turn "cannot read the signature" into "cannot open the app".
//

import Foundation

// MARK: - DER

enum DER {
	/// One tag-length-value element, addressed by absolute byte offsets.
	struct Element: Equatable {
		/// The identifier octet. High-tag-number form is not used by anything we read.
		let tag: UInt8
		/// First byte of the element (its tag).
		let start: Int
		/// First byte of the content.
		let content: Int
		/// One past the last content byte.
		let end: Int

		var contentLength: Int { end - content }
		var isConstructed: Bool { tag & 0x20 != 0 }
		/// Context-specific, constructed: `[n]` in a schema.
		var isContextConstructed: Bool { (tag & 0xc0) == 0x80 && isConstructed }
	}

	/// Longest length field we accept. Nothing in a certificate needs more than four.
	static let maximumLengthOctets = 4

	static func element(_ bytes: [UInt8], at offset: Int, limit: Int? = nil) -> Element? {
		let upperBound = min(limit ?? bytes.count, bytes.count)

		// 0x00 is the end-of-contents marker (indefinite form) and 0xff is reserved padding;
		// neither belongs in a DER element.
		guard offset >= 0, offset + 2 <= upperBound else { return nil }
		let tag = bytes[offset]
		guard tag != 0x00, tag != 0xff else { return nil }

		let first = bytes[offset + 1]
		let length: Int
		let headerLength: Int

		if first < 0x80 {
			length = Int(first)
			headerLength = 2
		} else {
			let octets = Int(first & 0x7f)
			// 0x80 alone means indefinite length, which DER forbids.
			guard octets > 0, octets <= maximumLengthOctets, offset + 2 + octets <= upperBound else {
				return nil
			}

			var value = 0
			for index in 0..<octets {
				value = value << 8 | Int(bytes[offset + 2 + index])
			}

			// Minimal form: a value below 0x80 belongs in the short form, and a leading zero
			// octet is padding. Both mean the file is not DER as written.
			guard value >= 0x80, octets == 1 || bytes[offset + 2] != 0 else { return nil }
			length = value
			headerLength = 2 + octets
		}

		let content = offset + headerLength
		let end = content + length
		guard end >= content, end <= upperBound else { return nil }

		return Element(tag: tag, start: offset, content: content, end: end)
	}

	/// The element's children, for constructed elements. `nil` when the content does not parse
	/// as a clean sequence of complete elements.
	static func children(_ bytes: [UInt8], in element: Element) -> [Element]? {
		guard element.isConstructed else { return nil }

		var children: [Element] = []
		var offset = element.content
		while offset < element.end {
			guard let child = self.element(bytes, at: offset, limit: element.end) else { return nil }
			children.append(child)
			offset = child.end
		}

		return offset == element.end ? children : nil
	}

	/// The first child, for the `[0] EXPLICIT` wrappers that carry a single element.
	static func onlyChild(_ bytes: [UInt8], in element: Element) -> Element? {
		guard let children = children(bytes, in: element), children.count == 1 else { return nil }
		return children[0]
	}

	/// Content octets.
	static func content(of element: Element, in bytes: [UInt8]) -> [UInt8] {
		Array(bytes[element.content..<element.end])
	}

	/// The whole element, tag and length included — what a fingerprint is taken over.
	static func raw(_ element: Element, in bytes: [UInt8]) -> [UInt8] {
		Array(bytes[element.start..<element.end])
	}
}
