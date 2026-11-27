// MARK: - Container path policy
//
// Every path in this subsystem is built from a generated identifier and one or
// more validated components. User strings never become paths directly.

import Foundation

enum ContainerPathPolicy {
    static let maximumNameLength = 120
    static let maximumResourceBytes: Int64 = 512 * 1024 * 1024

    private static let identifierPattern = "^cntr_[0-9a-f]{32}$"
    private static let namePattern = "^[A-Za-z0-9][A-Za-z0-9 _.-]{0,119}$"

    static func makeIdentifier() -> String {
        "cntr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        value.range(of: identifierPattern, options: .regularExpression) != nil
    }

    /// Validates one path component. Empty, dot, dot-dot, hidden, absolute and
    /// separator-bearing names are refused before they reach FileManager.
    static func safeComponent(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".", trimmed != "..",
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"), !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              trimmed.utf8.count <= maximumNameLength,
              trimmed.range(of: namePattern, options: .regularExpression) != nil else {
            throw ContainerError.invalidName(raw)
        }
        return trimmed
    }

    static func displayName(_ raw: String) throws -> String {
        try safeComponent(raw)
    }

    /// Accepts a relative resource path with `/` separators, rejecting every
    /// component that could escape or hide inside another container.
    static func safeRelativePath(_ raw: String) throws -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), normalized != "." else {
            throw ContainerError.unsafeResourcePath(raw)
        }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 16, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ContainerError.unsafeResourcePath(raw)
        }
        let safe = try parts.map { try safeComponent($0) }
        return safe.joined(separator: "/")
    }

    static func containerRoot(in root: URL, id: String) throws -> URL {
        guard isValidIdentifier(id) else { throw ContainerError.invalidIdentifier }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    static func resourceURL(in containerRoot: URL, relativePath: String) throws -> URL {
        let safe = try safeRelativePath(relativePath)
        let url = containerRoot.appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: false)
        guard isContained(url, in: containerRoot) else {
            throw ContainerError.unsafeResourcePath(relativePath)
        }
        return url
    }

    /// Lexical containment plus a symlink-aware check for paths that already
    /// exist. A symlink inside a container must never redirect a write outside.
    static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        let resolvedBase = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        func within(_ path: String, _ root: String) -> Bool {
            path == root || path.hasPrefix(root + "/")
        }
        return within(path, base) && within(resolved, resolvedBase)
    }

    static func isSymbolicLink(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false } // try? ok: unreadable metadata is treated as non-link
        return values.isSymbolicLink == true
    }
}
