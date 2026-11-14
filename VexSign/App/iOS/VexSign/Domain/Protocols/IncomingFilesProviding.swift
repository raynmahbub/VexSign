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

@MainActor
protocol RoutingDiagnosticsProviding: AnyObject {
    func warning(_ message: String, security: Bool)
    func info(_ message: String)
    func report(_ error: Error)
    func userMessage(for error: Error) -> String
}
