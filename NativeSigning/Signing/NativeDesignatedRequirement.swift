import Foundation
import CryptoKit

/// The only requirement dialect accepted by the native first slice:
/// designated => identifier <exact bundle> AND certificate leaf = <exact SHA1>.
/// SHA1 is Apple's legacy requirement encoding, NOT our trust/signature primitive.
/// Exact expected DER + RSA/SHA256 CMS and fresh Apple purpose/status checks are
/// independently mandatory. This policy alone never grants signer/install trust.
struct NativeDesignatedRequirement {
    static func encode(bundleIdentifier: String, certificateDER: Data) throws -> Data {
        try Task.checkCancellation()
        guard NativeAccountProvisioningRequest.isBundleIdentifier(bundleIdentifier),
              !certificateDER.isEmpty, certificateDER.count <= 64 * 1024 else { throw NativeSignedOutputError.unsupportedClaims }
        func word(_ value: Int) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) })
        }
        func operand(_ data: Data) -> Data {
            word(data.count) + data + Data(repeating: 0, count: (4 - data.count % 4) % 4)
        }
        // Apple Requirement::exprForm=1, opAnd=6, opIdent=2,
        // opAnchorHash=4, leafCert=0, baseAlignment=4.
        let expression = word(6) + word(2) + operand(Data(bundleIdentifier.utf8))
            + word(4) + word(0) + operand(Data(Insecure.SHA1.hash(data: certificateDER)))
        let requirement = word(0xfade0c00) + word(12 + expression.count) + word(1) + expression
        // Requirements SuperBlob: exactly designated type=3 at offset=20.
        return word(0xfade0c01) + word(20 + requirement.count) + word(1) + word(3) + word(20) + requirement
    }

    static func verify(_ blob: Data, bundleIdentifier: String, certificateDER: Data) throws {
        // Exact canonical equality is deliberate: no alternate identities, OR,
        // unknown/skippable opcodes, other certificate positions, requirements,
        // offsets, padding or unexamined expression data can grant authority.
        guard blob.count <= 1024,
              try blob == encode(bundleIdentifier: bundleIdentifier, certificateDER: certificateDER) else {
            throw NativeSignedOutputError.unsupportedClaims
        }
    }
}
