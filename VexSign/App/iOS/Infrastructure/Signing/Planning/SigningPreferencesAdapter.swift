import Foundation
import Combine
import CoreData
import NimbleExtensions

@MainActor
final class SigningPreferencesAdapter: SigningPreferencesProviding {
    private let options: OptionsManager
    private let profiles: NamedSigningProfileStore
    private let sharing: TemporaryFileSharing
    init(options: OptionsManager = .shared, profiles: NamedSigningProfileStore = .shared, sharing: TemporaryFileSharing) {
        self.options = options
        self.profiles = profiles
        self.sharing = sharing
    }
    func state() -> SigningPreferencesState {
        SigningPreferencesState(options: options.options, profiles: profiles.profiles, canAutoSign: AutoSignManager.canSign)
    }
    func changes() -> AsyncStream<SigningPreferencesState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state())
            let tokens = [options.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in if let self { continuation.yield(self.state()) } }
            }, profiles.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in if let self { continuation.yield(self.state()) } }
            }, NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange).sink { [weak self] _ in
                Task { @MainActor in if let self { continuation.yield(self.state()) } }
            }]
            let observation = StreamObservationCancellation(tokens)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    func saveOptions(_ value: Options) { options.options = value; options.saveOptions() }
    func saveProfile(_ profile: NamedSigningProfile) { profiles.save(profile) }
    func removeProfile(id: String) { profiles.remove(id: id) }
    func importProfiles(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // An untrusted presets file is metadata, not an unbounded archive.
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 2 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        try profiles.importJSON(Data(contentsOf: url))
    }
    func shareProfiles() throws {
        guard let data = profiles.exportJSON() else { throw CocoaError(.fileWriteUnknown) }
        let lease = try AppOperationRegistry.shared.acquireTemporaryWork()
        let directory = FileManager.default.uniqueTemporaryDirectory("SigningProfilesExport")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let url = directory.appendingPathComponent("VexSign-profiles.json")
            try data.write(to: url, options: .atomic)
            try sharing.shareFile(url) {
                defer { withExtendedLifetime(lease) {} }
                do { try FileManager.default.removeItem(at: directory) }
                catch { FileLogger.error("Could not remove signing profile export: \(error.localizedDescription)", category: "signing") }
            }
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { FileLogger.error("Could not remove failed profile export: \(error.localizedDescription)", category: "signing") }
            throw error
        }
    }
}
