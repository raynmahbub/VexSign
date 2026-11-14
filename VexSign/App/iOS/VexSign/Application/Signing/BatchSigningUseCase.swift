import Foundation

@MainActor
final class BatchSigningUseCase<Icon> {
    private let provider: any BatchSigningProviding<Icon>
    init(provider: any BatchSigningProviding<Icon>, request: BatchSigningRequest<Icon>) throws {
        guard !request.apps.isEmpty, Set(request.apps).count == request.apps.count else {
            throw WorkspaceAccessError.invalidReference
        }
        self.provider = provider
        try provider.prepare(request)
    }
    func state() throws -> BatchSigningState { try provider.state() }
    func changes() -> AsyncStream<Result<BatchSigningState, Error>> { provider.changes() }
    func run() async { await provider.run() }
    func cancel() { provider.cancel() }
    func skipCurrentInstall() { provider.skipCurrentInstall() }
    func setFallbackPresented(_ presented: Bool) { provider.setFallbackPresented(presented) }
}
