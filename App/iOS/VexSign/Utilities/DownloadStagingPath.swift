import Foundation

/// Produces a unique, single-component path for an untrusted server filename.
enum DownloadStagingPath {
    static func createTemporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.uniqueTemporaryDirectory(label)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func safeFilename(_ suggested: String?) -> String {
        let raw = suggested ?? ""
        let leaf = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init) ?? ""
        var cleaned = ""
        for scalar in leaf.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) && scalar != ":" {
            cleaned.unicodeScalars.append(scalar)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "download.ipa" }
        var bounded = ""
        for scalar in cleaned.unicodeScalars {
            let character = String(scalar)
            guard bounded.utf8.count + character.utf8.count <= 180 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "download.ipa" : bounded
    }

    /// A unique prefix prevents same-name responses from overwriting/removing
    /// another download's staged IPA before it is imported.
    static func destination(in directory: URL, suggestedFilename: String?) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString)-\(safeFilename(suggestedFilename))")
    }
}
