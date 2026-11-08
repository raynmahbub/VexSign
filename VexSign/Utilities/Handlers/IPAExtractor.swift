import Foundation
import ZIPFoundation

/// VexSign's import-only decoder. Runs on the import task, never a detached writer that
/// could keep touching the workspace after its owner starts cleanup. Uses the existing
/// ZIPFoundation dependency, not a forked decoder or a prebuilt third-party signer.
enum IPAExtractor {
    enum ExtractionError: LocalizedError {
        case checksum(String)
        case size(String)
        case duplicate(String)
        case timedOut
        case insufficientSpace

        var errorDescription: String? {
            switch self {
            case .checksum(let path): return "Archive checksum mismatch: \(path)"
            case .size(let path): return "Archive entry has an invalid expanded size: \(path)"
            case .duplicate(let path): return "Archive contains a conflicting output path: \(path)"
            case .insufficientSpace: return "Not enough free storage for the expanded IPA. Free up space and try again."
            case .timedOut: return "IPA extraction exceeded its time limit. The archive may be too large or damaged."
            }
        }
    }

    static func extract(
        _ source: URL,
        to root: URL,
        timeout: TimeInterval = 300,
        checkpoint: () throws -> Void = { try Task.checkCancellation() },
        progress: (Double) -> Void = { _ in }
    ) throws {
        var started = ProcessInfo.processInfo.systemUptime
        func check() throws {
            let beforeCheckpoint = ProcessInfo.processInfo.systemUptime
            try checkpoint()
            // Pausing at a checkpoint must not consume the extraction deadline.
            started += ProcessInfo.processInfo.systemUptime - beforeCheckpoint
            guard ProcessInfo.processInfo.systemUptime - started < timeout else {
                throw ExtractionError.timedOut
            }
        }
        try check()
        try ArchiveSafetyValidator.validate(source, destination: root)
        let archive = try Archive(url: source, accessMode: .read)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let total = archive.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        // Check expanded bytes, not a multiple of the compressed IPA size.
        // Highly compressible valid apps can be far larger than their download.
        if let available = manager.availableImportantCapacity(at: root),
           available < Int64(total) + 16 * 1024 * 1024 {
            throw ExtractionError.insufficientSpace
        }
        var completed: UInt64 = 0
        var seen = Set<String>()
        var directoryAttributes: [(URL, [FileAttributeKey: Any])] = []
        var lastProgress = 0.0
        progress(0)

        for entry in archive {
            try check()
            // Repeat containment validation immediately before every write.
            try ArchiveSafetyValidator.validateDestination(relativePath: entry.path, root: root)
            let destination = root.appendingPathComponent(entry.path).standardizedFileURL
            guard seen.insert(destination.path).inserted else {
                throw ExtractionError.duplicate(entry.path)
            }
            switch entry.type {
            case .directory:
                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    throw ExtractionError.duplicate(entry.path)
                }
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                // Apply read-only modes/dates only after children have been written.
                directoryAttributes.append((destination, entry.fileAttributes))
            case .file:
                guard !manager.fileExists(atPath: destination.path) else {
                    throw ExtractionError.duplicate(entry.path)
                }
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard manager.createFile(atPath: destination.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let output = try FileHandle(forWritingTo: destination)
                do {
                    var written: UInt64 = 0
                    let checksum = try archive.extract(entry, bufferSize: 256 * 1024) { data in
                        try check()
                        guard UInt64(data.count) <= entry.uncompressedSize - written else {
                            throw ExtractionError.size(entry.path)
                        }
                        try output.write(contentsOf: data)
                        written += UInt64(data.count)
                        let fraction = total == 0 ? 0 : Double(completed + written) / Double(total)
                        // Never announce completion before CRC and metadata checks finish.
                        if fraction - lastProgress >= 0.01, fraction < 1 {
                            lastProgress = fraction
                            progress(fraction)
                        }
                    }
                    guard written == entry.uncompressedSize else { throw ExtractionError.size(entry.path) }
                    guard checksum == entry.checksum else { throw ExtractionError.checksum(entry.path) }
                    try output.close()
                } catch {
                    try? output.close() // try? ok: preserve the original extraction failure
                    throw error
                }
                try manager.setAttributes(entry.fileAttributes, ofItemAtPath: destination.path)
            case .symlink:
                throw ArchiveSafetyValidator.ValidationError.symbolicLink(entry.path)
            }
            completed += entry.uncompressedSize
        }
        for (directory, attributes) in directoryAttributes.reversed() {
            try check()
            try manager.setAttributes(attributes, ofItemAtPath: directory.path)
        }
        try check()
        progress(1)
    }
}
