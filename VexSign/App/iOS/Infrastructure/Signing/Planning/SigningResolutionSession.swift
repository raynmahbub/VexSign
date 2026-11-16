import Foundation
import CoreFoundation
import CryptoKit
import NimbleExtensions

/// Run-scoped bridge from the existing credential store to the value-only
/// resolver. The existing native signer consumes protected copies of exactly
/// the bytes that passed authentication and private-key proof.
enum SigningResolutionSession {
    private struct ProfileMaterial {
        let profile: Certificate
        let data: Data
        let digest: String
        let certificateFingerprints: Set<String>
    }
    private struct Material {
        let input: SigningIdentityStore.Input
        let profileData: Data
        let p12Data: Data
    }
    private struct Resolved {
        let resolution: SigningResolution
        let materials: [String: Material]
        let notices: [String]
        let removals: [String]
        var choices: [String: [SigningComponentChoice]] = [:]
        var preferences: [String: ComponentSigningPreference] = [:]
        var deviceBinding: String = ""
        var sourceFingerprint: String = ""

        func review() throws -> SigningResolutionReview {
            let components = resolution.components.map { component in
                let candidate = component.candidate
                let device: String
                if component.issues.contains(where: { $0.code == .device }) { device = "Device authorization not established" }
                else if candidate?.profile.ProvisionsAllDevices == true { device = "In-House profile authorizes all devices; device trust is checked separately at installation" }
                else { device = "Target is in the authenticated device list; connectivity and trust are not implied" }
                return SigningComponentReview(id: component.id, bundleIdentifier: component.target.bundleIdentifier,
                    status: component.status, certificateName: candidate?.identity.displayName,
                    identityReference: candidate?.identity.reference, profileName: candidate?.profile.Name,
                    profileUUID: candidate?.profile.UUID, profileExpiration: candidate?.profile.ExpirationDate,
                    certificateExpiration: candidate?.identity.notAfter, team: candidate?.profile.TeamIdentifier.first,
                    deviceAuthorization: device, entitlementKeys: component.entitlements.keys.sorted(),
                    issues: component.issues.map(\.detail), choices: choices[component.id] ?? [],
                    selectedChoice: preferences[component.id]?.id)
            }
            let authorization: SigningResolutionAuthorization?
            if resolution.isReady {
                var bindings: [[String: Any]] = []
                var componentBindings: [[String: Any]] = []
                var identityBindings: [[String: Any]] = []
                var profileBindings: [[String: Any]] = []
                var capabilityBindings: [[String: Any]] = []
                for component in resolution.components {
                    guard let candidate = component.candidate else { throw CocoaError(.fileReadCorruptFile) }
                    let path = component.id
                    let identifier = component.target.bundleIdentifier
                    let material = materials[candidate.id]
                    let p12Digest = material.map { SigningIdentity.fingerprint(of: $0.p12Data) } ?? "missing"
                    let profileDigest = material.map { SigningIdentity.fingerprint(of: $0.profileData) } ?? "missing"
                    let identity: [String: Any] = ["path": path, "reference": candidate.identity.reference,
                        "certificate": candidate.identity.fingerprint, "p12": p12Digest]
                    let profile: [String: Any] = ["path": path, "digest": profileDigest]
                    let componentPlan: [String: Any] = ["path": path, "identifier": identifier]
                    let entitlementValue = try canonicalValue(component.entitlements)
                    let capabilities: [String: Any] = ["path": path, "entitlements": entitlementValue]
                    identityBindings.append(identity)
                    profileBindings.append(profile)
                    componentBindings.append(componentPlan)
                    capabilityBindings.append(capabilities)
                    bindings.append(["path": path, "identifier": identifier,
                        "candidate": candidate.id, "certificate": candidate.identity.fingerprint,
                        "p12": p12Digest, "entitlements": entitlementValue])
                }
                func digest(_ value: Any) throws -> String {
                    SigningIdentity.fingerprint(of: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
                }
                let bytes = try JSONSerialization.data(withJSONObject: ["components": bindings, "removals": removals.sorted(), "device": deviceBinding, "source": sourceFingerprint], options: [.sortedKeys])
                authorization = .init(fingerprint: SigningIdentity.fingerprint(of: bytes), plannedRemovals: removals.sorted(),
                    sourceFingerprint: sourceFingerprint, componentFingerprint: try digest(componentBindings),
                    identityFingerprint: try digest(identityBindings), profileFingerprint: try digest(profileBindings),
                    requiredCapabilitiesFingerprint: try digest(capabilityBindings), deviceFingerprint: deviceBinding)
            } else { authorization = nil }
            return SigningResolutionReview(components: components, inventoryNotices: notices,
                plannedRemovals: removals.sorted(), authorization: authorization)
        }
    }

    static func review(bundle: URL, options: Options, inventory: [SigningIdentityStore.Input],
                       preferredIdentity: String?, deviceUDID: String?) throws -> SigningResolutionReview {
        let source = try sourceFingerprint(in: bundle)
        return try resolve(bundle: bundle, options: options, inventory: inventory, preferredIdentity: preferredIdentity,
            deviceUDID: deviceUDID, preview: true, originalRequirements: nil, sourceFingerprint: source).review()
    }

    struct Prepared {
        let request: SigningEngineRequest
        let review: SigningResolutionReview
        let workspace: URL
        let assets: [String: SignatureVerifier.AssetExpectation]
        let validUntil: Date
    }

    /// Inside exclusive engine ownership: re-read the current inventory and
    /// authenticate/prove it again, then bind consent before editing or signing.
    static func prepare(bundle: URL, options: Options, inventory: [SigningIdentityStore.Input],
                        preferredIdentity: String?, deviceUDID: String?,
                        authorization: SigningResolutionAuthorization?,
                        originalRequirements: [String: [String: Any]]?, originalSourceFingerprint: String? = nil) throws -> Prepared {
        let source = try originalSourceFingerprint ?? sourceFingerprint(in: bundle)
        var resolved = try resolve(bundle: bundle, options: options, inventory: inventory,
            preferredIdentity: preferredIdentity, deviceUDID: deviceUDID, preview: false,
            originalRequirements: originalRequirements, sourceFingerprint: source)
        let reviewed = try resolved.review()
        guard reviewed.isReady else { throw refusal(reviewed) }
        if let authorization {
            if authorization != reviewed.authorization {
                throw changedSinceReview(from: authorization, to: reviewed.authorization)
            }
        } else if !resolved.removals.isEmpty {
            throw SigningFileHandlerError.identityRejected("Review and explicitly confirm the exact optional extensions to remove. Saved compatibility settings alone cannot authorize a new removal list.")
        }
        let removed = resolved.removals
        for path in removed {
            guard try OptionalExtensionPolicy.canRemove(path, in: bundle) else { throw changedSinceReview(.optionalRemovals) }
            try FileManager.default.removeItem(at: bundle.appendingPathComponent(path))
        }
        if !removed.isEmpty {
            resolved = try resolve(bundle: bundle, options: options, inventory: inventory,
                preferredIdentity: preferredIdentity, deviceUDID: deviceUDID, preview: false,
                originalRequirements: originalRequirements.map { $0.filter { !removed.contains($0.key) } }, sourceFingerprint: source)
            guard resolved.resolution.isReady, resolved.removals.isEmpty else { throw refusal(try resolved.review()) }
            resolved = Resolved(resolution: resolved.resolution, materials: resolved.materials,
                notices: resolved.notices, removals: removed, choices: resolved.choices,
                preferences: resolved.preferences, deviceBinding: resolved.deviceBinding, sourceFingerprint: source)
            let postRemovalAuthorization = try resolved.review().authorization
            guard postRemovalAuthorization == reviewed.authorization else {
                throw changedSinceReview(from: reviewed.authorization, to: postRemovalAuthorization)
            }
        }
        try BundleExecutableAudit.requireSignable(bundle)
        let workspace = bundle.deletingLastPathComponent().appendingPathComponent("SigningInputs-" + UUID().uuidString)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: workspace, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var request = SigningEngineRequest(appPath: bundle.path)
            request.removeProvisioning = false
            var identityFiles: [String: String] = [:], profileFiles: [String: String] = [:]
            var assets: [String: SignatureVerifier.AssetExpectation] = [:]
            var validUntil = Date.distantFuture
            for (index, component) in resolved.resolution.components.enumerated() {
                try Task.checkCancellation()
                guard let candidate = component.candidate, let material = resolved.materials[candidate.id],
                      let password = material.input.password, let expires = candidate.identity.notAfter else { throw refusal(reviewed) }
                validUntil = min(validUntil, min(expires, candidate.profile.ExpirationDate))
                let p12: String
                if let existing = identityFiles[candidate.identity.reference] { p12 = existing }
                else {
                    let url = workspace.appendingPathComponent(UUID().uuidString + ".p12")
                    try material.p12Data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    p12 = url.path; identityFiles[candidate.identity.reference] = p12
                }
                let profile: String
                if let existing = profileFiles[candidate.id] { profile = existing }
                else {
                    let url = workspace.appendingPathComponent(UUID().uuidString + ".mobileprovision")
                    try material.profileData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    profile = url.path; profileFiles[candidate.id] = profile
                }
                let entitlements = workspace.appendingPathComponent(String(index) + ".plist")
                try EntitlementBuilder.write(component.entitlements, to: entitlements)
                if index == 0 {
                    request.provisionPath = profile; request.p12Path = p12
                    request.p12Password = password; request.entitlementsPath = entitlements.path
                } else {
                    request.nestedProvisionPaths[component.target.bundleIdentifier] = profile
                    request.nestedAssets[component.target.bundleIdentifier] = .init(provisionPath: profile,
                        p12Path: p12, password: password, entitlementsPath: entitlements.path)
                }
                assets[component.id] = .init(bundleIdentifier: component.target.bundleIdentifier,
                    certificateFingerprint: candidate.identity.fingerprint, teamIdentifier: candidate.profile.TeamIdentifier[0],
                    profileDigest: SigningIdentity.fingerprint(of: material.profileData), entitlements: component.entitlements,
                    platform: component.target.platform, deviceUDID: deviceUDID)
            }
            guard validUntil > Date() else { throw ProvisioningProfileParser.Failure.expired }
            return Prepared(request: request, review: try resolved.review(), workspace: workspace, assets: assets, validUntil: validUntil)
        } catch {
            do { try manager.removeItem(at: workspace) } catch { /* The enclosing work-directory cleanup retains ownership. */ }
            throw error
        }
    }

    static func changedSinceReview() -> Error { changedSinceReview(.other) }

    static func changedSinceReview(from reviewed: SigningResolutionAuthorization?,
                                   to current: SigningResolutionAuthorization?) -> Error {
        changedSinceReview(reviewed?.mismatch(against: current) ?? .authorizationMissing)
    }

    static func changedSinceReview(_ mismatch: SigningAuthorizationMismatch) -> Error {
        let detail: String
        switch mismatch {
        case .sourceBundle:
            detail = .localized("The app bundle contents changed after review. Review the current IPA and approve again; no alternate identity or removal has been substituted.")
        case .optionalRemovals:
            detail = .localized("The optional-extension removal plan changed or is no longer safe after review. Review and confirm the exact current list; nothing has been silently removed.")
        case .componentPlan:
            detail = .localized("The app's components or Bundle Identifiers changed after review. Review the current app before signing; no identity or removal has been substituted.")
        case .signingIdentity:
            detail = .localized("The signing certificate or private-key identity changed after review. Review the current identity before signing; no alternate identity has been substituted.")
        case .provisioningProfile:
            detail = .localized("The provisioning profile changed after review. Review its App ID, team, device authorization, and capabilities before signing.")
        case .requiredCapabilities:
            detail = .localized("Required capabilities or entitlement values changed after review. Review the current component requirements and profile grants; no capability has been silently removed.")
        case .targetDevice:
            detail = .localized("The target device or pairing record changed after review. Re-select the device and review signing inputs again; no alternate identity has been substituted.")
        case .authorizationMissing:
            detail = .localized("A complete signing review could not be matched to the current inputs. Review the current app and signing setup again.")
        case .other:
            detail = .localized("The component, identity, profile, or required capabilities changed after review. Review the current inputs again; no alternate identity or removal has been silently substituted.")
        }
        return SigningFileHandlerError.identityRejected(detail)
    }

    static func refusal(_ review: SigningResolutionReview) -> Error {
        let details = review.components.filter { $0.status != .valid }.map {
            $0.bundleIdentifier + ": " + $0.issues.joined(separator: " ")
        }
        return SigningFileHandlerError.identityRejected((details + review.inventoryNotices).joined(separator: "\n"))
    }

    private static func resolve(bundle: URL, options: Options, inventory: [SigningIdentityStore.Input],
                                preferredIdentity: String?, deviceUDID: String?, preview: Bool,
                                originalRequirements: [String: [String: Any]]?, sourceFingerprint: String) throws -> Resolved {
        try Task.checkCancellation()
        let now = Date()
        var profiles: [String: ProfileMaterial] = [:]
        var identities: [(SigningIdentityStore.Input, Data, SigningIdentityStore.Proof)] = []
        var notices: [String] = []
        let urls = Set(inventory.flatMap(\.profileURLs))
        guard inventory.count <= 512, urls.count <= 512 else { throw SigningIdentityStore.InspectionFailure.inventoryLimit }
        // Profiles are an inventory, not private property of the row beside
        // which they were imported. Every profile is considered with every key.
        for url in urls.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            do {
                let data = try CertificateInputReader.read(url)
                let digest = SigningIdentity.fingerprint(of: data)
                if profiles[digest] != nil { continue }
                let profile = try ProvisioningProfileParser.parse(data, now: now)
                profiles[digest] = .init(profile: profile, data: data, digest: digest,
                    certificateFingerprints: Set((profile.DeveloperCertificates ?? []).map { SigningIdentity.fingerprint(of: $0) }))
            } catch { notices.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        for input in inventory {
            try Task.checkCancellation()
            if let notice = input.notice { notices.append(input.name + ": " + notice) }
            if input.revoked { notices.append(input.name + ": the stored certificate status is revoked or expired."); continue }
            guard options.automaticallyResolveSigningIdentity != false || input.reference == preferredIdentity else { continue }
            do {
                guard let url = input.p12URL else { throw SigningIdentityStore.InspectionFailure.certificateMissing }
                let p12 = try CertificateInputReader.read(url)
                identities.append((input, p12, try SigningIdentityStore.inspect(p12, password: input.password)))
            } catch { notices.append(input.name + ": " + error.localizedDescription) }
        }
        var candidates: [SigningProfileCandidate] = [], materials: [String: Material] = [:]
        // The membership index evaluates every combination without repeatedly
        // reparsing CMS or doing an O(profiles × identities × DER) key lookup.
        for profile in profiles.values.sorted(by: { $0.digest < $1.digest }) {
            for (input, p12, proof) in identities {
                let id = input.reference + ":" + proof.identity.fingerprint + ":" + profile.digest
                let identity = SigningIdentityCandidate(reference: input.reference, fingerprint: proof.identity.fingerprint,
                    teamIdentifier: proof.identity.teamIdentifier, displayName: proof.identity.commonName ?? input.name,
                    notBefore: proof.identity.notBefore, notAfter: proof.identity.notAfter, keyAvailability: proof.keyAvailability,
                    nativeSigningSupported: proof.nativeSigningSupported)
                candidates.append(.init(id: id, identity: identity, profile: profile.profile, isAuthenticated: true,
                    authorizedCertificateFingerprints: profile.certificateFingerprints))
                materials[id] = Material(input: input, profileData: profile.data, p12Data: p12)
                guard candidates.count <= 4096 else { throw SigningIdentityStore.InspectionFailure.inventoryLimit }
            }
        }
        let targets = try targets(in: bundle, options: options, preview: preview, originalRequirements: originalRequirements)
        guard Set(targets.map(\.bundleIdentifier)).count == targets.count else {
            throw SigningFileHandlerError.identityRejected("Two executable components declare the same Bundle Identifier. Import a complete, unambiguous IPA; assets cannot be safely assigned by identifier.")
        }
        var resolution = CompatibleIdentityResolver.resolve(targets: targets, candidates: candidates,
            deviceUDID: deviceUDID, preferredIdentity: preferredIdentity,
            preferences: options.componentSigningPreferences ?? [:], now: now)
        var removals: [String] = []
        for component in resolution.components.dropFirst() {
            let explicitlyRequested = options.removeAppExtensions && component.id.lowercased().hasSuffix(".appex")
            let compatibilityOnly = component.status != .valid && !component.issues.isEmpty
                && component.issues.allSatisfy { [.identifier, .entitlement].contains($0.code) }
            if explicitlyRequested || options.autoRemoveUnsupportedExtensions && compatibilityOnly {
                guard try OptionalExtensionPolicy.canRemove(component.id, in: bundle) else {
                    if explicitlyRequested { throw SigningFileHandlerError.identityRejected("This extension cannot be safely removed: " + component.id) }
                    continue
                }
                removals.append(component.id)
            }
        }
        if !removals.isEmpty {
            resolution = CompatibleIdentityResolver.resolve(targets: targets.filter { !removals.contains($0.id) },
                candidates: candidates, deviceUDID: deviceUDID, preferredIdentity: preferredIdentity,
                preferences: options.componentSigningPreferences ?? [:], now: now)
        }
        if options.removeProvisioning {
            resolution = .init(components: resolution.components.map { component in
                .init(target: component.target, status: .invalid, candidate: component.candidate,
                    issues: component.issues + [.init(code: .mode, detail: "Disable Remove Provisioning Profile for device signing. Every retained application/extension must embed its authorized profile.")], entitlements: component.entitlements)
            })
        }
        var choices: [String: [SigningComponentChoice]] = [:]
        let mainTeam = resolution.components.first?.candidate?.profile.TeamIdentifier.first
        for component in resolution.components {
            var used = Set<String>()
            choices[component.id] = candidates.compactMap { candidate in
                let value = ProfileCompatibilityValidator.evaluate(candidate, for: component.target,
                    deviceUDID: deviceUDID, requiredTeam: component.id == "." ? nil : mainTeam, now: now)
                guard value.status == .valid, used.insert(candidate.preference.id).inserted else { return nil }
                return SigningComponentChoice(preference: candidate.preference,
                    certificateName: candidate.identity.displayName ?? "Imported identity", profileName: candidate.profile.Name,
                    expiration: min(candidate.profile.ExpirationDate, candidate.identity.notAfter ?? .distantPast))
            }.sorted { $0.id < $1.id }
        }
        let deviceBinding = SigningIdentity.fingerprint(of: Data((deviceUDID ?? "no-target-device-evidence").utf8))
        return Resolved(resolution: resolution, materials: materials, notices: Array(Set(notices)).sorted(),
            removals: removals.sorted(), choices: choices, preferences: options.componentSigningPreferences ?? [:], deviceBinding: deviceBinding, sourceFingerprint: sourceFingerprint)
    }

    /// Consent covers the complete original tree, not only plist identifiers.
    /// Stream regular file bytes with bounded enumeration and unambiguous path /
    /// length framing. A copied tree must match before any customization starts.
    static func sourceFingerprint(in bundle: URL, maximumEntries: Int = 50_000,
                                  maximumBytes: UInt64 = 8 * 1024 * 1024 * 1024) throws -> String {
        let root = bundle.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw changedSinceReview(.sourceBundle) }
        var walkError: Error?, paths: [URL] = [], seen = Set<String>()
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, error in walkError = error; return false }) else { throw changedSinceReview(.sourceBundle) }
        for case let url as URL in walker {
            try Task.checkCancellation()
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard paths.count < maximumEntries, url.path.hasPrefix(root.path + "/"),
                  relative.split(separator: "/").count <= 32, relative.utf8.count <= 4096,
                  seen.insert(relative.lowercased()).inserted else { throw changedSinceReview(.sourceBundle) }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw changedSinceReview(.sourceBundle) }
            paths.append(url)
        }
        if let walkError { throw walkError }
        var digest = SHA256(), remaining = maximumBytes
        func count(_ number: UInt64) { var big = number.bigEndian; withUnsafeBytes(of: &big) { digest.update(data: Data($0)) } }
        for url in paths.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let path = Data(String(url.path.dropFirst(root.path.count + 1)).utf8)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw changedSinceReview(.sourceBundle) }
            count(UInt64(path.count)); digest.update(data: path)
            if values.isDirectory == true { digest.update(data: Data([0x44])); continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
                  UInt64(size) <= remaining else { throw changedSinceReview(.sourceBundle) }
            digest.update(data: Data([0x46])); count(UInt64(size))
            remaining -= UInt64(size)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() } // try? ok: read/hash errors throw; close is cleanup only.
            var read: UInt64 = 0
            while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
                try Task.checkCancellation()
                read += UInt64(block.count)
                guard read <= UInt64(size) else { throw changedSinceReview(.sourceBundle) }
                digest.update(data: block)
            }
            guard read == UInt64(size) else { throw changedSinceReview(.sourceBundle) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Capture before any binary surgery. A transform cannot turn unreadable or
    /// removed original entitlements into an empty set and silently drop a capability.
    static func requirements(in bundle: URL, options: Options) throws -> [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: try targets(in: bundle, options: options, preview: true, originalRequirements: nil).map {
            ($0.id, $0.requiredEntitlements)
        })
    }

    private static func targets(in bundle: URL, options: Options, preview: Bool,
                                originalRequirements: [String: [String: Any]]?) throws -> [BundleSigningTarget] {
        let plan = SigningPlan.make(appBundle: bundle)
        let problems = plan.validationIssues().filter { $0.severity == .blocking }
        guard problems.isEmpty else { throw SigningFileHandlerError.identityRejected(problems.map(\.detail).joined(separator: "\n")) }
        guard plan.components.count <= 256 else { throw SigningIdentityStore.InspectionFailure.inventoryLimit }
        let mainInfo = try info(bundle)
        guard let originalIdentifier = mainInfo["CFBundleIdentifier"] as? String else { throw SigningFileHandlerError.infoPlistNotFound }
        let mainIdentifier = preview
            ? MergedInfoPlist(original: mainInfo, options: options).effective["CFBundleIdentifier"] as? String : originalIdentifier
        guard let mainIdentifier else { throw SigningFileHandlerError.infoPlistNotFound }
        let all = [(".", bundle)] + plan.profileBoundComponents.map { ($0.path, bundle.appendingPathComponent($0.path)) }
        if let originalRequirements, Set(originalRequirements.keys) != Set(all.map { $0.0 }) {
            throw SigningFileHandlerError.identityRejected("A required application or extension disappeared during customization. Use the reviewed optional-removal policy; arbitrary file removal cannot silently strip a component.")
        }
        var identifiers: [String: String] = [:]
        for (path, url) in all {
            guard let value = try info(url)["CFBundleIdentifier"] as? String else { throw SigningFileHandlerError.infoPlistNotFound }
            identifiers[path] = path == "." ? mainIdentifier : (preview
                ? NestedBundleAudit.rewrittenIdentifier(value, from: originalIdentifier, to: options.effectiveAppIdentifier) : value)
        }
        var targets: [BundleSigningTarget] = []
        for (path, url) in all {
            let plist = try info(url)
            guard let identifier = plist["CFBundleIdentifier"] as? String,
                  let executable = SigningInputValidation.executable(in: url) else { throw SigningFileHandlerError.appNotFound }
            var requested = try (originalRequirements?[path] ?? MachOEntitlements.requiredEntitlements(forExecutableAt: executable))
            if path == ".", let file = options.appEntitlementsFile {
                let custom = try CertificateInputReader.read(file)
                guard let values = try PropertyListSerialization.propertyList(from: custom, options: [], format: nil) as? [String: Any],
                      ProfileEntitlementAuthorization.isBoundedPropertyList(values) else { throw SigningFileHandlerError.entitlementsUnreadable }
                for (key, value) in values {
                    if let original = requested[key], !["application-identifier", "com.apple.application-identifier", "com.apple.developer.team-identifier"].contains(key),
                       !ProfileEntitlementAuthorization.allows(original, granted: value, key: key) {
                        throw SigningFileHandlerError.identityRejected("The custom entitlements would remove or reduce the required capability " + key + ". Required capabilities are not silently stripped.")
                    }
                    requested[key] = value
                }
            }
            if path == ".", options.enableJIT { for key in EntitlementBuilder.jitEntitlementKeys { requested[key] = true } }
            let finalIdentifier = path == "." ? mainIdentifier : (preview
                ? NestedBundleAudit.rewrittenIdentifier(identifier, from: originalIdentifier, to: options.effectiveAppIdentifier) : identifier)
            let platforms = plist["CFBundleSupportedPlatforms"] as? [String] ?? []
            let platform = platforms.contains("WatchOS") || path.split(separator: "/").contains("Watch") ? "watchOS" : "iOS"
            let parent = path == "." ? nil : all.map { $0.0 }.filter {
                $0 == "." || (path != $0 && path.hasPrefix($0 + "/"))
            }.max(by: { $0.count < $1.count })
            targets.append(.init(relativePath: path, bundleIdentifier: finalIdentifier, platform: platform,
                requiredEntitlements: requested, isolateKeychainGroups: path == "." && options.keychainIsolation,
                parentBundleIdentifier: parent.flatMap { identifiers[$0] }))
        }
        for component in plan.components where !component.kind.requiresProfile && !component.isResourceOnly {
            let url = bundle.appendingPathComponent(component.path)
            guard let executable = component.kind == .dylib ? url : SigningInputValidation.executable(in: url) else { throw SigningFileHandlerError.appNotFound }
            guard try MachOEntitlements.requiredEntitlements(forExecutableAt: executable).isEmpty else {
                throw SigningFileHandlerError.identityRejected(component.path + " requests library/bundle entitlements that the existing engine would remove. This component shape is unsupported; no capability has been silently stripped.")
            }
        }
        return targets
    }

    private static func info(_ url: URL) throws -> [String: Any] {
        let bytes = try CertificateInputReader.read(url.appendingPathComponent("Info.plist"))
        guard let values = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else { throw SigningFileHandlerError.infoPlistNotFound }
        return values
    }

    /// Typed canonical form: NSNumber(1) must not hash like CFBoolean(true).
    private static func canonicalValue(_ value: Any) throws -> Any {
        if let dictionary = value as? [String: Any] { return try dictionary.mapValues { try canonicalValue($0) } }
        if let array = value as? [Any] { return try array.map { try canonicalValue($0) } }
        if let string = value as? String { return ["string": string] }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return ["boolean": number.boolValue] }
            return ["number": number.stringValue, "encoding": String(cString: number.objCType)]
        }
        throw SigningFileHandlerError.entitlementsUnreadable
    }
}
