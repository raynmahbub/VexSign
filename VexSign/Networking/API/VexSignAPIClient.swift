//
//  VexSignAPIClient.swift
//  VexSign
//
//  Typed client for the VexSign premium API. Requests are built with
//  `AuthenticatedRequestBuilder` and executed through
//  `VexSignAPI.performDataRequest`, which bounds the body and sanitizes
//  redirects, so this client never touches a bare URLSession.

import Foundation

enum VexSignAPIClient {
    enum Failure: LocalizedError, Equatable {
        case invalidEndpoint(String)
        case httpError(Int)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint(let endpoint):
                return "The VexSign API endpoint is invalid: \(endpoint)"
            case .httpError(let status):
                return "The VexSign API returned HTTP \(status)."
            case .decodingFailed:
                return "The VexSign API response could not be read."
            }
        }
    }

    /// Whether the premium API is reachable. A 2xx response is healthy; anything
    /// else is reported, never treated as success.
    static func fetchHealth() async throws -> Bool {
        guard let url = URL(string: VexSignAPI.apiHealthEndpoint) else {
            throw Failure.invalidEndpoint(VexSignAPI.apiHealthEndpoint)
        }
        let request = AuthenticatedRequestBuilder.request(url: url)
        let (_, response) = try await VexSignAPI.performDataRequest(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard DownloadIntegrity.isAcceptableHTTPStatus(status) else {
            throw Failure.httpError(status)
        }
        return true
    }

    /// The premium repository URLs the API unlocks for this device. The list
    /// arrives over the network, so callers must still validate each URL with
    /// `VexSignAPI.isRecordablePremiumSource` before recording it.
    static func fetchPremiumURLs() async throws -> [URL] {
        guard let url = URL(string: VexSignAPI.apiURLsEndpoint) else {
            throw Failure.invalidEndpoint(VexSignAPI.apiURLsEndpoint)
        }
        let request = AuthenticatedRequestBuilder.request(url: url)
        let (data, response) = try await VexSignAPI.performDataRequest(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard DownloadIntegrity.isAcceptableHTTPStatus(status) else {
            throw Failure.httpError(status)
        }
        guard let decoded = try? JSONDecoder().decode(VexSignAPI.URLsResponse.self, from: data) else {
            throw Failure.decodingFailed
        }
        return (decoded.urls ?? []).compactMap { URL(string: $0.url) }
    }
}
