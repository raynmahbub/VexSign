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

    private func makeStore(_ root: URL) async throws -> ContainerStore {
        let store = ContainerStore(root: root)
        try await store.prepare()
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
        var manifest = valid.manifest
        manifest.formatVersion = 99
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
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
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

    func testInterruptedReplacementRecoversOriginalOnPrepare() async throws {
        let root = try temporaryRoot()
        let store = try await makeStore(root)
        let original = try await store.create(displayName: "Before")
        _ = try await store.detachForReplacement(id: original.id)
        XCTAssertThrowsError(try await store.record(id: original.id))
        let recovered = try await makeStore(root)
        XCTAssertEqual(try await recovered.record(id: original.id).displayName, "Before")
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

@MainActor
private final class FailingContainerOpener: ContainerURLOpening {
    private(set) var queried = false
    func canOpenURL(_ url: URL) -> Bool { queried = true; return false }
    func openURL(_ url: URL) async -> Bool { false }
}
