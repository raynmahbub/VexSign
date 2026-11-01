import Foundation

/// Copies in bounded chunks so cancellation stops I/O and partial files are removed.
/// The caller owns security-scoped access for the entire operation.
enum CompanionIPAStager {
    static func copy(_ source: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try Task.checkCancellation()
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let directory = temporaryRoot.appendingPathComponent("CompanionHandoff", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            guard manager.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { close(input) }
            let output = try FileHandle(forWritingTo: destination)
            defer { close(output) }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try Task.checkCancellation()
            try output.synchronize()
            return destination
        } catch {
            let originalError = error
            do { try manager.removeItem(at: directory) }
            catch { FileLogger.log("Could not clean partial companion IPA: \(error)", category: "install") }
            throw originalError
        }
    }

    private static func close(_ handle: FileHandle) {
        do { try handle.close() }
        catch { FileLogger.log("Could not close companion IPA file: \(error)", category: "install") }
    }
}
