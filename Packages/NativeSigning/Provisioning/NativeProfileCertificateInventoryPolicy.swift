import Foundation
import SideSign

/// Strict material transfer only. Exact owned-key/certificate binding is checked
/// separately by NativeProfileResourcePolicy and the durable identity projection.
/// This does NOT validate a certificate chain, purpose, revocation or DER syntax.
struct NativeProfileCertificateInventoryPolicy {
    static func observations(_ rows: [VexSignDevelopmentCertificate]) throws -> [NativeProfileCertificateObservation] {
        guard rows.count <= 1000,
              rows.allSatisfy({ NativeRegistrationRecord.validIdentifier($0.certificateId)
                  && !$0.certContent.isEmpty && $0.certContent.count <= 64 * 1024 }),
              rows.reduce(0, { $0 + $1.certContent.count }) <= 512 * 1024,
              Set(rows.map(\.certificateId)).count == rows.count,
              Set(rows.map(\.certContent)).count == rows.count else { throw NativeProfileCreationError.inventoryRejected }
        return rows.map { NativeProfileCertificateObservation(identifier: $0.certificateId, certificateDER: $0.certContent) }
    }
}
