import Foundation
import NimbleExtensions

/// Owns security-scoped URL access, NSFileCoordinator, and disposable directories.
@MainActor
final class CoordinatedIncomingFilesAdapter: IncomingFilesProviding {
    private let diagnostics: RoutingDiagnosticsProviding
    init(diagnostics: RoutingDiagnosticsProviding) { self.diagnostics = diagnostics }

    func temporaryDirectory(label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)_\(UUID().uuidString)", isDirectory: true)
    }

    func copyCoordinatedFile(from url: URL, to destinationURL: URL, tempDirectory: URL) -> Result<Void, CoordinatedFileCopyFailure> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { sourceURL in
            do {
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let error = copyError {
            return .failure(CoordinatedFileCopyFailure(message: "Could not copy the shared file into the app.\n\nFile: \(url.lastPathComponent)\nReason: \(error.localizedDescription)"))
        }
        if let error = coordinatorError {
            return .failure(CoordinatedFileCopyFailure(message: "Could not read the shared file. The other app may have denied access.\n\nFile: \(url.lastPathComponent)\nReason: \(error.localizedDescription)"))
        }
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return .failure(CoordinatedFileCopyFailure(message: "The shared file could not be copied into the app. It may be inaccessible, or storage may be full.\n\nFile: \(url.lastPathComponent)"))
        }
        return .success(())
    }

    func removeTemporaryDirectory(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            diagnostics.warning(
                "Could not remove temporary directory \(url.lastPathComponent): \(error.localizedDescription)",
                security: false
            )
        }
    }
}
