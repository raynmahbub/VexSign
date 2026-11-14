//
//  PackageDownloadURLPolicy.swift
//  VexSign
//
//  Package links come from untrusted repository feeds. Keep them on a supported
//  transport and prevent a TLS-protected request from being downgraded by redirect.
//

import Foundation
import NimbleExtensions
import NimbleJSON

/// Transport policy for repository-provided IPA and update URLs.
enum PackageDownloadURLPolicy {
    enum Failure: LocalizedError {
        case unsupportedURL
        case packageTooLarge
        case insecureTransport
        case redirectDowngrade

        var errorDescription: String? {
            switch self {
            case .unsupportedURL:
                return String.localized("The package URL is invalid or uses an unsupported scheme.")
            case .packageTooLarge:
                return String.localized("The package is larger than the 8 GiB safety limit.")
            case .insecureTransport:
                return String.localized("Package downloads must use HTTPS. Plain HTTP is only available for a package on your local network, and only after enabling 'Allow Insecure HTTP Sources' in Settings → Security.")
            case .redirectDowngrade:
                return String.localized("The package download tried to redirect from HTTPS to an insecure connection, so it was blocked.")
            }
        }
    }

    /// Validate the URL before starting either a new or resumed package task.
    static func validateInitialURL(_ url: URL) throws {
        guard hasValidAuthority(url) else { throw Failure.unsupportedURL }
        switch url.scheme?.lowercased() {
        case "https":
            return
        case "http" where SourceURLPolicy.allowInsecureHTTP && SourceURLPolicy.isLocalNetworkHost(url):
            return
        case "http":
            throw Failure.insecureTransport
        default:
            throw Failure.unsupportedURL
        }
    }

    /// Validate a proposed redirect relative to the URL that produced it.
    /// HTTPS can never be downgraded, even when local HTTP sources are opted in.
    static func permitsRedirect(from source: URL?, to destination: URL) -> Bool {
        guard hasValidAuthority(destination) else { return false }
        guard let destinationScheme = destination.scheme?.lowercased() else { return false }

        switch destinationScheme {
        case "https":
            return true
        case "http":
            // The opt-in is a LAN convenience: it must not carry a public package URL,
            // and it must not be reached by downgrading an HTTPS request either.
            guard SourceURLPolicy.allowInsecureHTTP,
                  SourceURLPolicy.isLocalNetworkHost(destination) else { return false }
            return source?.scheme?.lowercased() == "http"
        default:
            return false
        }
    }

    /// Keep premium API/device credentials on their original origin only. Some
    /// URLSession implementations preserve custom headers across redirects.
    static func redirectRequest(from source: URL?, to request: URLRequest) -> URLRequest? {
        guard let destination = request.url,
              permitsRedirect(from: source, to: destination) else { return nil }
        return NBFetchService.safeRedirectRequest(from: source, to: request)
    }

    private static func hasValidAuthority(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}

/// Shared redirect delegate for URLSession transfers of untrusted package files.
final class PackageDownloadRedirectDelegate: NSObject, URLSessionDownloadDelegate {
    private let maximumBytes: Int64?
    private let sizeLock = NSLock()
    private var _didExceedLimit = false

    init(maximumBytes: Int64? = nil) {
        self.maximumBytes = maximumBytes
        super.init()
    }

    var didExceedLimit: Bool {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return _didExceedLimit
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let maximumBytes,
              DownloadIntegrity.transferExceedsPackageLimit(
                expectedBytes: min(totalBytesExpectedToWrite, maximumBytes + 1),
                receivedBytes: totalBytesWritten
              ) else { return }
        sizeLock.lock()
        _didExceedLimit = true
        sizeLock.unlock()
        downloadTask.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async download API returns and owns this location, not this delegate. Required by
        // URLSessionDownloadDelegate, which this class conforms to so that the size limit in
        // `didWriteData` is actually delivered for a download task.
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let safeRequest = PackageDownloadURLPolicy.redirectRequest(from: response.url, to: request) else {
            completionHandler(nil)
            return
        }
        completionHandler(safeRequest)
    }
}
