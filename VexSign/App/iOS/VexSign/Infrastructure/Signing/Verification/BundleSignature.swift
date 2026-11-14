//
//  BundleSignature.swift
//  VexSign
//
//  Which certificate signed a stored bundle, read from the bundle itself.
//
//  A signed Mach-O ends in a code-signature superblob; inside it, slot `CSSLOT_SIGNATURESLOT`
//  holds a CMS (PKCS#7) SignedData whose `certificates` set carries the signer's certificate.
//  Reading it answers three questions the library could not answer before:
//
//    * is this app signed at all, or ad-hoc signed with no certificate (`noCertificates`);
//    * which identity did the user actually keep (`SigningIdentity`, from the DER);
//    * when does that identity expire, as opposed to whatever the `CertificatePair` row says.
//
//  Nothing here verifies the signature itself — `SignatureVerifier` covers structural
//  verification, and installd is the only real judge. This only reports who signed what.
//

import Foundation
import NimbleExtensions

// MARK: - Bundle signature

enum BundleSignature {
	enum State: Equatable, Sendable {
		/// No `LC_CODE_SIGNATURE` load command: the executable was never signed.
		case noCodeSignature
		/// Signed, but the signature carries no certificate — ad-hoc signing.
		case noCertificates
		case certificates([SigningIdentity])
		/// The signature exists but could not be read. Never treated as "unsigned".
		case unreadable(String)

		/// Certificates in CMS order, which puts the signer first for every signer VexSign can
		/// invoke (zsign, ldid).
		var identities: [SigningIdentity] {
			if case .certificates(let identities) = self { return identities }
			return []
		}

		/// The certificate that most likely signed the bundle, when there is one.
		var signer: SigningIdentity? {
			identities.first
		}

		/// The soonest expiry in the chain: the leaf, in practice, and the one that matters.
		var expiresAt: Date? {
			identities.compactMap(\.notAfter).min()
		}

		var hasCertificate: Bool {
			!identities.isEmpty
		}
	}

	/// `CSSLOT_SIGNATURESLOT` — where the CMS blob lives in the superblob.
	static let signatureSlot: UInt32 = 0x10000
	private static let superblobMagic: UInt32 = 0xfade0cc0
	private static let blobWrapperMagic: UInt32 = 0xfade0b01

	// MARK: Read

	static func read(bundleAt url: URL) -> State {
		guard let executable = Bundle(url: url)?.executableURL else {
			return .unreadable(.localized("The bundle has no executable."))
		}
		return read(executableAt: executable)
	}

	static func read(executableAt url: URL) -> State {
		guard let offset = MachOEntitlements.codeSignatureOffset(forExecutableAt: url) else {
			return .noCodeSignature
		}

		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
			return .unreadable(.localized("The executable could not be read."))
		}

		// The superblob declares its own length; copy that and nothing else, so a 300 MB
		// executable does not become a 300 MB array.
		let base = data.startIndex
		guard
			let length = bigEndianU32(data, at: base + offset + 4),
			length >= 12,
			offset + Int(length) <= data.count
		else {
			return .unreadable(.localized("The code signature header is not readable."))
		}

		let superblob = [UInt8](data[(base + offset)..<(base + offset + Int(length))])
		guard let cms = certificateBlob(inSuperblob: superblob) else {
			return .noCertificates
		}

		guard let derCertificates = certificateDERs(inCMS: cms) else {
			return .unreadable(.localized("The signature carries no readable certificate set."))
		}

		let identities = derCertificates.compactMap { SigningIdentity($0) }
		return identities.isEmpty ? .noCertificates : .certificates(identities)
	}

	// MARK: Superblob

	/// The CMS bytes from `CSSLOT_SIGNATURESLOT`, or nil when the signature has no such slot
	/// (ad-hoc signing writes a CodeDirectory and nothing else).
	static func certificateBlob(inSuperblob bytes: [UInt8]) -> Data? {
		guard
			bytes.count >= 12,
			u32(bytes, at: 0) == superblobMagic,
			let count = u32(bytes, at: 8)
		else {
			return nil
		}

		// Every entry is eight bytes and must fit in what we were given.
		guard count > 0, count <= UInt32((bytes.count - 12) / 8) else { return nil }

		for index in 0..<Int(count) {
			let entry = 12 + index * 8
			guard let slot = u32(bytes, at: entry), let offset = u32(bytes, at: entry + 4) else {
				return nil
			}
			guard slot == signatureSlot else { continue }

			let start = Int(offset)
			guard
				start >= 0,
				start + 8 <= bytes.count,
				u32(bytes, at: start) == blobWrapperMagic,
				let length = u32(bytes, at: start + 4),
				length >= 8,
				start + Int(length) <= bytes.count
			else {
				return nil
			}

			return Data(bytes[(start + 8)..<(start + Int(length))])
		}

		return nil
	}

	// MARK: CMS

	/// The DER certificates in a CMS `SignedData`, in the order the signer wrote them.
	///
	/// Returns an empty array for a well-formed signature with no certificate set, and nil when
	/// the CMS itself does not parse — the two mean different things to the caller.
	static func certificateDERs(inCMS data: Data) -> [Data]? {
		let bytes = [UInt8](data)

		guard
			let contentInfo = DER.element(bytes, at: 0),
			contentInfo.tag == 0x30,
			let info = DER.children(bytes, in: contentInfo),
			info.count >= 2,
			info[0].tag == 0x06,               // contentType: id-signedData
			info[1].isContextConstructed,      // [0] EXPLICIT SignedData
			let signedDataElement = DER.onlyChild(bytes, in: info[1]),
			signedDataElement.tag == 0x30,
			let signedData = DER.children(bytes, in: signedDataElement)
		else {
			return nil
		}

		// certificates [0] IMPLICIT CertificateSet OPTIONAL — the only context tag that holds
		// certificates. [1] (crls) is ignored.
		guard let certificateSet = signedData.first(where: { $0.isContextConstructed }) else {
			return []
		}

		guard let certificates = DER.children(bytes, in: certificateSet) else { return nil }
		return certificates
			.filter { $0.tag == 0x30 }
			.map { Data(DER.raw($0, in: bytes)) }
	}

	// MARK: Bytes

	private static func u32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
		guard offset >= 0, offset + 4 <= bytes.count else { return nil }
		return bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
	}

	private static func bigEndianU32(_ data: Data, at index: Int) -> UInt32? {
		guard index >= data.startIndex, index + 4 <= data.endIndex else { return nil }
		var value: UInt32 = 0
		for byte in data[index..<(index + 4)] {
			value = value << 8 | UInt32(byte)
		}
		return value
	}
}
