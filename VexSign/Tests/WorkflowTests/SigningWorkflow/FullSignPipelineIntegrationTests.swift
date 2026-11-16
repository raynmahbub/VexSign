//
//  FullSignPipelineIntegrationTests.swift
//  VexSignTests
//
//  Deterministic admission/ownership integration. No Apple credentials or device installation.
//

import Foundation
import XCTest
@testable import VexSign

@MainActor
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
            let importClaim = registry.claimProduction(of: testUUID)
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
