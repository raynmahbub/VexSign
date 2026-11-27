// Deterministic device lifecycle tests. No pairing file, network, device service or
// simulator is involved: the service responses below are values, not production fakes.

import Foundation
import XCTest
import NimbleExtensions
#if canImport(DeviceFoundation)
@testable import DeviceFoundation
#else
@testable import IDeviceSwift
#endif
@testable import VexSign

final class DeviceLifecycleTests: XCTestCase {
    private let udid = "00008120-001A2B3C4D5E6F70"
    private let otherUDID = "00008130-001A2B3C4D5E6F71"
    private let digest = String(repeating: "a", count: 64)
    private let observedAt = Date(timeIntervalSince1970: 2_000_000)

    private func binding(_ identifier: String = "00008120-001A2B3C4D5E6F70") -> DeviceSessionBinding {
        guard let value = DeviceSessionBinding(deviceIdentifier: identifier, pairingSHA256: digest) else {
            XCTFail("fixture binding")
            fatalError()
        }
        return value
    }

    private func application(bundle: String = "com.example.app", version: String? = "1.2",
                             build: String? = "7", at: Date? = nil) -> DeviceInstalledApplication {
        DeviceInstalledApplication(bundleIdentifier: bundle, name: "Example", version: version,
            build: build, path: "/private/var/containers/Bundle/Application/A/App.app",
            binding: binding(), observedAt: at ?? observedAt)
    }

    private func snapshot(bundle: String = "com.example.app", version: String? = "1.2",
                          build: String? = "7", complete: Bool = true) -> DeviceInventorySnapshot {
        let inventory = DeviceApplicationInventory(
            applications: [application(bundle: bundle, version: version, build: build)],
            binding: binding(), observedAt: observedAt
        )
        return DeviceInventoryReconciler.applying(inventory, to: nil, deviceID: udid, complete: complete)!
    }

    private func store() -> (DeviceLifecycleStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VexSignLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        return (DeviceLifecycleStore(database: EcosystemDatabase(root: root)), root)
    }

    private func device(id: String = "00008120-001A2B3C4D5E6F70", name: String = "Test iPhone") -> ManagedDeviceRecord {
        ManagedDeviceRecord(id: id, hasStableIdentifier: true, name: name, link: .paired,
                            pairing: .readable, trust: .unverified)
    }

    private func catalogApp(version: String = "2.0", sha: String? = String(repeating: "b", count: 64),
                            minimumOS: String? = nil, size: Int64? = nil) -> CatalogAppRecord {
        let release = CatalogRelease(version: version, date: nil,
            downloadURL: "https://example.com/app.ipa", size: size, sha256: sha,
            changelog: nil, minimumOSVersion: minimumOS, supportedDevices: [], installName: nil)
        return CatalogAppRecord(id: "source-\(version)", sourceID: "source", sourceName: "Example Source",
            sourceURL: "https://example.com/source.json", bundleIdentifier: "com.example.app",
            name: "Example", developer: nil, summary: nil, description: nil, iconURL: nil,
            screenshotURLs: [], category: nil, tintColor: nil, releases: [release], permissions: [],
            extra: [:], fetchedAt: observedAt, metadataIsVerified: false)
    }

    private func context(apps: [CatalogAppRecord], installedVersion: String? = "1.2",
                         os: String? = "18.0", capabilities: Bool = true,
                         available: Int64? = 1_000_000) -> DeviceUpdateContext {
        let installed = installedVersion.map {
            ManagedInstalledApplication(bundleIdentifier: "com.example.app", name: "Example",
                                        version: $0, build: "7", observedAt: observedAt)
        } ?? nil
        let caps = capabilities ? [StoredDeviceCapability(operation: .pairedInstall,
                                                          status: .supported, detail: "fixture")] : []
        return DeviceUpdateContext(installedApplications: installed.flatMap { [$0] } ?? [],
            catalogApps: apps, deviceOSVersion: os, capabilities: caps,
            signingIdentityAvailable: true, availableBytes: available, now: observedAt)
    }

    // MARK: Device records

    func testIdentityIsStableForUDIDAndPseudonymousWithoutOne() {
        let primary = ManagedDeviceRecord.identity(udid: udid, pairingFingerprint: digest)
        let uppercase = ManagedDeviceRecord.identity(udid: udid.uppercased(), pairingFingerprint: digest)
        XCTAssertEqual(primary?.id, uppercase?.id)
        XCTAssertEqual(primary?.stable, true)

        let fallback = ManagedDeviceRecord.identity(udid: nil, pairingFingerprint: digest)
        XCTAssertEqual(fallback?.stable, false)
        XCTAssertNotEqual(fallback?.id, digest)
        XCTAssertEqual(fallback?.id, ManagedDeviceRecord.identity(udid: nil, pairingFingerprint: digest)?.id)
        XCTAssertNil(ManagedDeviceRecord.identity(udid: nil, pairingFingerprint: nil))
    }

    func testMultipleDeviceRecordsPersistIndependentlyAndDuplicatesAreRejected() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.save(devices: [device(), device(id: otherUDID, name: "Second iPhone")])
        let loaded = try await store.devices()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.id)), [udid, otherUDID])

        try await store.removeDevice(id: otherUDID)
        XCTAssertEqual(try await store.devices().map(\.id), [udid])

        let inventory = DeviceApplicationInventory(
            applications: [application()], binding: binding(), observedAt: observedAt
        )
        let saved = DeviceInventoryReconciler.applying(inventory, to: nil, deviceID: udid, complete: true)!
        try await store.saveInventory(saved)
        XCTAssertEqual(try await store.inventory(deviceID: udid)?.applications.count, 1)
        var sync = DeviceSyncState(deviceID: udid)
        sync.status = .synced
        try await store.saveSyncState(sync)
        XCTAssertEqual(try await store.syncState(deviceID: udid)?.status, .synced)

        var collection = ManagedDeviceCollection(devices: [device(), device()])
        XCTAssertFalse(collection.isWellFormed)
        collection.devices = [device()]
        XCTAssertTrue(collection.isWellFormed)
    }

    // MARK: Inventory

    func testPartialResponseDoesNotEraseMetadataOrClaimRemoval() {
        let prior = snapshot()
        let partial = DeviceApplicationInventory(applications: [application(version: nil, build: nil)],
                                                 binding: binding(), observedAt: observedAt.addingTimeInterval(10))
        let next = DeviceInventoryReconciler.applying(partial, to: prior, deviceID: udid, complete: false)
        XCTAssertNotNil(next)
        XCTAssertEqual(next?.applications.first?.version, "1.2")
        XCTAssertEqual(next?.applications.first?.build, "7")
        let diff = DeviceInventoryReconciler.reconcile(previous: prior, current: next!,
                                                       wantedBundleIdentifiers: ["com.example.app"])
        XCTAssertTrue(diff.noLongerReported.isEmpty)
        XCTAssertTrue(diff.changes.allSatisfy { $0.kind != .noLongerReported })
    }

    func testForeignBindingCannotOverwriteSnapshot() {
        let other = DeviceSessionBinding(deviceIdentifier: otherUDID, pairingSHA256: digest)
        let foreign = DeviceApplicationInventory(applications: [application()], binding: other,
                                                  observedAt: observedAt)
        XCTAssertNil(DeviceInventoryReconciler.applying(foreign, to: snapshot(), deviceID: udid, complete: true))
    }

    func testCompleteSnapshotDetectsAddedChangedAndNoLongerReportedApps() {
        let prior = snapshot()
        let newInventory = DeviceApplicationInventory(
            applications: [application(bundle: "com.example.new", version: "1.0", build: "1")],
            binding: binding(), observedAt: observedAt.addingTimeInterval(60)
        )
        let next = DeviceInventoryReconciler.applying(newInventory, to: prior, deviceID: udid, complete: true)!
        let diff = DeviceInventoryReconciler.reconcile(previous: prior, current: next,
                                                       wantedBundleIdentifiers: [])
        XCTAssertEqual(diff.added.count, 1)
        XCTAssertEqual(diff.noLongerReported.map(\.bundleIdentifier), ["com.example.app"])

        let changed = DeviceApplicationInventory(
            applications: [application(version: "2.0", build: "8")],
            binding: binding(), observedAt: observedAt.addingTimeInterval(120)
        )
        let changedSnapshot = DeviceInventoryReconciler.applying(changed, to: prior, deviceID: udid, complete: true)!
        let versionDiff = DeviceInventoryReconciler.reconcile(previous: prior, current: changedSnapshot,
                                                              wantedBundleIdentifiers: [])
        XCTAssertEqual(versionDiff.versionChanges.count, 1)
    }

    // MARK: Library and updates

    func testLibraryComparisonSeparatesDuplicatesDifferencesAndDeviceOnlyApps() {
        let first = LibraryAppRecord(id: "a", uuid: nil, isSigned: true, name: "A", version: "1.2",
            identifier: "com.example.app", originalIdentifier: nil, date: nil, icon: nil,
            appDescription: nil, sortIndex: 0, source: nil, certificateID: nil, bundleURL: nil, artifactURL: nil)
        let duplicate = LibraryAppRecord(id: "b", uuid: nil, isSigned: true, name: "B", version: "1.2",
            identifier: "com.example.app", originalIdentifier: nil, date: nil, icon: nil,
            appDescription: nil, sortIndex: 1, source: nil, certificateID: nil, bundleURL: nil, artifactURL: nil)
        let deviceOnly = snapshot(bundle: "com.example.only")
        let comparison = DeviceLibraryReconciler.compare(libraryApps: [first, duplicate], snapshot: deviceOnly)
        XCTAssertEqual(comparison.matches.count, 2)
        XCTAssertTrue(comparison.matches.contains { $0.state == .duplicateIdentifier })
    }

    func testUpdatePlannerRejectsDowngradesIncompatibleRoutesAndBadIntegrity() {
        XCTAssertEqual(DeviceUpdatePlanner.plans(context(apps: [catalogApp(version: "1.0")],
                                                          installedVersion: "1.2")).first?.verdict,
                       .downgradeRejected)
        XCTAssertEqual(DeviceUpdatePlanner.plans(context(apps: [catalogApp()], capabilities: false)).first?.verdict,
                       .incompatible)
        XCTAssertEqual(DeviceUpdatePlanner.plans(context(apps: [catalogApp(sha: "short")])).first?.verdict,
                       .incompatible)
        XCTAssertEqual(DeviceUpdatePlanner.plans(context(apps: [catalogApp(minimumOS: "99.0")])).first?.verdict,
                       .incompatible)
        XCTAssertEqual(DeviceUpdatePlanner.plans(context(apps: [catalogApp(size: 5_000_000)],
                                                          available: 1_000_000)).first?.verdict,
                       .incompatible)
    }

    func testCompatibleUpdateIsResolvedThroughExistingDownloadPipeline() {
        let plan = DeviceUpdatePlanner.plans(context(apps: [catalogApp()])).first
        XCTAssertEqual(plan?.verdict, .updateAvailable)
        XCTAssertEqual(plan?.download?.url.absoluteString, "https://example.com/app.ipa")
        XCTAssertTrue(plan?.canDownload == true)
    }

    func testStaleSnapshotAndNeverSyncedState() {
        let stale = DeviceInventorySnapshot(
            deviceID: udid, sessionBinding: binding(),
            capturedAt: Date(timeIntervalSince1970: 1_000_000),
            isComplete: true, applications: []
        )
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.freshnessTitle, .localized("Stale inventory"))
        XCTAssertEqual(DeviceSyncState(deviceID: udid).status, .never)
    }

    func testBackupRestoreConflictResolverDoesNotAllowSilentOverwrite() {
        let archive = BackupArchiveSnapshot(id: UUID(), createdAt: observedAt,
            appVersion: "1.0", schemaVersion: 1, contents: .library,
            counts: [.library: 1],
            integrity: BackupIntegrity(packSHA256: digest, certificateEntries: 0, certificateDirectories: 0))
        let conflicts = DeviceRestoreConflictResolver.conflicts(
            archive: archive, existingBundleIdentifiers: ["com.example.app"]
        )
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertTrue(conflicts.first?.detail.contains("keeps the existing record") == true)
        let empty = DeviceRestoreConflictResolver.conflicts(
            archive: archive, existingBundleIdentifiers: []
        )
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: Backup

    func testBackupScopeRequiresPasswordForCertificatesAndDeclaresBoundaries() {
        var scope = DeviceBackupScope()
        scope.includeCertificates = true
        XCTAssertThrowsError(try scope.validate())
        scope.password = String(repeating: "x", count: 16)
        XCTAssertNoThrow(try scope.validate())
        XCTAssertTrue(scope.exclusions.contains { $0.reason == .thirdPartySandbox })
        XCTAssertTrue(scope.exclusions.contains { $0.reason == .ipaData })
    }
}
