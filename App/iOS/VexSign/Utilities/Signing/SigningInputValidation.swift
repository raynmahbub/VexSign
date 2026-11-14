import Foundation

/// Validate files immediately before the native engine consumes them. UI preflight
/// alone cannot cover automation, batch runs, or files removed after review.
enum SigningInputValidation {
    static func entitlementsAreUsable(at path: String) -> Bool {
        guard !path.isEmpty else { return true } // No custom file: use profile defaults.
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return plist is [String: Any]
        } catch {
            return false
        }
    }

    /// CFBundleExecutable is a filename, not an arbitrary path. Never hand a missing
    /// executable, the bundle directory, or a symlink outside the bundle to dylib surgery.
    static func executable(in bundleURL: URL) -> URL? {
        do {
            let data = try Data(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let name = plist["CFBundleExecutable"] as? String,
                  !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
            let root = bundleURL.resolvingSymlinksInPath().standardizedFileURL
            let executable = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard executable.deletingLastPathComponent().path.split(separator: "/") == root.path.split(separator: "/") else { return nil }
            let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            return values.isRegularFile == true && values.isReadable == true ? executable : nil
        } catch {
            return nil
        }
    }
}
