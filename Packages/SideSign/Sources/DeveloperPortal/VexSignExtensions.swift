// VexSign additions to pinned SideSign (AGPL-3.0); retain modified source.
import Foundation

// MARK: - Privacy Overlay

/// Build-time privacy-overlay marker. Logging is suppressed by default in VexSign.
public enum VexSignSideSignPrivacy {
    public static var loggingSuppressed: Bool { true }
}

// MARK: - Registration Types

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

// MARK: - Registration Extensions

public extension DeveloperPortal {
    /// Requires journaled uncertain intent. One application send; never invokes
    /// the SDK registration convenience methods or their permissive dispatcher.
    /// UUID is correlation metadata, NOT a server idempotency guarantee.
    func vexsignRegisterOnce(kind: VexSignRegistrationKind, value: String, operationID: UUID,
                              team: Team, session apiSession: Session) async throws {
        var parameters = ["name": "VexSign"]
        let action: String
        switch kind {
        case .device:
            let legacy = value.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil
            let modern = value.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$", options: .regularExpression) != nil
            guard (value.utf8.count == 40 && legacy) || (value.utf8.count == 25 && modern) else {
                throw VexSignRegistrationTransportError.invalidRequest
            }
            action = "addDevice"
            parameters["deviceNumber"] = value
            parameters["DTDK_Platform"] = "ios"
        case .appID:
            guard value.utf8.count <= 255, value.contains("."), value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }) else { throw VexSignRegistrationTransportError.invalidRequest }
            action = "addAppId"
            parameters["identifier"] = value
        }
        _ = try await vexsignRegistrationRequest(action: action, parameters: parameters.mapValues { $0 as any Sendable }, requestID: operationID,
                                                 team: team, apiSession: apiSession, limit: 256 * 1024)
        // A successful direct response does not authorize local adoption. Caller
        // must observe a unique exact registration through fresh inventory.
    }

    func vexsignRegistrationInventory(kind: VexSignRegistrationKind, team: Team,
                                       session apiSession: Session) async throws -> VexSignRegistrationInventory {
        let action: String
        switch kind { case .device: action = "listDevices"; case .appID: action = "listAppIds" }
        let body = try await vexsignRegistrationRequest(action: action, parameters: [:], requestID: UUID(),
                                                        team: team, apiSession: apiSession, limit: 1024 * 1024)
        switch kind {
        case .device:
            let list: VexSignDeviceList = try Self.vexsignRegistrationDecode(body)
            guard list.devices.count <= 1000 else { throw VexSignRegistrationTransportError.unexpectedResponse }
            return .devices(list.devices)
        case .appID:
            let list: VexSignAppIDList = try Self.vexsignRegistrationDecode(body)
            guard list.appIds.count <= 1000 else { throw VexSignRegistrationTransportError.unexpectedResponse }
            return .appIDs(list.appIds)
        }
    }
}

extension DeveloperPortal {
    private static func vexsignRegistrationDecode<T: Decodable>(_ body: Data) throws -> T {
        if let value = try? PropertyListDecoder().decode(T.self, from: body) { return value }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(T.self, from: body) else { throw VexSignRegistrationTransportError.unexpectedResponse }
        return value
    }

    func vexsignRegistrationRequest(action: String, parameters: [String: any Sendable], requestID: UUID,
                                     team: Team, apiSession: Session, limit: Int) async throws -> Data {
        do {
            try Task.checkCancellation()
            guard VexSignSideSignPrivacy.loggingSuppressed, team.type == .free,
                  !team.identifier.isEmpty, team.identifier.utf8.count <= 256 else { throw VexSignRegistrationTransportError.invalidRequest }
            let endpoint: URL
            switch action {
            case "addDevice": endpoint = Constants.URLs.addDevice
            case "addAppId": endpoint = Constants.URLs.addAppID
            case "listDevices": endpoint = Constants.URLs.listDevices
            case "listAppIds": endpoint = Constants.URLs.listAppIDs
            case "createProvisioningProfile": endpoint = Constants.URLs.createProvisioningProfile
            case "listProvisioningProfiles": endpoint = Constants.URLs.listProvisioningProfiles
            case "downloadProvisioningProfile": endpoint = Constants.URLs.downloadManualProvisioningProfile
            case "listAllDevelopmentCerts": endpoint = Constants.URLs.listCertificates
            default: throw VexSignRegistrationTransportError.invalidRequest
            }
            guard endpoint.scheme == "https", endpoint.host == "developerservices2.apple.com",
                  endpoint.path == "/services/QH65B2/ios/" + action + ".action",
                  var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw VexSignRegistrationTransportError.invalidRequest }
            let h = customHeaders; let a = apiSession.anisetteData
            components.queryItems = [.init(name: "clientId", value: h.developerServices.clientID)]
            guard let url = components.url else { throw VexSignRegistrationTransportError.invalidRequest }
            var body = parameters
            body["clientId"] = h.developerServices.clientID; body["protocolVersion"] = h.developerServices.protocolVersion
            body["requestId"] = requestID.uuidString.uppercased(); body["teamId"] = team.identifier
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 30
            request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
            let headers = [
                "Content-Type": "text/x-xml-plist", "Accept": "text/x-xml-plist", "Accept-Language": "en-us",
                "User-Agent": h.developerServices.userAgent, "X-Apple-App-Info": h.grandSlam.authApp,
                "X-Xcode-Version": apiSession.xcodeVersion, "X-Apple-I-Identity-Id": apiSession.dsid,
                "X-Apple-GS-Token": apiSession.authToken, "X-Apple-I-MD-M": a.machineID,
                "X-Apple-I-MD": a.oneTimePassword, "X-Apple-I-MD-LU": a.localUserID,
                "X-Apple-I-MD-RINFO": a.routingInfo, "X-Mme-Device-Id": a.deviceID,
                "X-MMe-Client-Info": a.clientInfo, "X-Apple-I-Client-Time": a.clientTime,
                "X-Apple-Locale": a.locale, "X-Apple-I-Locale": a.locale, "X-Apple-I-TimeZone": a.timeZone,
                "Cache-Control": "no-store", "Pragma": "no-cache"
            ]
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (bytes, response) = try await self.session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200,
                  http.expectedContentLength <= Int64(limit) else { throw VexSignRegistrationTransportError.unexpectedResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw VexSignRegistrationTransportError.unexpectedResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            let status: VexSignRegistrationStatus = try Self.vexsignRegistrationDecode(data)
            guard status.resultCode == 0, status.errors?.isEmpty ?? true else { throw VexSignRegistrationTransportError.unexpectedResponse }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? VexSignRegistrationTransportError { throw safe }
            throw VexSignRegistrationTransportError.requestFailed
        }
    }
}

// MARK: - Certificate Inventory Types

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

// MARK: - Certificate Inventory Extensions

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

// MARK: - Prepared CSR Types

public enum VexSignPreparedCSRError: Error, Equatable, Sendable {
    case invalidRequest, unexpectedResponse, requestFailed
}

public struct VexSignPreparedCSRReceipt: Sendable {
    public let certificateIdentifier: String?
    public let certificateDER: Data?
}

private struct VexSignCSRWireResponse: Decodable {
    let resultCode: Int
    let certRequest: Certificate?
    struct Certificate: Decodable {
        let certificateId: String?
        let certContent: Data?
    }
}

// MARK: - Prepared CSR Extensions

public extension DeveloperPortal {
    /// Single application-level send; no key generation, retry loop, fallback
    /// signer, automatic quota cleanup or account repair. A request ID is NOT an
    /// Apple idempotency guarantee. Caller MUST journal uncertain intent first.
    /// Native VexSign uses only its private hardened URLSession/portal instance.
    func vexsignSubmitPreparedDevelopmentCSR(csrDER: Data, machineIdentifier: UUID,
                                             team: Team, session apiSession: Session) async throws -> VexSignPreparedCSRReceipt {
        do {
            try Task.checkCancellation()
            guard VexSignSideSignPrivacy.loggingSuppressed, team.type == .free,
                  !team.identifier.isEmpty, team.identifier.utf8.count <= 256,
                  csrDER.count >= 64, csrDER.count <= 32 * 1024, csrDER.first == 0x30 else {
                throw VexSignPreparedCSRError.invalidRequest
            }
            let h = customHeaders
            let endpoint = Constants.URLs.submitDevelopmentCSR
            guard endpoint.scheme == "https", endpoint.host == "developerservices2.apple.com",
                  endpoint.path == "/services/QH65B2/ios/submitDevelopmentCSR.action",
                  var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw VexSignPreparedCSRError.invalidRequest
            }
            components.queryItems = [URLQueryItem(name: "clientId", value: h.developerServices.clientID)]
            guard let url = components.url else { throw VexSignPreparedCSRError.invalidRequest }
            let pem = "-----BEGIN CERTIFICATE REQUEST-----\n" + csrDER.base64EncodedString(options: .lineLength64Characters)
                + "\n-----END CERTIFICATE REQUEST-----\n"
            let parameters: [String: String] = [
                "clientId": h.developerServices.clientID,
                "protocolVersion": h.developerServices.protocolVersion,
                "requestId": machineIdentifier.uuidString.uppercased(),
                "teamId": team.identifier, "machineId": machineIdentifier.uuidString.uppercased(),
                "machineName": "VexSign-" + machineIdentifier.uuidString,
                "csrContent": pem
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            request.httpBody = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)
            let a = apiSession.anisetteData
            let headers = [
                "Content-Type": "text/x-xml-plist", "Accept": "text/x-xml-plist",
                "Accept-Language": "en-us", "User-Agent": h.developerServices.userAgent,
                "X-Apple-App-Info": h.grandSlam.authApp, "X-Xcode-Version": apiSession.xcodeVersion,
                "X-Apple-I-Identity-Id": apiSession.dsid, "X-Apple-GS-Token": apiSession.authToken,
                "X-Apple-I-MD-M": a.machineID, "X-Apple-I-MD": a.oneTimePassword,
                "X-Apple-I-MD-LU": a.localUserID, "X-Apple-I-MD-RINFO": a.routingInfo,
                "X-Mme-Device-Id": a.deviceID, "X-MMe-Client-Info": a.clientInfo,
                "X-Apple-I-Client-Time": a.clientTime, "X-Apple-Locale": a.locale,
                "X-Apple-I-Locale": a.locale, "X-Apple-I-TimeZone": a.timeZone,
                "Cache-Control": "no-store", "Pragma": "no-cache"
            ]
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            // Deliberately bypass sendRequest's permissive status/result handling.
            // No raw header/body/response/error logging on this mutation path.
            let (bytes, response) = try await self.session.bytes(for: request)
            defer { bytes.task.cancel() }
            let limit = 256 * 1024
            guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200,
                  http.expectedContentLength <= Int64(limit) else { throw VexSignPreparedCSRError.unexpectedResponse }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < limit else { throw VexSignPreparedCSRError.unexpectedResponse }
                body.append(byte)
            }
            try Task.checkCancellation()
            let wire = (try? PropertyListDecoder().decode(VexSignCSRWireResponse.self, from: body))
                ?? (try? JSONDecoder().decode(VexSignCSRWireResponse.self, from: body))
            guard let wire, wire.resultCode == 0 else { throw VexSignPreparedCSRError.unexpectedResponse }
            if let certificate = wire.certRequest?.certContent, certificate.count > 64 * 1024 {
                throw VexSignPreparedCSRError.unexpectedResponse
            }
            // Missing direct certificate/ID requires read-only inventory recovery,
            // not reissuing the CSR. Never treat certRequestId as certificateId.
            return VexSignPreparedCSRReceipt(certificateIdentifier: wire.certRequest?.certificateId,
                                             certificateDER: wire.certRequest?.certContent)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? VexSignPreparedCSRError { throw safe }
            throw VexSignPreparedCSRError.requestFailed
        }
    }
}

// MARK: - Profile Types

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

// MARK: - Profile Extensions

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