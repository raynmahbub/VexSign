//
//  RemoteAnisetteDataProvider.swift
//  SideSign
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 SideSign. All rights reserved.
//

import Foundation
import AnisetteKit

public struct RemoteAnisetteDataProvider: AnisetteDataProvider, Sendable {
    public var requiresLocalLibraries: Bool { false }

    public let serverURL: URL
    public let allowsLegacyFallback: Bool

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let network: URLSession
    private static let maximumBytes = 64 * 1024

    private func jsonResponse(for request: URLRequest) async throws -> [String: String] {
        let (bytes, response) = try await network.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == request.url, http.mimeType?.lowercased() == "application/json" else {
            throw AnisetteError.invalidAnisetteData
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw AnisetteError.invalidAnisetteData }
            data.append(byte)
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private final class ProvisioningSessionManager: @unchecked Sendable {
        private let lock = NSLock()
        private var counter: UInt32 = 0
        private var activeSessions: [UInt32: URLSessionWebSocketTask] = [:]

        func store(_ task: URLSessionWebSocketTask) throws -> UInt32 {
            let key: UInt32 = try lock.withLock {
                guard activeSessions.count < 8 else { throw AnisetteError.invalidAnisetteData }
                counter &+= 1
                if counter == 0 { counter = 1 }
                activeSessions[counter] = task
                return counter
            }
            // An ADI caller may be cancelled between start and end provisioning.
            // Retire an orphan without retaining its socket indefinitely.
            Task {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
                retrieve(for: key)?.cancel(with: .goingAway, reason: nil)
            }
            return key
        }

        func retrieve(for session: UInt32) -> URLSessionWebSocketTask? {
            lock.withLock {
                activeSessions.removeValue(forKey: session)
            }
        }

        func cancelAll() {
            lock.withLock {
                for task in activeSessions.values {
                    task.cancel(with: .normalClosure, reason: nil)
                }
                activeSessions.removeAll()
            }
        }
    }

    private static let sessionManager = ProvisioningSessionManager()

    public init(serverURL: URL, allowsLegacyFallback: Bool = true) {
        self.serverURL = serverURL
        self.allowsLegacyFallback = allowsLegacyFallback
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.network = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    public func getAnisetteHeaders(
        libDir: String,
        provisioningDir: String,
        identifier: [UInt8],
        adiPb: [UInt8]
    ) async throws -> AnisetteDataResponse {
        let cleanIdentifier = identifier.map { String(format: "%02x", $0) }.joined()
        let baseURL = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 1. If adiPb is present, attempt v3 /v3/get_headers
        if !adiPb.isEmpty {
            if let v3HeadersURL = URL(string: "\(baseURL)/\(Constants.URLs.v3GetHeaders)") {
                var postReq = URLRequest(url: v3HeadersURL)
                postReq.timeoutInterval = Constants.Anisette.remoteRequestTimeout
                postReq.httpMethod = "POST"
                postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                postReq.cachePolicy = .reloadIgnoringLocalCacheData

                let payload: [String: String] = [
                    "identifier": cleanIdentifier,
                    "adi_pb": Data(adiPb).base64EncodedString()
                ]
                postReq.httpBody = try JSONSerialization.data(withJSONObject: payload)

                do {
                    let json = try await jsonResponse(for: postReq)
                    if let result = json["result"], result == "GetHeadersError" {
                        let msg = json["message"] ?? "GetHeadersError"
                        throw AnisetteError.badServerResponse(statusCode: -1, payload: msg)
                    }
                    return try AnisetteDataResponse(from: json)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if !allowsLegacyFallback { throw AnisetteError.invalidAnisetteData }
                }
            }
        }
        guard allowsLegacyFallback else { throw AnisetteError.invalidAnisetteData }

        // 2. Fallback to legacy v1 root GET
        var request = URLRequest(url: serverURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Constants.Anisette.remoteRequestTimeout

        let json = try await jsonResponse(for: request)
        return try AnisetteDataResponse(from: json)
    }

    public func startProvision(
        libDir: String,
        provisioningDir: String,
        identifier: [UInt8],
        spim: [UInt8]
    ) async throws -> (cpim: Data, session: UInt32) {
        let baseURL = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let httpURL = URL(string: "\(baseURL)/\(Constants.URLs.v3ProvisioningSession)"),
              var webSocketComponents = URLComponents(url: httpURL, resolvingAgainstBaseURL: true) else {
            throw AnisetteError.invalidURL
        }
        webSocketComponents.scheme = (webSocketComponents.scheme == "http") ? "ws" : "wss"
        guard let webSocketURL = webSocketComponents.url else {
            throw AnisetteError.invalidURL
        }

        guard serverURL.scheme?.lowercased() == "https", serverURL.user == nil,
              serverURL.password == nil, serverURL.query == nil, serverURL.fragment == nil else {
            throw AnisetteError.invalidURL
        }
        let webSocketTask = network.webSocketTask(with: webSocketURL)
        webSocketTask.maximumMessageSize = Self.maximumBytes
        webSocketTask.resume()

        let cleanIdentifier = identifier.map { String(format: "%02x", $0) }.joined()

        do {
            var step = 0
            while step < 3 {
                try Task.checkCancellation()
                let json = try await receiveWebSocketJSON(from: webSocketTask)
                guard let result = json["result"] as? String else {
                    throw AnisetteError.badServerResponse(statusCode: -1, payload: "Missing result in WebSocket response")
                }

                switch result {
                case "GiveIdentifier":
                    guard step == 0 else { throw AnisetteError.invalidAnisetteData }
                    step += 1
                    try await sendWebSocketJSON(["identifier": cleanIdentifier], to: webSocketTask)

                case "GiveStartProvisioningData":
                    guard step == 1 else { throw AnisetteError.invalidAnisetteData }
                    step += 1
                    let spimBase64 = Data(spim).base64EncodedString()
                    try await sendWebSocketJSON(["spim": spimBase64], to: webSocketTask)

                case "GiveEndProvisioningData":
                    guard step == 2 else { throw AnisetteError.invalidAnisetteData }
                    step += 1
                    guard let cpimBase64 = json["cpim"] as? String,
                          let cpimData = Data(base64Encoded: cpimBase64) else {
                        throw AnisetteError.badServerResponse(statusCode: -1, payload: "Missing or invalid cpim in GiveEndProvisioningData")
                    }
                    let sessionKey = try Self.sessionManager.store(webSocketTask)
                    return (cpimData, sessionKey)

                default:
                    let msg = json["message"] as? String ?? result
                    throw AnisetteError.badServerResponse(statusCode: -1, payload: "Unexpected remote provisioning step: \(msg)")
                }
            }
            throw AnisetteError.invalidAnisetteData
        } catch {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }

    public func endProvision(
        libDir: String,
        provisioningDir: String,
        identifier: [UInt8],
        session: UInt32,
        ptm: [UInt8],
        tk: [UInt8]
    ) async throws -> Data {
        guard let webSocketTask = Self.sessionManager.retrieve(for: session) else {
            throw AnisetteError.badServerResponse(statusCode: -1, payload: "Active WebSocket session not found for id \(session)")
        }
        defer {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
        }

        let ptmBase64 = Data(ptm).base64EncodedString()
        let tkBase64 = Data(tk).base64EncodedString()
        try await sendWebSocketJSON(["ptm": ptmBase64, "tk": tkBase64], to: webSocketTask)

        while true {
            let json = try await receiveWebSocketJSON(from: webSocketTask)
            guard let result = json["result"] as? String else {
                throw AnisetteError.badServerResponse(statusCode: -1, payload: "Missing result in WebSocket response")
            }

            switch result {
            case "ProvisioningSuccess":
                guard let adiPbStr = json["adi_pb"] as? String,
                      let adiPbData = Data(base64Encoded: adiPbStr), !adiPbData.isEmpty else {
                    throw AnisetteError.badServerResponse(statusCode: -1, payload: "Missing/invalid adi_pb in ProvisioningSuccess")
                }
                return adiPbData

            default:
                let msg = json["message"] as? String ?? result
                throw AnisetteError.badServerResponse(statusCode: -1, payload: "Remote provisioning end error: \(msg)")
            }
        }
    }

    private func sendWebSocketJSON(_ dict: [String: String], to webSocketTask: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let str = String(data: data, encoding: .utf8) else {
            throw AnisetteError.invalidAnisetteData
        }
        try await webSocketTask.send(.string(str))
    }

    private func receiveWebSocketJSON(from webSocketTask: URLSessionWebSocketTask) async throws -> [String: Any] {
        let msg = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask { try await webSocketTask.receive() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    webSocketTask.cancel(with: .goingAway, reason: nil)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let message = try await group.next() else { throw CancellationError() }
                return message
            }
        } onCancel: { webSocketTask.cancel(with: .goingAway, reason: nil) }
        let str: String
        switch msg {
        case .string(let s):
            str = s
        case .data(let d):
            str = String(data: d, encoding: .utf8) ?? ""
        @unknown default:
            str = ""
        }
        guard let jsonData = str.data(using: .utf8), jsonData.count <= Self.maximumBytes,
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AnisetteError.invalidAnisetteData
        }
        return json
    }
}
