import SwiftUI

/// Entry metadata only: marker contents are not passed through navigation or shown here.
struct FixtureRecoveryList: View {
    @EnvironmentObject private var services: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var locks = AppLockManager.shared
    @State private var entries: [FixtureRecoveryEntry] = []
    @State private var message = ""
    @State private var unlocking = false

    private var orphans: [FixtureRecoveryEntry] {
        let live = Set(services.workspace.snapshot.signedApps.compactMap(\.workspaceIdentity))
        return entries.filter { row in
            !live.contains(row.id) && (locks.isRevealingHiddenApps ||
                ![row.uuid, row.activeUUID].compactMap { $0 }.contains(where: locks.hiddenAppUUIDs.contains))
        }
    }
    var body: some View {
        List {
            if scenePhase == .active && !locks.isLocked {
                Section("Backups without the original library copy") {
                    ForEach(orphans) { entry in
                        if let locked = [entry.uuid, entry.activeUUID].compactMap({ $0 }).first(where: {
                            locks.isAppLocked($0) && !locks.isSessionUnlocked($0)
                        }) {
                            Button("Unlock protected backup") {
                                unlocking = true
                                locks.authenticateForApp(uuid: locked, name: "fixture backup") { _ in
                                    unlocking = false; reload()
                                }
                            }.disabled(unlocking)
                        } else {
                            NavigationLink(entry.bundle) { FixtureSlotView(entry: entry) }
                        }
                    }
                    if orphans.isEmpty && message.isEmpty { Text("No recoverable orphaned fixture backups.") }
                    if !message.isEmpty { Text(message) }
                }
            }
        }
        .navigationTitle("Fixture recovery")
        .onAppear { reload() }
        .onChange(of: scenePhase) { _, newValue in if newValue == .active { reload() } }
        .refreshable { reload() }
    }
    private func reload() {
        entries = []; message = ""
        guard !locks.isLocked, scenePhase == .active else { return }
        do { entries = try FixtureSlotStorage.recoveryEntries() }
        catch { message = error.localizedDescription }
    }
}

/// Re-resolve the journal on presentation instead of trusting the shortcut's snapshot.
struct FixtureShortcutDestination: View {
    let route: FixtureSlotRoute
    @ObservedObject private var locks = AppLockManager.shared
    @State private var entry: FixtureRecoveryEntry?
    @State private var message = ""

    var body: some View {
        Group {
            if let entry, locks.canOpenFixtureBackup(entry) {
                FixtureSlotView(entry: entry)
            } else {
                Text(message.isEmpty ? "The selected fixture backup is unavailable or locked." : message)
            }
        }
        .task(id: route.id) {
            entry = nil; message = ""
            do {
                guard !locks.isLocked, let current = try FixtureSlotStorage.load(route.copyID)?.recoveryEntry,
                      current.uuid == route.uuid else { return }
                entry = current
            } catch { message = error.localizedDescription }
        }
    }
}
