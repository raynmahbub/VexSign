//
//  TabBarPreferences.swift
//  VexSign
//
//  Navigation preferences: users can reorder and hide any destination except
//  Home and Settings, which remain available for navigation and recovery.
//

import Foundation

final class TabBarPreferences: ObservableObject {
    static let shared = TabBarPreferences()

    /// The familiar initial order. It is a default, not a permanent lock.
    static let primaryTabs: [TabEnum] = TabEnum.defaultTabs
    /// Secondary destinations carried forward from the older tab layout.
    static let secondaryTabs: [TabEnum] = TabEnum.customizableTabs
    /// Destinations that must remain visible so the user can recover navigation preferences.
    static let requiredTabs: Set<TabEnum> = [.home, .settings]
    static let hideableTabs: [TabEnum] = TabEnum.allCases.filter { !requiredTabs.contains($0) }
    private static let defaultOrder = primaryTabs + secondaryTabs

    /// Complete user-controlled order, including hidden destinations.
    @Published private(set) var order: [TabEnum]
    /// Any destination may be hidden except Home and Settings.
    @Published private(set) var hidden: Set<TabEnum>
    @Published var defaultLaunch: TabEnum {
        didSet { _save() }
    }
    @Published var showLabels: Bool {
        didSet { _save() }
    }

    private let _key = "VexSign.tabBarPreferences"
    private let defaults: UserDefaults

    private struct Stored: Codable {
        var version: Int
        var order: [String]
        var hidden: [String]
        var defaultLaunch: String
        var minimal: Bool
        var showLabels: Bool

        init(order: [String], hidden: [String], defaultLaunch: String, minimal: Bool, showLabels: Bool) {
            self.version = 4
            self.order = order
            self.hidden = hidden
            self.defaultLaunch = defaultLaunch
            self.minimal = minimal
            self.showLabels = showLabels
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
            order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
            hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
            defaultLaunch = try container.decodeIfPresent(String.self, forKey: .defaultLaunch) ?? TabEnum.home.rawValue
            minimal = try container.decodeIfPresent(Bool.self, forKey: .minimal) ?? false
            showLabels = try container.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loadedOrder = Self.defaultOrder
        var loadedHidden = Set(Self.secondaryTabs)
        var loadedLaunch: TabEnum = .home
        var loadedShowLabels = true

        if let data = defaults.data(forKey: _key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            loadedShowLabels = stored.showLabels
            loadedLaunch = Self.migratedLaunchTab(stored.defaultLaunch)

            if stored.version >= 4 {
                loadedOrder = Self.sanitizedOrder(stored.order.compactMap { TabEnum(rawValue: $0) })
                loadedHidden = Set(stored.hidden.compactMap { TabEnum(rawValue: $0) })
                    .intersection(Self.hideableTabs)
            } else {
                // Earlier builds kept the five default destinations fixed and
                // persisted only the optional/legacy order and visibility.
                var legacyOrder = stored.order.compactMap { TabEnum(rawValue: $0) }
                if stored.version < 2, legacyOrder.contains(.sources), !legacyOrder.contains(.appStore),
                   let index = legacyOrder.firstIndex(of: .sources) {
                    legacyOrder[index] = .appStore
                }
                var optionalOrder = legacyOrder.filter { Self.secondaryTabs.contains($0) }
                for tab in Self.secondaryTabs where !optionalOrder.contains(tab) {
                    optionalOrder.append(tab)
                }
                loadedOrder = Self.primaryTabs + optionalOrder

                loadedHidden = Set(stored.hidden.compactMap { TabEnum(rawValue: $0) })
                    .intersection(Self.secondaryTabs)
                // Files was mandatory in the oldest format; keep it hidden
                // after migration unless the user explicitly surfaced it.
                if stored.version < 2 { loadedHidden.insert(.files) }
            }
        } else if defaults.object(forKey: "VexSign.showTweaksTab") != nil,
                  defaults.bool(forKey: "VexSign.showTweaksTab") == false {
            loadedHidden = Set(Self.secondaryTabs)
        }

        self.order = Self.sanitizedOrder(loadedOrder)
        self.hidden = loadedHidden.subtracting(Self.requiredTabs)
        self.defaultLaunch = loadedLaunch
        self.showLabels = loadedShowLabels
        _normalize()
    }

    // MARK: - Derived state

    var orderedTabs: [TabEnum] { order }

    var visibleTabs: [TabEnum] {
        order.filter { !hidden.contains($0) }
    }

    var visibleSecondaryTabs: [TabEnum] {
        visibleTabs.filter { Self.secondaryTabs.contains($0) }
    }

    func isPrimary(_ tab: TabEnum) -> Bool {
        Self.primaryTabs.contains(tab)
    }

    func isHideable(_ tab: TabEnum) -> Bool {
        Self.hideableTabs.contains(tab)
    }

    func isHidden(_ tab: TabEnum) -> Bool {
        hidden.contains(tab)
    }

    var resolvedLaunchTab: TabEnum {
        visibleTabs.contains(defaultLaunch) ? defaultLaunch : .home
    }

    // MARK: - Mutations

    func setHidden(_ tab: TabEnum, _ value: Bool) {
        guard isHideable(tab) else { return }
        if value {
            hidden.insert(tab)
        } else {
            hidden.remove(tab)
        }
        _normalize()
        _save()
    }

    /// Reorders the full list, including hidden tabs, using List's move offsets.
    func move(from source: IndexSet, to destination: Int) {
        var current = order
        current.move(fromOffsets: source, toOffset: destination)
        order = Self.sanitizedOrder(current)
        _normalize()
        _save()
    }

    /// Retained for old callers; the secondary subset moves within its own slots.
    func moveSecondary(from source: IndexSet, to destination: Int) {
        var secondary = order.filter(Self.secondaryTabs.contains)
        secondary.move(fromOffsets: source, toOffset: destination)
        var iterator = secondary.makeIterator()
        order = order.map { Self.secondaryTabs.contains($0) ? (iterator.next() ?? $0) : $0 }
        _normalize()
        _save()
    }

    // MARK: - Normalization / persistence

    private static func sanitizedOrder(_ proposed: [TabEnum]) -> [TabEnum] {
        var result: [TabEnum] = []
        for tab in proposed where !result.contains(tab) {
            result.append(tab)
        }
        for tab in defaultOrder where !result.contains(tab) {
            result.append(tab)
        }
        return result
    }

    private static func migratedLaunchTab(_ rawValue: String) -> TabEnum {
        let tab = TabEnum(rawValue: rawValue) ?? .home
        switch tab {
        case .sources: return .appStore
        case .logs: return .settings
        case .tweaks: return .library
        default: return tab
        }
    }

    private func _normalize() {
        order = Self.sanitizedOrder(order)
        hidden = hidden.intersection(Self.hideableTabs)
        if !visibleTabs.contains(defaultLaunch) {
            defaultLaunch = .home
        }
    }

    private func _save() {
        let stored = Stored(
            order: order.map(\.rawValue),
            hidden: hidden.map(\.rawValue),
            defaultLaunch: defaultLaunch.rawValue,
            minimal: false,
            showLabels: showLabels
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: _key)
        }
        objectWillChange.send()
    }
}
