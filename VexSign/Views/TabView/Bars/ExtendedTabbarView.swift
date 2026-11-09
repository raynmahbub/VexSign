//
//  ExtendedTabbarView.swift
//  VexSign
//
//  Legacy iOS 18 tab presentation retained for compatibility. The active
//  TabbarView owns the user-configurable destination order and visibility.
//

import SwiftUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
    @ObservedObject private var tabSelection = TabSelectionObserver.shared
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @ObservedObject private var tweakManager = TweakManager.shared
    @ObservedObject private var tabPrefs = TabBarPreferences.shared
    @AppStorage("VexSign.showSourcesUpdateBadge") private var showSourcesUpdateBadge = true

    @State private var selectedTab: TabSelection = .main(.home)

    enum TabSelection: Hashable {
        case main(TabEnum)
    }

    private var selectionBinding: Binding<TabSelection> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard case .main(let tab) = newValue else { return }
                if tab == tabSelection.selectedTab,
                   tab == .appStore || tab == .sources {
                    tabSelection.sourcesRetapped.toggle()
                }
                selectedTab = .main(tab)
                tabSelection.selectedTab = tab
            }
        )
    }

    var body: some View {
        TabView(selection: selectionBinding) {
            ForEach(TabEnum.defaultTabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.icon, value: TabSelection.main(tab)) {
                    TabEnum.view(for: tab)
                }
                .badge(badgeCount(for: tab))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onAppear {
            let launchTab = tabPrefs.resolvedLaunchTab
            let initialTab = TabEnum.defaultTabs.contains(tabSelection.selectedTab)
                ? tabSelection.selectedTab
                : launchTab
            selectedTab = .main(initialTab)
            tabSelection.selectedTab = initialTab
        }
        .onChange(of: tabSelection.selectedTab) { _, newValue in
            guard TabEnum.defaultTabs.contains(newValue) else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedTab = .main(newValue)
            }
        }
    }

    private func badgeCount(for tab: TabEnum) -> Int {
        if tab == .appStore && showSourcesUpdateBadge {
            return updateChecker.updateCount
        }
        if tab == .downloads {
            return DownloadManager.shared.downloads.filter { $0.isActive }.count
        }
        if tab == .library {
            return tweakManager.defaultInjectCount
        }
        return 0
    }
}
