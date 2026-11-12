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

    /// Applies premium auth and catalog filtering to the sources that need it.
    static func fetchRepositories(from urls: [URL]) async -> [(url: URL, data: ASRepository)] {
        let requests: [(url: URL, request: URL, headers: [String: String])] = await MainActor.run {
            urls.map { ($0, VexSignAPI.catalogURL(for: $0), VexSignAPI.authHeaders(for: $0)) }
        }

        let service = NBFetchService()

        return await withTaskGroup(of: (URL, ASRepository?).self) { group in
            for item in requests {
                group.addTask {
                    let repository: ASRepository? = await withCheckedContinuation { continuation in
                        service.fetch(from: item.request, headers: item.headers) { (result: Result<ASRepository, Error>) in
                            switch result {
                            case .success(let repository):
                                continuation.resume(returning: repository)
                            case .failure(let error):
                                Logger.misc.error("Failed to fetch \(item.url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                continuation.resume(returning: nil)
                            }
                        }
                    }
                    return (item.url, repository)
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