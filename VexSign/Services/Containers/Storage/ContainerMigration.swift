// MARK: - Container metadata migration
//
// Only metadata shape changes are migrated. Resource files keep their relative
// paths; a directory whose metadata cannot be mapped is reported, never guessed
// into a new container.

import Foundation

enum ContainerMigration {
    /// Older builds wrote `info.json` with a flat shape and no schema version.
    static func normalize(_ data: Data, fallbackID: String) throws -> AppContainerRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current: AppContainerRecord?
        do { current = try decoder.decode(AppContainerRecord.self, from: data) }
        catch { current = nil }
        if let current, current.schemaVersion <= AppContainerRecord.currentSchemaVersion {
            return current
        }
        let object: [String: Any]?
        do { object = try JSONSerialization.jsonObject(with: data) as? [String: Any] }
        catch { object = nil }
        guard let object else { throw ContainerError.migrationFailed("The metadata file could not be read.") }
        guard let name = object["name"] as? String else {
            throw ContainerError.migrationFailed("The older record has no usable name.")
        }
        let displayName: String?
        do { displayName = try ContainerPathPolicy.displayName(name) }
        catch { displayName = nil }
        guard let displayName else { throw ContainerError.migrationFailed("The older record has no usable name.") }
        let app: ContainerAppReference?
        if let bundle = object["bundleIdentifier"] as? String, !bundle.isEmpty {
            app = ContainerAppReference(
                recordID: object["recordID"] as? String,
                uuid: object["uuid"] as? String,
                name: object["appName"] as? String,
                bundleIdentifier: bundle,
                version: object["version"] as? String,
                sourceURL: object["sourceURL"] as? String,
                certificateID: nil
            )
        } else { app = nil }
        return AppContainerRecord(
            id: object["id"] as? String ?? fallbackID,
            schemaVersion: AppContainerRecord.currentSchemaVersion,
            kind: .managedStorage,
            state: .active,
            displayName: displayName,
            detail: object["description"] as? String ?? "",
            createdAt: _date(object["createdAt"]) ?? Date(),
            updatedAt: _date(object["updatedAt"]) ?? _date(object["createdAt"]) ?? Date(),
            application: app,
            compatibility: .empty,
            preferences: [:],
            resources: [],
            runtimeHint: .none
        )
    }

    private static func _date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
