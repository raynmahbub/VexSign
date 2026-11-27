//
//  FullSignPipelineIntegrationTests.swift
//  VexSignTests
//
//  Deterministic admission/ownership integration. No Apple credentials or device installation.
//

import Foundation
import XCTest
import ZIPFoundation
@testable import VexSign

@MainActor
/// Pipeline wiring tests: identity refusal, import, task tracking, ownership and repacking.
///
/// This suite does NOT run `ZsignEngine` on a bundle and verify the output. Fresh-output verification
/// is pinned to Apple's production root, so it cannot be exercised with a generated chain. Until a
/// test-only trust seam exists, signing acceptance is covered by device tests, not this class.
final class FullSignPipelineIntegrationTests: XCTestCase {
    /// Exercise real import and the real pipeline's mandatory refusal without
    /// consulting ambient credentials, silently returning, swallowing a signing
    /// error, or enqueuing installation on the machine running the tests.
    func testImportAndMissingIdentityRefusalPreserveTheSourceWithoutInstalling() async throws {
        let testIPA = try createTestIPA()
        defer { try? FileManager.default.removeItem(at: testIPA.deletingLastPathComponent()) } // try? ok: synthetic archive cleanup
        let completed = expectation(description: "Synthetic IPA import completes")
        var imported: AppInfoPresentable?
        PackageImportService.importPackage(testIPA) { result in
            switch result {
            case .success(let app): imported = app
            case .failure(let error): XCTFail("Synthetic import failed: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 30)
        let app = try XCTUnwrap(imported)
        defer { XCTAssertTrue(Storage.shared.deleteApp(for: app), "Only the test-created library artifact may be removed.") }
        let snapshot = try CoreDataWorkspaceRepository(storage: Storage.shared).appRecord(app)
        let bundle = try XCTUnwrap(snapshot.bundleURL)
        let original = try SigningResolutionSession.sourceFingerprint(in: bundle)
        var options = Options.defaultOptions
        options.automaticallyResolveSigningIdentity = false
        options.post_installAppAfterSigned = false
        let review = try SigningResolutionSession.review(bundle: bundle, options: options,
            inventory: [], preferredIdentity: nil, deviceUDID: nil)
        XCTAssertFalse(review.isReady)
        XCTAssertNil(review.authorization)
        XCTAssertTrue(review.components.contains { $0.status == .invalid })
        XCTAssertTrue(review.components.flatMap(\.issues).contains { $0.contains("Import") })

        let request = SigningRequest(app: snapshot, options: options, icon: nil, certificate: nil).workerValue()
        let outcome = await SigningPipeline().run(request) { _ in
            XCTFail("A missing identity must refuse before reporting an execution stage.")
        }
        switch outcome {
        case .success: XCTFail("A synthetic import without an identity must never produce a signed artifact.")
        case .failure(let error): XCTAssertEqual(error as? SigningIdentityPolicy.Rejection, .missingCertificate)
        }
        XCTAssertEqual(original, try SigningResolutionSession.sourceFingerprint(in: bundle))
        XCTAssertEqual(snapshot.identifier, "com.vexsign.test.pipeline")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testIPA.path))
    }

    func testZipPackageUsesTheRealImportPipeline() async throws {
        let ipa = try createTestIPA()
        defer { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) } // try? ok: synthetic archive cleanup
        let zip = ipa.deletingLastPathComponent().appendingPathComponent("App.ZIP")
        try FileManager.default.copyItem(at: ipa, to: zip)
        let completed = expectation(description: "ZIP import completes")
        var imported: AppInfoPresentable?
        PackageImportService.importPackage(zip) { result in
            switch result {
            case .success(let app): imported = app
            case .failure(let error): XCTFail("ZIP import failed: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 30)
        let app = try XCTUnwrap(imported)
        defer { XCTAssertTrue(Storage.shared.deleteApp(for: app)) }
        let record = try CoreDataWorkspaceRepository(storage: Storage.shared).appRecord(app)
        XCTAssertEqual(record.identifier, "com.vexsign.test.pipeline")
        XCTAssertNotNil(record.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
    }

    /// Tests that UnifiedTaskCenter correctly tracks the pipeline stages
    func testUnifiedTaskCenterPipelineTracking() async throws {
        let center = UnifiedTaskCenter.shared
        let subject = "model-only-pipeline-" + UUID().uuidString
        
        // Start a download task
        let downloadTask = center.begin(kind: .download, title: "TestApp.ipa", phase: .downloading, subjectID: subject + "-download")
        XCTAssertEqual(downloadTask.phase, .downloading)
        
        // Transition through pipeline
        center.transition(downloadTask, to: .importing)
        XCTAssertEqual(downloadTask.phase, .importing)
        
        center.transition(downloadTask, to: .completed)
        XCTAssertEqual(downloadTask.phase, .completed)
        
        // Start a sign task
        let signTask = center.begin(kind: .sign, title: "TestApp", subtitle: "Signing", phase: .signing, subjectID: subject)
        XCTAssertEqual(signTask.phase, .signing)
        
        center.transition(signTask, to: .signed, progress: 1)
        center.transition(signTask, to: .completed, progress: 1)
        XCTAssertEqual(signTask.phase, .completed)
        
        // Start an install task
        let installTask = center.begin(kind: .install, title: "TestApp", subtitle: "Installing", phase: .preparingInstallation, subjectID: subject)
        XCTAssertEqual(installTask.phase, .preparingInstallation)
        
        center.transition(installTask, to: .waitingForIOS)
        center.transition(installTask, to: .installing)
        center.transition(installTask, to: .verifying)
        center.transition(installTask, to: .completed)
        XCTAssertEqual(installTask.phase, .completed)
        
        // Verify history contains all stages
        let history = center.history
        for task in [downloadTask, signTask, installTask] {
            XCTAssertTrue(history.contains { $0.id == task.id })
        }
    }

    /// Tests AppOperationRegistry correctly manages ownership across pipeline stages
    func testAppOperationRegistryPipelineOwnership() async throws {
        let registry = AppOperationRegistry()
        let testUUID = "test-pipeline-\(UUID().uuidString)"
        let key = "signed:\(testUUID)"

        // Import claims production
        do {
            let importClaim = try registry.claimProduction(of: testUUID)
            XCTAssertTrue(registry.knowsProduction(of: testUUID))

            // Import confirms production
            registry.confirmProduction(of: testUUID)
            XCTAssertTrue(registry.knowsProduction(of: testUUID))
            withExtendedLifetime(importClaim) {}
        }

        // A confirmed copy stays known after its claim is gone
        XCTAssertTrue(registry.knowsProduction(of: testUUID))

        // Sign acquires ownership; a second claim on the same copy is refused while it is held
        do {
            let signLease = try registry.acquire(key)
            XCTAssertTrue(registry.isBusy(key))
            XCTAssertThrowsError(try registry.acquire(key))

            // Cleanup cannot run while an operation holds a stored copy
            XCTAssertNil(registry.acquireCleanup())
            withExtendedLifetime(signLease) {}
        }

        // Releasing the lease frees the copy for cleanup
        XCTAssertFalse(registry.isBusy(key))
        XCTAssertNotNil(registry.acquireCleanup())
    }

    /// Import → artifact, end to end: the bundle the library holds must re-zip into an IPA that
    /// the installer's own validator accepts and that keeps the `Payload/` layout it came from.
    ///
    /// This is the half of the sign chain that does not need an Apple identity, and it is the half
    /// that breaks in practice — an import that unpacks correctly but cannot be repackaged leaves
    /// the user with an app they can see and cannot install. The producing half (a *verified
    /// signed* artifact) needs an Apple-authorised identity, which the simulator suite does not
    /// have; `TESTS.md` records that, and `make test-signing-core` covers the native sealer's
    /// CodeDirectory, hashing and CMS independently.
    func testImportedBundleRepackagesIntoACompleteArtifact() async throws {
        let ipa = try createTestIPA()
        defer { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) } // try? ok: synthetic archive cleanup

        let completed = expectation(description: "Synthetic IPA import completes")
        var imported: AppInfoPresentable?
        PackageImportService.importPackage(ipa) { result in
            switch result {
            case .success(let app): imported = app
            case .failure(let error): XCTFail("Synthetic import failed: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 30)
        let app = try XCTUnwrap(imported)
        defer { XCTAssertTrue(Storage.shared.deleteApp(for: app), "Only the test-created library artifact may be removed.") }

        let record = try CoreDataWorkspaceRepository(storage: Storage.shared).appRecord(app)
        let bundle = try XCTUnwrap(record.bundleURL)
        XCTAssertEqual(record.identifier, "com.vexsign.test.pipeline")

        let directory = ipa.deletingLastPathComponent()
        let repackaged = directory.appendingPathComponent("Repackaged.ipa")
        try AppArchiver.archive(appDir: bundle, to: repackaged, compression: .defaultCompression)

        let scratch = directory.appendingPathComponent("validator", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        XCTAssertNoThrow(
            try ArchiveSafetyValidator.validate(repackaged, destination: scratch),
            "the artifact the installer consumes must pass the same validator the import path applies"
        )
        // The library may rename the bundle it stores, so the artifact is checked by shape
        // rather than by comparing directory names with the source archive.
        let entries = try Self.entryPaths(in: repackaged)
        let bundles = Set(entries.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "Payload", parts[1].hasSuffix(".app") else { return nil }
            return String(parts[1])
        })
        XCTAssertEqual(bundles.count, 1, "One Payload folder holding one app bundle")
        let prefix = "Payload/" + (bundles.first ?? "")
        XCTAssertTrue(entries.contains(prefix + "/Info.plist"), "The artifact must carry the bundle's metadata")
        let executable = try XCTUnwrap(SigningInputValidation.executable(in: bundle))
        XCTAssertTrue(
            entries.contains(prefix + "/" + executable.lastPathComponent),
            "The artifact must carry the executable it was asked to install"
        )
    }

    /// Every entry path in an archive, sorted, so an artifact's layout can be inspected.
    private static func entryPaths(in url: URL) throws -> [String] {
        let archive = try Archive(url: url, accessMode: .read)
        return archive.map(\.path).sorted()
    }

    /// Non-runnable generated Mach-O data, not a dummy text executable or an
    /// Apple-signed fixture. Import inspection must not claim authenticated signing.
    private func createTestIPA() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TestPipeline-" + UUID().uuidString)
        let payload = directory.appendingPathComponent("Payload")
        let bundle = payload.appendingPathComponent("TestApp.app")
        do {
            try SigningRegressionFixture.bundle(at: bundle, identifier: "com.vexsign.test.pipeline")
            var info = try XCTUnwrap(SignatureVerifier.readInfo(at: bundle))
            info["CFBundleName"] = "Synthetic pipeline fixture"
            info["CFBundleVersion"] = "1"
            info["CFBundleShortVersionString"] = "1.0"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Info.plist"))
            let ipa = directory.appendingPathComponent("TestApp.ipa")
            try AppArchiver.zip(payload: payload, to: ipa, compression: .defaultCompression) { _ in }
            return ipa
        } catch {
            try? FileManager.default.removeItem(at: directory) // try? ok: retain the original fixture-creation failure
            throw error
        }
    }
}
