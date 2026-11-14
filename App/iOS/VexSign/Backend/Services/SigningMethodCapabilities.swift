/// Availability describes an implementation, never whether a particular
/// certificate is valid or an app is installed. Bootstrap installer/account type
/// and detected companion URL schemes do not grant signing capabilities.
struct SigningMethodCapabilities: Equatable, Sendable {
    enum Implementation: Equatable, Sendable { case implemented, notIntegrated }
    enum Runtime: Equatable, Sendable { case none, guestPrototypeUnavailable, guestPrototypeLoaded }

    let importedCertificateSigning: Implementation
    let nativeAppleAccountSigning: Implementation
    let vexSignPrimaryHost: Implementation
    let experimentalRuntime: Runtime

    static var current: Self {
        report(isGuestBuild: EmbeddedContainerRuntime.isGuestBuild,
               guestRuntimeLoaded: EmbeddedContainerRuntime.isAvailable)
    }

    static func report(isGuestBuild: Bool, guestRuntimeLoaded: Bool) -> Self {
        Self(
            importedCertificateSigning: .implemented,
            // Replace only when a concrete native account adapter is wired into
            // provisioning/signing. Never enable from preferences or canOpenURL.
            nativeAppleAccountSigning: .notIntegrated,
            vexSignPrimaryHost: .notIntegrated,
            experimentalRuntime: !isGuestBuild ? .none
                : guestRuntimeLoaded ? .guestPrototypeLoaded : .guestPrototypeUnavailable
        )
    }
}
