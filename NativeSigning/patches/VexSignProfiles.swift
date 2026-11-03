// VexSign addition to pinned SideSign (AGPL-3.0); retain modified source.
import Foundation

public enum VexSignProfileTransportError: Error, Equatable, Sendable {
    case invalidRequest, unexpectedResponse
}

/// Metadata is NOT proof of CMS authenticity, ownership or profile suitability.
public struct VexSignProfileListing: Decodable, Sendable {
    public let provisioningProfileId: String
    public let uuid: UUID
    public let appId: App
    public struct App: Decodable, Sendable {
        public let appIdId: String
        public let identifier: String
    }
    enum CodingKeys: String, CodingKey { case provisioningProfileId, uuid = "UUID", appId }
}
public struct VexSignDownloadedProfile: Decodable, Sendable {
    public let provisioningProfileId: String
    public let uuid: UUID
    public let encodedProfile: Data
    enum CodingKeys: String, CodingKey { case provisioningProfileId, uuid = "UUID", encodedProfile }
}
private struct VexSignProfileListResponse: Decodable {
    let provisioningProfiles: [VexSignProfileListing]
    let hasMore: Bool?
    let nextPage: Int?
    let nextCursor: String?
    let totalCount: Int?
}
private struct VexSignProfileDownloadResponse: Decodable { let provisioningProfile: VexSignDownloadedProfile }

public extension DeveloperPortal {
    /// Requires persisted uncertain intent and fresh bound resource validation.
    /// Exact one App ID, one certificate, one device; fixed limited development.
    /// No update/regeneration, distribution option, empty devices or cleanup API.
    func vexsignCreateLimitedProfileOnce(appID: String, certificateID: String, deviceID: String,
                                         operationID: UUID, team: Team, session apiSession: Session) async throws {
        guard [appID, certificateID, deviceID].allSatisfy(Self.vexsignProfileIdentifier) else {
            throw VexSignProfileTransportError.invalidRequest
        }
        let parameters: [String: any Sendable] = [
            "provisioningProfileName": "VexSign-" + operationID.uuidString,
            "appIdId": appID, "distributionType": "limited",
            "certificateIds": [certificateID], "deviceIds": [deviceID]
        ]
        _ = try await vexsignRegistrationRequest(action: "createProvisioningProfile", parameters: parameters,
            requestID: operationID, team: team, apiSession: apiSession, limit: 2 * 1024 * 1024)
        // Ignore direct profile receipt: executor must re-observe inventory and
        // authenticate the exact CMS before committing or returning any profile.
    }

    /// Read-only listing. Includes team profiles to avoid silently hiding an
    /// existing target. Known pagination indicators fail closed, never truncate.
    func vexsignListProfiles(team: Team, session apiSession: Session) async throws -> [VexSignProfileListing] {
        let data = try await vexsignRegistrationRequest(action: "listProvisioningProfiles",
            parameters: ["includeTeamProfiles": true], requestID: UUID(), team: team, apiSession: apiSession, limit: 1024 * 1024)
        let response: VexSignProfileListResponse = try Self.vexsignProfileDecode(data)
        let rows = response.provisioningProfiles
        guard rows.count <= 50, response.hasMore != true, response.nextPage == nil,
              response.nextCursor.map({ $0.isEmpty }) ?? true,
              response.totalCount.map({ $0 == rows.count }) ?? true,
              Set(rows.map(\.provisioningProfileId)).count == rows.count,
              Set(rows.map(\.uuid)).count == rows.count,
              rows.allSatisfy({ Self.vexsignProfileIdentifier($0.provisioningProfileId)
                  && Self.vexsignProfileIdentifier($0.appId.appIdId)
                  && !$0.appId.identifier.isEmpty && $0.appId.identifier.utf8.count <= 255 }) else {
            throw VexSignProfileTransportError.unexpectedResponse
        }
        return rows
    }

    /// Explicit ID-only manual download, NEVER the app-based SDK convenience
    /// which may generate a team profile as a side effect of "download".
    func vexsignDownloadProfile(id: String, team: Team, session apiSession: Session) async throws -> VexSignDownloadedProfile {
        guard Self.vexsignProfileIdentifier(id) else { throw VexSignProfileTransportError.invalidRequest }
        let data = try await vexsignRegistrationRequest(action: "downloadProvisioningProfile",
            parameters: ["provisioningProfileId": id], requestID: UUID(), team: team, apiSession: apiSession, limit: 2 * 1024 * 1024)
        let response: VexSignProfileDownloadResponse = try Self.vexsignProfileDecode(data)
        let profile = response.provisioningProfile
        guard profile.provisioningProfileId == id, !profile.encodedProfile.isEmpty,
              profile.encodedProfile.count <= 1024 * 1024 else { throw VexSignProfileTransportError.unexpectedResponse }
        return profile
    }
}

private extension DeveloperPortal {
    static func vexsignProfileIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
    static func vexsignProfileDecode<T: Decodable>(_ data: Data) throws -> T {
        if let value = try? PropertyListDecoder().decode(T.self, from: data) { return value }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw VexSignProfileTransportError.unexpectedResponse }
        return value
    }
}
