import Foundation

enum RepositoryExporter {
    struct Files { let source: Data; let apps: Data }

    static func encode(_ document: RepositoryDocument, as format: RepositoryFormat) throws -> Files {
        let errors = RepositoryValidator.validate(document).filter { $0.severity == .error }
        guard errors.isEmpty else { throw RepositoryError.invalid(errors.map(\.message).joined(separator: "\n")) }
        let rows = document.apps.map { app -> RepositoryJSON in
            var fields = app.extra
            let strings = ["name": app.name, "bundleIdentifier": app.bundleIdentifier,
                           "version": app.version, "versionDate": app.versionDate,
                           "localizedDescription": app.localizedDescription, "iconURL": app.iconURL,
                           "downloadURL": app.downloadURL, "developerName": app.developerName,
                           "category": app.category, "tintColor": app.tintColor]
            for (key, value) in strings { fields[key] = .string(value) }
            fields["size"] = .number(Double(app.size))
            fields["screenshotURLs"] = .array(app.screenshotURLs.map(RepositoryJSON.string))
            if format == .altStore || format == .sideStore {
                var latest: [String: RepositoryJSON] = [:]
                var history: [RepositoryJSON] = []
                if case .array(let versions) = fields["versions"] {
                    history = versions
                    if case .object(let original) = versions.first { latest = original }
                }
                latest["version"] = .string(app.version)
                latest["date"] = .string(app.versionDate)
                latest["downloadURL"] = .string(app.downloadURL)
                latest["size"] = .number(Double(app.size))
                if history.isEmpty { history = [.object(latest)] } else { history[0] = .object(latest) }
                fields["versions"] = .array(history)
            } else {
                // Avoid stale release metadata overriding the fields just edited.
                fields.removeValue(forKey: "versions")
            }
            return .object(fields)
        }
        var source = document.extra
        source["name"] = .string(document.name)
        source["identifier"] = .string(document.identifier)
        source["iconURL"] = .string(document.iconURL)
        source["apps"] = .array(rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try Files(source: encoder.encode(RepositoryJSON.object(source)), apps: encoder.encode(RepositoryJSON.array(rows)))
    }
}
