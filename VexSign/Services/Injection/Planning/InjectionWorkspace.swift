// MARK: - Isolated temporary storage for modification attempts
//
// Every staged package or configuration lives under a unique, owned directory.
// The original IPA in the library is never written to. A failed or cancelled
// attempt removes only what it created.

import Foundation

actor InjectionWorkspace {
    enum WorkspaceError: Error, LocalizedError, Equatable {
        case alreadyCommitted
        case unsafeDirectory

        var errorDescription: String? {
            switch self {
            case .alreadyCommitted: "This modification workspace has already been finished."
            case .unsafeDirectory: "The temporary workspace failed its ownership check."
            }
        }
    }

    private(set) var directory: URL
    private let fileManager: FileManager
    private var finished = false

    init(label: String = "VexSignInjection", fileManager: FileManager = .default) throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("\(label)_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        guard CleanupRemovalPolicy.isSafeDirectory(root, beneath: fileManager.temporaryDirectory) else {
            try? fileManager.removeItem(at: root) // try? ok: refusing an unsafe directory cannot depend on cleanup
            throw WorkspaceError.unsafeDirectory
        }
        self.directory = root
        self.fileManager = fileManager
    }

    func subdirectory(_ name: String) throws -> URL {
        guard name.utf8.count <= 128,
              !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              name != ".", name != ".." else { throw WorkspaceError.unsafeDirectory }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stage(_ source: URL, as name: String) throws -> URL {
        let target = try subdirectory("staged").appendingPathComponent(name)
        guard target.resolvingSymlinksInPath().path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw WorkspaceError.unsafeDirectory
        }
        try fileManager.copyItem(at: source, to: target)
        return target
    }

    func discard() throws {
        guard !finished else { return }
        finished = true
        try fileManager.removeItem(at: directory)
    }

    func markFinished() { finished = true }
}
