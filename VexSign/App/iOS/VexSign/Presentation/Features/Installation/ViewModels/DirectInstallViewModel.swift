import Foundation
import Combine
import NimbleExtensions

// MARK: - Direct Install ViewModel

@MainActor
final class DirectInstallViewModel: ObservableObject {
    @Published var urlString: String = ""
    @Published var selectedMode: DirectInstallMode = .signAndInstall
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage = ""

    private let useCase: DirectPackageInstallUseCase
    private let platform: PlatformSystemAdapting
    private var operation: Task<Void, Never>?
    private var isVisible = false
    private var generation: UUID?
    private var pendingConfirmation: UUID?

    init(
        initialURL: String = "",
        initialMode: DirectInstallMode = .signAndInstall,
        useCase: DirectPackageInstallUseCase,
        platform: PlatformSystemAdapting
    ) {
        self.urlString = initialURL
        self.selectedMode = initialMode
        self.useCase = useCase
        self.platform = platform
    }

    deinit { operation?.cancel() }

    func appear() { isVisible = true }

    func disappear() {
        // Retire callbacks before cancellation can complete a suspended worker.
        isVisible = false
        generation = nil
        pendingConfirmation = nil
        operation?.cancel()
        operation = nil
        useCase.cancel()
        isProcessing = false
        statusMessage = ""
    }

    func startInstall(onComplete: @escaping () -> Void) {
        guard isVisible, !isProcessing else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetURL = URL(string: trimmed), targetURL.scheme != nil else {
            platform.notifyError(.localized("Please enter a valid URL."), sticky: false)
            return
        }

        let attempt = UUID()
        let mode = selectedMode
        generation = attempt
        pendingConfirmation = nil
        useCase.cancel() // Discard a previous warning, never its registered app.
        isProcessing = true
        statusMessage = .localized("Downloading…")

        operation = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(attempt) else { return }
            defer {
                if self.isCurrent(attempt) {
                    self.isProcessing = false
                    self.operation = nil
                }
            }
            do {
                let result = try await self.useCase.execute(
                    urlString: trimmed,
                    mode: mode,
                    onStatus: { [weak self] status in
                        guard let self, self.isCurrent(attempt) else { return }
                        self.statusMessage = status
                    }
                )
                guard !Task.isCancelled, self.isCurrent(attempt) else { return }
                self.present(result, for: attempt, onComplete: onComplete)
            } catch {
                if self.isCurrent(attempt), !(error is CancellationError) {
                    self.platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
                }
            }
        }
    }

    private func isCurrent(_ attempt: UUID) -> Bool {
        isVisible && generation == attempt
    }

    private func present(_ result: DirectInstallResult, for attempt: UUID, onComplete: @escaping () -> Void) {
        guard isCurrent(attempt) else { return }
        switch result {
        case .queuedForDownloadAndSign:
            platform.notifySuccess(.localized("Download queued for signing & installation"), systemImage: "arrow.down.app")
        case .submittedForGuestImport:
            platform.notifySuccess(.localized("Guest import queued…"), systemImage: "shippingbox")
        case .submittedForInstallation:
            platform.notifySuccess(.localized("Installing without signing…"), systemImage: "bolt.badge.checkmark")
        case .needsIssueConfirmation(let issues):
            pendingConfirmation = attempt
            platform.presentYesNoAlert(
                title: .localized("Install Anyway?"),
                message: issues.joined(separator: "\n"),
                confirmTitle: .localized("Install Anyway")
            ) { [weak self] in
                self?.confirmAnyway(for: attempt, onComplete: onComplete)
            }
            return
        }
        // A platform callback may dismiss or supersede this view re-entrantly.
        guard isCurrent(attempt) else { return }
        onComplete()
    }

    private func confirmAnyway(for attempt: UUID, onComplete: @escaping () -> Void) {
        guard isCurrent(attempt), pendingConfirmation == attempt else { return }
        pendingConfirmation = nil // Consume before submission, including failures.
        do {
            let result = try useCase.confirmPendingInstall()
            present(result, for: attempt, onComplete: onComplete)
        } catch {
            if isCurrent(attempt), !(error is CancellationError) {
                platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
            }
        }
    }
}
