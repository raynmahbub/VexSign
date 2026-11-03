import Foundation

/// The same Info.plist compatibility flag used by EmbeddedContainerRuntime,
/// without importing the experimental runtime or its launch hooks. This is not
/// isolation against malicious native code with host-process authority.
enum AppleAccountStorageRuntimePolicy {
    static func isGuestBuild(metadata: [String: Any]) -> Bool {
        metadata["VexSignEmbeddedGuest"] as? Bool == true
    }

    static func requirePrimaryRuntime() throws {
        guard !isGuestBuild(metadata: Bundle.main.infoDictionary ?? [:]) else {
            throw AppleAccountCredentialStoreError.unsupportedGuestRuntime
        }
    }
}
