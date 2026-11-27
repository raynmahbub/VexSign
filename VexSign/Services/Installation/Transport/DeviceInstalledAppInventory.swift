//
//  DeviceInstalledAppInventory.swift
//  VexSign
//
//  Library-app-scoped inventory evidence.
//
//  This is deliberately not a "list every app on the phone" claim. The selected
//  device service is queried one bundle identifier at a time, and only a
//  positive, same-device, same-record reading is evidence. A filtered lookup, a
//  cancelled query, an empty answer or a version-less record is reported as
//  unreported — never as "not installed".
//

import Foundation
import IDeviceSwift
import NimbleExtensions

enum DeviceInstalledAppState: String, Equatable, Sendable {
    case current
    case otherVersion
    case unreported

    var title: String {
        switch self {
        case .current: return .localized("Matches library version")
        case .otherVersion: return .localized("Different version on device")
        case .unreported: return .localized("No comparable device report")
        }
    }
}

/// One row of the device inventory. Contains public app metadata only: no
/// bundle path, pairing fingerprint, UDID or installation receipt is retained.
struct DeviceInstalledAppRow: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let expectedVersion: String?
    let expectedBuild: String?
    let deviceName: String?
    let deviceVersion: String?
    let deviceBuild: String?
    let state: DeviceInstalledAppState
    let observedAt: Date?

    var detail: String {
        switch state {
        case .current:
            return .localized("The selected device reported this bundle identifier, version and build.")
        case .otherVersion:
            return .localized("The selected device reported this bundle identifier at another version. Installation of the library copy is not confirmed.")
        case .unreported:
            return .localized("The selected device did not return comparable version and build metadata. This is not proof that the app is absent.")
        }
    }
}

/// Pure comparison of a library app against one bounded native reading.
/// The model passes a frozen device binding; no caller-supplied version string
/// can turn a different device or record into a match.
enum DeviceInstalledAppAssessment {
    static let maximumApps = 64

    static func make(
        for app: LibraryAppRecord,
        expectedBuild: String?,
        observed: DeviceInstalledApplication?,
        binding: DeviceSessionBinding?,
        now: Date = Date()
    ) -> DeviceInstalledAppRow {
        let identifier = app.identifier ?? ""
        let base = DeviceInstalledAppRow(
            id: app.workspaceIdentity ?? (identifier.isEmpty ? app.id : identifier),
            name: app.name ?? identifier,
            bundleIdentifier: identifier,
            expectedVersion: app.version,
            expectedBuild: expectedBuild,
            deviceName: nil,
            deviceVersion: nil,
            deviceBuild: nil,
            state: .unreported,
            observedAt: nil
        )
        guard DeviceApplicationInventory.isBundleIdentifier(identifier),
              let observed, observed.bundleIdentifier == identifier,
              let binding, observed.binding == binding,
              let version = observed.version, let build = observed.build,
              DeviceApplicationInventory.isVersion(version), DeviceApplicationInventory.isVersion(build),
              now.timeIntervalSince(observed.observedAt) >= 0 else { return base }

        // The shared state engine applies the same version/build/binding rules as
        // install confirmation. `.notInstalled` cannot be produced here: the
        // service returns nil for unknown, and a positive reading is required.
        let reading = InstalledApp(application: observed)
        switch InstalledState.derive(from: reading, expecting: app.version, build: expectedBuild, binding: binding) {
        case .installed:
            return withObservation(base, observed: observed, state: .current)
        case .installedOtherVersion:
            return withObservation(base, observed: observed, state: .otherVersion)
        case .notInstalled, .unknown, .installing:
            return withObservation(base, observed: observed, state: .unreported)
        }
    }

    /// Eligible library apps, capped and deduplicated before any device call.
    static func eligible(_ apps: [LibraryAppRecord]) -> [LibraryAppRecord] {
        var seen = Set<String>()
        var result: [LibraryAppRecord] = []
        for app in apps {
            guard let identifier = app.identifier,
                  DeviceApplicationInventory.isBundleIdentifier(identifier),
                  seen.insert(identifier).inserted else { continue }
            result.append(app)
            if result.count == maximumApps { break }
        }
        return result
    }

    /// Names arrive from the device and are rendered directly. Reuse the same
    /// bounds the native inventory validator applies before accepting a record.
    private static func isDisplayableName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 1024
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func withObservation(_ row: DeviceInstalledAppRow,
                                       observed: DeviceInstalledApplication,
                                       state: DeviceInstalledAppState) -> DeviceInstalledAppRow {
        DeviceInstalledAppRow(
            id: row.id, name: row.name, bundleIdentifier: row.bundleIdentifier,
            expectedVersion: row.expectedVersion, expectedBuild: row.expectedBuild,
            deviceName: Self.isDisplayableName(observed.name) ? observed.name : nil,
            deviceVersion: observed.version, deviceBuild: observed.build,
            state: state, observedAt: observed.observedAt
        )
    }
}
