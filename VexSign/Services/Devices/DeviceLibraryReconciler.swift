// MARK: - Library/device reconciliation
//
// This comparison never creates, edits or deletes a library record. It reports where the
// device and the library disagree so that a person can authorize any change. Duplicates and
// version-less records are surfaced because they make automatic matching unsafe.

import Foundation
import NimbleExtensions

struct DeviceLibraryMatch: Equatable, Sendable, Identifiable {
    enum State: String, Equatable, Sendable {
        case matchingVersion, differentVersion, noDeviceReport, deviceOnly, duplicateIdentifier
    }

    let bundleIdentifier: String
    let libraryName: String
    let libraryVersion: String?
    let deviceVersion: String?
    let deviceBuild: String?
    let state: State

    var id: String { bundleIdentifier }

    var title: String {
        switch state {
        case .matchingVersion: .localized("Library version matches")
        case .differentVersion: .localized("Version differs")
        case .noDeviceReport: .localized("No comparable device report")
        case .deviceOnly: .localized("On device, not in Library")
        case .duplicateIdentifier: .localized("Duplicate bundle identifier")
        }
    }
}

struct DeviceLibraryComparison: Equatable, Sendable {
    let matches: [DeviceLibraryMatch]
    let ignoredInvalidIdentifiers: Int

    var duplicateCount: Int { matches.filter { $0.state == .duplicateIdentifier }.count }
    var versionDifferenceCount: Int { matches.filter { $0.state == .differentVersion }.count }
    var deviceOnlyCount: Int { matches.filter { $0.state == .deviceOnly }.count }

    var summary: String {
        String.localized(
            "%lld matched · %lld version differences · %lld device-only · %lld duplicates",
            arguments: matches.count, versionDifferenceCount, deviceOnlyCount, duplicateCount
        )
    }
}

enum DeviceLibraryReconciler {
    static func compare(libraryApps: [LibraryAppRecord],
                        snapshot: DeviceInventorySnapshot?) -> DeviceLibraryComparison {
        let byBundle = Dictionary(grouping: libraryApps) { app in
            app.identifier.map { DeviceApplicationInventory.isBundleIdentifier($0) ? $0.lowercased() : "" } ?? ""
        }
        let invalidCount = libraryApps.filter {
            guard let identifier = $0.identifier else { return true }
            return !DeviceApplicationInventory.isBundleIdentifier(identifier)
        }.count

        var rows: [DeviceLibraryMatch] = []
        var seenDeviceBundles = Set<String>()

        for (bundle, group) in byBundle where !bundle.isEmpty {
            let device = snapshot?.application(bundleIdentifier: bundle)
            seenDeviceBundles.insert(bundle)
            if group.count > 1 {
                rows.append(DeviceLibraryMatch(
                    bundleIdentifier: bundle, libraryName: group.first?.name ?? .localized("Duplicate app"),
                    libraryVersion: group.first?.version, deviceVersion: device?.version,
                    deviceBuild: device?.build, state: .duplicateIdentifier
                ))
                continue
            }
            guard let app = group.first else { continue }
            let state: DeviceLibraryMatch.State
            if let device, let libraryVersion = app.version, let deviceVersion = device.version,
               VersionOrder.isSame(libraryVersion, deviceVersion) {
                state = .matchingVersion
            } else if device != nil {
                state = .differentVersion
            } else {
                state = .noDeviceReport
            }
            rows.append(DeviceLibraryMatch(
                bundleIdentifier: bundle, libraryName: app.name ?? bundle, libraryVersion: app.version,
                deviceVersion: device?.version, deviceBuild: device?.build, state: state
            ))
        }

        if let snapshot {
            for app in snapshot.applications where !seenDeviceBundles.contains(app.bundleIdentifier) {
                rows.append(DeviceLibraryMatch(
                    bundleIdentifier: app.bundleIdentifier, libraryName: app.name,
                    libraryVersion: nil, deviceVersion: app.version,
                    deviceBuild: app.build, state: .deviceOnly
                ))
            }
        }

        return DeviceLibraryComparison(
            matches: rows.sorted { $0.bundleIdentifier < $1.bundleIdentifier },
            ignoredInvalidIdentifiers: invalidCount
        )
    }
}
