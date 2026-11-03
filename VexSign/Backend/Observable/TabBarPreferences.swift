//
//  TabBarPreferences.swift
//  VexSign — Library · Home · App Store · Downloads · Settings
//
//  The five primary tabs are a fixed, immutable navigation structure:
//  they are always visible, always in the required order and cannot be
//  hidden or reordered — user customization can never break it.
//  Only the legacy/secondary tabs (Sources, Logs, Tweaks, Certificates)
//  remain hideable and reorderable, and the launch tab stays configurable.
//

import Foundation

final class TabBarPreferences: ObservableObject {
    static let shared = TabBarPreferences()

    /// The required five-tab order. Immutable: not reorderable, not hideable.
    static let primaryTabs: [TabEnum] = TabEnum.defaultTabs

    /// Legacy/secondary tabs. These are the only customizable destinations:
    /// users may show/hide them and order them among themselves.
    static let secondaryTabs: [TabEnum] = TabEnum.customizableTabs

    /// Back-compat: the only hideable tabs are the secondary ones.
    static var hideableTabs: [TabEnum] { secondaryTabs }

    /// Minimal Mode hid primary tabs, which can violate the required
    /// navigation structure, so the mode is retired. Kept as an empty
    /// alias so call sites compile; it no longer hides anything.
    static var minimalTabs: [TabEnum] { [] }

    /// Order of the secondary tabs only (primary tabs are always first,
    /// in the fixed order).
    @Published private(set) var order: [TabEnum]
    /// Hidden secondary tabs. Never applies to a primary tab.
    @Published private(set) var hidden: Set<TabEnum>
    @Published var defaultLaunch: TabEnum {
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
        init(order: [String], hidden: [String], defaultLaunch: String, minimal: Bool) {
            self.version = 2
            self.order = order; self.hidden = hidden; self.defaultLaunch = defaultLaunch; self.minimal = minimal
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
            order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
            hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
            defaultLaunch = try c.decodeIfPresent(String.self, forKey: .defaultLaunch) ?? TabEnum.home.rawValue
            minimal = try c.decodeIfPresent(Bool.self, forKey: .minimal) ?? false
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loadedSecondaryOrder = Self.secondaryTabs
        var loadedHidden = Set(Self.secondaryTabs)
        var loadedLaunch: TabEnum = .home

        if let data = defaults.data(forKey: _key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            // Migrate the previous format, which stored every tab in `order`.
            // The relative order of secondary tabs is preserved; primary tabs
            // are dropped from the stored order because they are fixed now.
            var decoded = stored.order.compactMap { TabEnum(rawValue: $0) }
            if decoded.contains(.sources) && !decoded.contains(.appStore) {
                if let idx = decoded.firstIndex(of: .sources) {
                    decoded[idx] = .appStore
                }
            }
            var sanitized: [TabEnum] = []
            for tab in decoded where Self.secondaryTabs.contains(tab) && !sanitized.contains(tab) {
                sanitized.append(tab)
            }
            for tab in Self.secondaryTabs where !sanitized.contains(tab) {
                sanitized.append(tab)
            }
            loadedSecondaryOrder = sanitized

            loadedHidden = Set(stored.hidden.compactMap { TabEnum(rawValue: $0) })
                .intersection(Self.secondaryTabs)
            // Files used to be mandatory. Hide it on migration unless it was
            // explicitly stored as an optional destination in the new format.
            if stored.version < 2 { loadedHidden.insert(.files) }

            loadedLaunch = TabEnum(rawValue: stored.defaultLaunch) ?? .home
            // Legacy launch-tab remaps from earlier versions.
            if loadedLaunch == .sources { loadedLaunch = .appStore }
            if loadedLaunch == .logs { loadedLaunch = .settings }
            if loadedLaunch == .tweaks { loadedLaunch = .library }
        } else if defaults.object(forKey: "VexSign.showTweaksTab") != nil,
                  defaults.bool(forKey: "VexSign.showTweaksTab") == false {
            loadedHidden = Set(Self.secondaryTabs)
        }

        self.order = loadedSecondaryOrder
        self.hidden = loadedHidden
        self.defaultLaunch = loadedLaunch
        _normalize()
    }

    // MARK: - Derived state

    /// Primary tabs (fixed order) followed by the secondary tabs in the
    /// user's order. This is the full customization list in Settings.
    var orderedTabs: [TabEnum] {
        Self.primaryTabs + order
    }

    /// What the tab bar shows: always all five primary tabs, then any
    /// visible secondary tabs.
    var visibleTabs: [TabEnum] {
        Self.primaryTabs + visibleSecondaryTabs
    }

    /// Secondary tabs currently shown, in the user's order.
    var visibleSecondaryTabs: [TabEnum] {
        order.filter { !hidden.contains($0) }
    }

    func isPrimary(_ tab: TabEnum) -> Bool {
        Self.primaryTabs.contains(tab)
    }

    func isHideable(_ tab: TabEnum) -> Bool {
        Self.secondaryTabs.contains(tab)
    }

    func isHidden(_ tab: TabEnum) -> Bool {
        hidden.contains(tab)
    }

    var resolvedLaunchTab: TabEnum {
        visibleTabs.contains(defaultLaunch) ? defaultLaunch : .home
    }

    // MARK: - Mutations

    /// Only secondary tabs can be hidden. Primary tabs are always visible.
    func setHidden(_ tab: TabEnum, _ value: Bool) {
        guard isHideable(tab) else { return }
        if value { hidden.insert(tab) } else { hidden.remove(tab) }
        _normalize(); _save()
    }

    /// Reorder secondary tabs. `source`/`destination` are indices into the
    /// full secondary list (hidden ones included), as delivered by the
    /// EditMode move gesture on the secondary section.
    func moveSecondary(from source: IndexSet, to destination: Int) {
        var current = order
        current.move(fromOffsets: source, toOffset: destination)
        order = current
        _normalize(); _save()
    }

    /// Legacy entry point: reorders only the secondary portion of a full
    /// list move. Kept for compatibility with older call sites.
    func move(from source: IndexSet, to destination: Int) {
        moveSecondary(from: source, to: destination)
    }

    // MARK: - Normalization / persistence

    private func _normalize() {
        // The stored order only ever contains secondary tabs, in any order.
        var secondary = order.filter { Self.secondaryTabs.contains($0) }
        for tab in Self.secondaryTabs where !secondary.contains(tab) {
            secondary.append(tab)
        }
        order = secondary
        hidden = hidden.intersection(Self.secondaryTabs)
        if !visibleTabs.contains(defaultLaunch) {
            defaultLaunch = .home
        }
    }

    private func _save() {
        let stored = Stored(
            order: order.map { $0.rawValue },
            hidden: hidden.map { $0.rawValue },
            defaultLaunch: defaultLaunch.rawValue,
            minimal: false
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: _key)
        }
        objectWillChange.send()
    }
}
