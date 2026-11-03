// VexSign addition to pinned SideSign (AGPL-3.0); retain modified source.
import Foundation

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
