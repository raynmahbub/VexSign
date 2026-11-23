import Foundation
import NimbleExtensions

// What the signing sheet says when the run is refused before any work starts.
//
// `SigningIdentityPolicy.Rejection` is a Domain value and the Domain layer imports Foundation
// only, so the copy lives out here rather than inside it — the same split as
// `AppleAccountSessionErrorMessages`. Without it, `SigningPipeline` returned the rejection and
// the sheet showed `error.localizedDescription`: "The operation couldn't be completed.
// (VexSign.Rejection error 1.)" for a revoked certificate. The log line was explicit; the
// error the user actually read was not.
extension SigningIdentityPolicy.Rejection: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingCertificate:
            return .localized("Choose a signing certificate. Nothing was signed.")
        case .certificateExpired(let expiresAt):
            return .localized(
                "The selected certificate expired on %@. Import a current certificate and sign again.",
                arguments: expiresAt.formatted(date: .abbreviated, time: .omitted)
            )
        case .certificateRevoked:
            return .localized("The selected certificate has been revoked. Import a valid certificate and sign again.")
        }
    }
}
