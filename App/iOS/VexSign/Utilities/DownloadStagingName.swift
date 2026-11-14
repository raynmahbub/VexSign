import Foundation

/// Concurrent downloads never share a destination, even when servers suggest the same filename.
enum DownloadStagingName {
    static func destination(in directory: URL, suggestedFilename: String, token: UUID = UUID()) -> URL {
        let component = (suggestedFilename as NSString).lastPathComponent
        let suffix = (component as NSString).pathExtension
        let validSuffix = !suffix.isEmpty && suffix.count <= 10
            && suffix.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let ext = validSuffix ? suffix : "ipa"
        let base = (component as NSString).deletingPathExtension
        let safeBase = IPAExportNaming.stem(name: base, version: nil)
        return directory.appendingPathComponent("\(token.uuidString)-\(safeBase).\(ext)")
    }
}
