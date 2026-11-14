import Foundation
import Combine

@MainActor
final class CloudConfigurationAdapter: CloudConfigurationProviding {
    private let client: CloudSigningClient
    init(client: CloudSigningClient) { self.client = client }
    func state() -> CloudConfigurationState {
        CloudConfigurationState(isEnabled: client.isEnabled, endpoint: client.serverURLString,
            isTesting: client.isTesting, lastTestResult: client.lastTestResult,
            lastHealthCheckSucceeded: client.lastHealthCheckSucceeded)
    }
    func changes() -> AsyncStream<CloudConfigurationState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state())
            let token = client.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    continuation.yield(self.state())
                }
            }
            let cancellation = StreamObservationCancellation(token)
            continuation.onTermination = { _ in cancellation.cancel() }
        }
    }
    func setEnabled(_ value: Bool) { client.isEnabled = value }
    func setEndpoint(_ value: String) { client.serverURLString = value }
    func bearerToken() -> String { client.apiKey }
    func setBearerToken(_ value: String) { client.apiKey = value }
    func testConnection() async { await client.testConnection() }
}
