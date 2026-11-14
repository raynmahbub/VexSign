import Foundation

struct FileWorkspaceRoots {
    let documents: URL
    let downloads: URL
    let archives: URL
    let certificates: URL
    let signed: URL
    let unsigned: URL
    let tweaks: URL
}

struct FileStorageUsage: Equatable {
    let used: Int64?
    let available: Int64?
}

enum FileLibraryOwner {
    case app(LibraryAppRecord)
    case certificate(CertificateRecord)
}

/// File URLs are display/selection values. Only this port interprets them or
/// touches disk, including protected-root migration and security-scoped imports.
@MainActor
protocol FileWorkspaceProviding: AnyObject {
    func sha256(of url: URL) async -> String?
    func matchesHash(_ url: URL, expected: String) async -> Bool
    func documentBytes() async -> Int64
    func iconData(named name: String) -> Data?
    func volumeCapacity(for key: URLResourceKey) -> Int64
    var roots: FileWorkspaceRoots { get }
    func usage() -> FileStorageUsage
    func usageChanges() -> AsyncStream<FileStorageUsage>
    func children(of directory: URL, includesHidden: Bool, measuringDirectorySize: Bool) async -> [IPAFileEntry]
    func entry(at url: URL) -> IPAFileEntry
    func kind(of url: URL, isDirectory: Bool) -> IPAFileKind
    func attributes(at url: URL) -> [FileAttributeKey: Any]
    func text(at url: URL) -> String?
    func plistText(at url: URL) -> String?
    func plist(at url: URL) -> Any?
    func data(at url: URL) -> Data?
    func head(of url: URL, count: Int) -> Data?
    func names(at directory: URL) -> [String]
    func count(at directory: URL) -> Int
    func size(at url: URL) -> Int64
    func exists(at url: URL, directory: Bool) -> Bool
    func inspect(at url: URL) async -> MachOInspector.Inspection
    func summary(at appURL: URL) -> IPABundleSummary
    func owner(of url: URL) -> FileLibraryOwner?
    func isInsideLibraryFolder(_ url: URL) -> Bool
    func deletionWarning(for urls: [URL]) -> String?
    func createFolder(named name: String, in directory: URL) -> URL?
    func createTextFile(named name: String, in directory: URL) -> URL?
    func importFiles(_ urls: [URL], into directory: URL) -> Int
    func rename(_ url: URL, to name: String) -> URL?
    func duplicate(_ url: URL) -> URL?
    func move(_ url: URL, into directory: URL) -> URL?
    func delete(_ urls: [URL]) -> Int
    func removeOfferingUndo(_ url: URL, onChange: @escaping () -> Void)
    func save(data: Data, to url: URL) throws
    func write(plist: Any, to url: URL) -> Bool
    func share(_ url: URL)
    func export(_ urls: [URL])
    func copyPath(_ url: URL)
    func sendToTweakManager(_ url: URL)
    func stagePackage(_ url: URL) throws -> URL
    func shareText(_ text: String, fileName: String) throws
}
