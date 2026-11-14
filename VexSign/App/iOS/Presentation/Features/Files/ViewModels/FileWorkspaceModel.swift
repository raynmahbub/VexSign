import Foundation
import Combine

@MainActor
final class FileWorkspaceModel: ObservableObject {
    @Published private(set) var usage: FileStorageUsage
    private let useCase: FileWorkspaceUseCase
    private var observation: Task<Void, Never>?
    init(useCase: FileWorkspaceUseCase) {
        self.useCase = useCase; usage = useCase.usage()
        let changes = useCase.usageChanges()
        observation = Task { @MainActor [weak self] in
            for await usage in changes {
                guard !Task.isCancelled, let self else { break }
                self.usage = usage
            }
        }
    }
    deinit { observation?.cancel() }
    func sha256(of url: URL) async -> String? { await useCase.sha256(of: url) }
    func matchesHash(_ url: URL, expected: String) async -> Bool { await useCase.matchesHash(url, expected: expected) }
    func documentBytes() async -> Int64 { await useCase.documentBytes() }
    func iconData(named name: String) -> Data? { useCase.iconData(named: name) }
    func volumeCapacity(for key: URLResourceKey) -> Int64 { useCase.volumeCapacity(for: key) }
    var roots: FileWorkspaceRoots { useCase.roots }
    func children(of directory: URL, includesHidden: Bool = false, measuringDirectorySize: Bool = true) async -> [IPAFileEntry] {
        await useCase.children(of: directory, includesHidden: includesHidden, measuringDirectorySize: measuringDirectorySize)
    }
    func entry(at url: URL) -> IPAFileEntry { useCase.entry(at: url) }
    func kind(of url: URL, isDirectory: Bool) -> IPAFileKind { useCase.kind(of: url, isDirectory: isDirectory) }
    func attributes(at url: URL) -> [FileAttributeKey: Any] { useCase.attributes(at: url) }
    func text(at url: URL) -> String? { useCase.text(at: url) }
    func plistText(at url: URL) -> String? { useCase.plistText(at: url) }
    func plist(at url: URL) -> Any? { useCase.plist(at: url) }
    func data(at url: URL) -> Data? { useCase.data(at: url) }
    func head(of url: URL, count: Int) -> Data? { useCase.head(of: url, count: count) }
    func names(at directory: URL) -> [String] { useCase.names(at: directory) }
    func count(at directory: URL) -> Int { useCase.count(at: directory) }
    func size(at url: URL) -> Int64 { useCase.size(at: url) }
    func exists(at url: URL, directory: Bool = false) -> Bool { useCase.exists(at: url, directory: directory) }
    func inspect(at url: URL) async -> MachOInspector.Inspection { await useCase.inspect(at: url) }
    func summary(at appURL: URL) -> IPABundleSummary { useCase.summary(at: appURL) }
    func owner(of url: URL) -> FileLibraryOwner? { useCase.owner(of: url) }
    func isInsideLibraryFolder(_ url: URL) -> Bool { useCase.isInsideLibraryFolder(url) }
    func deletionWarning(for urls: [URL]) -> String? { useCase.deletionWarning(for: urls) }
    @discardableResult func createFolder(named name: String, in directory: URL) -> URL? { useCase.createFolder(named: name, in: directory) }
    @discardableResult func createTextFile(named name: String, in directory: URL) -> URL? { useCase.createTextFile(named: name, in: directory) }
    @discardableResult func importFiles(_ urls: [URL], into directory: URL) -> Int { useCase.importFiles(urls, into: directory) }
    @discardableResult func rename(_ url: URL, to name: String) -> URL? { useCase.rename(url, to: name) }
    @discardableResult func duplicate(_ url: URL) -> URL? { useCase.duplicate(url) }
    @discardableResult func move(_ url: URL, into directory: URL) -> URL? { useCase.move(url, into: directory) }
    @discardableResult func delete(_ urls: [URL]) -> Int { useCase.delete(urls) }
    func removeOfferingUndo(_ url: URL, onChange: @escaping () -> Void) { useCase.removeOfferingUndo(url, onChange: onChange) }
    func save(data: Data, to url: URL) throws { try useCase.save(data: data, to: url) }
    func write(plist: Any, to url: URL) -> Bool { useCase.write(plist: plist, to: url) }
    func share(_ url: URL) { useCase.share(url) }
    func export(_ urls: [URL]) { useCase.export(urls) }
    func copyPath(_ url: URL) { useCase.copyPath(url) }
    func sendToTweakManager(_ url: URL) { useCase.sendToTweakManager(url) }
    func shareText(_ text: String, fileName: String) throws { try useCase.shareText(text, fileName: fileName) }
    func isTweakArchive(_ url: URL) -> Bool { useCase.isTweakArchive(url) }
}
