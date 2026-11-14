import Foundation
import NimbleExtensions

/// Certificate files should be small. Bound reads before passing untrusted input
/// to decoders so choosing a huge file cannot exhaust the app's memory.
enum CertificateInputReader {
    static let maximumBytes = 10 * 1024 * 1024

    enum ReadError: LocalizedError {
        case invalidFile, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidFile: return .localized("Choose a readable certificate or provisioning-profile file.")
            case .tooLarge: return .localized("The certificate or provisioning-profile file exceeds the safe import size limit.")
            }
        }
    }

    static func read(_ url: URL, maximumBytes: Int = CertificateInputReader.maximumBytes) throws -> Data {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw ReadError.invalidFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ReadError.invalidFile }
        if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(maximumBytes) {
            throw ReadError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() }
            catch { FileLogger.log("Could not close certificate input: \(error)", category: "certificate") }
        }
        var result = Data()
        while true {
            let count = min(1 << 20, maximumBytes - result.count + 1)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            result.append(chunk)
            guard result.count <= maximumBytes else { throw ReadError.tooLarge }
        }
        return result
    }
}
