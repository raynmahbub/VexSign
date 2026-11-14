import Foundation

@MainActor
final class RoutingDiagnosticsAdapter: RoutingDiagnosticsProviding {
    func warning(_ message: String, security: Bool) {
        SubsystemDiagnosticsLog.warn(message, subsystem: security ? .security : .routing)
    }
    func info(_ message: String) { SubsystemDiagnosticsLog.info(message, subsystem: .routing) }
    func report(_ error: Error) { SubsystemDiagnosticsLog.error(error, subsystem: .security) }
    func userMessage(for error: Error) -> String { ErrorBoundary.userMessage(for: error) }
}
