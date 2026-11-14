import Foundation

/// Provider protocol identifiers, not an SDK's transport or authentication type.
enum AnisetteProtocolKind: String, CaseIterable, Codable, Sendable {
    case headers
    case v3
}

struct AnisetteConfiguration: Equatable, Sendable {
    let identifier: String
    let displayName: String
    let policyRevision: String
    let endpoint: URL?
    let protocolKind: AnisetteProtocolKind
}

@MainActor
protocol AnisetteConfigurationProviding: AnyObject {
    var currentConfiguration: AnisetteConfiguration? { get }
    func loadBundledCatalog() throws -> AnisetteServerCatalog
    func probe(_ configuration: AnisetteConfiguration) async throws
    func save(_ configuration: AnisetteConfiguration) throws
    func clear()
    func synchronize() async
}
