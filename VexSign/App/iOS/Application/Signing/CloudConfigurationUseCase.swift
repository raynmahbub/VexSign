import Foundation

@MainActor
final class CloudConfigurationUseCase {
    private let provider: CloudConfigurationProviding
    private var testing = false
    init(provider: CloudConfigurationProviding) { self.provider = provider }
    func state() -> CloudConfigurationState { provider.state() }
    func changes() -> AsyncStream<CloudConfigurationState> { provider.changes() }
    func setEnabled(_ value: Bool) { provider.setEnabled(value) }
    func setEndpoint(_ value: String) { provider.setEndpoint(value) }
    func bearerToken() -> String { provider.bearerToken() }
    func setBearerToken(_ value: String) { provider.setBearerToken(value) }
    func testConnection() async {
        guard !testing, !Task.isCancelled else { return }
        testing = true; defer { testing = false }
        await provider.testConnection()
    }
}
