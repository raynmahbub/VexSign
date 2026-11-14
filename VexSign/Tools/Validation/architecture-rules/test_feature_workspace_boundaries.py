#!/usr/bin/env python3
"""Portable source regressions for the consumed workspace boundaries.

These pin wiring and safety-critical ordering. They intentionally do NOT claim
Swift compilation, native behavioral execution, signing or device acceptance.
The corresponding fake-provider/Core Data XCTest cases require Xcode.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[4]
APP = ROOT / "VexSign/App/iOS/VexSign"


def code(path: str) -> str:
    return (APP / path).read_text(encoding="utf-8")


class FeatureWorkspaceBoundaryTests(unittest.TestCase):
    def require(self, path: str, *tokens: str) -> str:
        source = code(path)
        for token in tokens:
            self.assertIn(token, source, f"{path}: missing boundary invariant {token}")
        return source

    def test_composition_consumes_the_existing_owners_instead_of_duplicate_lifecycles(self):
        self.require("App/Composition/AppContainer.swift",
            "CoreDataWorkspaceRepository(storage: Storage.shared)",
            "SourceCatalogStore.shared", "UnifiedTaskCenter.shared", "DownloadManager.shared",
            "AppleAccountWorkspaceAdapter(manager: NativeSigningManager.shared", "BackupWorkspaceAdapter(manager: BackupManager.shared)",
            "LibraryCloningAdapter(repository: workspaceRepository, cloner: AppCloner.shared)",
            "CompanionArchiveAdapter(repository: workspaceRepository, sharing: sharing)")

    def test_library_references_are_store_bound_and_wrong_signedness_fails_closed(self):
        self.require("Infrastructure/Persistence/Repositories/CoreDataWorkspaceRepository.swift",
            'reference.isSigned ? "Signed" : "Imported"', "managedObjectID(forURIRepresentation: uri)",
            'id.entity.name == expected', "app.uuid == reference.uuid", "app.isSigned == reference.isSigned",
            "rows.count == 1", "row.managedObjectContext === storage.context")
        self.require("Domain/Entities/LibraryApp.swift", '"\(isSigned ? "signed" : "imported"):\(uuid)"')

    def test_typed_app_projections_cannot_bypass_the_store_admission_gate(self):
        source = self.require("Infrastructure/Persistence/Repositories/CoreDataWorkspaceRepository.swift",
            "func appRecord(_ app: AppInfoPresentable) throws -> LibraryAppRecord",
            "signedApps: try signed.map { try appRecord($0) }",
            "importedApps: try imported.map { try appRecord($0) }")
        self.assertNotRegex(source, r"\bfunc\s+appRecord\s*\(\s*_\s+\w+\s*:\s*(?:Signed|Imported)\s*\)",
            "A statically typed row must not resolve to an unchecked overload")
        projection = source.split("func appRecord(_ app: AppInfoPresentable) throws -> LibraryAppRecord", 1)[1].split("private func appRecord", 1)[0]
        for token in ["app as? NSManagedObject", "row.managedObjectContext === storage.context",
                      "!row.isDeleted", "!row.objectID.isTemporaryID", "throw WorkspaceAccessError.mismatchedRecord"]:
            self.assertLess(projection.index(token), projection.index("if let signed"),
                "Admission must happen before a foreign/deleted row's relationships are read")
        for attribute in ["signed.sortIndex", "signed.source", "signed.certificate", "imported.sortIndex", "imported.source"]:
            self.assertGreater(projection.index(attribute), projection.index("!row.objectID.isTemporaryID"))

    def test_app_projection_failures_propagate_through_all_typed_result_consumers(self):
        self.require("Infrastructure/Tasks/BatchSigningAdapter.swift", "signed: try item.signed.map { try repository.appRecord($0) }")
        self.require("Infrastructure/Signing/Execution/LibrarySigningAdapter.swift",
            "case .success(let signed): onEvent(.finished(Result { try repository.appRecord(signed) }))")
        self.require("Infrastructure/Archives/IPA/ArchiveWorkspaceAdapter.swift", "return try repository.appRecord(signed)")
        self.require("Infrastructure/Persistence/Database/Storage+Shared.swift",
            "context.fetch(Signed.fetchRequest()).map { try adapter.appRecord($0) }",
            "context.fetch(Imported.fetchRequest()).map { try adapter.appRecord($0) }")

    def test_update_toggle_reads_immutable_library_snapshots_on_their_owner(self):
        source = self.require("Infrastructure/Updates/UpdateMatchingPreferences.swift",
            "Storage.shared.getSignedApps()", "Storage.shared.getImportedApps()")
        self.assertRegex(source, r"@MainActor\s+func toggleAutoUpdate\(for uuid: String\)")
        storage = code("Infrastructure/Persistence/Database/Storage+Shared.swift")
        for method in ["getSignedApps", "getImportedApps"]:
            self.assertRegex(storage, r"@MainActor\s+func " + method + r"\(\)",
                "Fix consumers rather than weakening the persistence executor boundary")

    def test_scheduled_certificate_monitoring_uses_the_shared_inspection_owner_not_a_view_model(self):
        maintenance = self.require("Infrastructure/Tasks/EcosystemMaintenance.swift",
            "try await CertificateInspector.inspectAll(online: true)", "report.errors.isEmpty",
            "for cert in report.certificates", "guard !Task.isCancelled else { return }")
        self.assertNotIn("CertificateDashboardViewModel", maintenance)
        self.require("Infrastructure/Identity/CertificateWorkspaceAdapter.swift",
            "try await CertificateInspector.inspectAll(storage: storage, online: online)")
        inspector = self.require("Infrastructure/Identity/CertificateInspector.swift",
            "storage.getAllCertificates()", "try Task.checkCancellation()", "CertificateHealthReport(certificates: health, errors: errors)")
        self.assertRegex(inspector, r"@MainActor\s+static func inspectAll")
        self.assertEqual(inspector.count("storage.getAllCertificates()"), 1)

    def test_stream_termination_releases_subscriptions_and_producers_hop_to_their_owner(self):
        for path in ["Infrastructure/Tasks/TaskWorkspaceAdapter.swift", "Infrastructure/Identity/CertificateWorkspaceAdapter.swift",
                     "Infrastructure/Tasks/BatchSigningAdapter.swift", "Infrastructure/Signing/Engines/Cloud/CloudConfigurationAdapter.swift"]:
            self.require(path, "bufferingNewest(1)", "StreamObservationCancellation", "continuation.onTermination", "Task { @MainActor")
        owner = self.require("Infrastructure/Observation/StreamObservationCancellation.swift", "NSLock()", "subscriptions = []", "lock.unlock()", "current.forEach { $0.cancel() }")
        self.assertLess(owner.index("lock.unlock()"), owner.index("current.forEach { $0.cancel() }"))

    def test_direct_install_admission_outlives_cancelled_workers_without_undoing_commits(self):
        source = self.require("Application/Installation/DirectPackageInstallUseCase.swift",
            "guard !working else { throw ArchitectureDomainError.duplicateOrBusyOperation }",
            "working = true", "defer { working = false }", "guard !retired else { throw CancellationError() }",
            "if pendingPackage != package { installation.releaseImportedPackage(package) }")
        execute = source.split("func execute(", 1)[1].split("func confirmPendingInstall()", 1)[0]
        self.assertLess(execute.index("guard !working"), execute.index("releasePendingPackage()"))
        self.assertLess(execute.index("try Task.checkCancellation()"), execute.index("releasePendingPackage()"))
        self.assertRegex(execute, r'onStatus\(NSLocalizedString\("Importing…", comment: ""\)\)\s*try checkAdmission\(\)')
        imported = execute.split("let package = try await installation.importPackage(downloadedURL)", 1)[1]
        self.assertLess(imported.index("try checkAdmission()"), imported.index("installation.submitInstallation"))
        warning = imported.split("catch DirectInstallationRequestError.verificationFailed", 1)[1]
        self.assertLess(warning.index("try checkAdmission()"), warning.index("pendingPackage = package"))
        cancellation = source.split("func cancel()", 1)[1].split("func execute(", 1)[0]
        self.assertIn("retired = true", cancellation)
        self.assertIn("releasePendingPackage()", cancellation)
        self.assertNotIn("working = false", cancellation, "A cancelled worker must finish before admission/lease release")
        self.require("Infrastructure/Devices/Installation/DirectPackageInstallationAdapter.swift",
            "withTaskCancellationHandler", "cancellation.adopt(worker)", "onCancel: { cancellation.cancel() }")

    def test_direct_install_callbacks_are_bound_to_the_visible_reviewed_request(self):
        source = self.require("Presentation/Features/Installation/ViewModels/DirectInstallViewModel.swift",
            "private var operation: Task<Void, Never>?", "guard isVisible, !isProcessing else { return }",
            "isVisible && generation == attempt", "let mode = selectedMode", "mode: mode",
            "self?.confirmAnyway(for: attempt, onComplete: onComplete)",
            "guard isCurrent(attempt), pendingConfirmation == attempt", "let result = try useCase.confirmPendingInstall()",
            "present(result, for: attempt, onComplete: onComplete)")
        disappeared = source.split("func disappear()", 1)[1].split("func startInstall", 1)[0]
        self.assertLess(disappeared.index("generation = nil"), disappeared.index("operation?.cancel()"))
        self.assertIn("useCase.cancel()", disappeared)
        self.assertLess(source.index("let mode = selectedMode"), source.index("operation = Task"))
        confirmation = source.split("private func confirmAnyway", 1)[1]
        self.assertLess(confirmation.index("pendingConfirmation = nil"), confirmation.index("useCase.confirmPendingInstall()"))
        self.assertIn('case .submittedForGuestImport:', source)
        self.assertIn('systemImage: "shippingbox"', source)
        self.require("Presentation/Features/Library/Views/DirectInstallSheet.swift",
            ".onAppear { viewModel.appear() }", ".onDisappear { viewModel.disappear() }")

    def test_batch_callbacks_are_bound_to_installer_generation_and_entry(self):
        source = self.require("Infrastructure/Tasks/BatchJobRunner.swift", "[weak self, weak installer]", "self.currentInstaller === installer",
            "self.installGeneration == generation", "self.items[self.currentIndex].id == entryID", "installGeneration = nil",
            "installer.stop(preserveHandoff: handedOff && (_skipRequested || _cancelled))")
        callback = source.split("installer.start {", 1)[1].split("let handedOff", 1)[0]
        self.assertLess(callback.index("self.installGeneration == generation"), callback.index("self._resumeInstall("))
        self.require("Infrastructure/Tasks/BatchSigningAdapter.swift", "withTaskCancellationHandler", "runner.cancel()")

    def test_certificate_commit_precedes_secret_cleanup_and_failed_save_is_local(self):
        source = code("Infrastructure/Persistence/Database/Storage+Certificate.swift")
        deletion = source.split("func deleteCertificate(for cert: CertificatePair, saveDeletion:", 1)[1].split("static var certificateDeletionRoot", 1)[0]
        for token in ["cert.managedObjectContext === context", "deletion.rollback()", "try saveDeletion(deletion)", "CertificateStatusManager.shared.removeRevocationSnapshot"]:
            self.assertIn(token, deletion)
        self.assertLess(deletion.index("try saveDeletion(deletion)"), deletion.index("try SecureSecretStore.delete"))
        self.assertLess(deletion.index("try saveDeletion(deletion)"), deletion.index("try FileManager.default.removeItem(at: directory)"))
        self.assertNotIn("Task {", deletion, "UUID invalidation must retire checks before synchronous undo")
        insertion = source.split("func addCertificate(", 1)[1].split("func deleteCertificate(", 1)[0]
        self.assertLess(insertion.index("UUID(uuidString: uuid)"), insertion.index("try SecureSecretStore.write"))
        self.assertLess(insertion.index("try context.fetch(existing).isEmpty"), insertion.index("try SecureSecretStore.write"))
        self.assertIn("new.date = date\n", insertion)
        self.assertIn("new.revoked = revoked", insertion)
        self.assertIn("row.certificate == nil", insertion)

    def test_certificate_failed_rollback_is_durable_not_a_temporary_sweep_target(self):
        source = self.require("Infrastructure/Identity/CertificateRemoval.swift", "StagedAppDeletion(root: Storage.certificateDeletionRoot",
            "retainingManifest: true", "try token.stage()", "saveDeletion: saveDeletion", "SecureSecretStore.read")
        self.assertNotIn("RecoverableFileRemoval.remove(", source)
        self.assertNotIn("cert.requireSigningPassword()", source, "undo preparation must not persist unrelated view edits through migration")
        self.require("Infrastructure/Persistence/Database/Storage+Certificate.swift", "recoverPendingCertificateDeletions()", "request.includesPendingChanges = false",
            "allowedCertificateDeletionOriginal", "FileManager.default.certificates.resolvingSymlinksInPath()",
            "containsCertificateIdentity(uuid: entry.original.lastPathComponent)", 'NSPredicate(format: "uuid ==[c] %@", uuid)',
            "return committed || pending", "persistentStoreCoordinator.persistentStores.isEmpty", "removingUnownedOriginals: true")
        self.assertIn("storage.recoverCertificateDeletion(token)", source, "expiry must retain journal ownership even after failed re-stage")
        self.assertIn("storage.containsCertificateIdentity(uuid: snapshot.uuid)", source)
        self.assertIn("offer = try _prepareUndo", source)
        self.assertIn("Certificate files could not be set aside; deletion refused.", source)
        journal = self.require("Infrastructure/Persistence/Database/StagedAppDeletion.swift", "removingUnownedOriginals: Bool = false",
            "if removingUnownedOriginals, FileManager.default.fileExists(atPath: entry.original.path)", "try remove(entry.original)")
        self.assertLess(journal.index("let decisions = try entries.map"), journal.index("try remove(entry.original)"))
        self.require("App/Lifecycle/AppDelegate.swift", "Storage.shared.recoverPendingCertificateDeletions()")
        self.require("Application/Shared/RemovalUndoLease.swift", "static let window: Duration = .seconds(6)", "precondition(Thread.isMainThread)", "ContinuousClock().now < deadline", "restore = nil", "discard = nil")

    def test_late_certificate_checks_cannot_publish_for_an_undone_or_reimported_row(self):
        self.require("Infrastructure/Identity/CertificateStatusManager.swift", "revocationJobs[uuid] == generation", "!Task.isCancelled",
            "let objectID = cert.objectID", 'NSPredicate(format: "SELF == %@", objectID)', "row === cert",
            "revocationTasks.removeValue(forKey: uuid)?.cancel()")
        self.require("Infrastructure/Persistence/Database/Storage+Certificate.swift", "let certObjectID = cert.objectID",
            "self._certificate(objectID: certObjectID, uuid: certUUID)")

    def test_signing_completion_uses_reviewed_inputs_and_consumes_each_action_once(self):
        source = self.require("Application/Signing/SigningWorkspaceUseCase.swift", "self.active[request.id] == invocation", "successfulRuns[request.id]",
            "!run.captured", "!run.settled", "try LibraryAppReference(app: output) == run.output",
            "deletesSource == run.request.options.post_deleteAppAfterSigned", "try provider.captureSuccessfulRun(run.request)",
            "try provider.finishSuccessfulRun(run.request, output: run.output, deletesSource: deletesSource)")
        self.assertLess(source.index("run.captured = true"), source.index("try provider.captureSuccessfulRun"))
        self.assertLess(source.index("run.settled = true"), source.index("try provider.finishSuccessfulRun"))
        self.require("Presentation/Features/Signing/Views/SigningView.swift", "for: app, requestID: requestID",
            "deletesSource: runOptions.post_deleteAppAfterSigned, requestID: requestID")
        self.require("Infrastructure/Signing/Execution/NamedSigningProfileStore.swift", "JSONEncoder().encode(profiles.map { $0.withoutOneShotFiles() })")

    def test_account_approvals_and_closed_cms_gate_remain_separate(self):
        self.require("Application/Accounts/AppleAccountWorkspaceUseCase.swift", "guard approval.isComplete", "guard consentGiven", "guard !provisioning", "try Task.checkCancellation()")
        source = self.require("Infrastructure/Accounts/AppleAccountWorkspaceAdapter.swift", "try requireContext(request.contextID)",
            "try await manager.requireProfileOperations()", "recordCertificateCreationApproval", "recordRegistrationApproval", "recordProfileCreationApproval",
            "recordKeyExportConsent", "pendingProfiles[receiptID]", "pendingProfiles.removeValue(forKey: receiptID)", "currentApp.identifier == bundleID", "profile.expiresAt > Date()")
        self.assertLess(source.index("try await manager.requireProfileOperations()"), source.index("try await manager.provisioningPreflight("))
        self.assertLess(source.index("try await manager.requireProfileOperations()"), source.index("try await manager.prepareSigningIdentity("))

    def test_backup_boundary_contains_only_allowlisted_preview_metadata(self):
        domain = code("Domain/Entities/BackupWorkspace.swift")
        preview = domain.split("struct BackupArchiveSnapshot", 1)[1].split("struct BackupComponents", 1)[0]
        for forbidden in ["password", "manifest:", "root:", "BackupArchive", "FileManager"]:
            self.assertNotIn(forbidden, preview)
        self.require("Application/Backups/BackupWorkspaceUseCase.swift", "components.subtracting(preview.contents).isEmpty", "provider.release(archiveID: preview.id)")
        self.require("Infrastructure/Backups/BackupWorkspaceAdapter.swift", "private var opened: [UUID: BackupArchive]", "manager.restore(archive, components: components)")

    def test_backup_completion_and_restart_are_owned_by_the_visible_operation(self):
        state = self.require("Presentation/Features/Backups/Models/BackupPresentationState.swift",
            "isVisible && generation == attempt", "guard isVisible else { return nil }",
            "guard isCurrent(attempt), completedRestore != attempt", "guard isCurrent(completion.generation)")
        hidden = state.split("mutating func disappear()", 1)[1].split("mutating func beginOperation()", 1)[0]
        for token in ["isVisible = false", "generation = nil", "restoreCompletion = nil"]:
            self.assertIn(token, hidden)
        take = state.split("mutating func takeRestoreCompletion()", 1)[1]
        self.assertLess(take.index("restoreCompletion = nil"), take.index("return completion"))
        view = self.require("Presentation/Features/Backups/Views/BackupView.swift",
            "presentationState.completeRestore(summary, for: attempt)", "try await Task.sleep(for: .milliseconds(350))",
            "pending.generation == generation", "let offerGeneration = _exportPickerGeneration",
            "if openedArchiveID == archive.id", "presentationState.isCurrent(archiveGeneration)",
            "guard let presenter = UIApplication.topViewController()")
        self.assertNotIn("DispatchQueue.main.asyncAfter", view, "The completion delay must be cancellable and owned by the screen task")
        self.assertNotIn("_pendingSummary", view, "Unbound completion state must not survive a retired screen")
        disappeared = view.split(".onDisappear {", 1)[1].split("private func _beginOperation", 1)[0]
        self.assertLess(disappeared.index("presentationState.disappear()"), disappeared.index("operation?.cancel()"))
        completion = view.split("private func _presentRestoreComplete()", 1)[1]
        self.assertLess(completion.index("guard !_isWorking, _archive == nil"), completion.index("takeRestoreCompletion()"))
        self.assertLess(completion.index("guard presentationState.isCurrent(completion.generation)"), completion.index("suspendAndReopen()"))

    def test_embedded_import_waits_for_its_reader_and_never_switches_after_dismissal(self):
        self.require("Infrastructure/Devices/Installation/CompanionArchiveAdapter.swift", "embeddedReaders.insert(key)", "embeddedReaders.remove(key)",
            "sharingFiles.contains(key) || embeddedReaders.contains(key)", "onCancel: { worker.cancel() }", "try Task.checkCancellation()")
        source = self.require("Presentation/Features/Devices/Views/EmbeddedContainerControls.swift", "stagingTask?.cancel()", "isVisible = false",
            "services.companion.prepareEmbeddedImport(ipa)", "generation == attempt", "!Task.isCancelled, isVisible")
        self.assertLess(source.index("!Task.isCancelled, isVisible"), source.index("if !EmbeddedContainerRuntime.open(.container)"))
        runtime = self.require("Platform/Compatibility/EmbeddedContainerRuntime.swift", "try ArchiveSafetyValidator.validate(local)", "try Task.checkCancellation()", "source.stopAccessingSecurityScopedResource()")
        self.assertRegex(runtime, r"try Task.checkCancellation\(\)\s*//[^\n]*\n\s*//[^\n]*\n\s*return VEXEmbeddedRuntimeStageIPA\(local\)")

    def test_onboarding_and_explorer_cancellation_use_the_existing_import_owner(self):
        self.require("Presentation/Features/Onboarding/Views/OnboardingView.swift", "services.library.importPackage(url)", "importTask?.cancel()")
        self.require("Infrastructure/Persistence/Repositories/CoreDataWorkspaceRepository.swift", "PackageImportService.importPackage(source)", "cancellation.adopt(worker)")
        self.require("Infrastructure/Archives/IPA/IPAWorkspace.swift", "cancellation.adopt(worker)", "isCancellationRequested: { cancellation.isSet }", "guard !Task.isCancelled else")


if __name__ == "__main__":
    unittest.main(verbosity=2)
