//
//  TabbarView.swift
//  VexSign
//
//  Five native default tabs. Optional extra destinations use the custom shell
//  to avoid losing tabs to UIKit's More controller.
//

import SwiftUI

struct TabbarView: View {
    @ObservedObject private var tabSelection = TabSelectionObserver.shared
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @ObservedObject private var tweakManager = TweakManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var tabPrefs = TabBarPreferences.shared
    @AppStorage("VexSign.showSourcesUpdateBadge") private var showSourcesUpdateBadge = true
    @Namespace private var tabSelectionAnimation
    @State private var visitedTabs: Set<TabEnum> = []

    private var visibleTabs: [TabEnum] {
        tabPrefs.visibleTabs
    }

    private var currentTab: TabEnum {
        visibleTabs.contains(tabSelection.selectedTab)
            ? tabSelection.selectedTab
            : tabPrefs.resolvedLaunchTab
    }

    private var selectionBinding: Binding<TabEnum> {
        Binding(
            get: { currentTab },
            set: { select($0) }
        )
    }

    var body: some View {
        Group {
            if visibleTabs.count <= 5 {
                // Native UITabBar supplies real Liquid Glass on iOS 26, and
                // the correct system appearance on older supported versions.
                if #available(iOS 26.0, *) {
                    tabContent.tabBarMinimizeBehavior(.onScrollDown)
                } else {
                    tabContent
                }
            } else {
                // Optional extra destinations must not disappear into More.
                // Do not create a >5-item UITabBarController and hide it:
                // its More UINavigationController can add a second back bar.
                extraTabContent
                    .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            }
        }
        .onAppear { repairSelection() }
        .onChange(of: visibleTabs) { _ in repairSelection() }
    }

    @ViewBuilder
    private var tabContent: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: selectionBinding) {
                ForEach(visibleTabs, id: \.self) { tab in
                    Tab(tab.title, systemImage: tab.icon, value: tab) {
                        TabEnum.view(for: tab)
                    }
                    .badge(badge(for: tab) ?? 0)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tint(Color.userTint)
        } else {
            TabView(selection: selectionBinding) {
                ForEach(visibleTabs, id: \.self) { tab in
                    TabEnum.view(for: tab)
                        .tabItem { Label(tab.title, systemImage: tab.icon) }
                        .badge(badge(for: tab) ?? 0)
                        .tag(tab)
                }
            }
            .tint(Color.userTint)
        }
    }

    private var extraTabContent: some View {
        ZStack {
            // Only create optional roots after visiting them, then retain their
            // navigation/state. This avoids loading every file browser at launch.
            ForEach(visibleTabs.filter { visitedTabs.contains($0) || $0 == currentTab }, id: \.self) { tab in
                TabEnum.view(for: tab)
                    .opacity(tab == currentTab ? 1 : 0)
                    .allowsHitTesting(tab == currentTab)
                    .accessibilityHidden(tab != currentTab)
                    .zIndex(tab == currentTab ? 1 : 0)
            }
        }
        .onAppear { visitedTabs.insert(currentTab) }
        .onChange(of: currentTab) { tab in visitedTabs.insert(tab) }
    }

    private func repairSelection() {
        if !visibleTabs.contains(tabSelection.selectedTab) {
            tabSelection.selectedTab = tabPrefs.resolvedLaunchTab
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                Button {
                    select(tab)
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: currentTab == tab ? tab.icon : tab.iconOutline)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(height: 21)

                            if let badge = badge(for: tab), badge > 0 {
                                Text(badge > 99 ? "99+" : "\(badge)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 16, minHeight: 15)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: 11, y: -7)
                            }
                        }
                        Text(tab.title)
                            .font(.caption2.weight(currentTab == tab ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(currentTab == tab ? Color.userTint : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .background {
                        if currentTab == tab {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.tintSoft)
                                .matchedGeometryEffect(id: "selected-tab", in: tabSelectionAnimation)
                        }
                    }
                }
                .buttonStyle(VexSignFlareButtonStyle())
                .accessibilityLabel(Text(tab.title))
                .accessibilityAddTraits(currentTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 5)
        .padding(.bottom, 2)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: currentTab)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
        }
    }

    private func select(_ tab: TabEnum) {
        if tab == tabSelection.selectedTab, tab == .appStore || tab == .sources {
            tabSelection.sourcesRetapped.toggle()
        }
        tabSelection.selectedTab = tab
    }

    private func badge(for tab: TabEnum) -> Int? {
        if (tab == .appStore || tab == .sources) && showSourcesUpdateBadge {
            return updateChecker.updateCount
        }
        if tab == .tweaks {
            return tweakManager.defaultInjectCount
        }
        if tab == .downloads {
            return downloadManager.downloads.filter { $0.isActive }.count
        }
        return nil
    }
}
