import XCTest
@testable import VexSign

final class EmbeddedContainerRuntimeTests: XCTestCase {
    func testNormalBuildDoesNotAdvertiseAnEmbeddedHost() {
        // The packager sets the guest marker only in the separate combined copy.
        XCTAssertFalse(EmbeddedContainerRuntime.isGuestBuild)
        XCTAssertFalse(EmbeddedContainerRuntime.isAvailable)
        XCTAssertTrue(EmbeddedContainerRuntime.supportsScheduledGuestTasks)
    }

    @MainActor
    func testMissingHostRejectsSessionSwitchWithoutExternalFallback() {
        XCTAssertFalse(EmbeddedContainerRuntime.open(.container))
        XCTAssertFalse(EmbeddedContainerRuntime.open(.sideStore))
    }

    func testUnhostedStagingRejectsInputWithoutAnExternalFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test-only cleanup
        let file = root.appendingPathComponent("invalid.ipa")
        try Data("not an archive".utf8).write(to: file)
        XCTAssertFalse(try EmbeddedContainerRuntime.stageIPA(file))
        XCTAssertEqual(try Data(contentsOf: file), Data("not an archive".utf8))
    }
}
