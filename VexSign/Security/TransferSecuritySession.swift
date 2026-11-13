import Foundation

/// Executes one-off file downloads (direct-install IPAs, firmware IPSWs) through
/// `PackageDownloadRedirectDelegate` + HTTP 2xx validation + explicit byte caps
/// instead of bare `URLSession.shared.download(from:)`.
enum TransferSecuritySession {
    static func download(
        url: URL,
        maximumBytes: Int64?,
        requestTimeout: TimeInterval = 60,
        applyAuthHeaders: Bool = false
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if applyAuthHeaders {
            VexSignAPI.applyAuthHeaders(to: &request)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        let redirectDelegate = PackageDownloadRedirectDelegate(maximumBytes: maximumBytes)
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: request, delegate: redirectDelegate)
        } catch {
            if redirectDelegate.didExceedLimit {
                throw PackageDownloadURLPolicy.Failure.packageTooLarge
            }
            throw error
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard DownloadIntegrity.isAcceptableHTTPStatus(status) else {
            removeTemporaryFile(at: tempURL)
            throw ArchitectureDomainError.httpError(statusCode: status)
        }

        let fileSize = (try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            removeTemporaryFile(at: tempURL)
            throw ArchitectureDomainError.emptyDownloadPayload
        }

        if let maximumBytes, fileSize > maximumBytes {
            removeTemporaryFile(at: tempURL)
            throw ArchitectureDomainError.transferSizeExceeded(limitBytes: maximumBytes)
        }

        return tempURL
    }

    private static func removeTemporaryFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            SubsystemDiagnosticsLog.warn(
                "Could not remove rejected download artifact: \(error.localizedDescription)",
                subsystem: .network
            )
        }
    }
}
