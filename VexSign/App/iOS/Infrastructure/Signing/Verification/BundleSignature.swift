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
//  This display reader reports the CMS's claimed signer, selected by SignerInfo,
//  not by certificate SET order. Fresh output receives independent cryptographic
//  verification in SignatureVerifier before it can enter the signed library.
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

        /// The SignerInfo-matched leaf first, then the remaining embedded chain.
        /// This is display metadata, not independent signature/trust evidence.
		var identities: [SigningIdentity] {
			if case .certificates(let identities) = self { return identities }
			return []
		}

		/// The certificate that most likely signed the bundle, when there is one.
		var signer: SigningIdentity? {
			identities.first
		}

        /// The claimed leaf's expiry; an unrelated embedded certificate cannot
        /// shorten or extend the signing identity's displayed validity.
        var expiresAt: Date? { signer?.notAfter }

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
		guard let executable = SigningInputValidation.executable(in: url) else {
			return .unreadable(.localized("The bundle has no executable."))
		}
		return read(executableAt: executable)
	}

	static func read(executableAt url: URL) -> State {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let images = try MachOEntitlements.images(in: data)
            guard let evidence = ExecutablePreflight.inspectImages(data) else { return .unreadable("Malformed executable") }
            let index = evidence.firstIndex(where: { $0.evidence.isArm64 }) ?? 0
            let image = images[index]
            guard image.signatureRange != nil else { return .noCodeSignature }
            guard let blob = image.blobs[signatureSlot] else { return .noCertificates }
            guard MachOReader.u32(blob, at: 0, bigEndian: true) == blobWrapperMagic,
                  let certificates = certificateDERs(inCMS: Data(blob.dropFirst(8))) else {
                return .unreadable(.localized("The signature carries no readable certificate set."))
            }
            let identities = certificates.compactMap { SigningIdentity($0) }
            return identities.isEmpty ? .noCertificates : .certificates(identities)
        } catch { return .unreadable(error.localizedDescription) }
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

    /// The unique SignerInfo-matched leaf, followed by the other embedded DER
    /// certificates. An incomplete/missing signer is unreadable, not an ad-hoc
    /// signature and never a certificate guessed from SET ordering.
	static func certificateDERs(inCMS data: Data) -> [Data]? {
        guard !data.isEmpty, data.count <= 1024 * 1024 else { return nil }
		let bytes = [UInt8](data)

		guard
			let contentInfo = DER.element(bytes, at: 0),
            contentInfo.tag == 0x30, contentInfo.end == bytes.count,
			let info = DER.children(bytes, in: contentInfo),
            info.count == 2,
            info[0].tag == 0x06, DER.content(of: info[0], in: bytes) == [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02],
            info[1].tag == 0xa0, // [0] EXPLICIT SignedData
			let signedDataElement = DER.onlyChild(bytes, in: info[1]),
			signedDataElement.tag == 0x30,
			let signedData = DER.children(bytes, in: signedDataElement)
		else {
			return nil
		}

        guard let certificateSet = signedData.first(where: { $0.tag == 0xa0 }),
              let certificates = DER.children(bytes, in: certificateSet), certificates.count <= 16,
              let signerSet = signedData.last, signerSet.tag == 0x31,
              let signers = DER.children(bytes, in: signerSet), signers.count == 1,
              let fields = DER.children(bytes, in: signers[0]), fields.count >= 3, fields[1].tag == 0x30,
              let issuerAndSerial = DER.children(bytes, in: fields[1]), issuerAndSerial.count == 2,
              issuerAndSerial[0].tag == 0x30, issuerAndSerial[1].tag == 0x02 else { return nil }
        let issuer = DER.raw(issuerAndSerial[0], in: bytes), serial = DER.raw(issuerAndSerial[1], in: bytes)
        let matches = certificates.filter { certificate in
            guard certificate.tag == 0x30, let parts = DER.children(bytes, in: certificate), parts.count == 3,
                  let tbs = DER.children(bytes, in: parts[0]) else { return false }
            let start = tbs.first?.tag == 0xa0 ? 1 : 0
            guard tbs.count >= start + 3 else { return false }
            return DER.raw(tbs[start], in: bytes) == serial && DER.raw(tbs[start + 2], in: bytes) == issuer
        }
        guard matches.count == 1, let leaf = matches.first else { return nil }
        return ([leaf] + certificates.filter { $0 != leaf && $0.tag == 0x30 }).map { Data(DER.raw($0, in: bytes)) }
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
