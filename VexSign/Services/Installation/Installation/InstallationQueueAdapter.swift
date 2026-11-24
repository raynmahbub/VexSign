import Foundation
import Combine
import IDeviceSwift

@MainActor
final class InstallationQueueAdapter: InstallationQueueProviding {
    private let queue: InstallQueue
    private let repository: CoreDataWorkspaceRepository
    init(queue: InstallQueue, repository: CoreDataWorkspaceRepository) { self.queue = queue; self.repository = repository }

    func state() throws -> InstallationQueueState {
        func entry(_ item: AnyApp) throws -> InstallationQueueEntry {
            InstallationQueueEntry(id: item.id, base: try repository.appRecord(item.base), archive: item.archive)
        }
        let taskPhase = UnifiedTaskCenter.shared.tasks.first { $0.id == queue.currentTaskID }?.phase
        let installer = try queue.installer.map { try InstallationSessionProjection.state($0, repository: repository, taskPhase: taskPhase) }
        let failure = queue.failurePresentation.map {
            InstallationFailure(id: $0.id, title: $0.title, message: $0.message, details: $0.details,
                needsTrust: $0.needsTrust, canRetryLocally: $0.canRetryLocally,
                requiresDeviceCheckBeforeRetry: $0.requiresDeviceCheckBeforeRetry, waitingCount: $0.waitingCount)
        }
        return InstallationQueueState(current: try queue.current.map(entry), upcoming: try queue.upcoming.map(entry),
            installedApps: try queue.installedApps.map(entry), installer: installer, index: queue.index,
            isFinished: queue.isFinished, isPaused: queue.isPaused, isSheetPresented: queue.isSheetPresented,
            failure: failure, succeededCount: queue.succeededCount, failedCount: queue.failedCount,
            latestReport: queue.latestReportTask.map { TaskReceipt.report(for: $0) }, currentTaskID: queue.currentTaskID)
    }
    func changes() -> AsyncStream<Result<InstallationQueueState, Error>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(Result { try state() })
            let status = queue.$installer.map { installer -> AnyPublisher<Void, Never> in
                guard let installer else { return Empty(completeImmediately: false).eraseToAnyPublisher() }
                return installer.objectWillChange.merge(with: installer.viewModel.objectWillChange).eraseToAnyPublisher()
            }.switchToLatest()
            let subscription = queue.objectWillChange.merge(with: status)
                .merge(with: UnifiedTaskCenter.shared.objectWillChange).sink { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        continuation.yield(Result { try self.state() })
                    }
                }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    func setPresented(_ presented: Bool) {
        if presented { InstallQueueWindow.shared.ensure() }
        queue.isSheetPresented = presented
    }
    func sheetDismissed() { queue.sheetDismissed() }
    func activate() { queue.activate() }
    func pause() { queue.pause() }
    func resume() { queue.resume() }
    func clear() { queue.clear() }
    func skip(entryID: String?) { PairingBridge.restartHeartbeat(); queue.skip(forEntryID: entryID) }
    func retry(entryID: String?, useLocalhost: Bool, afterManualDeviceCheck: Bool) {
        guard queue.current?.id == entryID else { return }
        PairingBridge.restartHeartbeat()
        queue.retryCurrent(useLocalhost: useLocalhost, afterManualDeviceCheck: afterManualDeviceCheck)
    }
    func stopAfterFailure() { PairingBridge.restartHeartbeat(); queue.stopAfterFailure() }
    func setFallbackPresented(_ presented: Bool) { queue.installer?.isPresentingFallbackPage = presented }
}

@MainActor
enum InstallationSessionProjection {
    static func state(_ installer: AppInstaller, repository: CoreDataWorkspaceRepository,
                      taskPhase: UnifiedTaskPhase? = nil) throws -> InstallationSessionState {
        let presentation = InstallPresentation.resolve(status: installer.viewModel.status, phase: installer.installationPhase,
            taskPhase: taskPhase, isExport: installer.isExport)
        return InstallationSessionState(app: try repository.appRecord(installer.app), presentation: presentation,
            overallProgress: installer.viewModel.overallProgress,
            displayedPercentage: InstallerStatusViewModel.displayedPercentage(phase: installer.installationPhase,
                overall: installer.viewModel.overallProgress, isCompleted: presentation == .installed || presentation == .operationCompleted),
            verificationAttempt: installer.verificationAttempt, hasHandedOffInstall: installer.hasHandedOffInstall,
            isExport: installer.isExport, fallbackPageURL: installer.fallbackPageURL,
            isPresentingFallbackPage: installer.isPresentingFallbackPage)
    }
}
