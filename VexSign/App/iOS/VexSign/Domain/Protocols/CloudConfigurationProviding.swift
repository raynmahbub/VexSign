import Foundation

/// Configuration and health only. No signing/upload capability or token in an
/// observed/persisted UI snapshot; the existing client keeps Keychain authority.
struct CloudConfigurationState: Sendable {
    var isEnabled = false
    var endpoint = ""
    var isTesting = false
    var lastTestResult: String?
    var lastHealthCheckSucceeded: Bool?
}
@MainActor
protocol CloudConfigurationProviding: AnyObject {
    func state() -> CloudConfigurationState
    func changes() -> AsyncStream<CloudConfigurationState>
    func setEnabled(_ enabled: Bool)
    func setEndpoint(_ endpoint: String)
    func bearerToken() -> String
    func setBearerToken(_ token: String)
    func testConnection() async
}
