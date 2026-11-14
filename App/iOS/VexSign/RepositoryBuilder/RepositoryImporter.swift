import Foundation

enum RepositoryImporter {
    static let maximumBytes = 20 * 1_024 * 1_024

    /// Accepts the common AltStore/SideStore/Feather dialect and plain ESign JSON.
    /// Encrypted ESign feeds remain handled by the existing AltSourceKit pipeline.
    static func decode(_ data: Data, format: RepositoryFormat = .altStore, appsData: Data? = nil) throws -> RepositoryDocument {
        guard data.count <= maximumBytes, (appsData?.count ?? 0) <= maximumBytes else {
            throw RepositoryError.invalid("Repository exceeds the 20 MB limit.")
        }
        let json = try JSONDecoder().decode(RepositoryJSON.self, from: data)
        guard case .object(var source) = json else { throw RepositoryError.invalid("source.json must be an object.") }
        func text(_ key: String, fallback: String = "") -> String {
            if case .string(let value) = source[key] { return value }
            return fallback
        }
        var doc = RepositoryDocument(name: text("name", fallback: text("sourceName")),
                                     identifier: text("identifier"), iconURL: text("iconURL"), format: format)
        let appsJSON: RepositoryJSON?
        if let appsData {
            let separate = try JSONDecoder().decode(RepositoryJSON.self, from: appsData)
            if case .object(let object) = separate { appsJSON = object["apps"] }
            else { appsJSON = separate }
        } else { appsJSON = source["apps"] }
        guard case .array(let rows) = appsJSON, rows.count <= 50_000 else {
            throw RepositoryError.invalid("Expected an apps array (at most 50,000 entries).")
        }
        doc.apps = try rows.enumerated().map { index, row in
            guard case .object(var fields) = row else { throw RepositoryError.invalid("App \(index + 1) must be an object.") }
            func string(_ key: String, _ alias: String? = nil) -> String {
                if case .string(let value) = fields[key] { return value }
                if let alias, case .string(let value) = fields[alias] { return value }
                return ""
            }
            var app = RepositoryApp()
            app.name = string("name")
            app.bundleIdentifier = string("bundleIdentifier", "bundleID")
            app.version = string("version")
            app.versionDate = string("versionDate")
            app.downloadURL = string("downloadURL", "download")
            // Modern sources put release information in versions[0]. Keep the full history.
            if case .array(let versions) = fields["versions"], case .object(let latest) = versions.first {
                if case .string(let v) = latest["version"] { app.version = v }
                if case .string(let v) = latest["date"] { app.versionDate = v }
                if case .string(let v) = latest["downloadURL"] { app.downloadURL = v }
                if case .number(let v) = latest["size"], v >= 0, v < Double(Int64.max) { app.size = Int64(v) }
            }
            app.localizedDescription = string("localizedDescription", "description")
            app.iconURL = string("iconURL", "icon")
            app.developerName = string("developerName", "developer")
            app.category = string("category")
            app.tintColor = string("tintColor")
            if case .number(let v) = fields["size"], v >= 0, v < Double(Int64.max) { app.size = Int64(v) }
            if case .array(let values) = fields["screenshotURLs"] {
                app.screenshotURLs = try values.map {
                    guard case .string(let value) = $0 else { throw RepositoryError.invalid("Screenshots must be URL strings.") }
                    return value
                }
            }
            for key in ["name", "bundleIdentifier", "bundleID", "version", "versionDate", "downloadURL", "download", "localizedDescription", "description", "iconURL", "icon", "developerName", "developer", "category", "tintColor", "size", "screenshotURLs"] { fields.removeValue(forKey: key) }
            app.extra = fields
            return app
        }
        for key in ["name", "sourceName", "identifier", "iconURL", "apps"] { source.removeValue(forKey: key) }
        doc.extra = source
        return doc
    }
}
