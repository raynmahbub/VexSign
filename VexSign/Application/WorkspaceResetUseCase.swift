import Foundation

/// Coordinates workspace cache, database, tweaks, certificates, and preference resets.
@MainActor
final class WorkspaceResetUseCase {
    private let resetStore: WorkspaceResetting
    private let platform: PlatformSystemAdapting

    init(resetStore: WorkspaceResetting, platform: PlatformSystemAdapting) {
        self.resetStore = resetStore
        self.platform = platform
    }

    func summary() -> WorkspaceCountsSummary {
        resetStore.currentSummary()
    }

    func perform(_ scope: WorkspaceResetScope) {
        resetStore.perform(scope)
    }

    func requestConfirmedReset(title: String, message: String = "", scope: WorkspaceResetScope) {
        platform.presentDestructiveConfirmation(title: title, message: message) { [weak self] in
            self?.resetStore.perform(scope)
            self?.platform.restartOrSuspendApp()
        }
    }
}
