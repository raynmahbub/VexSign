// MARK: - VexSign-owned application container model
//
// A container here is a directory inside VexSign's own sandbox. It is NOT an
// iOS application sandbox, not an installed app, and not an independent process.
// The model names the only thing it can honestly represent: managed storage and
// configuration belonging to a VexSign library record.

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import NimbleExtensions

enum AppContainerKind: String, Codable, Sendable {
    /// A directory VexSign owns. No code is executed from it.
    case managedStorage
}

enum AppContainerState: String, Codable, Sendable {
    case active
    case incomplete
    case corrupted
    case archived

    var title: String {
        switch self {
        case .active: .localized("Active")
        case .incomplete: .localized("Incomplete")
        case .corrupted: .localized("Damaged")
        case .archived: .localized("Archived")
        }
    }
}

/// What the user may reasonably expect after a hand-off. None of these values
/// claim that an external app accepted, launched or installed anything.
enum ContainerRuntimeHint: String, Codable, Sendable {
    case none
    case liveContainerScheme
    case embeddedHost
}

struct ContainerAppReference: Codable, Equatable, Sendable {
    let recordID: String?
    let uuid: String?
    let name: String?
    let bundleIdentifier: String?
    let version: String?
    let sourceURL: String?
    let certificateID: String?
}

struct ContainerCompatibility: Codable, Equatable, Sendable {
    var minimumSystemVersion: String?
    var supportedFormats: [String]
    var notes: String?

    static let empty = ContainerCompatibility(supportedFormats: [])
}

enum ContainerPreferenceValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Int)
    case flag(Bool)

    var displayValue: String {
        switch self {
        case .text(let value): value
        case .number(let value): "\(value)"
        case .flag(let value): value ? .localized("On") : .localized("Off")
        }
    }
}

struct ContainerResource: Codable, Equatable, Sendable {
    /// A single safe path component or a nested path using `/`, always relative
    /// to this container's `Resources` directory.
    let relativePath: String
    let byteCount: Int64
    let sha256: String?
    let addedAt: Date
    let typeIdentifier: String?

    var fileName: String { (relativePath as NSString).lastPathComponent }

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
}

struct AppContainerRecord: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 2

    let id: String
    var schemaVersion: Int
    var kind: AppContainerKind
    var state: AppContainerState
    var displayName: String
    var detail: String
    var createdAt: Date
    var updatedAt: Date
    var application: ContainerAppReference?
    var compatibility: ContainerCompatibility
    var preferences: [String: ContainerPreferenceValue]
    var resources: [ContainerResource]
    var runtimeHint: ContainerRuntimeHint

    var size: Int64 { resources.reduce(0) { $0 + $1.byteCount } }

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct ContainerUsage: Equatable, Sendable {
    let allocatedBytes: Int64
    let fileCount: Int

    var formatted: String { ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file) }
}

struct ContainerExportManifest: Codable, Equatable, Sendable {
    static let format = "vexsign.container"
    static let currentFormatVersion = 1

    let format: String
    let formatVersion: Int
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let container: AppContainerRecord

    func validateFormat() throws {
        guard format == Self.format else { throw ContainerArchiveError.unsupportedFormat }
        guard formatVersion == Self.currentFormatVersion,
              container.schemaVersion <= AppContainerRecord.currentSchemaVersion else {
            throw ContainerArchiveError.unsupportedVersion
        }
    }
}

struct ContainerExport: Sendable {
    let url: URL
    let manifest: ContainerExportManifest
    let archiveSHA256: String?
    let isEncrypted: Bool
}

enum ContainerRestoreAuthorization: Sendable {
    /// Keep the manifest's identity only when free; otherwise create a new container.
    case createNew
    /// Replace only this exact local id, after the incoming archive validated.
    case replace(id: String)
}

enum ContainerHandoffRoute: String, CaseIterable, Sendable {
    case liveContainerURLScheme
    case embeddedHost
}

enum ContainerHandoffOutcome: Equatable, Sendable {
    /// iOS accepted the URL. This is not proof that a guest app exists or launched.
    case openedUnverified
    /// The embedded host accepted the request. Not a launch or install result.
    case embeddedHostRequested
    case rejected
    case invalidDestination

    var message: String {
        switch self {
        case .openedUnverified:
            .localized("The hand-off was sent to LiveContainer. VexSign cannot observe whether the guest app launched.")
        case .embeddedHostRequested:
            .localized("The embedded host accepted the switch request. VexSign cannot observe a successful launch from here.")
        case .rejected:
            .localized("No application accepted this hand-off. Install the external host and try again.")
        case .invalidDestination:
            .localized("That hand-off destination is not supported or the URL could not be built safely.")
        }
    }
}

enum ContainerError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidName(String)
    case missingContainer
    case duplicateName
    case inaccessibleContainer
    case corruptedContainer
    case resourceExists(String)
    case resourceMissing(String)
    case unsafeResourcePath(String)
    case resourceTooLarge
    case operationInterrupted
    case persistenceFailed(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: .localized("That container identifier is not valid.")
        case .invalidName(let detail): String.localized("Use a name without path separators or control characters: %@", arguments: detail)
        case .missingContainer: .localized("That container no longer exists.")
        case .duplicateName: .localized("A container with that name already exists.")
        case .inaccessibleContainer: .localized("This container's data could not be accessed.")
        case .corruptedContainer: .localized("This container's metadata is damaged.")
        case .resourceExists(let name): String.localized("A resource named %@ already exists.", arguments: name)
        case .resourceMissing(let name): String.localized("The resource %@ is missing.", arguments: name)
        case .unsafeResourcePath(let path): String.localized("The resource path %@ is not safe.", arguments: path)
        case .resourceTooLarge: .localized("That file is too large to store in a container.")
        case .operationInterrupted: .localized("The operation was interrupted before it completed. No partial container was published.")
        case .persistenceFailed(let detail): String.localized("Container data could not be saved: %@", arguments: detail)
        case .migrationFailed(let detail): String.localized("Older container data could not be migrated: %@", arguments: detail)
        }
    }
}

enum ContainerArchiveError: LocalizedError, Equatable {
    case unsupportedFormat
    case unsupportedVersion
    case malformedManifest
    case archiveInvalid
    case checksumMismatch(String)
    case passwordRequired
    case passwordTooShort
    case destinationExists
    case extractionFailed
    case interrupted

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: .localized("This file is not a VexSign container export.")
        case .unsupportedVersion: .localized("This container export was made by an incompatible version.")
        case .malformedManifest: .localized("The container manifest could not be read safely.")
        case .archiveInvalid: .localized("The container archive failed validation and was not restored.")
        case .checksumMismatch(let path): String.localized("A restored file did not match its recorded checksum: %@", arguments: path)
        case .passwordRequired: .localized("This container export is encrypted and needs its password.")
        case .passwordTooShort: .localized("Use at least 8 characters for an encrypted export.")
        case .destinationExists: .localized("A container already exists at the destination. Confirm replacement before restoring.")
        case .extractionFailed: .localized("The container could not be extracted.")
        case .interrupted: .localized("Restore was interrupted before it completed. No partial container was published.")
        }
    }
}


struct ContainerArchiveFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .zip] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
