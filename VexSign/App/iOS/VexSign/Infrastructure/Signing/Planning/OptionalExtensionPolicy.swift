import Foundation

/// Narrow, conservative compatibility policy for system-discovered optional
/// extension points. It never repairs guessed references or alters the source
/// library artifact. Unknown references, limits, links and nested apps block
/// removal; the exact approved list is bound to final execution authorization.
enum OptionalExtensionPolicy {
    private static let optionalPoints: Set<String> = [
        "com.apple.widgetkit-extension", "com.apple.share-services",
        "com.apple.ui-services", "com.apple.photo-editing"
    ]

    static func canRemove(_ path: String, in app: URL) throws -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count == 2, ["PlugIns", "Extensions"].contains(String(parts[0])),
              parts[1].lowercased().hasSuffix(".appex"), !parts.contains(".."), !parts.contains(".") else { return false }
        let extensionURL = app.appendingPathComponent(path)
        let properties = try extensionURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { return false }
        let plist = try info(extensionURL.appendingPathComponent("Info.plist"))
        guard let identifier = plist["CFBundleIdentifier"] as? String,
              ProfileApplicationIdentifierMatcher.isValidBundleIdentifier(identifier),
              let metadata = plist["NSExtension"] as? [String: Any],
              let point = metadata["NSExtensionPointIdentifier"] as? String,
              optionalPoints.contains(point) else { return false }
        let nested = SigningPlan.make(appBundle: extensionURL)
        guard nested.discoveryIssues.isEmpty, nested.profileBoundComponents.isEmpty,
              nested.validationIssues().allSatisfy({ $0.severity != .blocking }),
              SigningInputValidation.executable(in: extensionURL) != nil else { return false }
        let entirePlan = SigningPlan.make(appBundle: app)
        guard entirePlan.discoveryIssues.isEmpty else { return false }
        let sealedBundles = Set([app] + entirePlan.components.filter { !$0.isResourceOnly && $0.kind != .dylib }.map {
            app.appendingPathComponent($0.path)
        })
        let strings = [identifier, path, "/" + path, String(parts[1])]
        let needles: [Data] = strings.flatMap { value in
            [Data(value.utf8), value.data(using: .utf16LittleEndian), value.data(using: .utf16BigEndian)].compactMap { $0 }
        }
        var walkError: Error?
        guard let walker = FileManager.default.enumerator(at: app,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in walkError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        var count = 0, remainingBytes = 2 * 1024 * 1024 * 1024
        for case let file as URL in walker {
            try Task.checkCancellation()
            count += 1
            guard count <= 50_000 else { throw CocoaError(.fileReadTooLarge) }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return false }
            if file == extensionURL { walker.skipDescendants(); continue }
            guard values.isRegularFile == true else {
                if values.isDirectory != true { return false }
                continue
            }
            // Existing resource seals mention the extension's files by design;
            // they are regenerated for every retained executable before signing.
            if file.lastPathComponent == "CodeResources", file.deletingLastPathComponent().lastPathComponent == "_CodeSignature",
               sealedBundles.contains(file.deletingLastPathComponent().deletingLastPathComponent()) { continue }
            if file.pathExtension.lowercased() == "plist",
               references(try info(file), strings: strings) { return false }
            if try containsReference(file, needles: needles, remainingBytes: &remainingBytes) { return false }
        }
        if let walkError { throw walkError }
        return true
    }

    private static func containsReference(_ file: URL, needles: [Data], remainingBytes: inout Int) throws -> Bool {
        let overlap = (needles.map(\.count).max() ?? 1) - 1
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() } // try? ok: read failures propagate; close is cleanup.
        var tail = Data()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard bytes.count <= remainingBytes else { throw CocoaError(.fileReadTooLarge) }
            remainingBytes -= bytes.count
            let window = tail + bytes
            if needles.contains(where: { window.range(of: $0) != nil }) { return true }
            tail = Data(window.suffix(overlap))
        }
        return false
    }

    private static func references(_ value: Any, strings: [String]) -> Bool {
        if let string = value as? String { return strings.contains { string.contains($0) } }
        if let values = value as? [Any] { return values.contains { references($0, strings: strings) } }
        if let values = value as? [String: Any] {
            return values.contains { key, value in strings.contains { key.contains($0) } || references(value, strings: strings) }
        }
        return false
    }

    private static func info(_ file: URL) throws -> [String: Any] {
        let data = try CertificateInputReader.read(file)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              ProfileEntitlementAuthorization.isBoundedPropertyList(plist) else { throw CocoaError(.fileReadCorruptFile) }
        return plist
    }
}
