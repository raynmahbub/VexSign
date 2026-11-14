import Foundation
import UIKit
import Combine
import IDeviceSwift

@MainActor
final class BatchSigningAdapter: BatchSigningProviding {
    typealias Icon = UIImage
    private let repository: CoreDataWorkspaceRepository
    private var runner: BatchJobRunner?
    private var sourceApps: [String: LibraryAppRecord] = [:]
    init(repository: CoreDataWorkspaceRepository) { self.repository = repository }
    func prepare(_ request: BatchSigningRequest<UIImage>) throws {
        guard runner == nil else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        let rows = try request.apps.map { try repository.storage.managedApp(matching: $0) }
        let snapshots = try rows.map { try repository.appRecord($0) }
        sourceApps = Dictionary(uniqueKeysWithValues: snapshots.compactMap { app in app.workspaceIdentity.map { ($0, app) } })
        let certificate = try request.certificateID.map { try repository.storage.managedCertificate(id: $0) }
        runner = BatchJobRunner(apps: rows, mode: request.mode, options: request.options, overrides: request.overrides,
            icons: request.icons, certificate: certificate, resignsSigned: request.resignsSigned)
    }
    func state() throws -> BatchSigningState {
        guard let runner else { throw WorkspaceAccessError.invalidReference }
        let items = try runner.items.map { item in
            guard let source = sourceApps[item.id] else { throw WorkspaceAccessError.missingRecord }
            return BatchSigningItem(id: item.id, app: source, state: item.state,
                signed: try item.signed.map { try repository.appRecord($0) })
        }
        return BatchSigningState(items: items, phase: runner.phase, currentIndex: runner.currentIndex,
            currentInstaller: try runner.currentInstaller.map { try InstallationSessionProjection.state($0, repository: repository,
                taskPhase: $0.hasOpenedInstallHandoff ? .waitingForIOS : nil) }, isCancelled: runner.isCancelled)
    }
    func changes() -> AsyncStream<Result<BatchSigningState, Error>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(Result { try state() })
            guard let runner else { continuation.finish(); return }
            let progress = runner.$currentInstaller.map { installer -> AnyPublisher<Void, Never> in
                guard let installer else { return Empty(completeImmediately: false).eraseToAnyPublisher() }
                return installer.objectWillChange.merge(with: installer.viewModel.objectWillChange).eraseToAnyPublisher()
            }.switchToLatest()
            let subscription = runner.objectWillChange.merge(with: progress).sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    continuation.yield(Result { try self.state() })
                }
            }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    func run() async {
        guard let runner else { return }
        if Task.isCancelled { runner.cancel() }
        await withTaskCancellationHandler(operation: { await runner.run() }, onCancel: {
            Task { @MainActor in runner.cancel() }
        })
    }
    func cancel() { runner?.cancel() }
    func skipCurrentInstall() { runner?.skipCurrentInstall() }
    func setFallbackPresented(_ presented: Bool) { runner?.currentInstaller?.isPresentingFallbackPage = presented }
}
