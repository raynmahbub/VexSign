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

/// Raw public certificate material, NOT trust/purpose/revocation evidence.
/// certificateId is required: certRequestId is never guessed to be its identity.
public struct VexSignDevelopmentCertificate: Decodable, Sendable {
    public let certificateId: String
    public let certContent: Data
}

private struct VexSignProfileListResponse: Decodable {
    let provisioningProfiles: [VexSignProfileListing]
    let hasMore: Bool?
    let nextPage: Int?
    let nextCursor: String?
    let totalCount: Int?
}

private struct VexSignProfileDownloadResponse: Decodable { let provisioningProfile: VexSignDownloadedProfile }

private struct VexSignDevelopmentCertificateList: Decodable {
    let certificates: [VexSignDevelopmentCertificate]
}

// Registration types from VexSignRegistration patch
public enum VexSignRegistrationTransportError: Error, Equatable, Sendable {
    case invalidRequest, unexpectedResponse, requestFailed
}

public enum VexSignRegistrationKind: Sendable { case device, appID }

public struct VexSignRegistrationDevice: Decodable, Sendable {
    public let deviceNumber: String
    public let deviceId: String?
    public let deviceClass: String
    public let status: String
}

public struct VexSignRegistrationAppID: Decodable, Sendable {
    public let appIdId: String
    public let identifier: String
    public let expirationDate: Date?
}

public enum VexSignRegistrationInventory: Sendable {
    case devices([VexSignRegistrationDevice])
    case appIDs([VexSignRegistrationAppID])
}

private struct VexSignRegistrationStatus: Decodable {
    let resultCode: Int
    let errors: [IgnoredError]?
    struct IgnoredError: Decodable {}
}

private struct VexSignDeviceList: Decodable { let devices: [VexSignRegistrationDevice] }

private struct VexSignAppIDList: Decodable { let appIds: [VexSignRegistrationAppID] }