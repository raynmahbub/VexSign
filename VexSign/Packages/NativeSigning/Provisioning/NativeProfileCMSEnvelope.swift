import Foundation
import CryptoKit

/// Parsed signature inputs only; this type is NOT authenticated profile output.
struct NativeProfileCMSEnvelope {
    let payload: Data
    let certificates: [Data]
    let signerIssuer: Data
    let signerSerial: Data
    let signedAttributes: Data
    let signature: Data

    private static let dataOID = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,7,1])
    private static let signedDataOID = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,7,2])
    private static let sha256OID = Data([0x60,0x86,0x48,1,0x65,3,4,2,1])
    private static let rsaOID = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1])
    private static let sha256RSAOID = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,0x0b])
    private static let contentTypeOID = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,3])
    private static let digestOID = Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,4])

    static func parse(_ cms: Data) throws -> Self { try parse(cms, detachedContent: nil) }

    /// Separate role: NEVER used by profile verification. Detached CMS must omit
    /// eContent entirely and bind the supplied CodeDirectory through signed digest.
    static func parseDetachedCodeSignature(_ cms: Data, codeDirectory: Data) throws -> Self {
        guard (88...1024 * 1024).contains(codeDirectory.count) else { throw NativeProfileValidationError.cmsRejected }
        return try parse(cms, detachedContent: codeDirectory)
    }

    private static func parse(_ cms: Data, detachedContent: Data?) throws -> Self {
        guard !cms.isEmpty, cms.count <= 1024 * 1024 else { throw NativeProfileValidationError.cmsRejected }
        let outer = try NativeProfileDER.one(cms, tag: 0x30).children(tag: 0x30, limit: 2)
        guard outer.count == 2, isOID(outer[0], signedDataOID) else { throw NativeProfileValidationError.cmsRejected }
        let explicit = try outer[1].children(tag: 0xa0, limit: 1)
        guard explicit.count == 1 else { throw NativeProfileValidationError.cmsRejected }
        let body = try explicit[0].children(tag: 0x30, limit: 5)
        // Exactly v1, digestAlgorithms, encapsulated data, cert set, signerInfos.
        // CRLs/other optional structures and alternate CMS versions are rejected.
        guard body.count == 5, body[0].tag == 2, body[0].content == Data([1]) else { throw NativeProfileValidationError.cmsRejected }
        let digests = try body[1].children(tag: 0x31, limit: 1)
        guard digests.count == 1 else { throw NativeProfileValidationError.cmsRejected }
        try algorithm(digests[0], allowed: [sha256OID])
        let encapsulated = try body[2].children(tag: 0x30, limit: 2)
        guard !encapsulated.isEmpty, isOID(encapsulated[0], dataOID) else { throw NativeProfileValidationError.cmsRejected }
        let payload: Data
        if let detachedContent {
            guard encapsulated.count == 1 else { throw NativeProfileValidationError.cmsRejected }
            payload = detachedContent
        } else {
            guard encapsulated.count == 2 else { throw NativeProfileValidationError.cmsRejected }
            let content = try encapsulated[1].children(tag: 0xa0, limit: 1)
            guard content.count == 1, content[0].tag == 4, !content[0].content.isEmpty,
                  content[0].content.count <= 512 * 1024 else { throw NativeProfileValidationError.cmsRejected }
            payload = content[0].content
        }
        let certificates = try body[3].children(tag: 0xa0, limit: 8)
        guard !certificates.isEmpty, certificates.allSatisfy({ $0.tag == 0x30 && $0.encoded.count <= 64 * 1024 }),
              Set(certificates.map(\.encoded)).count == certificates.count else { throw NativeProfileValidationError.cmsRejected }
        let signers = try body[4].children(tag: 0x31, limit: 1)
        guard signers.count == 1 else { throw NativeProfileValidationError.cmsRejected }
        let signer = try signers[0].children(tag: 0x30, limit: 6)
        guard signer.count == 6, signer[0].tag == 2, signer[0].content == Data([1]) else { throw NativeProfileValidationError.cmsRejected }
        let sid = try signer[1].children(tag: 0x30, limit: 2)
        guard sid.count == 2, sid[0].tag == 0x30 else { throw NativeProfileValidationError.cmsRejected }
        try NativeProfileDER.positiveInteger(sid[1])
        try algorithm(signer[2], allowed: [sha256OID])
        var attributeBudget = 512
        try NativeProfileDER.validateConstructed(signer[3], budget: &attributeBudget)
        let attrs = try signer[3].children(tag: 0xa0, limit: 16, sorted: true)
        var seen = Set<Data>(); var contentType = false; var digest = false
        for attr in attrs {
            let parts = try attr.children(tag: 0x30, limit: 2)
            guard parts.count == 2, parts[0].tag == 6, !parts[0].content.isEmpty,
                  seen.insert(parts[0].content).inserted else { throw NativeProfileValidationError.cmsRejected }
            let values = try parts[1].children(tag: 0x31, limit: 8, sorted: true)
            guard !values.isEmpty else { throw NativeProfileValidationError.cmsRejected }
            if parts[0].content == contentTypeOID {
                guard values.count == 1, isOID(values[0], dataOID) else { throw NativeProfileValidationError.cmsRejected }
                contentType = true
            } else if parts[0].content == digestOID {
                guard values.count == 1, values[0].tag == 4,
                      values[0].content == Data(SHA256.hash(data: payload)) else { throw NativeProfileValidationError.cmsRejected }
                digest = true
            }
            // Other signed attributes do not grant authority. In particular a
            // signingTime is never used to backdate trust/expiry verification.
        }
        guard contentType, digest else { throw NativeProfileValidationError.cmsRejected }
        try algorithm(signer[4], allowed: [rsaOID, sha256RSAOID])
        guard signer[5].tag == 4, (256...512).contains(signer[5].content.count) else { throw NativeProfileValidationError.cmsRejected }
        var signed = signer[3].encoded; signed[signed.startIndex] = 0x31
        return Self(payload: payload, certificates: certificates.map(\.encoded),
                    signerIssuer: sid[0].encoded, signerSerial: sid[1].encoded,
                    signedAttributes: signed, signature: signer[5].content)
    }
    private static func isOID(_ node: NativeProfileDER.Node, _ oid: Data) -> Bool { node.tag == 6 && node.content == oid }
    private static func algorithm(_ node: NativeProfileDER.Node, allowed: [Data]) throws {
        let fields = try node.children(tag: 0x30, limit: 2)
        guard (1...2).contains(fields.count), fields[0].tag == 6, allowed.contains(fields[0].content),
              fields.count == 1 || (fields[1].tag == 5 && fields[1].content.isEmpty) else { throw NativeProfileValidationError.cmsRejected }
    }
}
