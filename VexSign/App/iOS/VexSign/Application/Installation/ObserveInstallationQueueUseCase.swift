import Foundation

@MainActor
final class ObserveInstallationQueueUseCase {
    private let provider: InstallationQueueProviding
    init(provider: InstallationQueueProviding) { self.provider = provider }
    func state() throws -> InstallationQueueState { try provider.state() }
    func changes() -> AsyncStream<Result<InstallationQueueState, Error>> { provider.changes() }
    func setPresented(_ presented: Bool) { provider.setPresented(presented) }
    func sheetDismissed() { provider.sheetDismissed() }
    func activate() { provider.activate() }
    func pause() { provider.pause() }
    func resume() { provider.resume() }
    func clear() { provider.clear() }
    func skip(entryID: String?) { provider.skip(entryID: entryID) }
    func retry(entryID: String?, useLocalhost: Bool) { provider.retry(entryID: entryID, useLocalhost: useLocalhost) }
    func stopAfterFailure() { provider.stopAfterFailure() }
    func setFallbackPresented(_ presented: Bool) { provider.setFallbackPresented(presented) }
}
