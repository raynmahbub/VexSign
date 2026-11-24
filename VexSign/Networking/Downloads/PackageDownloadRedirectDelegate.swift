//
//  PackageDownloadRedirectDelegate.swift
//  VexSign
//
//  Shared redirect delegate for URLSession transfers of untrusted package files.
//  Enforces the package size cap mid-stream and refuses TLS downgrades on
//  redirect. The URL policy itself lives in Security (Policies); this is the
//  transport half of that policy.

import Foundation

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
