//
//  FR+Repository.swift
//  VexSign
//
//  Repository handling and API key wiring.
//

import Foundation
import Security
import UIKit
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import OSLog
import NimbleExtensions

extension FR {
    // MARK: - Premium repository API key wiring

    /// Registers the app-wide repository fetch key provider and loads the effective key.
    /// Precedence: hardcoded developer override → persisted (redeemed, keychain) key.
    /// Call once at launch so every manifest fetch/decrypt attaches it as `X-API-Key`.
    static func registerRepositoryKeyProvider() {
        let effectiveKey: String = {
            if !VexSignAPI.developerPremiumAPIKey.isEmpty {
                return VexSignAPI.developerPremiumAPIKey
            }
            if let persisted = VexSignAPI.premiumAPIKey {
                return persisted
            }
            return ""
        }()
        #if canImport(AltSourceKit)
        EsignSourceKey.customApiKey = effectiveKey
        NBFetchService.apiKeyProvider = { EsignSourceKey.customApiKey }
        #else
        NBFetchService.apiKeyProvider = { effectiveKey }
        #endif
    }

    static func handleSource(
        _ urlString: String,
        showAlerts: Bool = true,
        competion: @escaping (Result<String, Error>) -> Void
    ) {
        var cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.lowercased().hasPrefix("http://") && !cleaned.lowercased().hasPrefix("https://") {
            cleaned = "https://" + cleaned
        }

        guard let url = URL(string: cleaned), url.host != nil else {
            let error = NSError(domain: "VexSign", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            if showAlerts {
                DispatchQueue.main.async {
                    Toast.error(.localized("Invalid URL"), duration: .sticky)
                }
            }
            competion(.failure(error))
            return
        }

        // Transport policy: repositories must be HTTPS unless the user has
        // explicitly opted into insecure HTTP for local repositories.
        do {
            try SourceURLPolicy.validate(url)
            } catch {
            if showAlerts {
                DispatchQueue.main.async {
                    Toast.error(error.localizedDescription, duration: .sticky)
                }
            }
            competion(.failure(error))
            return
        }

        if let apiURL = GitHubReleaseSource.apiURL(for: url) {
            _handleGitHubSource(url, apiURL: apiURL, showAlerts: showAlerts, completion: competion)
            return
        }

        var headers: [String: String] = VexSignAPI.authHeaders(for: url)
        #if canImport(AltSourceKit)
        // Belt-and-braces: also attach the premium key directly when a non-empty
        // `customApiKey` is configured (single-source path through EsignSourceKey).
        if !EsignSourceKey.customApiKey.isEmpty, headers["X-API-Key"] == nil {
            headers["X-API-Key"] = EsignSourceKey.customApiKey
        }
        #endif

        NBFetchService().fetch(from: url, headers: headers) { (result: Result<ASRepository, Error>) in
            switch result {
            case .success(let data):
                let id = data.id ?? url.absoluteString

                // `NBFetchService` calls back on a global queue, and the source row is
                // a view-context insert: it has to happen on the main queue.
                var addError: Error?
                var alreadyAdded = false
                let addOnMain = {
                    if Storage.shared.sourceExists(id) {
                        alreadyAdded = true
                    } else {
                        Storage.shared.addSource(url, repository: data, id: id) { addError = $0 }
                    }
                }
                if Thread.isMainThread {
                    addOnMain()
                } else {
                    DispatchQueue.main.sync(execute: addOnMain)
                }

                if let addError {
                    competion(.failure(addError))
                } else if !alreadyAdded {
                    competion(.success(data.name ?? url.absoluteString))
                } else {
                    let error = NSError(domain: "VexSign", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository already added."])
                    if showAlerts {
                        DispatchQueue.main.async {
                            Toast.error(.localized("Repository already added."), duration: .sticky)
                        }
                    }
                    competion(.failure(error))
                }
            case .failure(let error):
                if showAlerts {
                    DispatchQueue.main.async {
                        Toast.error(error.localizedDescription, duration: .sticky)
                    }
                }
                competion(.failure(error))
            }
        }
    }

    private static func _handleGitHubSource(
        _ sourceURL: URL,
        apiURL: URL,
        showAlerts: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task.detached {
            do {
                var request = URLRequest(url: apiURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("VexSign", forHTTPHeaderField: "User-Agent")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                // Adding a source must fail visibly; it must not sit on a spinner while the
                // session's 60 s default runs out, once per redirect hop.
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw GitHubReleaseSource.Failure.malformedRelease
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw GitHubReleaseSource.Failure.httpStatus(response.statusCode)
                }
                let repository = try GitHubReleaseSource.repository(from: data, sourceURL: sourceURL)
                await MainActor.run {
                    _addGitHubRepository(repository, sourceURL: sourceURL, showAlerts: showAlerts, completion: completion)
                }
                } catch {
                if showAlerts {
                    DispatchQueue.main.async { Toast.error(error.localizedDescription, duration: .sticky) }
                }
                completion(.failure(error))
            }
        }
    }

    @MainActor
    private static func _addGitHubRepository(
        _ repository: ASRepository,
        sourceURL: URL,
        showAlerts: Bool,
        // Escaping: `Storage.addSource`'s completion is `@escaping`, and this closure is captured
        // by it. The caller `_handleGitHubSource` already takes its own completion as escaping.
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let id = repository.id ?? sourceURL.absoluteString
        guard !Storage.shared.sourceExists(id) else {
            let error = NSError(domain: "VexSign", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository already added."])
            if showAlerts { Toast.error(error.localizedDescription, duration: .sticky) }
            completion(.failure(error))
            return
        }
        Storage.shared.addSource(sourceURL, repository: repository, id: id) { error in
            if let error {
                if showAlerts { Toast.error(error.localizedDescription, duration: .sticky) }
                completion(.failure(error))
            } else {
                completion(.success(repository.name ?? sourceURL.absoluteString))
            }
        }
    }
}