//
//  AuthenticatedRequestBuilder.swift
//  VexSign
//
//  Builds URLRequests with the app's premium-source credentials applied.
//  Credential rules live in `VexSignAPI` (the single source of truth for which
//  hosts are premium and which headers they need); this builder only assembles
//  the request so API clients never hand-roll header logic.

import Foundation

enum AuthenticatedRequestBuilder {
    /// A request for `url` with caller headers first, then the premium-source
    /// credentials `VexSignAPI` decides apply. A caller-supplied header is never
    /// overwritten by the credential pass.
    static func request(
        url: URL,
        method: String = "GET",
        timeout: TimeInterval = HTTPTimeoutPolicy.metadataFetch,
        headers: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        VexSignAPI.applyAuthHeaders(to: &request)
        return request
    }
}
