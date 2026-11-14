import Foundation

/// Reduce a client-supplied upload/download name to one safe inbox component.
enum WebManagerFilenamePolicy {
    static func filename(_ name: String) -> String? {
        let decoded = name.removingPercentEncoding ?? name
        guard decoded.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let last = (decoded as NSString).lastPathComponent
        let cleaned = last.replacingOccurrences(of: "/", with: "_")
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return cleaned
    }

    /// The filename is a quoted HTTP parameter, not a raw header fragment.
    static func contentDisposition(filename: String) -> String {
        let escaped = filename.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "attachment; filename=\"\(escaped)\""
    }
}
