// VexSign addition to pinned SideSign (AGPL-3.0); retain modified source.
import Foundation

/// Raw public certificate material, NOT trust/purpose/revocation evidence.
/// certificateId is required: certRequestId is never guessed to be its identity.
public struct VexSignDevelopmentCertificate: Decodable, Sendable {
    public let certificateId: String
    public let certContent: Data
}
public enum VexSignCertificateInventoryError: Error, Equatable, Sendable {
    case unexpectedResponse
}
private struct VexSignDevelopmentCertificateList: Decodable {
    let certificates: [VexSignDevelopmentCertificate]
    let hasMore: Bool?
    let nextPage: Int?
    let nextCursor: String?
    let totalCount: Int?
}

public extension DeveloperPortal {
    /// Fixed legacy plist action, no permissive services dispatcher, dialect
    /// fallback, compactMap/drop of malformed certificates or missing-array default.
    /// Unsupported Apple dialects fail closed, never masquerade as an empty list.
    func vexsignDevelopmentCertificates(team: Team, session apiSession: Session) async throws -> [VexSignDevelopmentCertificate] {
        let data = try await vexsignRegistrationRequest(action: "listAllDevelopmentCerts", parameters: [:],
            requestID: UUID(), team: team, apiSession: apiSession, limit: 1024 * 1024)
        let response: VexSignDevelopmentCertificateList
        if let plist = try? PropertyListDecoder().decode(VexSignDevelopmentCertificateList.self, from: data) {
            response = plist
        } else if let json = try? JSONDecoder().decode(VexSignDevelopmentCertificateList.self, from: data) {
            response = json
        } else { throw VexSignCertificateInventoryError.unexpectedResponse }
        try Task.checkCancellation()
        let rows = response.certificates
        guard rows.count <= 1000, response.hasMore != true, response.nextPage == nil,
              response.nextCursor.map({ $0.isEmpty }) ?? true,
              response.totalCount.map({ $0 == rows.count }) ?? true,
              rows.allSatisfy({ Self.vexsignCertificateID($0.certificateId) && !$0.certContent.isEmpty && $0.certContent.count <= 64 * 1024 }),
              rows.reduce(0, { $0 + $1.certContent.count }) <= 512 * 1024,
              Set(rows.map(\.certificateId)).count == rows.count,
              Set(rows.map(\.certContent)).count == rows.count else {
            throw VexSignCertificateInventoryError.unexpectedResponse
        }
        return rows
    }
}

private extension DeveloperPortal {
    static func vexsignCertificateID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
}
