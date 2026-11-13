//
//  FR+Export.swift
//  VexSign
//
//  Certificate export and repository fetching.
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
    static func exportCertificateAndOpenUrl(using template: String) {
        // Helper that performs the export for a given certificate
        func performExport(for certificate: CertificatePair) {
            guard
                let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
                let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile) // try? ok: certificate file may be missing or unreadable
            else {
                return
            }
            
            let base64encodedCert = certificateKeyFileData.base64EncodedString()
            
            var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
            allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
            
            guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
                return
            }
            
            let urlStr = template
                .replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
                .replacingOccurrences(of: "$(PASSWORD)", with: certificate.signingPassword ?? "")
            
            guard let callbackUrl = URL(string: urlStr) else {
                return
            }
            
            // Reject web schemes and dangerous protocols to prevent private key exfiltration
            guard let scheme = callbackUrl.scheme?.lowercased(),
                  !["http", "https", "file", "javascript", "data", "about"].contains(scheme) else {
                Logger.misc.error("Rejected certificate export to web or unsafe URL scheme")
                return
            }
            
            UIApplication.shared.open(callbackUrl)
        }
        
        let certificates = Storage.shared.getAllCertificates()
        guard !certificates.isEmpty else { return }
        
        DispatchQueue.main.async {
            var selectionActions: [UIAlertAction] = []
            
            for cert in certificates {
                var title: String
                let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
                
                title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")
                
                if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
                    title = "🐞 \(title)"
                }
                
                let selectAction = UIAlertAction(title: title, style: .default) { _ in
                    performExport(for: cert)
                }
                selectionActions.append(selectAction)
            }
            
            UIAlertController.showAlertWithCancel(
                title: .localized("Export Certificate"),
                message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
                style: .alert,
                actions: selectionActions
            )
        }
    }

    /// Filters repository URLs through `SourceURLPolicy` so batch imports
    /// cannot bypass the transport rules enforced by `FR.handleSource`.
    static func validatedRepositoryURLs(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            do {
                try SourceURLPolicy.validate(url)
                return true
            } catch {
                Logger.security.warning("Skipping insecure repository: \(url.absoluteString, privacy: .public)")
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