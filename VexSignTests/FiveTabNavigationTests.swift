import XCTest
@testable import VexSign

final class FiveTabNavigationTests: XCTestCase {
    func testHomeIsMiddlePrimaryTab() {
        XCTAssertEqual(TabEnum.defaultTabs.count, 5)
        XCTAssertEqual(TabEnum.defaultTabs[2], .home)
    }

    @MainActor
    func testSearchIntentSelectsItsDestinationAndPersistsForMount() {
        let selection = TabSelectionObserver()
        selection.librarySection = .files
        selection.search("  certificate  ", in: .settings)
        XCTAssertEqual(selection.selectedTab, .settings)
        XCTAssertEqual(selection.searchRequest?.query, "certificate")
        selection.search("test", in: .library)
        XCTAssertEqual(selection.librarySection, .apps)
        XCTAssertEqual(selection.searchRequest?.tab, .library)
        let previous = selection.searchRequest
        selection.search("unsupported", in: .downloads)
        XCTAssertEqual(selection.searchRequest, previous)
    }

    @MainActor
    func testEmbeddedPagesCanShareOneNavigationStack() {
        XCTAssertFalse(LibraryView(ownsNavigationStack: false).ownsNavigationStack)
        XCTAssertFalse(FilesTabView(ownsNavigationStack: false).ownsNavigationStack)
        XCTAssertFalse(DownloadsTabView(ownsNavigationStack: false).ownsNavigationStack)
        XCTAssertFalse(TaskCenterView().ownsNavigationStack, "Pushed tasks must not create a second navigation stack")
    }

    func testMergedActivityPreservesExistingDownloadDeepLinkIdentifier() {
        XCTAssertEqual(TabEnum.downloads.rawValue, "downloads")
        XCTAssertTrue(TabEnum.defaultTabs.contains(.downloads))
        XCTAssertFalse(TabEnum.defaultTabs.contains(.files))
        XCTAssertFalse(TabEnum.defaultTabs.contains(.logs))
    }

    func testLegacyWorkspaceLinksResolveIntoVisibleTabs() {
        XCTAssertEqual(WorkspaceRoute.resolve(host: "FILES"), .files)
        XCTAssertEqual(WorkspaceRoute.files.tab, .library)
        XCTAssertEqual(WorkspaceRoute.files.librarySection, .files)
        XCTAssertEqual(WorkspaceRoute.logs.tab, .downloads)
        XCTAssertEqual(WorkspaceRoute.logs.activitySection, .logs)
        XCTAssertEqual(WorkspaceRoute.resolve(host: "activity"), .downloads)
        XCTAssertNil(WorkspaceRoute.resolve(host: "not-a-destination"))
    }

    @MainActor
    func testNavigationResetsOnlyTheRequestedWorkspaceSection() {
        let selection = TabSelectionObserver()
        selection.navigate(to: .files)
        XCTAssertEqual(selection.selectedTab, .library)
        XCTAssertEqual(selection.librarySection, .files)
        selection.navigate(to: .logs)
        XCTAssertEqual(selection.selectedTab, .downloads)
        XCTAssertEqual(selection.activitySection, .logs)
        XCTAssertEqual(selection.librarySection, .files)
        selection.navigate(to: .apps)
        XCTAssertEqual(selection.librarySection, .apps)
        selection.navigate(to: .downloads)
        XCTAssertEqual(selection.activitySection, .downloads)
        selection.navigate(to: .files)
        selection.requestIPAExplorer()
        XCTAssertEqual(selection.librarySection, .apps)
        XCTAssertEqual(selection.selectedTab, .library)
        XCTAssertTrue(selection.ipaExplorerRequested, "Explorer intent must survive until the app library mounts")
    }

    func testFreshPreferencesUseFiveNativeTabsIncludingHome() throws {
        let name = "VexSignTabsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = TabBarPreferences(defaults: defaults)
        XCTAssertEqual(preferences.visibleTabs, [.library, .appStore, .home, .downloads, .settings])
        XCTAssertEqual(preferences.resolvedLaunchTab, .home)
        XCTAssertTrue(preferences.isHidden(.files))
    }

    func testLegacySixTabOrderMigratesWithoutKeepingFilesMandatory() throws {
        let name = "VexSignTabsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let old: [String: Any] = [
            "order": ["files", "library", "home", "appStore", "downloads", "settings"],
            "hidden": ["sources", "logs", "tweaks", "certificates"],
            "defaultLaunch": "files", "minimal": false
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "VexSign.tabBarPreferences")
        let preferences = TabBarPreferences(defaults: defaults)
        XCTAssertEqual(preferences.visibleTabs.count, 5)
        XCTAssertEqual(preferences.resolvedLaunchTab, .home)
        preferences.setHidden(.files, false)
        XCTAssertTrue(preferences.visibleTabs.contains(.files))
        let reloaded = TabBarPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.visibleTabs.contains(.files), "Explicit optional Files choice survives relaunch")
    }
}
