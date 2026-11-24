import Foundation

/// Rendering facts projected from the authoritative installer. The only installed
/// state comes from its device-confirmation phase, never a successful submission.
enum InstallPresentation: Equatable, Sendable {
    case preparing, awaitingConfirmation, sendingManifest, installing, verifying
    case installed, unconfirmed, failed, operationCompleted
}

struct InstallationSessionState: Sendable {
    let app: LibraryAppRecord
    let presentation: InstallPresentation
    let overallProgress: Double
    let displayedPercentage: Int?
    let verificationAttempt: Int
    let hasHandedOffInstall: Bool
    let isExport: Bool
    let fallbackPageURL: URL?
    let isPresentingFallbackPage: Bool
    var isCompleted: Bool { presentation == .installed || presentation == .operationCompleted }
}

struct InstallationQueueEntry: Identifiable, Sendable {
    let id: String
    let base: LibraryAppRecord
    let archive: Bool
}

struct InstallationFailure: Identifiable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let details: String
    let needsTrust: Bool
    let canRetryLocally: Bool
    let requiresDeviceCheckBeforeRetry: Bool
    let waitingCount: Int
}

struct InstallationQueueState {
    var current: InstallationQueueEntry?
    var upcoming: [InstallationQueueEntry] = []
    var installedApps: [InstallationQueueEntry] = []
    var installer: InstallationSessionState?
    var index = 0
    var isFinished = false
    var isPaused = false
    var isSheetPresented = false
    var failure: InstallationFailure?
    var succeededCount = 0
    var failedCount = 0
    var latestReport: String?
    var currentTaskID: String?
    static var empty: Self { Self() }
}

@MainActor
protocol InstallationQueueProviding: AnyObject {
    func state() throws -> InstallationQueueState
    func changes() -> AsyncStream<Result<InstallationQueueState, Error>>
    func setPresented(_ presented: Bool)
    func sheetDismissed()
    func activate()
    func pause()
    func resume()
    func clear()
    func skip(entryID: String?)
    func retry(entryID: String?, useLocalhost: Bool, afterManualDeviceCheck: Bool)
    func stopAfterFailure()
    func setFallbackPresented(_ presented: Bool)
}
