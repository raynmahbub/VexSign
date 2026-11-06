import Foundation
import NimbleExtensions

/// Direct process-local host access. A detected external URL handler is not enough.
enum EmbeddedContainerRuntime {
    enum Destination: Equatable { case container, sideStore }

    static var isGuestBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "VexSignEmbeddedGuest") as? Bool == true
    }

    static var isAvailable: Bool { VEXEmbeddedRuntimeAvailable() }

    // BGTask launch would restart the host UI without the guest's task handlers.
    // Keep manual/foreground automation; do not register unsupported guest jobs.
    static var supportsScheduledGuestTasks: Bool { !isGuestBuild }

    @MainActor
    static func open(_ destination: Destination) -> Bool {
        VEXEmbeddedRuntimeOpen(destination == .sideStore)
    }

    /// Run on a worker task: both ZIP inspection and copying can be expensive.
    static func stageIPA(_ source: URL) throws -> Bool {
        guard isAvailable else { return false }
        let manager = FileManager.default
        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        // LiveContainer deliberately symlinks guest tmp to the host tmp folder.
        // Copy into guest-owned Caches before the native home-containment check;
        // never broaden that check to all shared temporary files.
        let root = caches.appendingPathComponent("VexSignEmbeddedImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) } // try? ok: best-effort cleanup of a private staging copy
        let local = root.appendingPathComponent("Import.ipa")
        try manager.copyItem(at: source, to: local)
        try ArchiveSafetyValidator.validate(local)
        return VEXEmbeddedRuntimeStageIPA(local)
    }
}


/// A container import is intentionally separate from an installd registration.
/// Even .imported does not prove signing, a successful launch, or renewal.
enum ContainerGuestState: Equatable, Sendable {
    case unavailable
    case unknown
    case notImported
    case imported(version: String?)

    static func derive(runtimeAvailable: Bool, answer: [String: String]?) -> Self {
        guard runtimeAvailable else { return .unavailable }
        switch answer?["state"] {
        case "imported": return .imported(version: answer?["version"])
        case "notImported": return .notImported
        default: return .unknown
        }
    }

    var title: String {
        switch self {
        case .unavailable: return .localized("Embedded runtime not loaded")
        case .unknown: return .localized("Unknown")
        case .notImported: return .localized("Not imported")
        case .imported(let version):
            return version.map { String.localized("Imported guest · v%@", arguments: $0) }
                ?? .localized("Imported guest")
        }
    }
}

extension EmbeddedContainerRuntime {
    static func guestState(for identifier: String) -> ContainerGuestState {
        guard isAvailable else { return .unavailable }
        return .derive(runtimeAvailable: true, answer: VEXEmbeddedRuntimeGuestInfo(identifier))
    }
}
