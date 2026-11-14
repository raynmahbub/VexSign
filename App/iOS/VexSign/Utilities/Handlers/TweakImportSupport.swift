import Foundation
import NimbleExtensions

/// Validate untrusted picker/provider inputs before copying or native parsing.
/// A single library is also checked against `TweakCompatibility`, so one that no app could
/// load is refused here rather than at signing. Packages and bundles are checked when they
/// are unpacked for injection. Passing is not a guarantee that a tweak works.
enum TweakImportSupport {
    static let maximumBytes: Int64 = 512 * 1024 * 1024
    static let maximumEntries = 10_000

    enum Failure: LocalizedError {
        case unsupported, unsafe, tooLarge, invalidHeader
        /// The library cannot be loaded by a sideloaded app; carries the reason.
        case incompatible(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return String.localized("Choose a dylib, Debian package, framework, bundle or app extension.")
            case .unsafe: return String.localized("The tweak contains a missing, unreadable or unsafe file.")
            case .tooLarge: return String.localized("The tweak exceeds the safe import limit of 512 MiB or 10,000 files.")
            case .invalidHeader: return String.localized("The selected file is not a supported Mach-O library or Debian package.")
            case .incompatible(let reason): return reason
            }
        }
    }

    static func validate(_ source: URL, maximumBytes: Int64 = TweakImportSupport.maximumBytes) throws {
        try Task.checkCancellation()
        let ext = source.pathExtension.lowercased()
        let directory = ["framework", "bundle", "appex"].contains(ext)
        guard directory || ["dylib", "deb"].contains(ext) else { throw Failure.unsupported }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey]
        let root = try source.resourceValues(forKeys: keys)
        guard root.isSymbolicLink != true, root.isReadable == true,
              directory ? root.isDirectory == true : root.isRegularFile == true,
              maximumBytes >= 0 else { throw Failure.unsafe }
        var total: Int64 = 0
        func countFile(_ values: URLResourceValues) throws {
            guard values.isSymbolicLink != true, values.isReadable == true else { throw Failure.unsafe }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0,
                      Int64(size) <= maximumBytes - total else { throw Failure.tooLarge }
                total += Int64(size)
            } else if values.isDirectory != true { throw Failure.unsafe }
        }
        try countFile(root)
        if directory {
            var walkError: Error?
            guard let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                walkError = error
                return false
            }) else { throw Failure.unsafe }
            var count = 0
            for case let child as URL in walker {
                try Task.checkCancellation()
                count += 1
                guard count <= maximumEntries else { throw Failure.tooLarge }
                try countFile(child.resourceValues(forKeys: keys))
            }
            if let walkError { throw walkError }
        } else {
            let handle = try FileHandle(forReadingFrom: source)
            defer {
                do { try handle.close() }
                catch { FileLogger.log("Could not close tweak input: \(error)", category: "tweaks") }
            }
            let header = try handle.read(upToCount: 32) ?? Data()
            if ext == "deb" {
                guard header.starts(with: Data("!<arch>\n".utf8)) else { throw Failure.invalidHeader }
            } else {
                let thin = MachOReader.u32(header, at: 0, bigEndian: false)
                let fat = MachOReader.u32(header, at: 0, bigEndian: true)
                guard header.count >= 32,
                      thin == MachOReader.machO64 || thin == MachOReader.machO64Swapped ||
                      fat == MachOReader.fat || fat == MachOReader.fat64 else { throw Failure.invalidHeader }
                // The same rules signing enforces. Advisory findings do not stop an import.
                let findings = TweakCompatibility.evaluate(binary: MachOInspector.inspect(fileAt: source))
                if let blocking = findings.first(where: \.isBlocking) {
                    throw Failure.incompatible(blocking.message)
                }
            }
        }
    }

    /// Resolve only bundle-local libraries; a crafted load command must not expose
    /// arbitrary files through the browser's Share / Send to Tweak Manager menu.
    static func resolvedDylibURL(_ load: String, in appRoot: URL) -> URL? {
        guard !load.contains("\u{0}") else { return nil }
        let candidate: URL
        if load.hasPrefix("@rpath/") {
            candidate = appRoot.appendingPathComponent("Frameworks").appendingPathComponent(String(load.dropFirst("@rpath/".count)))
        } else if load.hasPrefix("@executable_path/") {
            candidate = appRoot.appendingPathComponent(String(load.dropFirst("@executable_path/".count)))
        } else { return nil }
        return containedRegularFile(candidate, in: appRoot)
    }

    static func containedRegularFile(_ candidate: URL, in appRoot: URL) -> URL? {
        let root = appRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else { return nil }
        do {
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? resolved : nil
        } catch { return nil } // A missing/unreadable browser item has no export action.
    }

    /// URLSession's async download owns the temporary file; this delegate only
    /// enforces transfer limits and refuses HTTPS-to-HTTP redirects.
    final class DownloadLimit: NSObject, URLSessionDownloadDelegate {
        let maximumBytes: Int64
        init(maximumBytes: Int64) { self.maximumBytes = maximumBytes; super.init() }

        static func shouldCancel(written: Int64, expected: Int64, maximum: Int64) -> Bool {
            maximum <= 0 || written < 0 || written > maximum || expected > maximum
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            if Self.shouldCancel(written: totalBytesWritten, expected: totalBytesExpectedToWrite, maximum: maximumBytes) {
                downloadTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The async download API returns and owns this location, not this delegate.
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }

    static func repositoryFilename(for url: URL) -> String? {
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\u{0}"),
              name.utf8.count <= 200 else { return nil }
        return url.pathExtension.isEmpty ? name + ".dylib" : name
    }

    static func stage(_ sources: [URL]) async throws -> [URL] {
        let worker = Task.detached(priority: .userInitiated) { () throws -> [URL] in
            var staged: [URL] = []
            do {
                for source in sources {
                    try Task.checkCancellation()
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    try validate(source)
                    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("VexSignTweak_\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    let destination = parent.appendingPathComponent(source.lastPathComponent)
                    staged.append(destination) // Own cleanup even if copy fails partway.
                    try FileManager.default.copyItem(at: source, to: destination)
                    try validate(destination)
                }
                try Task.checkCancellation()
                return staged
            } catch {
                discard(staged)
                throw error
            }
        }
        let staged = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        if Task.isCancelled {
            discard(staged)
            throw CancellationError()
        }
        return staged
    }

    struct PreparedVersion: Sendable {
        struct File: Sendable { let name: String; let size: Int64 }
        let directory: URL
        let files: [File]
    }

    /// Copy/validate provider files and assemble a version off the UI thread.
    /// Commit is then one same-container directory rename, not another large copy.
    static func prepareVersion(_ sources: [URL]) async throws -> PreparedVersion {
        let staged = try await stage(sources)
        defer { discard(staged) }
        let worker = Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("VexSignTweak_\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                var files: [PreparedVersion.File] = []
                var taken = Set<String>()
                for source in staged {
                    try Task.checkCancellation()
                    let stem = source.deletingPathExtension().lastPathComponent
                    let ext = source.pathExtension
                    var name = source.lastPathComponent
                    var suffix = 2
                    while taken.contains(name.lowercased()) {
                        name = "\(stem) \(suffix).\(ext)"
                        suffix += 1
                    }
                    let destination = directory.appendingPathComponent(name)
                    try fm.moveItem(at: source, to: destination)
                    files.append(.init(name: name, size: fm.allocatedSize(at: destination)))
                    taken.insert(name.lowercased())
                }
                try Task.checkCancellation()
                return PreparedVersion(directory: directory, files: files)
            } catch {
                discard([directory.appendingPathComponent("cleanup")])
                throw error
            }
        }
        let prepared = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        if Task.isCancelled {
            discardPrepared(prepared)
            throw CancellationError()
        }
        return prepared
    }

    static func discardPrepared(_ prepared: PreparedVersion) {
        guard FileManager.default.fileExists(atPath: prepared.directory.path) else { return }
        discard([prepared.directory.appendingPathComponent("cleanup")])
    }

    static func discard(_ urls: [URL]) {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        for url in urls {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard parent.lastPathComponent.hasPrefix("VexSignTweak_"),
                  parent.deletingLastPathComponent().path == temporary.path else { continue }
            do { try FileManager.default.removeItem(at: parent) }
            catch { FileLogger.log("Could not remove temporary tweak import: \(error)", category: "tweaks") }
        }
    }
}
