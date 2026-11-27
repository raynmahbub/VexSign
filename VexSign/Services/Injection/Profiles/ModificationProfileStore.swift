// MARK: - Saved tweak modification profiles
//
// Profiles reference imported tweaks by stable identifier and validated version.
// They never store file paths, passwords, key material or copied binaries. A
// profile with a broken reference is reported and cannot be applied until the
// user removes or replaces that entry.

import Foundation
import NimbleExtensions

struct ModificationProfileEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let tweakID: UUID
    let versionID: UUID
    let enabled: Bool
    let injectionPath: String?
    let injectionFolder: String?

    init(
        id: UUID = UUID(),
        tweakID: UUID,
        versionID: UUID,
        enabled: Bool = true,
        injectionPath: String? = nil,
        injectionFolder: String? = nil
    ) {
        self.id = id
        self.tweakID = tweakID
        self.versionID = versionID
        self.enabled = enabled
        self.injectionPath = injectionPath
        self.injectionFolder = injectionFolder
    }
}

struct ModificationProfile: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let appBundleIdentifier: String
    let entries: [ModificationProfileEntry]
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        appBundleIdentifier: String,
        entries: [ModificationProfileEntry],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.appBundleIdentifier = appBundleIdentifier
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var enabledEntries: [ModificationProfileEntry] { entries.filter(\.enabled) }

    func duplicating(name: String, now: Date = Date()) -> ModificationProfile {
        ModificationProfile(
            name: name,
            appBundleIdentifier: appBundleIdentifier,
            entries: entries.map {
                ModificationProfileEntry(
                    tweakID: $0.tweakID, versionID: $0.versionID, enabled: $0.enabled,
                    injectionPath: $0.injectionPath, injectionFolder: $0.injectionFolder
                )
            },
            createdAt: now,
            updatedAt: now
        )
    }
}

enum ProfileReferenceStatus: Equatable, Sendable {
    case valid
    case broken(reason: String)
}

enum ModificationProfileValidator {
    static func status(
        of entry: ModificationProfileEntry,
        against tweaks: [ManagedTweak]
    ) -> ProfileReferenceStatus {
        guard let tweak = tweaks.first(where: { $0.id == entry.tweakID }) else {
            return .broken(reason: "The referenced tweak is no longer in the library.")
        }
        guard tweak.versions.contains(where: { $0.id == entry.versionID }) else {
            return .broken(reason: "The referenced tweak version was removed or replaced.")
        }
        guard tweak.activeVersion?.id == entry.versionID else {
            return .broken(reason: "A different version is now active for this tweak.")
        }
        return .valid
    }

    /// Removes entries that no longer name an imported, active version. This is
    /// used when a package is deleted or replaced so no profile silently points
    /// at a file that is gone.
    static func sanitized(_ profile: ModificationProfile, against tweaks: [ManagedTweak]) -> ModificationProfile {
        var changed = false
        let kept = profile.entries.filter { entry in
            let valid = status(of: entry, against: tweaks) == .valid
            if !valid { changed = true }
            return valid
        }
        guard changed else { return profile }
        return ModificationProfile(
            id: profile.id,
            name: profile.name,
            appBundleIdentifier: profile.appBundleIdentifier,
            entries: kept,
            createdAt: profile.createdAt,
            updatedAt: Date()
        )
    }
}

struct ModificationProfileStore {
    enum StoreError: LocalizedError, Equatable {
        case unreadable
        case malformed
        case limitExceeded

        var errorDescription: String? {
            switch self {
            case .unreadable: "Saved modification profiles could not be read."
            case .malformed: "Saved modification profiles are damaged; nothing was changed."
            case .limitExceeded: "Too many modification profiles are saved."
            }
        }
    }

    private static let maximumProfiles = 256
    let directory: URL
    let fileManager: FileManager

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let base = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = base.appendingPathComponent("ModificationProfiles", isDirectory: true)
        self.fileManager = fileManager
    }

    private var fileURL: URL { directory.appendingPathComponent("profiles.json") }

    func load() throws -> [ModificationProfile] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: fileURL, options: .mappedIfSafe) }
        catch { throw StoreError.unreadable }
        guard data.count <= 4 * 1024 * 1024 else { throw StoreError.limitExceeded }
        do { return try JSONDecoder().decode([ModificationProfile].self, from: data) }
        catch { throw StoreError.malformed }
    }

    @discardableResult
    func save(_ profiles: [ModificationProfile]) throws -> [ModificationProfile] {
        guard profiles.count <= Self.maximumProfiles else { throw StoreError.limitExceeded }
        let data = try JSONEncoder().encode(profiles)
        guard data.count <= 4 * 1024 * 1024 else { throw StoreError.limitExceeded }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return profiles
    }

    func upsert(_ profile: ModificationProfile) throws -> [ModificationProfile] {
        var profiles = try load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        return try save(profiles)
    }

    func remove(id: UUID) throws -> [ModificationProfile] {
        try save(try load().filter { $0.id != id })
    }

    /// Drops references to deleted or replaced packages from every saved profile.
    func prune(against tweaks: [ManagedTweak]) throws -> [ModificationProfile] {
        try save(try load().map { ModificationProfileValidator.sanitized($0, against: tweaks) })
    }
}
