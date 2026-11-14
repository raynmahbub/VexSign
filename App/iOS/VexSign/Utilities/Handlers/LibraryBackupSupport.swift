import Foundation

struct LibraryBackupEntry: Codable {
    let uuid: String
    let bundleName: String
    let signed: Bool
    let name: String?
    let identifier: String?
    let originalIdentifier: String?
    let version: String?
    let appDescription: String?
    let certificateUUID: String?
}

enum LibraryBackupSupport {
    // Match the archive extraction policy; encryption itself is chunked.
    static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maximumManifestBytes = 16 * 1024 * 1024
    static let maximumEntries = 49_999 // Reserve the ZIP's outer staging directory.

    enum Failure: LocalizedError {
        case invalidEntry
        case tooLarge
        case busy
        case tooManyEntries
        var errorDescription: String? {
            switch self {
            case .invalidEntry: return "The library backup contains a missing or unsafe app bundle."
            case .tooLarge: return "This backup exceeds the 8 GiB safe extraction limit. Export larger apps as individual IPAs instead."
            case .tooManyEntries: return "This library contains too many files for a safe backup. Export smaller groups of apps instead."
            case .busy: return "Finish active signing, downloads and installation before backing up or restoring the app library."
            }
        }
    }

    static func validate(_ entry: LibraryBackupEntry) throws {
        guard UUID(uuidString: entry.uuid) != nil,
              entry.bundleName.hasSuffix(".app"), !entry.bundleName.hasPrefix("."),
              !entry.bundleName.contains("/"), !entry.bundleName.contains("\\"),
              !entry.bundleName.contains("\0") else { throw Failure.invalidEntry }
    }

    /// Reject links and bound the entire staged container (not just its ZIP size).
    static func validateTree(_ root: URL, maximumBytes: Int64 = LibraryBackupSupport.maximumBytes) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true, maximumBytes >= 0 else { throw Failure.invalidEntry }
        var enumerationError: Error?
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
            throw Failure.invalidEntry
        }
        var total: Int64 = 0
        var entries = 0
        for case let file as URL in walker {
            try Task.checkCancellation()
            entries += 1
            guard entries <= maximumEntries else { throw Failure.tooManyEntries }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw Failure.invalidEntry }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0 else { throw Failure.invalidEntry }
                let bytes = Int64(size)
                guard bytes <= maximumBytes - total else { throw Failure.tooLarge }
                total += bytes
            } else if values.isDirectory != true { throw Failure.invalidEntry }
        }
        if let enumerationError { throw enumerationError }
        return total
    }
}
