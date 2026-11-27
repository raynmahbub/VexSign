import XCTest
import Foundation
import ZIPFoundation
@testable import VexSign

final class ContainerPipelineTests: XCTestCase {
    private func temporaryRoot(_ label: String = "ContainerTests") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) } // try? ok: fixture cleanup
        return root
    }

    private func makeStore(
        _ root: URL,
        fileManager: FileManager = .default
    ) async throws -> ContainerStore {
        let store = ContainerStore(root: root, fileManager: fileManager)
        _ = try await store.prepare()
        return store
    }

    private func makeFile(in root: URL, name: String = "note.txt", text: String = "hello") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func reference() -> ContainerAppReference {
        ContainerAppReference(recordID: "app-1", uuid: "uuid-1", name: "Example",
                              bundleIdentifier: "com.example.app", version: "1.0",
                              sourceURL: "https://catalog.example.test/source.json", certificateID: "cert-1")
    }

    // MARK: - Lifecycle and identity

    func testCreatePersistsAndIdentifierIsStable() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let created = try await store.create(displayName: "Work", detail: "Notes", application: reference())
        XCTAssertTrue(ContainerPathPolicy.isValidIdentifier(created.id))
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id), [created.id])
        XCTAssertEqual(listed.first?.application?.bundleIdentifier, "com.example.app")
        let reread = try await store.record(id: created.id)
        XCTAssertEqual(reread, created)
        let other = try await store.create(displayName: "Other")
        XCTAssertNotEqual(other.id, created.id)
    }

    func testRenameMetadataAndPreferencesPersist() async throws {
        let store = try await makeStore(try temporaryRoot())
        let container = try await store.create(displayName: "Original")
        let renamed = try await store.rename(id: container.id, to: "Renamed")
        XCTAssertEqual(renamed.displayName, "Renamed")
        let detailed = try await store.update(id: container.id, detail: "A description",
                                              compatibility: ContainerCompatibility(minimumSystemVersion: "16.0",
                                                                                     supportedFormats: ["file"], notes: nil))
        XCTAssertEqual(detailed.compatibility.minimumSystemVersion, "16.0")
        let preferred = try await store.setPreference(id: container.id, key: "theme", value: .flag(true))
        XCTAssertEqual(preferred.preferences["theme"], .flag(true))
        let cleared = try await store.setPreference(id: container.id, key: "theme", value: nil)
        XCTAssertNil(cleared.preferences["theme"])
        XCTAssertThrowsError(try await store.rename(id: container.id, to: "Renamed"))
    }

    func testPathTraversalAndUnsafeNamesAreRejected() throws {
        for name in ["../escape", "a/b", "..", "", ".hidden", "bad\nname"] {
            XCTAssertThrowsError(try ContainerPathPolicy.displayName(name))
            XCTAssertThrowsError(try ContainerPathPolicy.safeRelativePath(name))
        }
        XCTAssertEqual(try ContainerPathPolicy.safeRelativePath("docs/note.txt"), "docs/note.txt")
        XCTAssertThrowsError(try ContainerPathPolicy.containerRoot(in: URL(fileURLWithPath: "/tmp"), id: "../../bad"))
    }

    func testResourceIsolationBetweenContainers() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let first = try await store.create(displayName: "First")
        let second = try await store.create(displayName: "Second")
        let fileOne = try makeFile(in: root, name: "shared.txt", text: "one")
        let fileTwo = try makeFile(in: root, name: "shared2.txt", text: "two")
        _ = try await store.addResource(id: first.id, from: fileOne, relativePath: "shared.txt")
        _ = try await store.addResource(id: second.id, from: fileTwo, relativePath: "shared.txt")
        let firstURL = try await store.resourceURL(id: first.id, relativePath: "shared.txt")
        let secondURL = try await store.resourceURL(id: second.id, relativePath: "shared.txt")
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("two".utf8))
        XCTAssertTrue(try await store.verifyResources(id: first.id))
        XCTAssertThrowsError(try await store.addResource(id: first.id, from: fileOne, relativePath: "shared.txt"))
    }

    func testSymbolicLinkResourceIsRejected() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let container = try await store.create(displayName: "Links")
        let link = root.appendingPathComponent("link.txt", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("outside.txt"))
        XCTAssertThrowsError(try await store.addResource(id: container.id, from: link, relativePath: "link.txt"))
    }

    // MARK: - Export and restore

    func testExportRestoreRoundTripPreservesResources() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let archives = ContainerArchiveService(store: store)
        let container = try await store.create(displayName: "Backup Me", detail: "Round trip", application: reference())
        let file = try makeFile(in: root, name: "payload.txt", text: "payload bytes")
        _ = try await store.addResource(id: container.id, from: file, relativePath: "docs/payload.txt")
        let export = try await archives.export(id: container.id, password: nil)
        XCTAssertFalse(export.isEncrypted)
        XCTAssertEqual(export.archiveSHA256?.count, 64)

        let restored = try await archives.restore(file: export.url, password: nil, authorization: .createNew)
        XCTAssertNotEqual(restored.id, container.id)
        XCTAssertEqual(restored.displayName, "Backup Me")
        XCTAssertEqual(try Data(contentsOf: try await store.resourceURL(id: restored.id,
                                                                        relativePath: "docs/payload.txt")),
                       Data("payload bytes".utf8))
        XCTAssertTrue(try await store.verifyResources(id: restored.id))
    }

    func testEncryptedExportRequiresPasswordAndRestores() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let archives = ContainerArchiveService(store: store)
        let container = try await store.create(displayName: "Secret")
        let file = try makeFile(in: root, text: "secret text")
        _ = try await store.addResource(id: container.id, from: file, relativePath: "secret.txt")
        let export = try await archives.export(id: container.id, password: "correct-horse")
        XCTAssertTrue(export.isEncrypted)
        XCTAssertTrue(BackupCrypto.isEncrypted(export.url))
        XCTAssertThrowsError(try await archives.inspect(file: export.url, password: nil))
        let restored = try await archives.restore(file: export.url, password: "correct-horse", authorization: .createNew)
        XCTAssertEqual(restored.displayName, "Secret")
    }

    func testCorruptedArchiveAndWrongManifestAreRejected() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let archives = ContainerArchiveService(store: store)
        let broken = try makeFile(in: root, name: "broken.vexcontainer", text: "not a zip")
        XCTAssertThrowsError(try await archives.restore(file: broken, password: nil, authorization: .createNew))

        let container = try await store.create(displayName: "Versioned")
        let valid = try await archives.export(id: container.id, password: nil)
        let manifest = ContainerExportManifest(
            format: valid.manifest.format,
            formatVersion: 99,
            schemaVersion: valid.manifest.schemaVersion,
            exportedAt: valid.manifest.exportedAt,
            appVersion: valid.manifest.appVersion,
            container: valid.manifest.container
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rewritten = try _archiveReplacingManifest(
            export: valid, manifestData: try encoder.encode(manifest), in: root
        )
        XCTAssertThrowsError(try await archives.restore(file: rewritten, password: nil, authorization: .createNew)) { error in
            guard case ContainerArchiveError.unsupportedVersion = error else {
                return XCTFail("expected version rejection, got \(error)")
            }
        }
    }

    func testDuplicateManifestResourcePathsAreRejected() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let archives = ContainerArchiveService(store: store)
        let container = try await store.create(displayName: "Duplicate manifest")
        let file = try makeFile(in: root, text: "payload")
        let withResource = try await store.addResource(
            id: container.id,
            from: file,
            relativePath: "payload.txt"
        )
        let valid = try await archives.export(id: withResource.id, password: nil)
        var duplicated = withResource
        let firstResource = try XCTUnwrap(withResource.resources.first)
        duplicated.resources.append(firstResource)
        let manifest = ContainerExportManifest(
            format: valid.manifest.format,
            formatVersion: valid.manifest.formatVersion,
            schemaVersion: valid.manifest.schemaVersion,
            exportedAt: valid.manifest.exportedAt,
            appVersion: valid.manifest.appVersion,
            container: duplicated
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rewritten = try _archiveReplacingManifest(
            export: valid,
            manifestData: try encoder.encode(manifest),
            in: root
        )

        do {
            _ = try await archives.restore(
                file: rewritten,
                password: nil,
                authorization: .createNew
            )
            XCTFail("expected duplicate manifest resource rejection")
        } catch {
            guard case ContainerArchiveError.malformedManifest = error else {
                return XCTFail("expected duplicate manifest resource rejection, got \(error)")
            }
        }
    }

    func testReplaceRequiresExplicitMatchingIdentifier() async throws {
        let store = try await makeStore(try temporaryRoot())
        let archives = ContainerArchiveService(store: store)
        let container = try await store.create(displayName: "Replaceable")
        let export = try await archives.export(id: container.id, password: nil)
        XCTAssertThrowsError(try await archives.restore(
            file: export.url, password: nil, authorization: .replace(id: ContainerPathPolicy.makeIdentifier())
        ))
        let replaced = try await archives.restore(file: export.url, password: nil,
                                                  authorization: .replace(id: container.id))
        XCTAssertEqual(replaced.id, container.id)
        XCTAssertEqual(try await store.list().count, 1)
    }

    func testArchiveBombLimitsAreEnforcedDuringRestore() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let lenient = ContainerArchiveService(store: store)
        let container = try await store.create(displayName: "Small")
        let file = try makeFile(in: root, text: "0123456789")
        _ = try await store.addResource(id: container.id, from: file, relativePath: "data.txt")
        let export = try await lenient.export(id: container.id, password: nil)

        var limits = ArchiveSafetyValidator.Limits.default
        limits.maxExpandedBytes = 1
        let strict = ContainerArchiveService(store: store, limits: limits)
        XCTAssertThrowsError(try await strict.restore(file: export.url, password: nil, authorization: .createNew))
    }

    func testSymlinkEntryIsRejectedBeforeExtraction() throws {
        let root = try temporaryRoot()
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: input.appendingPathComponent("escape"), withDestinationURL: root.appendingPathComponent("outside")
        )
        let archiveURL = root.appendingPathComponent("symlink.zip", isDirectory: false)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "escape", relativeTo: input)
        XCTAssertThrowsError(try ArchiveSafetyValidator.validate(
            archiveURL, destination: root.appendingPathComponent("output", isDirectory: true)
        )) { error in
            guard case .some(.symbolicLink) = error as? ArchiveSafetyValidator.ValidationError else {
                return XCTFail("expected symlink rejection, got \(error)")
            }
        }
    }

    // MARK: - Failure handling

    func testInterruptedCreatePublishesNothing() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        XCTAssertThrowsError(try await store.create(displayName: "Interrupted") { throw CancellationError() }) { error in
            guard case ContainerError.operationInterrupted = error else {
                return XCTFail("expected interruption, got \(error)")
            }
        }
        XCTAssertTrue(try await store.list().isEmpty)
        let rootItems = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(rootItems, [".staging"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(".staging").path
        ).isEmpty)
    }

    func testDuplicateAndDeleteCleanUpFiles() async throws {
        let store = try await makeStore(try temporaryRoot())
        let original = try await store.create(displayName: "Original")
        let file = try makeFile(in: temporaryRoot(), text: "copy me")
        _ = try await store.addResource(id: original.id, from: file, relativePath: "copy.txt")
        let copy = try await store.duplicate(id: original.id, displayName: "Copy")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertTrue(try await store.verifyResources(id: copy.id))
        XCTAssertThrowsError(try await store.duplicate(id: original.id, displayName: "Copy"))

        try await store.delete(id: copy.id)
        XCTAssertThrowsError(try await store.record(id: copy.id))
        XCTAssertEqual(try await store.list().map(\.id), [original.id])
    }

    func testValidatedInstallMoveFailurePublishesNoPartialContainer() async throws {
        let root = try temporaryRoot()
        let initial = try await makeStore(root)
        let original = try await initial.create(displayName: "Original")
        let file = try makeFile(in: root, name: "transaction.txt", text: "complete")
        _ = try await initial.addResource(id: original.id, from: file, relativePath: "transaction.txt")
        let manager = FaultingContainerFileManager(moveFailures: 1, moveSourceSuffix: ".incomplete")
        let failing = ContainerStore(root: root, fileManager: manager)

        do {
            _ = try await failing.duplicate(id: original.id, displayName: "Failed copy")
            XCTFail("expected publication move failure")
        } catch {
            guard case ContainerError.persistenceFailed(_) = error else {
                return XCTFail("expected persistence failure, got \(error)")
            }
        }

        let records = try await failing.list()
        XCTAssertEqual(records.map(\.id), [original.id])
        let staged = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(".staging", isDirectory: true).path
        )
        XCTAssertTrue(staged.isEmpty)
    }

    func testValidatedInstallAcceptsACompletedMoveOnlyAfterValidation() async throws {
        let root = try temporaryRoot()
        let initial = try await makeStore(root)
        let original = try await initial.create(displayName: "Original")
        let file = try makeFile(in: root, name: "transaction.txt", text: "complete")
        _ = try await initial.addResource(id: original.id, from: file, relativePath: "transaction.txt")
        let manager = FaultingContainerFileManager(
            failuresAfterMove: 1,
            moveSourceSuffix: ".incomplete"
        )
        let recovering = ContainerStore(root: root, fileManager: manager)

        let copy = try await recovering.duplicate(id: original.id, displayName: "Validated copy")

        XCTAssertNotEqual(copy.id, original.id)
        let copiedResource = try await recovering.resourceURL(id: copy.id, relativePath: "transaction.txt")
        XCTAssertEqual(try Data(contentsOf: copiedResource), Data("complete".utf8))
    }

    func testInterruptedReplacementRecoversOriginalOnPrepare() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let original = try await store.create(displayName: "Before")
        let detached = try await store.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        XCTAssertThrowsError(try await store.record(id: original.id))

        let recovered = ContainerStore(root: root)
        let report = try await recovered.prepare()

        XCTAssertTrue(report.entries.contains { $0.containerID == original.id && $0.status == .recovered })
        let restored = try await recovered.record(id: original.id)
        XCTAssertEqual(restored.displayName, "Before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
    }

    func testRollbackRestoresOriginalAndRemovesPartialInstallation() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let original = try await store.create(displayName: "Before")
        let detached = try await store.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        let target = try await store.containerURL(id: original.id)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: target.appendingPathComponent("metadata.json"))

        try await store.rollbackReplacement(held, id: original.id)

        let restored = try await store.record(id: original.id)
        XCTAssertEqual(restored.displayName, "Before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".staging/\(original.id).recovery.incomplete").path
        ))
    }

    func testFailedRollbackRetainsTheOnlyRecoverableOriginal() async throws {
        let root = try temporaryRoot()
        let manager = FaultingContainerFileManager(moveFailures: 1, moveSourceSuffix: ".replaced")
        let store = try await makeStore(root, fileManager: manager)
        let original = try await store.create(displayName: "Before")
        let detached = try await store.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        let target = try await store.containerURL(id: original.id)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: target.appendingPathComponent("metadata.json"))

        do {
            try await store.rollbackReplacement(held, id: original.id)
            XCTFail("expected rollback failure")
        } catch {
            guard case ContainerError.persistenceFailed(_) = error else {
                return XCTFail("expected persistence failure, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertEqual(try _record(at: held).displayName, "Before")

        let retried = ContainerStore(root: root)
        let report = try await retried.prepare()
        XCTAssertTrue(report.entries.contains { $0.containerID == original.id && $0.status == .recovered })
        let restored = try await retried.record(id: original.id)
        XCTAssertEqual(restored.displayName, "Before")
    }

    func testRestoreSurfacesRollbackFailureAndRetainsOriginal() async throws {
        let root = try temporaryRoot()
        let manager = FaultingContainerFileManager(moveFailures: 1, moveSourceSuffix: ".replaced")
        let store = try await makeStore(root, fileManager: manager)
        let archives = ContainerArchiveService(store: store)
        let original = try await store.create(displayName: "Before")
        let export = try await archives.export(id: original.id, password: nil)
        let target = try await store.containerURL(id: original.id)

        do {
            _ = try await archives.restore(
                file: export.url,
                password: nil,
                authorization: .replace(id: original.id),
                checkpoint: {
                    if !FileManager.default.fileExists(atPath: target.path) { throw CancellationError() }
                }
            )
            XCTFail("expected actionable rollback failure")
        } catch {
            guard case ContainerError.persistenceFailed(_) = error else {
                return XCTFail("expected actionable rollback failure, got \(error)")
            }
        }

        let held = root.appendingPathComponent(".staging/\(original.id).replaced", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertEqual(try _record(at: held).displayName, "Before")
    }

    func testPrepareReportsDestinationCollisionAndPreservesBothValidCopies() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let original = try await store.create(displayName: "Before")
        let detached = try await store.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        let target = try await store.containerURL(id: original.id)
        try FileManager.default.copyItem(at: held, to: target)
        var incoming = original
        incoming.displayName = "Incoming"
        try _writeRecord(incoming, to: target)

        let recovering = ContainerStore(root: root)
        let first = try await recovering.prepare()
        let second = try await recovering.prepare()

        XCTAssertTrue(first.entries.contains { $0.containerID == original.id && $0.status == .unresolved })
        XCTAssertTrue(second.entries.contains { $0.containerID == original.id && $0.status == .unresolved })
        let destination = try await recovering.record(id: original.id)
        XCTAssertEqual(destination.displayName, "Incoming")
        XCTAssertEqual(try _record(at: held).displayName, "Before")
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
    }

    func testExplicitRollbackDoesNotMoveAsideAnInaccessibleDestination() async throws {
        let root = try temporaryRoot()
        let initial = try await makeStore(root)
        let original = try await initial.create(displayName: "Before")
        let detached = try await initial.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        let target = try await initial.containerURL(id: original.id)
        try FileManager.default.copyItem(at: held, to: target)
        let denied = FaultingContainerFileManager(
            attributeFailures: 1,
            attributeSuffix: original.id
        )
        let recovering = ContainerStore(root: root, fileManager: denied)

        do {
            try await recovering.rollbackReplacement(held, id: original.id)
            XCTFail("expected inaccessible destination to prevent rollback")
        } catch {
            guard case ContainerError.persistenceFailed(_) = error else {
                return XCTFail("expected persistence failure, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testPrepareRollsBackPartialInstallationAndIsSafeToRepeat() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        var original = try await store.create(displayName: "Before")
        let source = try makeFile(in: root, name: "recovery-source.txt", text: "original bytes")
        original = try await store.addResource(id: original.id, from: source, relativePath: "payload.txt")
        let detached = try await store.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        let target = try await store.containerURL(id: original.id)
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Metadata promises a resource, but the interrupted destination does not contain it.
        try _writeRecord(original, to: target)

        let recovering = ContainerStore(root: root)
        let first = try await recovering.prepare()
        let second = try await recovering.prepare()

        XCTAssertTrue(first.entries.contains { $0.containerID == original.id && $0.status == .recovered })
        XCTAssertFalse(first.needsAttention)
        XCTAssertTrue(second.entries.isEmpty)
        let resourceURL = try await recovering.resourceURL(id: original.id, relativePath: "payload.txt")
        XCTAssertEqual(try Data(contentsOf: resourceURL), Data("original bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
    }

    func testPrepareMoveFailureKeepsRecoverableCopyInStaging() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let original = try await store.create(displayName: "Only Copy")
        let detached = try await store.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        let manager = FaultingContainerFileManager(moveFailures: 1, moveSourceSuffix: ".replaced")
        let recovering = ContainerStore(root: root, fileManager: manager)

        let report = try await recovering.prepare()

        XCTAssertTrue(report.needsAttention)
        XCTAssertTrue(report.entries.contains { $0.containerID == original.id && $0.status == .unresolved })
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertEqual(try _record(at: held).displayName, "Only Copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".staging").path))
    }

    func testPrepareAcceptsCompletedRenameOnlyAfterDestinationValidation() async throws {
        let root = try temporaryRoot()
        let initial = try await makeStore(root)
        let original = try await initial.create(displayName: "Rename completed")
        let detached = try await initial.detachForReplacement(id: original.id)
        let held = try XCTUnwrap(detached)
        let manager = FaultingContainerFileManager(
            failuresAfterMove: 1,
            moveSourceSuffix: ".replaced"
        )
        let recovering = ContainerStore(root: root, fileManager: manager)

        let report = try await recovering.prepare()

        XCTAssertTrue(report.entries.contains {
            $0.containerID == original.id && $0.status == .recovered
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
        let restored = try await recovering.record(id: original.id)
        XCTAssertEqual(restored.displayName, "Rename completed")
    }

    func testPrepareRemoveFailureRetainsOrphanForLaterCleanup() async throws {
        let root = try temporaryRoot()
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        let orphan = staging.appendingPathComponent("resource-fixture.incomplete", isDirectory: false)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: orphan)
        let manager = FaultingContainerFileManager(removeFailures: 1, removeSuffix: ".incomplete")
        let store = ContainerStore(root: root, fileManager: manager)

        let failed = try await store.prepare()
        XCTAssertTrue(failed.entries.contains { $0.item == orphan.lastPathComponent && $0.status == .unresolved })
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        let retried = ContainerStore(root: root)
        let recovered = try await retried.prepare()
        XCTAssertTrue(recovered.entries.contains { $0.item == orphan.lastPathComponent && $0.status == .orphaned })
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testPrepareRetainsInvalidTransactionEntries() async throws {
        let root = try temporaryRoot()
        let invalid = root.appendingPathComponent(".staging/not-an-id.replaced", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("recoverable".utf8).write(to: invalid.appendingPathComponent("data"))
        let store = ContainerStore(root: root)

        let report = try await store.prepare()

        XCTAssertTrue(report.entries.contains { $0.item == invalid.lastPathComponent && $0.status == .invalid })
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
    }

    func testPrepareRetainsInvalidStagedOriginalInsteadOfPublishingIt() async throws {
        let root = try temporaryRoot()
        let id = ContainerPathPolicy.makeIdentifier()
        let held = root.appendingPathComponent(".staging/\(id).replaced", isDirectory: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try Data("not metadata".utf8).write(
            to: held.appendingPathComponent("metadata.json", isDirectory: false)
        )
        let store = ContainerStore(root: root)

        let report = try await store.prepare()

        XCTAssertTrue(report.entries.contains { $0.containerID == id && $0.status == .invalid })
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        let destination = root.appendingPathComponent(id, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLegacyMetadataMigratesAndBrokenMetadataIsReported() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let legacyID = ContainerPathPolicy.makeIdentifier()
        let legacyDir = try await store.containerURL(id: legacyID)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyJSON = """
        {"name":"Legacy","description":"Old record","bundleIdentifier":"com.example.legacy","version":"1.2"}
        """
        try Data(legacyJSON.utf8).write(to: legacyDir.appendingPathComponent("info.json"))
        let migrated = try await store.list()
        XCTAssertEqual(migrated.first?.displayName, "Legacy")
        XCTAssertEqual(migrated.first?.application?.bundleIdentifier, "com.example.legacy")
        XCTAssertEqual(migrated.first?.schemaVersion, AppContainerRecord.currentSchemaVersion)

        let brokenID = ContainerPathPolicy.makeIdentifier()
        let brokenDir = try await store.containerURL(id: brokenID)
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try Data("not metadata".utf8).write(to: brokenDir.appendingPathComponent("metadata.json"))
        let listed = try await store.list()
        XCTAssertTrue(listed.contains { $0.id == brokenID && $0.state == .corrupted })
    }

    // MARK: - Hand-off and application records

    @MainActor
    func testHandoffURLValidationAndOpenFailureAreHonest() async {
        XCTAssertNil(ContainerURLHandoff.makeLiveContainerURL(bundleIdentifier: "bad"))
        let url = ContainerURLHandoff.makeLiveContainerURL(bundleIdentifier: "com.example.app")
        XCTAssertEqual(url?.scheme, "livecontainer")
        XCTAssertEqual(url?.host, "livecontainer-launch")
        XCTAssertNil(ContainerURLHandoff.makeLiveContainerURL(bundleIdentifier: "com.example.app",
                                                              openURL: URL(string: "file:///etc/passwd")))

        let opener = FailingContainerOpener()
        let handoff = ContainerURLHandoff(opener: opener)
        let outcome = await handoff.handoff(route: .liveContainerURLScheme, bundleIdentifier: "com.example.app")
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(outcome.message.contains("cannot observe") || outcome.message.contains("No application"))
    }

    @MainActor
    func testApplicationRecordAssociationUsesRealLibraryMetadata() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let model = ContainerWorkspaceModel(store: store, workspaceProvider: {
            var snapshot = WorkspaceSnapshot()
            snapshot.importedApps = [LibraryAppRecord(
                id: "record-1", uuid: "uuid-1", isSigned: false, name: "Example", version: "2.1",
                identifier: "com.example.app", originalIdentifier: nil, date: nil, icon: nil,
                appDescription: nil, sortIndex: 0, source: URL(string: "https://catalog.example.test/source.json"),
                certificateID: nil, bundleURL: nil, artifactURL: nil
            )]
            return snapshot
        })
        await model.load()
        XCTAssertEqual(model.libraryApps.count, 1)
        guard let container = await model.create(name: "Library", detail: "") else { return XCTFail("create failed") }
        await model.associate(container, app: model.libraryApps[0])
        XCTAssertEqual(model.selected?.application?.version, "2.1")
        XCTAssertEqual(model.selected?.application?.recordID, "record-1")
    }

    // MARK: - Fixtures

    private func _writeRecord(_ record: AppContainerRecord, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(
            to: directory.appendingPathComponent("metadata.json", isDirectory: false),
            options: .atomic
        )
    }

    private func _record(at directory: URL) throws -> AppContainerRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            AppContainerRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent("metadata.json", isDirectory: false))
        )
    }

    private func _archiveReplacingManifest(export: ContainerExport, manifestData: Data, in root: URL) throws -> URL {
        let work = root.appendingPathComponent("Rewrite-\(UUID().uuidString)", isDirectory: true)
        let input = work.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try manifestData.write(to: input.appendingPathComponent("manifest.json"), options: .atomic)
        let archiveURL = work.appendingPathComponent("rewritten.zip", isDirectory: false)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "manifest.json", relativeTo: input)
        return archiveURL
    }
}

private final class FaultingContainerFileManager: FileManager, @unchecked Sendable {
    private let stateLock = NSLock()
    private var moveFailures: Int
    private var failuresAfterMove: Int
    private var removeFailures: Int
    private var attributeFailures: Int
    private let moveSourceSuffix: String?
    private let removeSuffix: String?
    private let attributeSuffix: String?

    init(
        moveFailures: Int = 0,
        failuresAfterMove: Int = 0,
        moveSourceSuffix: String? = nil,
        removeFailures: Int = 0,
        removeSuffix: String? = nil,
        attributeFailures: Int = 0,
        attributeSuffix: String? = nil
    ) {
        self.moveFailures = moveFailures
        self.failuresAfterMove = failuresAfterMove
        self.moveSourceSuffix = moveSourceSuffix
        self.removeFailures = removeFailures
        self.removeSuffix = removeSuffix
        self.attributeFailures = attributeFailures
        self.attributeSuffix = attributeSuffix
        super.init()
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        if _consumeMoveFailure(for: source) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.moveItem(at: source, to: destination)
        if _consumeFailureAfterMove(for: source) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
    }

    override func removeItem(at URL: URL) throws {
        if _consumeRemoveFailure(for: URL) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.removeItem(at: URL)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if _consumeAttributeFailure(for: path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        return try super.attributesOfItem(atPath: path)
    }

    private func _consumeMoveFailure(for source: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard moveFailures > 0,
              moveSourceSuffix.map({ source.lastPathComponent.hasSuffix($0) }) ?? true else { return false }
        moveFailures -= 1
        return true
    }

    private func _consumeFailureAfterMove(for source: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard failuresAfterMove > 0,
              moveSourceSuffix.map({ source.lastPathComponent.hasSuffix($0) }) ?? true else { return false }
        failuresAfterMove -= 1
        return true
    }

    private func _consumeAttributeFailure(for path: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard attributeFailures > 0,
              attributeSuffix.map({ path.hasSuffix($0) }) ?? true else { return false }
        attributeFailures -= 1
        return true
    }

    private func _consumeRemoveFailure(for item: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard removeFailures > 0,
              removeSuffix.map({ item.lastPathComponent.hasSuffix($0) }) ?? true else { return false }
        removeFailures -= 1
        return true
    }
}

@MainActor
private final class FailingContainerOpener: ContainerURLOpening {
    private(set) var queried = false
    func canOpenURL(_ url: URL) -> Bool { queried = true; return false }
    func openURL(_ url: URL) async -> Bool { false }
}
