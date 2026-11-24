// VexSign modification to pinned SideSign: supplied-CSR submission only.
// Included in the AGPL-3.0 SideSign build; retain this modification's source.
import Foundation

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
