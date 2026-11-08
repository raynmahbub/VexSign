import Foundation
import NimbleExtensions

/// Conservative estimates are not reservations. Unknown capacity does not bypass
/// archive limits, and real write errors still propagate through owned cleanup.
enum StoragePreflight {
    static let margin: Int64 = 128 * 1024 * 1024
    struct Insufficient: LocalizedError {
        let required: Int64
        let available: Int64
        var errorDescription: String? {
            .localized("Not enough free storage. This operation needs about %@ of working space; %@ is available. Free space and retry. The original app has not been deleted.",
                arguments: ByteCountFormatter.string(fromByteCount: required, countStyle: .file), ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
        }
    }
    static func required(bytes: Int64, copies: Int64) -> Int64 {
        let (size, overflow) = max(0, bytes).multipliedReportingOverflow(by: max(1, copies))
        guard !overflow, size <= Int64.max - margin else { return Int64.max }
        return size + margin
    }
    static func check(bytes: Int64, copies: Int64, at url: URL, available: Int64? = nil) throws {
        let required = required(bytes: bytes, copies: copies)
        let capacity = available ?? FileManager.default.availableImportantCapacity(at: url)
        if let capacity, capacity < required { throw Insufficient(required: required, available: capacity) }
    }
    static func logicalSize(_ source: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let info = try source.resourceValues(forKeys: keys)
        if info.isDirectory != true { return Int64(info.fileSize ?? 0) }
        guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys)) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var total: Int64 = 0
        while let item = entries.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            if values.isDirectory != true {
                let (sum, overflow) = total.addingReportingOverflow(Int64(values.fileSize ?? 0))
                if overflow { return Int64.max }
                total = sum
            }
        }
        return total
    }
    static func checkBundle(_ source: URL, copies: Int64, destination: URL) throws {
        try check(bytes: logicalSize(source), copies: copies, at: destination)
    }
}
