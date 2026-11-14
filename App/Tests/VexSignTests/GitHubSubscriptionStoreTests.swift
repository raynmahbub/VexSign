import XCTest
@testable import VexSign

final class GitHubSubscriptionStoreTests: XCTestCase {
    @MainActor
    func testExplicitReleaseAndAssetPersistAndCanBeRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        let file = root.appendingPathComponent("subscriptions.json")
        let repository = try GitHubIPAReleases.Repository("owner/repo")
        let json = #"[{"id":7,"tag_name":"v1","draft":false,"prerelease":false,"assets":[{"id":8,"name":"App.ipa","size":42,"browser_download_url":"https://github.com/owner/repo/releases/download/v1/App.ipa"}]}]"#
        let release = try XCTUnwrap(GitHubIPAReleases.decode(Data(json.utf8), repository: repository, includePrereleases: false).first)
        let asset = try XCTUnwrap(release.assets.first)
        let store = GitHubSubscriptionStore(file: file)
        store.track(repository: repository, release: release, asset: asset, bundleID: "com.example.app", includePrereleases: false)
        let restored = GitHubSubscriptionStore(file: file)
        let record = try XCTUnwrap(restored.subscriptions.first)
        XCTAssertEqual(record.releaseID, 7)
        XCTAssertEqual(record.assetID, 8)
        XCTAssertEqual(record.bundleID, "com.example.app")
        restored.remove(record.id)
        XCTAssertTrue(GitHubSubscriptionStore(file: file).subscriptions.isEmpty)
    }

    @MainActor
    func testCorruptStateIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("subscriptions.json")
        let original = Data("broken".utf8)
        try original.write(to: file)
        let store = GitHubSubscriptionStore(file: file)
        XCTAssertNotNil(store.warning)
        store.remove(UUID())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    @MainActor
    private func trackingFixture(_ body: @MainActor (URL, GitHubIPAReleases.Repository, GitHubIPAReleases.Release) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: GameMode.enabledKey)
        defaults.set(false, forKey: GameMode.enabledKey)
        defer {
            if let previous { defaults.set(previous, forKey: GameMode.enabledKey) }
            else { defaults.removeObject(forKey: GameMode.enabledKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown
        let repository = try GitHubIPAReleases.Repository("owner/repo")
        let json = #"[{"id":7,"tag_name":"v1","draft":false,"prerelease":false,"assets":[{"id":8,"name":"App.ipa","browser_download_url":"https://github.com/owner/repo/releases/download/v1/App.ipa"}]}]"#
        let release = try XCTUnwrap(GitHubIPAReleases.decode(Data(json.utf8), repository: repository, includePrereleases: false).first)
        try await body(root.appendingPathComponent("subscriptions.json"), repository, release)
    }

    private var newMetadata: Data {
        Data(#"[{"id":9,"tag_name":"v2","draft":false,"prerelease":false,"assets":[{"id":10,"name":"Changed-Name.ipa","browser_download_url":"https://github.com/owner/repo/releases/download/v2/Changed-Name.ipa"}]}]"#.utf8)
    }

    @MainActor
    func testConditionalCacheCooldownAndRelaunch() async throws {
        try await trackingFixture { file, repository, release in
            var clock = Date(timeIntervalSince1970: 10000)
            var calls = 0
            let metadata = newMetadata
            let store = GitHubSubscriptionStore(file: file, fetcher: { _, etag in
                calls += 1
                if calls == 1 {
                    XCTAssertNil(etag)
                    return .init(data: metadata, status: 200, etag: "fixture-tag", retryAt: clock.addingTimeInterval(60))
                }
                XCTAssertEqual(etag, "fixture-tag")
                return .init(data: nil, status: 304, etag: nil, retryAt: clock.addingTimeInterval(60))
            }, now: { clock }, ruleForBundle: { _ in PerAppUpdateRule() })
            store.track(repository: repository, release: release, asset: release.assets[0], bundleID: "com.fixture.app", includePrereleases: false)
            let id = try XCTUnwrap(store.subscriptions.first?.id)
            let first = try await store.check(id)
            XCTAssertEqual(first.map(\.id), [9])
            let immediate = try await store.check(id)
            XCTAssertTrue(immediate.isEmpty)
            XCTAssertEqual(calls, 1)
            clock = clock.addingTimeInterval(61)
            let cached = try await store.check(id)
            XCTAssertEqual(cached.map(\.id), [9])
            XCTAssertEqual(calls, 2)
            let restored = GitHubSubscriptionStore(file: file, fetcher: { _, _ in
                XCTFail("Persisted cooldown must prevent this request")
                throw CancellationError()
            }, now: { clock }, ruleForBundle: { _ in PerAppUpdateRule() })
            let afterRelaunch = try await restored.check(id)
            XCTAssertTrue(afterRelaunch.isEmpty)
        }
    }

    @MainActor
    func testRateLimitAppliesToNewSubscriptionForSameRepository() async throws {
        try await trackingFixture { file, repository, release in
            let clock = Date(timeIntervalSince1970: 10000)
            var calls = 0
            let store = GitHubSubscriptionStore(file: file, fetcher: { _, _ in
                calls += 1
                return .init(data: nil, status: 429, etag: nil, retryAt: clock.addingTimeInterval(3600))
            }, now: { clock }, ruleForBundle: { _ in PerAppUpdateRule() })
            store.track(repository: repository, release: release, asset: release.assets[0], bundleID: "com.fixture.one", includePrereleases: false)
            let first = try XCTUnwrap(store.subscriptions.first?.id)
            do { _ = try await store.check(first); XCTFail("429 must be reported") }
            catch { XCTAssertEqual(error as? GitHubIPAReleases.Failure, .requestFailed(429)) }
            store.track(repository: repository, release: release, asset: release.assets[0], bundleID: "com.fixture.two", includePrereleases: false)
            let second = try XCTUnwrap(store.subscriptions.last?.id)
            let blocked = try await store.check(second)
            XCTAssertTrue(blocked.isEmpty)
            XCTAssertEqual(calls, 1)
        }
    }

    @MainActor
    func testPersistenceFailurePreventsRequest() async throws {
        try await trackingFixture { file, repository, release in
            var calls = 0
            let store = GitHubSubscriptionStore(file: file, fetcher: { _, _ in
                calls += 1
                throw CancellationError()
            }, ruleForBundle: { _ in PerAppUpdateRule() })
            store.track(repository: repository, release: release, asset: release.assets[0], bundleID: "com.fixture.app", includePrereleases: false)
            let id = try XCTUnwrap(store.subscriptions.first?.id)
            let root = file.deletingLastPathComponent()
            try FileManager.default.removeItem(at: root)
            try Data([1]).write(to: root)
            do { _ = try await store.check(id); XCTFail("Storage failure must reject the request") }
            catch { XCTAssertTrue(error is GitHubSubscriptionStore.Failure) }
            XCTAssertEqual(calls, 0)
            XCTAssertNotNil(store.warning)
        }
    }

    @MainActor
    func testRulesAreRecheckedBeforePublishing() async throws {
        try await trackingFixture { file, repository, release in
            var rule = PerAppUpdateRule()
            let metadata = newMetadata
            let store = GitHubSubscriptionStore(file: file, fetcher: { _, _ in
                rule.disableUpdates = true
                return .init(data: metadata, status: 200, etag: nil, retryAt: Date().addingTimeInterval(60))
            }, ruleForBundle: { _ in rule })
            store.track(repository: repository, release: release, asset: release.assets[0], bundleID: "com.fixture.app", includePrereleases: false)
            let result = try await store.check(try XCTUnwrap(store.subscriptions.first?.id))
            XCTAssertTrue(result.isEmpty)
        }
    }

    @MainActor
    func testMaintenanceIsOptInAndCacheReviewDoesNotRequestAgain() async throws {
        try await trackingFixture { file, repository, release in
            var calls = 0
            let metadata = newMetadata
            let store = GitHubSubscriptionStore(file: file, fetcher: { _, _ in
                calls += 1
                return .init(data: metadata, status: 200, etag: "fixture", retryAt: Date().addingTimeInterval(3600))
            }, ruleForBundle: { _ in PerAppUpdateRule() })
            store.track(repository: repository, release: release, asset: release.assets[0], bundleID: "com.fixture.app", includePrereleases: false)
            let id = try XCTUnwrap(store.subscriptions.first?.id)
            let beforeConsent = await store.checkDueSubscriptions()
            XCTAssertEqual(beforeConsent.checked, 0)
            XCTAssertEqual(calls, 0)
            store.setMaintenanceChecks(id, enabled: true)
            let afterConsent = await store.checkDueSubscriptions()
            XCTAssertEqual(afterConsent.checked, 1)
            XCTAssertEqual(afterConsent.reviewable, 1)
            XCTAssertEqual(try store.cachedReleases(id).map(\.id), [9])
            let repeated = await store.checkDueSubscriptions()
            XCTAssertEqual(repeated.checked, 0)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(GitHubSubscriptionStore(file: file).subscriptions.first?.maintenanceChecks, true)
        }
    }

}
