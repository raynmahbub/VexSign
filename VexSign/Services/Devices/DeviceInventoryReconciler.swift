// MARK: - Inventory reconciliation
//
// A device inventory is a series of positive observations, not a database of truth. The
// reconciler never invents an app from a library record and never treats an omitted bundle as
// an uninstall. A "removed" row means only that a *complete* snapshot no longer reports it.

import Foundation
import IDeviceSwift
import NimbleExtensions

struct DeviceInventoryChange: Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case added, versionChanged, noLongerReported, stillUnreported, unchanged
    }

    let bundleIdentifier: String
    let name: String
    let kind: Kind
    let previousVersion: String?
    let currentVersion: String?

    var id: String { bundleIdentifier }

    var title: String {
        switch kind {
        case .added: .localized("Newly reported")
        case .versionChanged: .localized("Version changed")
        case .noLongerReported: .localized("No longer reported")
        case .stillUnreported: .localized("Still unreported")
        case .unchanged: .localized("Unchanged")
        }
    }

    var detail: String {
        switch kind {
        case .added:
            .localized("The device service reported this bundle in the latest snapshot and not in the previous one.")
        case .versionChanged:
            .localized("The device service reported a different version or build. No installation source is implied.")
        case .noLongerReported:
            .localized("This bundle was in the previous snapshot but is absent from a complete new snapshot. Check the device before treating it as removed.")
        case .stillUnreported:
            .localized("No comparable device report was received for this library app. This is unknown, not absent.")
        case .unchanged:
            .localized("The reported version and build match the previous snapshot.")
        }
    }
}

struct DeviceInventoryReconciliation: Equatable, Sendable {
    let changes: [DeviceInventoryChange]
    let reportedCount: Int
    let unreportedCount: Int
    let capturedAt: Date

    var added: [DeviceInventoryChange] { changes.filter { $0.kind == .added } }
    var versionChanges: [DeviceInventoryChange] { changes.filter { $0.kind == .versionChanged } }
    var noLongerReported: [DeviceInventoryChange] { changes.filter { $0.kind == .noLongerReported } }

    var summary: String {
        String.localized(
            "%lld reported · %lld without a comparable report · %lld newly reported · %lld changed · %lld no longer reported",
            arguments: reportedCount, unreportedCount, added.count, versionChanges.count, noLongerReported.count
        )
    }
}

enum DeviceInventoryReconciler {
    /// Compares two snapshots, plus the library identifiers that were asked about. `wanted`
    /// is needed because a library app with no device report must remain visibly unknown.
    static func reconcile(
        previous: DeviceInventorySnapshot?,
        current: DeviceInventorySnapshot,
        wantedBundleIdentifiers: [String],
        now: Date = Date()
    ) -> DeviceInventoryReconciliation {
        let old = previous?.applications ?? []
        let new = current.applications
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.bundleIdentifier, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.bundleIdentifier, $0) })

        var changes: [DeviceInventoryChange] = []
        for app in new {
            guard let before = oldByID[app.bundleIdentifier] else {
                changes.append(DeviceInventoryChange(
                    bundleIdentifier: app.bundleIdentifier, name: app.name, kind: .added,
                    previousVersion: nil, currentVersion: app.version
                ))
                continue
            }
            let changed = before.version != app.version || before.build != app.build
            changes.append(DeviceInventoryChange(
                bundleIdentifier: app.bundleIdentifier, name: app.name,
                kind: changed ? .versionChanged : .unchanged,
                previousVersion: before.version, currentVersion: app.version
            ))
        }

        if current.isComplete {
            for app in old where newByID[app.bundleIdentifier] == nil {
                changes.append(DeviceInventoryChange(
                    bundleIdentifier: app.bundleIdentifier, name: app.name, kind: .noLongerReported,
                    previousVersion: app.version, currentVersion: nil
                ))
            }
        }

        var seen = Set(new.map(\.bundleIdentifier))
        for identifier in wantedBundleIdentifiers where DeviceApplicationInventory.isBundleIdentifier(identifier) {
            guard seen.insert(identifier).inserted else { continue }
            changes.append(DeviceInventoryChange(
                bundleIdentifier: identifier, name: .localized("Unknown app"), kind: .stillUnreported,
                previousVersion: oldByID[identifier]?.version, currentVersion: nil
            ))
        }

        return DeviceInventoryReconciliation(
            changes: changes.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.bundleIdentifier < $1.bundleIdentifier
            },
            reportedCount: new.count,
            unreportedCount: wantedBundleIdentifiers.filter { newByID[$0] == nil }.count,
            capturedAt: now
        )
    }

    /// Applies a fresh device reading to a prior snapshot without discarding metadata the
    /// device did not supply. A partial or wrong-session reading is rejected as a whole.
    static func applying(
        _ inventory: DeviceApplicationInventory,
        to previous: DeviceInventorySnapshot?,
        deviceID: String,
        complete: Bool,
        at date: Date = Date()
    ) -> DeviceInventorySnapshot? {
        guard inventory.binding.isWellFormed, !deviceID.isEmpty,
              inventory.observedAt.timeIntervalSince1970 >= 0 else { return nil }
        if let previous, previous.sessionBinding != inventory.binding {
            // A different pairing record or device cannot update this device's history.
            return nil
        }
        let oldByID = Dictionary(uniqueKeysWithValues: (previous?.applications ?? []).map { ($0.bundleIdentifier, $0) })
        var merged: [ManagedInstalledApplication] = []
        var seen = Set<String>()

        for reading in inventory.applications {
            guard let current = ManagedInstalledApplication(reading: reading), seen.insert(current.bundleIdentifier).inserted else {
                continue
            }
            let prior = oldByID[current.bundleIdentifier]
            let version = current.version ?? prior?.version
            let build = current.build ?? prior?.build
            let name = current.name.isEmpty ? (prior?.name ?? current.name) : current.name
            merged.append(ManagedInstalledApplication(
                bundleIdentifier: current.bundleIdentifier, name: name,
                version: version, build: build,
                observedAt: max(current.observedAt, prior?.observedAt ?? current.observedAt)
            ))
        }

        let snapshot = DeviceInventorySnapshot(
            deviceID: deviceID,
            sessionBinding: inventory.binding,
            capturedAt: inventory.observedAt,
            isComplete: complete,
            applications: merged
        )
        return snapshot.isWellFormed ? snapshot : nil
    }
}
