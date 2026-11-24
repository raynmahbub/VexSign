//
//  RepositoryCatalogService.swift
//  VexSign
//
//  Repository validation, fetching, provenance verification, and API key wiring.
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

/// One place for the limits applied to third-party repository traffic.
///
/// These numbers used to be repeated per call site, which is how the GitHub path ended up with an
/// explicit 20 s timeout and 16 MB cap while the generic feed and the download probe used
/// `URLSession.shared` with no stated budget. `NBFetchService` still enforces its own 20 MB cap for
/// streamed feeds; this type is the policy the *callers* share.
enum RepositoryNetworkPolicy {
    /// Feed and release metadata requests. A source that cannot answer in this window is broken
    /// for the user, and waiting on the session default only delays the error.
    static let requestTimeout: TimeInterval = 20
    /// Plain-text repository feeds are JSON; anything past this is not one.
    static let maxFeedBytes = 16 * 1024 * 1024
    /// HEAD probes are per app and run in small batches, so they can be shorter than a feed fetch.
    static let probeTimeout: TimeInterval = 15
    /// Concurrent probes per batch: enough to feel immediate, few enough not to look like an attack.
    static let maxConcurrentProbes = 4
}

enum RepositoryCatalogService {
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
        NBFetchService.scopedApiKeyProvider = { url in
            VexSignAPI.isPremiumSource(url) ? EsignSourceKey.customApiKey : nil
        }
        #else
        NBFetchService.apiKeyProvider = { effectiveKey }
        NBFetchService.scopedApiKeyProvider = { url in
            VexSignAPI.isPremiumSource(url) ? effectiveKey : nil
        }
        #endif
    }

    static func addSource(
        _ urlString: String,
        showAlerts: Bool = true,
        completion: @escaping (Result<String, Error>) -> Void
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
            completion(.failure(error))
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
            completion(.failure(error))
            return
        }

        // Duplicate detection by address, before any network request. The declared identifier
        // is not the address a source was added by, so a catalogue reachable as two spellings
        // of the same URL used to become two sources with two independent catalogs.
        if let key = CatalogIdentity.sourceKey(url.absoluteString),
           Storage.shared.configuredSourceAddresses().contains(where: {
               CatalogIdentity.sourceKey($0) == key
           }) {
            let error = NSError(domain: "VexSign", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String.localized("This repository is already added.")])
            if showAlerts {
                DispatchQueue.main.async { Toast.error(error.localizedDescription, duration: .sticky) }
            }
            completion(.failure(error))
            return
        }

        if let apiURL = GitHubReleaseSource.apiURL(for: url) {
            _handleGitHubSource(url, apiURL: apiURL, showAlerts: showAlerts, completion: completion)
            return
        }

        let headers: [String: String] = VexSignAPI.authHeaders(for: url)

        NBFetchService().fetchRaw(from: url, headers: headers) { (result: Result<Data, Error>) in
            switch result {
            case .success(let payload):
                guard !payload.isEmpty else {
                    let error = NSError(domain: "VexSign", code: 2, userInfo: [NSLocalizedDescriptionKey: String.localized("Couldn't load this source")])
                    if showAlerts {
                        DispatchQueue.main.async { Toast.error(error.localizedDescription, duration: .sticky) }
                    }
                    completion(.failure(error))
                    return
                }

                let provenance = SourceProvenanceVerifier.evaluate(payload)
                SourceProvenanceStore.record(provenance, for: url)
                if case .claimedButInvalid(let reason) = provenance {
                    let error = NSError(domain: "VexSign", code: 3, userInfo: [NSLocalizedDescriptionKey: reason])
                    if showAlerts {
                        DispatchQueue.main.async { Toast.error(reason, duration: .sticky) }
                    }
                    completion(.failure(error))
                    return
                }

                let data: ASRepository
                do {
                    data = try SourceFeedLoader.decode(payload)
                } catch {
                    if showAlerts {
                        DispatchQueue.main.async { Toast.error(error.localizedDescription, duration: .sticky) }
                    }
                    completion(.failure(error))
                    return
                }

                let id = data.id ?? url.absoluteString

                // `NBFetchService` calls back on a global queue, and the source row is
                // a view-context insert: hop asynchronously to the main queue instead of
                // blocking a worker thread with `DispatchQueue.main.sync`.
                DispatchQueue.main.async {
                    if Storage.shared.sourceExists(id) {
                        let error = NSError(domain: "VexSign", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository already added."])
                        if showAlerts {
                            Toast.error(.localized("Repository already added."), duration: .sticky)
                        }
                        completion(.failure(error))
                    } else {
                        Storage.shared.addSource(url, repository: data, id: id) { addError in
                            if let addError {
                                if showAlerts {
                                    Toast.error(addError.localizedDescription, duration: .sticky)
                                }
                                completion(.failure(addError))
                            } else {
                                completion(.success(data.name ?? url.absoluteString))
                            }
                        }
                    }
                }
            case .failure(let error):
                if showAlerts {
                    DispatchQueue.main.async {
                        Toast.error(error.localizedDescription, duration: .sticky)
                    }
                }
                completion(.failure(error))
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
                request.timeoutInterval = RepositoryNetworkPolicy.requestTimeout
                let (data, response) = try await BoundedResponseFetch.fetch(
                    request,
                    maximumBytes: Int64(RepositoryNetworkPolicy.maxFeedBytes)
                )
                guard let response = response as? HTTPURLResponse else {
                    throw GitHubReleaseSource.Failure.malformedRelease
                }
                guard let finalURL = response.url,
                      finalURL.scheme?.lowercased() == "https",
                      finalURL.user == nil,
                      finalURL.password == nil else {
                    throw SourceURLPolicy.Failure.notHTTPS
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw GitHubReleaseSource.Failure.httpStatus(response.statusCode)
                }
                guard data.count <= RepositoryNetworkPolicy.maxFeedBytes else {
                    throw GitHubReleaseSource.Failure.malformedRelease
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

    /// Filters repository URLs through `SourceURLPolicy` so batch imports
    /// cannot bypass the transport rules enforced by `RepositoryCatalogService.addSource`.
    static func validatedRepositoryURLs(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            do {
                try SourceURLPolicy.validate(url)
                return true
            } catch {
                Logger.security.warning("Skipping insecure repository: \(url.logSafeDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Applies premium auth, transport policy, and provenance checks to fetched sources.
    static func fetchRepositories(from urls: [URL]) async -> [(url: URL, data: ASRepository)] {
        let allowed = validatedRepositoryURLs(urls)
        let requests: [(url: URL, identifier: String, headers: [String: String])] = await MainActor.run {
            allowed.map { url in
                let isGitHub = GitHubReleaseSource.isGitHubRepositoryURL(url)
                return (
                    url,
                    url.absoluteString,
                    isGitHub ? [:] : VexSignAPI.authHeaders(for: url)
                )
            }
        }

        let loader = SourceFeedLoader(fetcher: { url, headers in
            let service = NBFetchService()
            return await withCheckedContinuation { continuation in
                service.fetchRaw(from: url, headers: headers) { result in
                    continuation.resume(returning: result)
                }
            }
        })

        return await withTaskGroup(of: (URL, ASRepository?).self) { group in
            for item in requests {
                group.addTask {
                    let result = await loader.load(url: item.url, headers: item.headers, identifier: item.identifier)
                    switch result.outcome {
                    case .decoded(let repository, _):
                        return (item.url, repository)
                    case .invalid, .failed:
                        return (item.url, nil)
                    }
                }
            }

            var results: [(url: URL, data: ASRepository)] = []
            for await (url, repository) in group {
                if let repository {
                    results.append((url: url, data: repository))
                }
            }
            return results
        }
    }
}
