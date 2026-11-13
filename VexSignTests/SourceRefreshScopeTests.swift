import Foundation
import XCTest
@testable import VexSign

private actor RefreshGate {
    private var continuation: CheckedContinuation<Result<Data, Error>, Never>?

    func wait(started: XCTestExpectation) async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(_ result: Result<Data, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

final class SourceRefreshScopeTests: XCTestCase {
    private let payload = Data("""
    {"name":"Saved","apps":[{"name":"App","iconURL":"https://example.com/icon.png","versions":[{"version":"1.0"}]}]}
    """.utf8)

    @MainActor
    func testTargetedFailurePreservesOtherSourceCatalogAndPreferences() async throws {
        let storage = Storage(inMemory: true)
        let firstID = "test.refresh.first.\(UUID().uuidString)"
        let secondID = "test.refresh.second.\(UUID().uuidString)"
        let first = AltSource(context: storage.context)
        first.date = Date()
        first.identifier = firstID
        first.sourceURL = URL(string: "https://example.com/first.json")!
        let second = AltSource(context: storage.context)
        second.date = Date()
        second.identifier = secondID
        second.sourceURL = URL(string: "https://example.com/second.json")!
        defer {
            for id in [firstID, secondID] {
                RepositorySnapshotCache.remove(identifier: id)
                SourcePreferences.removeAllData(for: id)
            }
        }
        RepositorySnapshotCache.store(identifier: firstID, sourceURL: first.sourceURL, payload: payload)
        RepositorySnapshotCache.store(identifier: secondID, sourceURL: second.sourceURL, payload: payload)
        SourcePreferences.setPinned(secondID, pinned: true)
        SourcePreferences.setAutoUpdatesEnabled(false, for: secondID)

        var retained: Set<String> = []
        let model = SourcesViewModel(fetcher: { _, _ in .failure(URLError(.notConnectedToInternet)) },
                                     retainSnapshots: { retained = $0 })
        await model.fetchSources([first], refresh: true, configuredSources: [first, second])

        XCTAssertEqual(model.sources[first]?.name, "Saved")
        XCTAssertEqual(model.sources[second]?.name, "Saved")
        XCTAssertTrue(model.isStale(first))
        XCTAssertTrue(model.isStale(second))
        XCTAssertNotNil(SourcePreferences.lastError(for: firstID))
        XCTAssertNil(SourcePreferences.lastFetch(for: secondID))
        XCTAssertTrue(SourcePreferences.isPinned(secondID))
        XCTAssertFalse(SourcePreferences.autoUpdatesEnabled(for: secondID))
        XCTAssertNotNil(RepositorySnapshotCache.load(identifier: secondID))
        XCTAssertEqual(retained, [firstID, secondID])
    }

    @MainActor
    func testResetDiscardsLateNetworkResult() async throws {
        let storage = Storage(inMemory: true)
        let id = "test.refresh.cancel.\(UUID().uuidString)"
        let source = AltSource(context: storage.context)
        source.date = Date()
        source.identifier = id
        source.sourceURL = URL(string: "https://example.com/cancel.json")!
        defer {
            RepositorySnapshotCache.remove(identifier: id)
            SourcePreferences.removeAllData(for: id)
        }
        let started = expectation(description: "network request started")
        let gate = RefreshGate()
        let model = SourcesViewModel(fetcher: { _, _ in await gate.wait(started: started) }, retainSnapshots: { _ in })
        let task = Task { await model.fetchSources([source], refresh: true) }
        await fulfillment(of: [started], timeout: 15)
        model.resetLoadingState()
        await gate.finish(.success(payload))
        await task.value

        XCTAssertTrue(model.isFinished)
        XCTAssertNil(model.sources[source])
        XCTAssertNil(RepositorySnapshotCache.load(identifier: id))
        XCTAssertNil(SourcePreferences.lastFetch(for: id))
    }

    @MainActor
    func testDeletedSourceDoesNotReappearAfterFetch() async throws {
        let storage = Storage(inMemory: true)
        let id = "test.refresh.deleted.\(UUID().uuidString)"
        let source = AltSource(context: storage.context)
        source.date = Date()
        source.identifier = id
        source.sourceURL = URL(string: "https://example.com/deleted.json")!
        try storage.context.save()
        defer {
            RepositorySnapshotCache.remove(identifier: id)
            SourcePreferences.removeAllData(for: id)
        }
        let started = expectation(description: "network request started")
        let gate = RefreshGate()
        var retained: Set<String> = [id]
        let model = SourcesViewModel(fetcher: { _, _ in await gate.wait(started: started) },
                                     retainSnapshots: { retained = $0 })
        let task = Task { await model.fetchSources([source], refresh: true) }
        await fulfillment(of: [started], timeout: 15)
        storage.context.delete(source)
        model.evictDeletedSources(valid: [])
        await gate.finish(.success(payload))
        await task.value

        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertNil(RepositorySnapshotCache.load(identifier: id))
        XCTAssertNil(SourcePreferences.lastFetch(for: id))
        XCTAssertTrue(retained.isEmpty)
    }

    @MainActor
    func testAddSourcesInvokesCompletionOnce() throws {
        let key = SourceURLPolicy.allowInsecureHTTPKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)

        let goodID = "com.example.good.\(UUID().uuidString)"
        let badID = "com.example.bad.\(UUID().uuidString)"
        let goodPayload = Data("""
        {"name":"Good","identifier":"\(goodID)","apps":[{"name":"App","iconURL":"https://example.com/i.png","versions":[{"version":"1.0"}]}]}
        """.utf8)
        let badPayload = Data("""
        {"name":"Bad","identifier":"\(badID)","apps":[{"name":"App","iconURL":"https://example.com/i.png","versions":[{"version":"1.0"}]}]}
        """.utf8)
        let goodRepo = try SourceFeedLoader.decode(goodPayload)
        let badRepo = try SourceFeedLoader.decode(badPayload)

        let storage = Storage(inMemory: true)
        let goodURL = URL(string: "https://example.com/good.json")!
        let badURL = URL(string: "http://example.com/bad.json")!
        var callbacks = 0
        var recordedError: Error?

        storage.addSources(repos: [badURL: badRepo, goodURL: goodRepo]) { error in
            callbacks += 1
            recordedError = error
        }

        XCTAssertEqual(callbacks, 1)
        XCTAssertNotNil(recordedError)
        XCTAssertTrue(storage.sourceExists(goodID))
        XCTAssertFalse(storage.sourceExists(badID))
    }

}
