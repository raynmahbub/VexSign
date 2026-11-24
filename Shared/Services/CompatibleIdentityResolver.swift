import Foundation

/// One mandatory validator for candidate selection and execution admission.
/// Authentication and key proofs are produced by the platform adapter, never
/// inferred from a filename, selected row, or untrusted plist.
enum ProfileCompatibilityValidator {
    static func evaluate(_ candidate: SigningProfileCandidate, for target: BundleSigningTarget,
                         deviceUDID: String?, requiredTeam: String? = nil,
                         now: Date = Date()) -> SigningComponentResolution {
        let profile = candidate.profile
        var issues: [SigningResolutionIssue] = []
        var hasInvalid = false, hasUnsupported = false
        func reject(_ code: SigningResolutionIssue.Code, _ detail: String, status: SigningValidationStatus = .invalid) {
            issues.append(.init(code: code, detail: detail))
            hasInvalid = hasInvalid || status == .invalid
            hasUnsupported = hasUnsupported || status == .unsupported
        }
        if !candidate.isAuthenticated { reject(.authenticity, "The profile's Apple CMS signature could not be authenticated. Import an original profile issued by Apple.") }
        if profile.ExpirationDate <= now || profile.CreationDate > now {
            reject(.expiration, "The profile is expired or is not valid yet. Import a current profile.")
        }
        let appID = profile.Entitlements?["application-identifier"]?.value as? String ?? ""
        let match = ProfileApplicationIdentifierMatcher.match(applicationIdentifier: appID, bundleIdentifier: target.bundleIdentifier)
        if !match.isAuthorized {
            reject(.identifier, "Profile \"\(profile.Name)\" authorizes \"\(appID)\", not \"\(target.bundleIdentifier)\". Import a profile for this original Bundle Identifier and its matching .p12 identity; identifiers will not be changed to fit a profile.")
        }
        if let prefix = match.authorized?.prefix, !(profile.ApplicationIdentifierPrefix ?? []).contains(prefix) {
            reject(.prefix, "The App ID prefix is not in the profile's authorized prefix list.")
        }
        let team = profile.TeamIdentifier.first
        if profile.TeamIdentifier.count != 1 || team?.isEmpty != false || candidate.identity.teamIdentifier != team
            || (requiredTeam != nil && requiredTeam != team)
            || profile.Entitlements?["com.apple.developer.team-identifier"]?.value as? String != team {
            reject(.team, "The profile, certificate and containing application must belong to the same Apple team. An App ID prefix is not a substitute for a Team ID.")
        }
        if !candidate.authorizedCertificateFingerprints.contains(candidate.identity.fingerprint) {
            reject(.certificate, "The signing certificate is not included in this profile. Import a profile issued for this certificate.")
        }
        if candidate.identity.notBefore == nil || candidate.identity.notAfter == nil
            || candidate.identity.notBefore.map({ $0 > now }) == true || candidate.identity.notAfter.map({ $0 <= now }) == true {
            reject(.certificate, "The signing certificate is expired, not yet valid, or has no readable validity window.")
        }
        if !candidate.identity.nativeSigningSupported {
            reject(.certificate, "This certificate issuer is not supported by the current native CMS writer. No incompatible identity has been selected; import an Apple-issued identity supported by this backend.", status: .unsupported)
        }
        switch candidate.identity.keyAvailability {
        case .accessible: break
        case .missing: reject(.privateKey, "The certificate is present but its matching private key is missing. Import the complete signing identity (.p12).")
        case .inaccessible:
            reject(.privateKey, "The private key is inaccessible. Unlock the device and verify the identity's saved password.", status: .ambiguous)
        }
        if profile.profileType == .distribution || profile.profileType == .unknown {
            reject(.mode, "This profile cannot be used for direct device installation. Use Development, Ad Hoc, or In-House provisioning.", status: .unsupported)
        }
        if profile.ProvisionsAllDevices != true {
            if let deviceUDID, !deviceUDID.isEmpty, target.platform != "watchOS" {
                if !(profile.ProvisionedDevices ?? []).contains(where: { $0.caseInsensitiveCompare(deviceUDID) == .orderedSame }) {
                    reject(.device, "The selected target device is not authorized by this profile. Register it and regenerate the profile.")
                }
            } else {
                reject(.device, target.platform == "watchOS"
                    ? "The companion Watch device has not been selected or authorized. An iPhone pairing record does not prove Watch device authorization."
                    : "Device authorization is unknown. Import the target device's pairing record before using a device-limited profile.", status: .ambiguous)
            }
        }
        if !profile.Platform.contains(where: { $0.caseInsensitiveCompare(target.platform) == .orderedSame }) {
            reject(.platform, "The profile does not support this component's platform (\(target.platform)).", status: .unsupported)
        }
        if let parent = target.parentBundleIdentifier, !target.bundleIdentifier.hasPrefix(parent + ".") {
            reject(.structure, "A nested application's or extension's Bundle Identifier must remain within its containing application's identifier namespace.")
        }
        if !ProfileEntitlementAuthorization.isSupportedByNativeEncoder(target.requiredEntitlements) {
            reject(.entitlement, "This entitlement value type is not supported by the native encoder. It has not been silently converted or removed.", status: .unsupported)
        }
        let entitlements = ProfileEntitlementAuthorization.planned(target.requiredEntitlements, profile: profile,
            bundleIdentifier: target.bundleIdentifier, isolateKeychainGroups: target.isolateKeychainGroups) ?? [:]
        if entitlements.isEmpty { reject(.entitlement, "Identity entitlements could not be constructed safely.") }
        let grants = profile.Entitlements?.mapValues(\.value) ?? [:]
        for key in ProfileEntitlementAuthorization.failures(requested: entitlements, grants: grants) {
            reject(.entitlement, "The profile does not authorize the required entitlement \(key) for \(target.bundleIdentifier). Import a profile with that capability; it will not be silently removed.")
        }
        let status: SigningValidationStatus = issues.isEmpty ? .valid : (hasInvalid ? .invalid : (hasUnsupported ? .unsupported : .ambiguous))
        return .init(target: target, status: status, candidate: candidate,
                     issues: issues, entitlements: entitlements)
    }
}

/// Evaluates the whole inventory and tries every valid main-app candidate. This
/// avoids a locally good main profile locking nested bundles to the wrong team.
/// A preference breaks ties only after mandatory checks and exact-ID ranking.
enum CompatibleIdentityResolver {
    static func resolve(targets: [BundleSigningTarget], candidates: [SigningProfileCandidate],
                        deviceUDID: String?, preferredIdentity: String? = nil,
                        preferences: [String: ComponentSigningPreference] = [:], now: Date = Date()) -> SigningResolution {
        guard let main = targets.first else { return .init(components: []) }
        struct RankingKey: Hashable { let path: String; let team: String? }
        var rankings: [RankingKey: [SigningComponentResolution]] = [:]
        func ranked(_ target: BundleSigningTarget, team: String?) -> [SigningComponentResolution] {
            let key = RankingKey(path: target.id, team: team)
            if let cached = rankings[key] { return cached }
            let preference = preferences[target.id]
            let eligible = candidates.filter { preference == nil || $0.preference == preference }
            let values: [SigningComponentResolution] = eligible.map { ProfileCompatibilityValidator.evaluate($0, for: target, deviceUDID: deviceUDID,
                                                                      requiredTeam: team, now: now) }
                .sorted { lhs, rhs in
                    if (lhs.status == .valid) != (rhs.status == .valid) { return lhs.status == .valid }
                    if lhs.issues.count != rhs.issues.count { return lhs.issues.count < rhs.issues.count }
                    guard let l = lhs.candidate, let r = rhs.candidate else { return lhs.id < rhs.id }
                    let lID = l.profile.Entitlements?["application-identifier"]?.value as? String ?? ""
                    let rID = r.profile.Entitlements?["application-identifier"]?.value as? String ?? ""
                    let le = ProfileApplicationIdentifierMatcher.match(applicationIdentifier: lID, bundleIdentifier: target.bundleIdentifier).outcome == .exact
                    let re = ProfileApplicationIdentifierMatcher.match(applicationIdentifier: rID, bundleIdentifier: target.bundleIdentifier).outcome == .exact
                    if le != re { return le }
                    if (l.identity.reference == preferredIdentity) != (r.identity.reference == preferredIdentity) {
                        return l.identity.reference == preferredIdentity
                    }
                    let lv = min(l.profile.ExpirationDate, l.identity.notAfter ?? .distantPast)
                    let rv = min(r.profile.ExpirationDate, r.identity.notAfter ?? .distantPast)
                    if lv != rv { return lv > rv }
                    return l.id < r.id
                }
            rankings[key] = values
            return values
        }
        func missing(_ target: BundleSigningTarget) -> SigningComponentResolution {
            .init(target: target, status: .invalid, candidate: nil,
                  issues: [.init(code: .noCandidate, detail: preferences[target.id] == nil
                    ? "No imported identity/profile can authorize \(target.bundleIdentifier). Import an Apple-issued profile for this identifier and its matching .p12 private key."
                    : "The selected component identity/profile is no longer available. Choose Automatic or import the selected Apple-issued profile and complete .p12; no alternative has been silently substituted.")], entitlements: [:])
        }
        let mains = ranked(main, team: nil)
        var best: [SigningComponentResolution]?
        for choice in mains where choice.status == .valid {
            let team = choice.candidate?.profile.TeamIdentifier.first
            let plan = [choice] + targets.dropFirst().map { ranked($0, team: team).first ?? missing($0) }
            if plan.allSatisfy({ $0.status == .valid }) { return .init(components: plan) }
            if best == nil || plan.filter({ $0.status == .valid }).count > (best?.filter({ $0.status == .valid }).count ?? 0) { best = plan }
        }
        return .init(components: best ?? targets.map { ranked($0, team: nil).first ?? missing($0) })
    }
}
