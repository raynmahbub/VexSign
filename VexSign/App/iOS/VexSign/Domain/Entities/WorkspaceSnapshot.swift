import Foundation

/// Values crossing the persistence boundary. `id` is an opaque store identity, not a
/// UUID lookup: imported and signed artifacts may legitimately have the same UUID.
struct LibraryAppReference: Hashable, Sendable {
    let recordID: String?
    let uuid: String
    let isSigned: Bool

    init(app: AppInfoPresentable) throws {
        guard let uuid = app.uuid, !uuid.isEmpty else { throw WorkspaceAccessError.invalidReference }
        self.recordID = app.recordID
        self.uuid = uuid
        self.isSigned = app.isSigned
    }
}

protocol WorkspaceDatedRecord: Identifiable {
    var date: Date? { get }
    var workspaceName: String { get }
    var workspaceOrder: Int32 { get }
}

extension WorkspaceDatedRecord {
    var workspaceOrder: Int32 { 0 }
}

struct LibraryAppRecord: AppInfoPresentable, WorkspaceDatedRecord, Hashable, Sendable {
    let id: String
    let uuid: String?
    let isSigned: Bool
    let name: String?
    let version: String?
    let identifier: String?
    let originalIdentifier: String?
    let date: Date?
    let icon: String?
    let appDescription: String?
    let sortIndex: Int32
    let source: URL?
    let certificateID: String?
    let bundleURL: URL?
    let artifactURL: URL?

    var recordID: String? { id }
    var workspaceName: String { name ?? "" }
    var workspaceOrder: Int32 { sortIndex }
}

/// Public identity/profile metadata only. There is deliberately no password,
/// Keychain handle, private-key URL, or managed object in this contract.
struct CertificateRecord: WorkspaceDatedRecord, Hashable {
    let id: String
    let uuid: String?
    let nickname: String?
    let date: Date?
    let expiration: Date?
    let isDefault: Bool
    let ppQCheck: Bool
    let revoked: Bool
    let profile: Certificate?
    let additionalProfilePatterns: [String]

    var workspaceName: String { nickname ?? profile?.Name ?? "" }
    var profileType: ProvisionProfileType { profile?.profileType ?? .unknown }
    var isPPQLess: Bool { !ppQCheck && (profile?.isPPQLess ?? false) }
    var isPPQ: Bool { !isPPQLess }
    var supportsJIT: Bool { !isPPQLess }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.nickname == rhs.nickname && lhs.date == rhs.date &&
        lhs.expiration == rhs.expiration && lhs.isDefault == rhs.isDefault &&
        lhs.ppQCheck == rhs.ppQCheck && lhs.revoked == rhs.revoked &&
        lhs.profile?.UUID == rhs.profile?.UUID && lhs.additionalProfilePatterns == rhs.additionalProfilePatterns
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RepositoryRecord: WorkspaceDatedRecord, Hashable, Sendable {
    let id: String
    let name: String?
    let identifier: String?
    let sourceURL: URL?
    let iconURL: URL?
    let date: Date?

    var workspaceName: String { name ?? "" }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct WorkspaceSnapshot {
    var signedApps: [LibraryAppRecord] = []
    var importedApps: [LibraryAppRecord] = []
    var certificates: [CertificateRecord] = []
    var repositories: [RepositoryRecord] = []

    var apps: [LibraryAppRecord] { signedApps + importedApps }
    static var empty: Self { Self() }
}

enum WorkspaceAccessError: Error, Equatable {
    case invalidReference
    case missingRecord
    case mismatchedRecord
    case persistenceFailed
    case invalidOrder
}
