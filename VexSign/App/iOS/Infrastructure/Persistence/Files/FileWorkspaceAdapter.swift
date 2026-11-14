import Foundation
import Combine
import NimbleExtensions

@MainActor
final class FileWorkspaceAdapter: FileWorkspaceProviding {
    private let repository: CoreDataWorkspaceRepository
    private let sharing: TemporaryFileSharing
    init(repository: CoreDataWorkspaceRepository, sharing: TemporaryFileSharing) {
        self.repository = repository; self.sharing = sharing
    }
    func sha256(of url: URL) async -> String? {
        guard !Task.isCancelled else { return nil }
        let lease: AppOperationRegistry.Lease
        do { lease = try AppOperationRegistry.shared.acquireTemporaryWork() }
        catch { FileLogger.error("File digest refused during cleanup.", category: "files"); return nil }
        defer { withExtendedLifetime(lease) {} }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let worker = Task.detached(priority: .utility) {
            do { return try FileIntegrity.sha256(of: url, cancellationCheck: { try Task.checkCancellation() }) }
            catch { return nil as String? } // A cancelled digest is never published as a hash.
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        return Task.isCancelled ? nil : result
    }
    func matchesHash(_ url: URL, expected: String) async -> Bool {
        guard let actual = await sha256(of: url), !Task.isCancelled else { return false }
        return actual == FileIntegrity.normalize(expected)
    }
    func documentBytes() async -> Int64 {
        let directory = URL.documentsDirectory
        let worker = Task.detached(priority: .utility) {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return Int64(0) }
            var total: Int64 = 0
            while let url = files.nextObject() as? URL {
                if Task.isCancelled { break }
                if let value = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), value.isRegularFile == true { total += Int64(value.fileSize ?? 0) } // try? ok: optional file preview/metadata or owner lookup is unavailable, not a successful mutation
            }
            return total
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
    func iconData(named name: String) -> Data? {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent("Icons").appendingPathComponent(name)) // try? ok: optional file preview/metadata or owner lookup is unavailable, not a successful mutation
    }
    func volumeCapacity(for key: URLResourceKey) -> Int64 {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [key])
            switch key {
            case .volumeTotalCapacityKey: return Int64(values.volumeTotalCapacity ?? 0)
            case .volumeAvailableCapacityKey: return Int64(values.volumeAvailableCapacity ?? 0)
            default: return 0
            }
        } catch {
            FileLogger.warn("Failed to read volume metadata (\(key.rawValue)): \(error.localizedDescription)", category: "diagnostics")
            return 0
        }
    }
    var roots: FileWorkspaceRoots {
        let fm = FileManager.default
        // `certificates` performs the existing protected-directory migration.
        return FileWorkspaceRoots(documents: URL.documentsDirectory, downloads: fm.downloadStaging,
            archives: fm.archives, certificates: fm.certificates, signed: fm.signed, unsigned: fm.unsigned, tweaks: fm.tweaksLibrary)
    }
    func usage() -> FileStorageUsage {
        FileStorageUsage(used: StorageManager.shared.report?.total,
            available: FileManager.default.availableImportantCapacity(at: URL.documentsDirectory))
    }
    func usageChanges() -> AsyncStream<FileStorageUsage> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(usage())
            let subscription = StorageManager.shared.$report.sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    continuation.yield(self.usage())
                }
            }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    func children(of directory: URL, includesHidden: Bool, measuringDirectorySize: Bool) async -> [IPAFileEntry] {
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [IPAFileEntry]() }
            return IPAFileLoader.children(of: directory, includesHidden: includesHidden, measuringDirectorySize: measuringDirectorySize)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
    func entry(at url: URL) -> IPAFileEntry { IPAFileLoader.entry(at: url) }
    func kind(of url: URL, isDirectory: Bool) -> IPAFileKind { IPAFileLoader.kind(of: url, isDirectory: isDirectory) }
    func attributes(at url: URL) -> [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:] } // try? ok: optional file preview/metadata or owner lookup is unavailable, not a successful mutation
    func text(at url: URL) -> String? { IPAFileLoader.text(at: url) }
    func plistText(at url: URL) -> String? { IPAFileLoader.plistText(at: url) }
    func plist(at url: URL) -> Any? { IPAFileLoader.plist(at: url) }
    func data(at url: URL) -> Data? { try? Data(contentsOf: url) } // try? ok: optional file preview/metadata or owner lookup is unavailable, not a successful mutation
    func head(of url: URL, count: Int) -> Data? { IPAFileLoader.head(of: url, count: count) }
    func names(at directory: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] } // try? ok: optional file preview/metadata or owner lookup is unavailable, not a successful mutation
    func count(at directory: URL) -> Int { names(at: directory).count }
    func size(at url: URL) -> Int64 { FileManager.default.allocatedSize(at: url) }
    func exists(at url: URL, directory: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && (!directory || isDirectory.boolValue)
    }
    func inspect(at url: URL) async -> MachOInspector.Inspection {
        await Task.detached(priority: .userInitiated) { MachOInspector.inspect(fileAt: url) }.value
    }
    func summary(at appURL: URL) -> IPABundleSummary { IPABundleSummary.read(at: appURL) }
    func owner(of url: URL) -> FileLibraryOwner? {
        switch FileManagerActions.owner(of: url) {
        case .app(let app): return (try? repository.appRecord(app)).map(FileLibraryOwner.app) // try? ok: optional file preview/metadata or owner lookup is unavailable, not a successful mutation
        case .certificate(let certificate): return .certificate(repository.certificateRecord(certificate))
        case nil: return nil
        }
    }
    func isInsideLibraryFolder(_ url: URL) -> Bool { FileManagerActions.isInsideLibraryFolder(url) }
    func deletionWarning(for urls: [URL]) -> String? { FileManagerActions.deletionWarning(for: urls) }
    func createFolder(named name: String, in directory: URL) -> URL? { FileManagerActions.createFolder(named: name, in: directory) }
    func createTextFile(named name: String, in directory: URL) -> URL? { FileManagerActions.createTextFile(named: name, in: directory) }
    func importFiles(_ urls: [URL], into directory: URL) -> Int { FileManagerActions.importFiles(urls, into: directory) }
    func rename(_ url: URL, to name: String) -> URL? { FileManagerActions.rename(url, to: name) }
    func duplicate(_ url: URL) -> URL? { FileManagerActions.duplicate(url) }
    func move(_ url: URL, into directory: URL) -> URL? { FileManagerActions.move(url, into: directory) }
    func delete(_ urls: [URL]) -> Int { FileManagerActions.delete(urls) }
    func removeOfferingUndo(_ url: URL, onChange: @escaping () -> Void) { RecoverableFileRemoval.removeOfferingUndo(url, onChange: onChange) }
    func save(data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
    func write(plist: Any, to url: URL) -> Bool { IPAFileLoader.write(plist: plist, to: url) }
    func share(_ url: URL) { FileManagerActions.share(url) }
    func export(_ urls: [URL]) { FileManagerActions.export(urls) }
    func copyPath(_ url: URL) { FileManagerActions.copyPath(url) }
    func sendToTweakManager(_ url: URL) { FileManagerActions.sendToTweakManager(url) }
    func stagePackage(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.downloadStaging
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = FileManagerActions.uniqueURL(for: url.lastPathComponent, in: directory)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }
    func shareText(_ text: String, fileName: String) throws {
        let lease = try AppOperationRegistry.shared.acquireTemporaryWork()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: fileName).lastPathComponent
        let url = directory.appendingPathComponent(name.isEmpty ? "Export.txt" : name)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try sharing.shareFile(url) {
                defer { withExtendedLifetime(lease) {} }
                do { try FileManager.default.removeItem(at: directory) }
                catch { FileLogger.error("Could not remove temporary text export.", category: "files") }
            }
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { FileLogger.error("Could not remove failed text export.", category: "files") }
            throw error
        }
    }
}
