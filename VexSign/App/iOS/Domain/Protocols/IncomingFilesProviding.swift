import Foundation

struct CoordinatedFileCopyFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol IncomingFilesProviding: AnyObject {
    func temporaryDirectory(label: String) -> URL
    func copyCoordinatedFile(from source: URL, to destination: URL, tempDirectory: URL) -> Result<Void, CoordinatedFileCopyFailure>
    func removeTemporaryDirectory(_ url: URL)
}

extension IncomingFilesProviding {
    /// Removes one staged file under a temporary directory.
    ///
    /// Same removal path as `removeTemporaryDirectory`, but the name says what the caller is
    /// doing: a deep-link import stages a `.p12` outside this layer and must delete it without
    /// reaching for `FileManager` from an application use case.
    func discardTemporaryFile(_ url: URL) {
        removeTemporaryDirectory(url)
    }
}

@MainActor
protocol RoutingDiagnosticsProviding: AnyObject {
    func warning(_ message: String, security: Bool)
    func info(_ message: String)
    func report(_ error: Error)
    func userMessage(for error: Error) -> String
}
