import Foundation

/// Centralized security policy gateway implementing `SecurityPolicyValidating`
/// so deep-link handlers, direct installers, firmware browsers, and source flows
/// enforce one uniform set of transport, scheme, and extension rules.
struct SecurityPolicyGateway: SecurityPolicyValidating, Sendable {
    private static let allowedTweakExtensions: Set<String> = ["dylib", "deb", "framework", "bundle", "zip"]
    /// Characters accepted in a callback scheme: RFC 3986's `ALPHA *( ALPHA / DIGIT / "+" / "-" /
    /// "." )` plus `_`.
    ///
    /// A `String`, not a `CharacterSet`: this type is `Sendable` and a `CharacterSet` static would
    /// not be under strict concurrency.
    ///
    /// `_` is the one deliberate departure from the RFC. It cannot delimit a URL, so admitting it
    /// does not weaken what this check guarantees — that the text before `://` is one scheme token
    /// and not something `URL(string:)` will resolve differently — while custom schemes registered
    /// in the wild do use it, and refusing one would break a working export for a receiving app
    /// this repository knows nothing about.
    private static let schemeCharacters = "abcdefghijklmnopqrstuvwxyz0123456789+-._"

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
        if CertificateCallbackPolicy.disallowedSchemes.contains(where: { lowercased.hasPrefix($0 + ":") }) {
            return false
        }
        guard let schemeSeparator = lowercased.range(of: "://") else {
            return false
        }
        let scheme = String(lowercased[..<schemeSeparator.lowerBound])
        // The scheme must be a single well-formed token (see `schemeCharacters`). Anything else
        // ahead of `://` means that text is not a scheme, so what `URL(string:)` later makes of the
        // string is not what was checked here — `"foo:http://host"` and a smuggled newline both
        // used to reach this point with a "scheme" that no URL parser would agree with.
        let schemeScalars = Self.schemeCharacters.unicodeScalars
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.unicodeScalars.allSatisfy({ schemeScalars.contains($0) })
        else { return false }
        return !CertificateCallbackPolicy.disallowedSchemes.contains(scheme)
    }

    func isAllowedPackageExtension(_ ext: String) -> Bool {
        PackageArchiveType.pickerExtensions.contains(ext.lowercased())
    }

    func isAllowedTweakExtension(_ ext: String) -> Bool {
        Self.allowedTweakExtensions.contains(ext.lowercased())
    }
}
