import Foundation

/// Product release tracks are independent from Apple signing/distribution methods.
enum DistributionChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta
    case alpha
    case development
}

/// An Apple/iOS distribution path. OTA is a delivery mechanism, not a signing class.
enum DistributionMethod: String, Codable, CaseIterable, Sendable {
    case testFlight
    case appStore
    case adHoc
    case enterprise
    case mobileDeviceManagement
    case personalTeam
    case directOTA
    /// Authenticated artifact download/inspection only; this is not an iOS install route.
    case artifactDownload

}

enum ArtifactSigningClass: String, Codable, Sendable {
    case development
    case adHoc
    case enterprise
    case appStore
    case personalTeam
    case unsigned
    case unknown
}

/// Facts required to make a conservative distribution decision. A `true` value
/// must come from inspected evidence, not from a user-selected label.
struct DistributionEligibilityContext: Equatable, Sendable {
    var testFlightAvailable: Bool = false
    var appStoreEligible: Bool = false
    var registeredDevice: Bool = false
    var enterpriseProgramEligible: Bool = false
    var organizationManagedDevice: Bool = false
    var personalTeamProvisioningValid: Bool = false
    var profileNotExpired: Bool = false
    var bundleIdentifierMatches: Bool = false
    var deviceIncludedInProfile: Bool = false
}

struct DistributionEligibility: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case eligible
        case ineligible(reason: Reason)
        case requiresExternalFlow(reason: Reason)
    }

    enum Reason: String, Equatable, Sendable {
        case testFlightNotPublished
        case appStoreRequiresAppleDistribution
        case registeredDeviceRequired
        case enterpriseMembershipRequired
        case managedDeviceRequired
        case personalTeamProfileRequired
        case expiredOrMissingProfile
        case bundleIdentifierMismatch
        case deviceNotIncluded
        case otaRequiresEligibleSignedArtifact
        case mdmRequiresOrganizationManagement
        case unsupportedArtifactSigningClass
    }

    let method: DistributionMethod
    let state: State
}

struct DistributionEligibilityService: Sendable {
    func evaluate(
        method: DistributionMethod,
        signingClass: ArtifactSigningClass,
        context: DistributionEligibilityContext
    ) -> DistributionEligibility {
        func result(_ state: DistributionEligibility.State) -> DistributionEligibility {
            DistributionEligibility(method: method, state: state)
        }
        func eligibleProfile() -> DistributionEligibility.State? {
            guard context.profileNotExpired else { return .ineligible(reason: .expiredOrMissingProfile) }
            guard context.bundleIdentifierMatches else { return .ineligible(reason: .bundleIdentifierMismatch) }
            return nil
        }

        switch method {
        case .testFlight:
            return result(
                context.testFlightAvailable ? .eligible : .requiresExternalFlow(reason: .testFlightNotPublished)
            )
        case .appStore:
            guard signingClass == .appStore else {
                return result(.ineligible(reason: .appStoreRequiresAppleDistribution))
            }
            return result(
                context.appStoreEligible ? .eligible : .requiresExternalFlow(reason: .appStoreRequiresAppleDistribution)
            )
        case .adHoc:
            guard signingClass == .adHoc else { return result(.ineligible(reason: .unsupportedArtifactSigningClass)) }
            if let failure = eligibleProfile() { return result(failure) }
            guard context.deviceIncludedInProfile else { return result(.ineligible(reason: .deviceNotIncluded)) }
            return result(context.registeredDevice ? .eligible : .ineligible(reason: .registeredDeviceRequired))
        case .enterprise:
            guard signingClass == .enterprise else {
                return result(.ineligible(reason: .unsupportedArtifactSigningClass))
            }
            if let failure = eligibleProfile() { return result(failure) }
            return result(
                context.enterpriseProgramEligible ? .eligible : .ineligible(reason: .enterpriseMembershipRequired)
            )
        case .personalTeam:
            guard signingClass == .personalTeam else {
                return result(.ineligible(reason: .unsupportedArtifactSigningClass))
            }
            if let failure = eligibleProfile() { return result(failure) }
            guard context.personalTeamProvisioningValid else {
                return result(.ineligible(reason: .personalTeamProfileRequired))
            }
            guard context.deviceIncludedInProfile else { return result(.ineligible(reason: .deviceNotIncluded)) }
            return result(context.registeredDevice ? .eligible : .ineligible(reason: .registeredDeviceRequired))
        case .mobileDeviceManagement:
            return result(
                context.organizationManagedDevice ? .eligible : .ineligible(reason: .mdmRequiresOrganizationManagement)
            )
        case .directOTA:
            guard [.adHoc, .enterprise].contains(signingClass) else {
                return result(.ineligible(reason: .otaRequiresEligibleSignedArtifact))
            }
            if let failure = eligibleProfile() { return result(failure) }
            if signingClass == .adHoc {
                guard context.deviceIncludedInProfile else { return result(.ineligible(reason: .deviceNotIncluded)) }
                guard context.registeredDevice else { return result(.ineligible(reason: .registeredDeviceRequired)) }
            } else if !context.enterpriseProgramEligible {
                return result(.ineligible(reason: .enterpriseMembershipRequired))
            }
            return result(.eligible)
        case .artifactDownload:
            return result(.eligible)
        }
    }
}

struct ReleaseSigningInformation: Codable, Equatable, Sendable {
    let distributionMethod: DistributionMethod
    let signingClass: ArtifactSigningClass
    let teamIdentifier: String?
    let certificateSHA256: String?
}

/// Signed metadata payload. The detached signature covers the exact UTF-8 bytes
/// carried by `SignedReleaseManifest.payloadBase64`; consumers verify before decoding.
struct ReleaseManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let applicationIdentifier: String
    let version: String
    let buildNumber: String
    let channel: DistributionChannel
    let minimumOSVersion: String
    let downloadURL: URL
    let ipaSHA256: String
    let releaseNotesURL: URL?
    let createdAt: Date
    let expiresAt: Date
    let signing: ReleaseSigningInformation
}

struct SignedReleaseManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let algorithm: String
    let keyID: String
    let payloadBase64: String
    let signatureBase64: String
}

enum ReleaseManifestFailure: Error, Equatable {
    case unsupportedSchema
    case invalidApplicationIdentifier
    case invalidVersion
    case invalidBuildNumber
    case invalidMinimumOSVersion
    case invalidURL
    case invalidSHA256
    case invalidSigningFingerprint
    case invalidTeamIdentifier
    case invalidSigningClass
    case invalidDateRange
    case expired
    case futureDated
    case unsupportedMinimumOS
    case malformedEnvelope
    case unsupportedSignatureAlgorithm
    case unknownSigningKey
    case invalidSignature
    case invalidPayload
}
