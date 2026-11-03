import Foundation

/// Transient, single-use Apple mutation approval, separate from consent to an
/// anisette provider. The caller must obtain informed user approval before asking
/// the backend to mint this token. The type cannot independently prove that UI.
/// Not Codable; never restore, auto-renew or mint at app launch.
public struct NativeCertificateCreationApproval: Equatable, Sendable {
    let id: UUID
    let contextID: UUID
    let identityID: UUID
    let flow: UUID
    let epoch: UUID
    let expiresAt: Date
}
