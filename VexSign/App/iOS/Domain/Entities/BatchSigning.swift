import Foundation

enum BatchSigningMode {
    case sign, install, signAndInstall
    var signs: Bool { self != .install }
    var installs: Bool { self != .sign }
}

enum BatchSigningPhase: Equatable { case signing, installing, finished }
enum BatchSigningItemState: Equatable {
    case queued, working, signed, alreadySigned, installed, unconfirmed, skipped
    case failed(String)
}

struct BatchSigningItem: Identifiable {
    let id: String
    let app: LibraryAppRecord
    let state: BatchSigningItemState
    let signed: LibraryAppRecord?
    var installable: LibraryAppRecord { signed ?? app }
}

struct BatchSigningRequest<Icon> {
    let apps: [LibraryAppReference]
    let mode: BatchSigningMode
    let options: Options
    let overrides: [String: Options]
    let icons: [String: Icon]
    let certificateID: String?
    let resignsSigned: Bool
}

struct BatchSigningState {
    var items: [BatchSigningItem] = []
    var phase: BatchSigningPhase
    var currentIndex = 0
    var currentInstaller: InstallationSessionState?
    var isCancelled = false
}

@MainActor
protocol BatchSigningProviding<Icon>: AnyObject {
    associatedtype Icon
    func prepare(_ request: BatchSigningRequest<Icon>) throws
    func state() throws -> BatchSigningState
    func changes() -> AsyncStream<Result<BatchSigningState, Error>>
    func run() async
    func cancel()
    func skipCurrentInstall()
    func setFallbackPresented(_ presented: Bool)
}
