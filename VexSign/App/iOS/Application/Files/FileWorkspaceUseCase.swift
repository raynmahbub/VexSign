import Foundation

@MainActor
final class FileWorkspaceUseCase {
    private let provider: FileWorkspaceProviding
    init(provider: FileWorkspaceProviding) { self.provider = provider }
    func sha256(of url: URL) async -> String? { await provider.sha256(of: url) }
    func matchesHash(_ url: URL, expected: String) async -> Bool { await provider.matchesHash(url, expected: expected) }
    func documentBytes() async -> Int64 { await provider.documentBytes() }
    func iconData(named name: String) -> Data? { provider.iconData(named: name) }
    func volumeCapacity(for key: URLResourceKey) -> Int64 { provider.volumeCapacity(for: key) }
    var roots: FileWorkspaceRoots { provider.roots }
    func usage() -> FileStorageUsage { provider.usage() }
    func usageChanges() -> AsyncStream<FileStorageUsage> { provider.usageChanges() }
    func children(of directory: URL, includesHidden: Bool = false, measuringDirectorySize: Bool = true) async -> [IPAFileEntry] {
        await provider.children(of: directory, includesHidden: includesHidden, measuringDirectorySize: measuringDirectorySize)
    }
    func entry(at url: URL) -> IPAFileEntry { provider.entry(at: url) }
    func kind(of url: URL, isDirectory: Bool) -> IPAFileKind { provider.kind(of: url, isDirectory: isDirectory) }
    func attributes(at url: URL) -> [FileAttributeKey: Any] { provider.attributes(at: url) }
    func text(at url: URL) -> String? { provider.text(at: url) }
    func plistText(at url: URL) -> String? { provider.plistText(at: url) }
    func plist(at url: URL) -> Any? { provider.plist(at: url) }
    func data(at url: URL) -> Data? { provider.data(at: url) }
    func head(of url: URL, count: Int) -> Data? { provider.head(of: url, count: max(0, min(count, 65_536))) }
    func names(at directory: URL) -> [String] { provider.names(at: directory) }
    func count(at directory: URL) -> Int { provider.count(at: directory) }
    func size(at url: URL) -> Int64 { provider.size(at: url) }
    func exists(at url: URL, directory: Bool = false) -> Bool { provider.exists(at: url, directory: directory) }
    func inspect(at url: URL) async -> MachOInspector.Inspection { await provider.inspect(at: url) }
    func summary(at appURL: URL) -> IPABundleSummary { provider.summary(at: appURL) }
    func owner(of url: URL) -> FileLibraryOwner? { provider.owner(of: url) }
    func isInsideLibraryFolder(_ url: URL) -> Bool { provider.isInsideLibraryFolder(url) }
    func deletionWarning(for urls: [URL]) -> String? { provider.deletionWarning(for: urls) }
    func createFolder(named name: String, in directory: URL) -> URL? { provider.createFolder(named: name, in: directory) }
    func createTextFile(named name: String, in directory: URL) -> URL? { provider.createTextFile(named: name, in: directory) }
    func importFiles(_ urls: [URL], into directory: URL) -> Int { provider.importFiles(uniqueInOrder(urls), into: directory) }
    func rename(_ url: URL, to name: String) -> URL? { provider.rename(url, to: name) }
    func duplicate(_ url: URL) -> URL? { provider.duplicate(url) }
    func move(_ url: URL, into directory: URL) -> URL? { provider.move(url, into: directory) }
    func delete(_ urls: [URL]) -> Int { provider.delete(uniqueInOrder(urls)) }
    func removeOfferingUndo(_ url: URL, onChange: @escaping () -> Void) { provider.removeOfferingUndo(url, onChange: onChange) }
    func save(data: Data, to url: URL) throws { try provider.save(data: data, to: url) }
    func write(plist: Any, to url: URL) -> Bool { provider.write(plist: plist, to: url) }
    func share(_ url: URL) { provider.share(url) }
    func export(_ urls: [URL]) { provider.export(urls) }
    func copyPath(_ url: URL) { provider.copyPath(url) }
    func sendToTweakManager(_ url: URL) { provider.sendToTweakManager(url) }
    func stagePackage(_ url: URL) throws -> URL { try provider.stagePackage(url) }
    func shareText(_ text: String, fileName: String) throws { try provider.shareText(text, fileName: fileName) }
    private func uniqueInOrder(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
    /// Matches `FileManagerActions.isTweakArchive`: a `.tipa` is an app package.
    func isTweakArchive(_ url: URL) -> Bool { ["dylib", "deb", "framework", "bundle"].contains(url.pathExtension.lowercased()) }
}
