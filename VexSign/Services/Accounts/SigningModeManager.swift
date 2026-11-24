import Combine
import Foundation
import NimbleExtensions

/// The two app-delivery pipelines. Direct mode installs an already prepared IPA through OTA or
/// a paired device; container mode stages a guest for explicit import by the embedded host.
enum SigningMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case directPaid
    case containerized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directPaid: return .localized("Direct Paid / Certificate")
        case .containerized: return .localized("Containerized Free Account")
        }
    }
}

/// Automatic is the default so the combined host works without a certificate while existing
/// standalone installs keep their OTA/IDevice behavior. Explicit modes never silently fall back.
enum SigningModePreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case directPaid
    case containerized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return .localized("Automatic")
        case .directPaid: return SigningMode.directPaid.title
        case .containerized: return SigningMode.containerized.title
        }
    }
}

/// Non-secret facts used only for route selection. This is deliberately weaker than signing
/// preflight: profile entitlement/device scope and PKCS#12 password validation still happen in
/// the existing signing pipeline. A short development profile is not assumed to be paid.
struct CertificateRoutingEvidence: Equatable, Sendable {
    var hasIdentityFile: Bool
    var hasProvisioningProfile: Bool
    var isRevoked: Bool
    var certificateExpiresAt: Date?
    var profileExpiresAt: Date?
    var profileTimeToLive: Int?
    var provisionsAllDevices: Bool

    func isDirectPaidCandidate(at date: Date) -> Bool {
        guard hasIdentityFile, hasProvisioningProfile, !isRevoked,
              let certificateExpiresAt, certificateExpiresAt > date,
              let profileExpiresAt, profileExpiresAt > date else { return false }
        return provisionsAllDevices || (profileTimeToLive.map { $0 > 7 } ?? false)
    }
}

enum InstallationPipeline: Equatable, Sendable {
    case directPaid(InstallMethodKind)
    case containerized

    var mode: SigningMode {
        switch self {
        case .directPaid: return .directPaid
        case .containerized: return .containerized
        }
    }

    var installMethod: InstallMethodKind {
        switch self {
        case .directPaid(let method): return method
        case .containerized: return .liveContainer
        }
    }

    var installationMethodValue: Int {
        switch installMethod {
        case .server: return 0
        case .idevice: return 1
        case .liveContainer: return 2
        case .export, .trollstore: return -1
        }
    }
}

enum InstallationRoutingError: Error, Equatable {
    case containerUnavailable
    case unknownInstallationMethod(Int)
    case invalidDirectMethod(Int)
}

extension InstallationRoutingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return .localized("Containerized routing requires the embedded LiveContainer runtime. Install and open the experimental combined host, or choose Direct Paid / Certificate routing.")
        case .unknownInstallationMethod:
            return .localized("Unknown installation method. Choose OTA, pairing/IDevice or containerized routing in Settings → Installation.")
        case .invalidDirectMethod(let value):
            return .localized("The saved direct installation method (%lld) is invalid. Choose Server or idevice in Settings → Installation.", arguments: value)
        }
    }
}

struct InstallationRoutingInput: Equatable, Sendable {
    var preference: SigningModePreference = .automatic
    var certificate: CertificateRoutingEvidence?
    var hasEmbeddedRuntime = false
    var storedInstallationMethod = 0
    var preferredDirectInstallationMethod = 0
}

/// Pure routing policy, separate from Core Data and the runtime so every branch can be tested.
enum InstallationRouter {
    static func resolve(_ input: InstallationRoutingInput, at date: Date = Date()) throws -> InstallationPipeline {
        guard (0...2).contains(input.storedInstallationMethod) else {
            throw InstallationRoutingError.unknownInstallationMethod(input.storedInstallationMethod)
        }

        switch input.preference {
        case .containerized:
            return try container(input.hasEmbeddedRuntime)
        case .directPaid:
            return .directPaid(try directMethod(forExplicitDirectRoute: input))
        case .automatic:
            // Value 2 was the guest route before mode routing existed. Preserve that explicit
            // choice instead of allowing a later certificate import to change it unexpectedly.
            if input.storedInstallationMethod == 2 {
                return try container(input.hasEmbeddedRuntime)
            }
            let method = try directMethod(storedValue: input.storedInstallationMethod)
            if input.certificate?.isDirectPaidCandidate(at: date) == true {
                return .directPaid(method)
            }
            if input.hasEmbeddedRuntime { return .containerized }
            // A standalone build has no guest destination. Keep its established direct pipeline
            // for already signed/ad-hoc IPAs; signing preflight still requires an identity.
            return .directPaid(method)
        }
    }

    private static func container(_ available: Bool) throws -> InstallationPipeline {
        guard available else { throw InstallationRoutingError.containerUnavailable }
        return .containerized
    }

    private static func directMethod(forExplicitDirectRoute input: InstallationRoutingInput) throws -> InstallMethodKind {
        if input.storedInstallationMethod != 2 {
            return try directMethod(storedValue: input.storedInstallationMethod)
        }
        return try directMethod(storedValue: input.preferredDirectInstallationMethod, invalidAsDirect: true)
    }

    private static func directMethod(storedValue: Int, invalidAsDirect: Bool = false) throws -> InstallMethodKind {
        switch storedValue {
        case 0: return .server
        case 1: return .idevice
        default:
            if invalidAsDirect { throw InstallationRoutingError.invalidDirectMethod(storedValue) }
            throw InstallationRoutingError.unknownInstallationMethod(storedValue)
        }
    }
}

/// Owns the persisted mode preference and resolves non-secret certificate evidence at the moment
/// an installer is created. No account tokens, passwords or certificate bytes enter preferences.
@MainActor
final class SigningModeManager: ObservableObject {
    static let shared = SigningModeManager()
    static let preferenceKey = "VexSign.signingModePreference"
    static let preferredDirectMethodKey = "VexSign.preferredDirectInstallationMethod"
    private static let installationMethodKey = "VexSign.installationMethod"

    @Published private(set) var preference: SigningModePreference
    private let defaults: UserDefaults
    /// Profile parsing can be expensive in a library with hundreds of rows. Identity UUID,
    /// revocation and recorded expiry form the cache key; a new import uses a new identity UUID.
    private var certificateEvidenceCache: [String: CertificateRoutingEvidence] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = defaults.string(forKey: Self.preferenceKey)
            .flatMap(SigningModePreference.init(rawValue:)) ?? .automatic
    }

    func selectPreference(_ newPreference: SigningModePreference) {
        if newPreference == .directPaid,
           defaults.integer(forKey: Self.installationMethodKey) == 2 {
            defaults.set(preferredDirectMethod, forKey: Self.installationMethodKey)
        }
        guard preference != newPreference else { return }
        preference = newPreference
        defaults.set(newPreference.rawValue, forKey: Self.preferenceKey)
    }

    func selectDirectMethod(_ value: Int) {
        guard value == 0 || value == 1 else { return }
        defaults.set(value, forKey: Self.preferredDirectMethodKey)
        defaults.set(value, forKey: Self.installationMethodKey)
        selectPreference(.directPaid)
    }

    var preferredDirectMethod: Int {
        let value = defaults.object(forKey: Self.preferredDirectMethodKey) == nil
            ? 0 : defaults.integer(forKey: Self.preferredDirectMethodKey)
        return value == 0 || value == 1 ? value : 0
    }

    func pipeline(for app: AppInfoPresentable? = nil, at date: Date = Date()) throws -> InstallationPipeline {
        let storedMethod = defaults.integer(forKey: Self.installationMethodKey)
        return try InstallationRouter.resolve(InstallationRoutingInput(
            preference: preference,
            certificate: certificateEvidence(for: app),
            hasEmbeddedRuntime: EmbeddedContainerRuntime.isAvailable,
            storedInstallationMethod: storedMethod,
            preferredDirectInstallationMethod: preferredDirectMethod
        ), at: date)
    }

    private func certificateEvidence(for app: AppInfoPresentable?) -> CertificateRoutingEvidence? {
        let associated = app.flatMap { Storage.shared.getCertificate(from: $0) }
        let selectedIndex = defaults.integer(forKey: "vexsign.selectedCert")
        let certificate = associated ?? Storage.shared.getCertificate(for: selectedIndex)
        guard let certificate else { return nil }

        let identity = certificate.uuid ?? certificate.objectID.uriRepresentation().absoluteString
        let cacheKey = "\(identity)|\(certificate.revoked)|\(certificate.expiration?.timeIntervalSince1970 ?? 0)"
        if let cached = certificateEvidenceCache[cacheKey] { return cached }

        let profileURL = Storage.shared.getFile(.provision, from: certificate)
        let profile = Storage.shared.getProvisionFileDecoded(for: certificate)
        let evidence = CertificateRoutingEvidence(
            hasIdentityFile: Storage.shared.getFile(.certificate, from: certificate) != nil,
            hasProvisioningProfile: profileURL != nil && profile != nil,
            isRevoked: certificate.revoked,
            certificateExpiresAt: certificate.expiration,
            profileExpiresAt: profile?.ExpirationDate,
            profileTimeToLive: profile?.TimeToLive,
            provisionsAllDevices: profile?.ProvisionsAllDevices == true
        )
        certificateEvidenceCache[cacheKey] = evidence
        return evidence
    }
}
