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
    func testHomeUpdatesShortcutSelectsUpdatesSegment() {
        let selection = TabSelectionObserver()
        selection.openAppStoreUpdates()
        XCTAssertEqual(selection.selectedTab, .appStore)
        XCTAssertEqual(selection.appStoreSectionRequest, "Updates")
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

    func testLibraryHasThreeOrderedNonoverlappingSections() {
        XCTAssertEqual(LibraryWorkspaceSection.allCases, [.files, .apps, .signedApps])
        XCTAssertFalse(LibraryWorkspaceSection.signedApps.title.isEmpty)
        XCTAssertTrue(LibraryWorkspaceSection.apps.includesApp(isSigned: false))
        XCTAssertFalse(LibraryWorkspaceSection.apps.includesApp(isSigned: true))
        XCTAssertTrue(LibraryWorkspaceSection.signedApps.includesApp(isSigned: true))
        XCTAssertFalse(LibraryWorkspaceSection.signedApps.includesApp(isSigned: false))
        XCTAssertFalse(LibraryWorkspaceSection.files.includesApp(isSigned: true))
        XCTAssertFalse(LibraryWorkspaceSection.files.includesApp(isSigned: false))
    }

    @MainActor
    func testSignedRoutesAndHighlightsSelectSignedApps() {
        let selection = TabSelectionObserver()
        selection.navigate(to: .signedApps)
        XCTAssertEqual(selection.selectedTab, .library)
        XCTAssertEqual(selection.librarySection, .signedApps)
        XCTAssertEqual(WorkspaceRoute.resolve(host: "signedapps"), .signedApps)
        XCTAssertEqual(WorkspaceRoute.resolve(host: "signed"), .signedApps)
        selection.navigateToLibraryWithHighlight(uuid: "signed-row", isSigned: true)
        XCTAssertEqual(selection.librarySection, .signedApps)
        XCTAssertEqual(selection.highlightedAppUUID, "signed-row")
        selection.navigateToLibraryWithHighlight(uuid: "imported-row", isSigned: false)
        XCTAssertEqual(selection.librarySection, .apps)
    }

    func testKSignStyleActionsRespectStoredAppKind() {
        XCTAssertEqual(LibraryAppWorkflowAction.actions(isSigned: true), [.install, .resign])
        XCTAssertEqual(LibraryAppWorkflowAction.actions(isSigned: false), [.signAndInstall])
        XCTAssertFalse(LibraryAppWorkflowAction.actions(isSigned: false).contains(.install),
                       "Unsigned imports must not bypass signing through the quick action")
    }

    func testSignAndInstallIntentChangesOnlyTheRequestOptions() {
        var base = Options.batchBase
        base.post_installAppAfterSigned = false
        let request = LibraryAppWorkflowAction.signingOptions(from: base, installAfterSigning: true)
        XCTAssertTrue(request.post_installAppAfterSigned)
        XCTAssertFalse(base.post_installAppAfterSigned, "The quick action must not change saved global defaults")
        XCTAssertFalse(LibraryAppWorkflowAction.signingOptions(from: base, installAfterSigning: false).post_installAppAfterSigned)
        base.post_installAppAfterSigned = true
        XCTAssertTrue(LibraryAppWorkflowAction.signingOptions(from: base, installAfterSigning: false).post_installAppAfterSigned)
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
