import Foundation

/// Opaque, transient approval for ONE exact device/App ID registration attempt.
/// Separate from anisette disclosure consent; not signing/profile authorization.
/// Caller must obtain informed user approval before minting it, never at launch.
public struct NativeAccountRegistrationApproval: Equatable, Sendable {
    let id: UUID
    let contextID: UUID
    let ownerDigest: String
    let subjectDigest: String
    let flow: UUID
    let epoch: UUID
    let expiresAt: Date
}
