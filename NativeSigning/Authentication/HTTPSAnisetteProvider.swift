import Foundation
import SideSign

public enum HTTPSAnisetteProviderError: Error, Equatable {
    case remoteEndpointRequired
    case invalidLimit
    case invalidResponse
    case oversizedResponse
    case httpStatus(Int)
    case invalidContentType
    case staleResponse
    case transportSecurityFailure
    case networkFailure
}

/// A deliberately narrow, header-only JSON dialect, not automatic v3 discovery
/// or provisioning. Never a remote signing/login API. No default endpoint exists.
public struct AnisetteHeaderResponse: Sendable {
    let url: URL
    let status: Int
    let mimeType: String?
    let body: Data

    public init(url: URL, status: Int, mimeType: String?, body: Data) {
        self.url = url; self.status = status; self.mimeType = mimeType; self.body = body
    }
}

public protocol AnisetteHeaderTransport: Sendable {
    func fetch(from endpoint: URL, maximumBytes: Int) async throws -> AnisetteHeaderResponse
}

/// The bridge invokes this only after provider-bound user consent. This API cannot
/// independently prove UI consent; it receives no Apple credentials or UDID.
public struct HTTPSAnisetteProvider<Transport: AnisetteHeaderTransport>: ConsentedAnisetteProvider {
    public static var maximumResponseBytes: Int { 64 * 1024 }
    public let descriptor: AnisetteProviderDescriptor
    private let endpoint: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date

    init(descriptor: AnisetteProviderDescriptor, transport: Transport,
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let endpoint = descriptor.endpoint else { throw HTTPSAnisetteProviderError.remoteEndpointRequired }
        self.descriptor = descriptor
        self.endpoint = endpoint
        self.transport = transport
        self.clock = clock
    }

    public func freshHeaders() async throws -> AnisetteData {
        do {
            try Task.checkCancellation()
            let response = try await transport.fetch(from: endpoint, maximumBytes: Self.maximumResponseBytes)
            try Task.checkCancellation()
            // Check again at the provider boundary even for an injected transport.
            guard response.url == endpoint else { throw HTTPSAnisetteProviderError.invalidResponse }
            guard response.status == 200 else { throw HTTPSAnisetteProviderError.httpStatus(response.status) }
            guard response.mimeType?.lowercased() == "application/json" else {
                throw HTTPSAnisetteProviderError.invalidContentType
            }
            guard !response.body.isEmpty else { throw HTTPSAnisetteProviderError.invalidResponse }
            guard response.body.count <= Self.maximumResponseBytes else { throw HTTPSAnisetteProviderError.oversizedResponse }
            var parser = AnisetteHeaderJSON(bytes: Array(response.body))
            let raw = try parser.parse()
            let required: Set<String> = [
                "x-apple-i-md-m", "x-apple-i-md", "x-apple-i-md-lu", "x-apple-i-md-rinfo",
                "x-mme-device-id", "x-apple-i-srl-no", "x-mme-client-info", "user-agent",
                "x-apple-i-client-time", "x-apple-locale", "x-apple-i-timezone"
            ]
            var fields: [String: String] = [:]
            for (name, value) in raw {
                let key = name.lowercased()
                guard required.contains(key), fields[key] == nil,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf8.count <= 4096,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw HTTPSAnisetteProviderError.invalidResponse
                }
                fields[key] = value
            }
            guard Set(fields.keys) == required else { throw HTTPSAnisetteProviderError.invalidResponse }
            // No force unwraps: the exact key set above is still checked at every
            // read so schema changes cannot silently produce empty auth headers.
            func field(_ key: String) throws -> String {
                guard let value = fields[key] else { throw HTTPSAnisetteProviderError.invalidResponse }
                return value
            }
            let machineID = try field("x-apple-i-md-m")
            let otp = try field("x-apple-i-md")
            guard let machineBytes = Data(base64Encoded: machineID), !machineBytes.isEmpty,
                  let otpBytes = Data(base64Encoded: otp), !otpBytes.isEmpty,
                  UUID(uuidString: try field("x-mme-device-id")) != nil else {
                throw HTTPSAnisetteProviderError.invalidResponse
            }
            let routing = try field("x-apple-i-md-rinfo")
            guard routing.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw HTTPSAnisetteProviderError.invalidResponse
            }
            let timestamp = try field("x-apple-i-client-time")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var issued = formatter.date(from: timestamp)
            if issued == nil {
                formatter.formatOptions = [.withInternetDateTime]
                issued = formatter.date(from: timestamp)
            }
            let now = clock()
            guard let issued, now.timeIntervalSince1970.isFinite,
                  abs(issued.timeIntervalSince(now)) <= 300 else {
                throw HTTPSAnisetteProviderError.staleResponse
            }
            let headers = AnisetteData(
                machineID: machineID, oneTimePassword: otp, localUserID: try field("x-apple-i-md-lu"),
                routingInfo: routing, deviceID: try field("x-mme-device-id"), serialNumber: try field("x-apple-i-srl-no"),
                clientInfo: try field("x-mme-client-info"), userAgent: try field("user-agent"),
                clientTime: timestamp, locale: try field("x-apple-locale"), timeZone: try field("x-apple-i-timezone")
            )
            try SideSignSessionCodec.validateFreshHeaders(headers)
            try Task.checkCancellation()
            return headers
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? HTTPSAnisetteProviderError { throw safe }
            throw HTTPSAnisetteProviderError.invalidResponse
        }
    }
}

/// Bounded streaming, not data(for:) followed by a post-allocation size check.
/// Each instance owns an ephemeral session. No cookies/cache/credentials, body,
/// identity headers, provisioning blobs, redirect following or TLS challenge hook.
public final class SystemAnisetteHeaderTransport: AnisetteHeaderTransport, Sendable {
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func fetch(from endpoint: URL, maximumBytes: Int) async throws -> AnisetteHeaderResponse {
        guard maximumBytes > 0, maximumBytes <= 64 * 1024 else { throw HTTPSAnisetteProviderError.invalidLimit }
        // Public transport is independently guarded, even outside the provider.
        guard endpoint.scheme?.lowercased() == "https", endpoint.host?.isEmpty == false,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw AnisetteConsentError.invalidProvider
        }
        do {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.setValue("VexSign-Anisette/1", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, let url = http.url, url == endpoint else {
                throw HTTPSAnisetteProviderError.invalidResponse
            }
            guard http.statusCode == 200 else { throw HTTPSAnisetteProviderError.httpStatus(http.statusCode) }
            guard http.mimeType?.lowercased() == "application/json" else { throw HTTPSAnisetteProviderError.invalidContentType }
            guard http.expectedContentLength <= Int64(maximumBytes) else { throw HTTPSAnisetteProviderError.oversizedResponse }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < maximumBytes else { throw HTTPSAnisetteProviderError.oversizedResponse }
                body.append(byte)
            }
            try Task.checkCancellation()
            return AnisetteHeaderResponse(url: url, status: http.statusCode, mimeType: http.mimeType, body: body)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? HTTPSAnisetteProviderError { throw safe }
            if let transport = error as? URLError {
                switch transport.code {
                case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                    throw HTTPSAnisetteProviderError.transportSecurityFailure
                default: break
                }
            }
            throw HTTPSAnisetteProviderError.networkFailure
        }
    }
}

public extension HTTPSAnisetteProvider where Transport == SystemAnisetteHeaderTransport {
    init(descriptor: AnisetteProviderDescriptor) throws {
        try self.init(descriptor: descriptor, transport: SystemAnisetteHeaderTransport())
    }
}

/// Flat string-only JSON parser with duplicate-key detection. Foundation's usual
/// dictionary decoding discards exact duplicate keys before validation. Individual
/// string decoding is delegated to JSONDecoder for Unicode/escape correctness.
private struct AnisetteHeaderJSON {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() throws -> [String: String] {
        try consume(123) // {
        var result: [String: String] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == 125 { index += 1 }
        else {
            while true {
                let key = try string()
                try consume(58) // :
                let value = try string()
                guard result[key] == nil, result.count < 11 else { throw HTTPSAnisetteProviderError.invalidResponse }
                result[key] = value
                skipWhitespace()
                guard index < bytes.count else { throw HTTPSAnisetteProviderError.invalidResponse }
                if bytes[index] == 125 { index += 1; break }
                try consume(44) // ,
            }
        }
        skipWhitespace()
        guard index == bytes.count else { throw HTTPSAnisetteProviderError.invalidResponse }
        return result
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) throws {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == byte else { throw HTTPSAnisetteProviderError.invalidResponse }
        index += 1
    }

    private mutating func string() throws -> String {
        skipWhitespace()
        let start = index
        try consume(34) // quote
        while index < bytes.count {
            if bytes[index] == 92 { index += 2 } // escaped byte; JSONDecoder validates the escape itself
            else if bytes[index] == 34 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            } else { index += 1 }
        }
        throw HTTPSAnisetteProviderError.invalidResponse
    }
}
