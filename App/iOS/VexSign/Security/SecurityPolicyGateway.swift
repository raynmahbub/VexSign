import Foundation

/// Centralized security policy gateway implementing `SecurityPolicyValidating`
/// so deep-link handlers, direct installers, firmware browsers, and source flows
/// enforce one uniform set of transport, scheme, and extension rules.
struct SecurityPolicyGateway: SecurityPolicyValidating, Sendable {
    private static let disallowedCallbackSchemes: Set<String> = [
        "http", "https", "file", "javascript", "data", "about"
    ]
    private static let allowedPackageExtensions: Set<String> = ["ipa", "tipa"]
    private static let allowedTweakExtensions: Set<String> = ["dylib", "deb", "framework", "bundle", "zip"]

    func validatePackageDownloadURL(_ url: URL) throws {
        try PackageDownloadURLPolicy.validateInitialURL(url)
    }

    func validateFirmwareDownloadURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            throw ArchitectureDomainError.insecureTransport(
                "Firmware downloads require a valid HTTPS URL without embedded credentials."
            )
        }
    }

    func validateRepositoryURL(_ url: URL) throws {
        try SourceURLPolicy.validate(url)
    }

    func isAllowedCertificateCallbackTemplate(_ template: String) -> Bool {
        let lowercased = template.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercased.isEmpty else { return false }
        if Self.disallowedCallbackSchemes.contains(where: { lowercased.hasPrefix($0 + ":") }) {
            return false
        }
        guard let schemeSeparator = lowercased.range(of: "://") else {
            return false
        }
        let scheme = String(lowercased[..<schemeSeparator.lowerBound])
        return !scheme.isEmpty && !Self.disallowedCallbackSchemes.contains(scheme)
    }

    func isAllowedPackageExtension(_ ext: String) -> Bool {
        Self.allowedPackageExtensions.contains(ext.lowercased())
    }

    func isAllowedTweakExtension(_ ext: String) -> Bool {
        Self.allowedTweakExtensions.contains(ext.lowercased())
    }
}
