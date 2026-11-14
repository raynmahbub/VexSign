import Foundation
import NimbleExtensions

/// Builds only the documented SideStore install handoff; no credentials or callbacks.
enum CompanionHandoffLink {
    enum InputIssue: Equatable {
        case empty, malformed, requiresHTTPS, credentials, fragment

        var message: String {
            switch self {
            case .empty: return .localized("Enter a hosted IPA HTTPS URL.")
            case .malformed: return .localized("Enter a complete URL with a host and no unescaped whitespace or control characters.")
            case .requiresHTTPS: return .localized("Use an HTTPS link. Local files and other URL schemes cannot be sent through this action.")
            case .credentials: return .localized("Remove the username and password from the URL. Embedded credentials are not accepted.")
            case .fragment: return .localized("Remove the URL fragment after # before sending this link.")
            }
        }
    }

    static func issue(for input: String) -> InputIssue? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }), let url = URL(string: trimmed) else { return .malformed }
        guard url.scheme?.lowercased() == "https" else { return .requiresHTTPS }
        guard let host = url.host, !host.isEmpty else { return .malformed }
        guard url.user == nil, url.password == nil else { return .credentials }
        guard url.fragment == nil else { return .fragment }
        return nil
    }

    /// Host only: never include a path, token, userinfo or query in summaries.
    static func destinationHost(for input: String) -> String? {
        guard issue(for: input) == nil else { return nil }
        return URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines))?.host
    }

    static func sideStoreInstall(_ input: String) -> URL? {
        guard issue(for: input) == nil,
              let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var components = URLComponents()
        components.scheme = "sidestore"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url
    }
}
