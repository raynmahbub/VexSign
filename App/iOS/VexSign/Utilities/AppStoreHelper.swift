//
//  AppStoreHelper.swift
//  VexSign
//
//  Resolves an installed app's bundle identifier to its public App Store page.
//  The lookup is deliberately defensive: repository metadata is user supplied
//  and Apple's response is not guaranteed to contain every field.
//

import Foundation
import UIKit

struct AppStoreHelper {
    struct AppStoreResponse: Decodable {
        let resultCount: Int?
        let results: [AppStoreApp]
    }

    struct AppStoreApp: Decodable {
        let trackName: String?
        let trackViewUrl: String?
        let trackId: Int?
        let bundleId: String?
    }

    enum AppStoreError: LocalizedError {
        case invalidBundleId
        case networkError(String)
        case noData
        case serverError(Int)
        case notFoundOnAppStore
        case unexpectedResponse
        case invalidURL
        case failedToOpen

        var errorDescription: String? {
            switch self {
            case .invalidBundleId:
                return "Invalid bundle identifier"
            case .networkError(let message):
                return "Network error: \(message)"
            case .noData:
                return "No data received from the App Store"
            case .serverError(let status):
                return "The App Store returned HTTP \(status)"
            case .notFoundOnAppStore:
                return "This app is not listed on the App Store"
            case .unexpectedResponse:
                return "Unexpected response from the App Store"
            case .invalidURL:
                return "Invalid App Store URL"
            case .failedToOpen:
                return "Failed to open the App Store"
            }
        }
    }

    /// Looks up and opens the App Store page. Completion is always delivered on
    /// the main queue so callers may update SwiftUI state safely.
    static func openAppStore(
        for bundleId: String,
        completion: @escaping (Result<Void, AppStoreError>) -> Void
    ) {
        let trimmedBundleID = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleID.isEmpty, trimmedBundleID.contains(".") else {
            DispatchQueue.main.async { completion(.failure(.invalidBundleId)) }
            return
        }

        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: trimmedBundleID),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
            URLQueryItem(name: "entity", value: "software")
        ]

        guard let lookupURL = components?.url else {
            DispatchQueue.main.async { completion(.failure(.invalidBundleId)) }
            return
        }

        var request = URLRequest(url: lookupURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<String, AppStoreError>
            if let error {
                result = .failure(.networkError(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse,
                      !(200...299).contains(http.statusCode) {
                result = .failure(.serverError(http.statusCode))
            } else if let data, !data.isEmpty {
                result = decodeURL(from: data)
            } else {
                result = .failure(.noData)
            }

            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let string):
                    guard let url = URL(string: string) else {
                        completion(.failure(.invalidURL))
                        return
                    }
                    UIApplication.shared.open(url, options: [:]) { opened in
                        if opened {
                            completion(successResult())
                        } else {
                            completion(.failure(.failedToOpen))
                        }
                    }
                }
            }
        }.resume()
    }

    private static func emptyVoid() {}

    private static func successResult() -> Result<Void, AppStoreError> {
        .success(emptyVoid())
    }

    private static func decodeURL(from data: Data) -> Result<String, AppStoreError> {
        do {
            let response = try JSONDecoder().decode(AppStoreResponse.self, from: data)
            guard response.resultCount != 0, let app = response.results.first else {
                return .failure(.notFoundOnAppStore)
            }

            // Prefer Apple's canonical web URL. A track ID is a reliable
            // fallback for responses that omit trackViewUrl.
            if let trackViewUrl = app.trackViewUrl, !trackViewUrl.isEmpty {
                return .success(trackViewUrl)
            }
            if let trackId = app.trackId {
                return .success("https://apps.apple.com/app/id\(trackId)")
            }
            return .failure(.unexpectedResponse)
        } catch {
            return .failure(.unexpectedResponse)
        }
    }
}
