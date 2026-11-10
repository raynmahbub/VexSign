import CryptoKit
import Foundation

/// Public verification keys are supplied by a pinned application trust store.
/// The production key must be provisioned before signed releases are accepted.
struct ReleaseManifestVerifier: Sendable {
    private let trustedPublicKeys: [String: Data]
    private let expectedApplicationIdentifier: String

    init(trustedPublicKeys: [String: Data], expectedApplicationIdentifier: String) {
        self.trustedPublicKeys = trustedPublicKeys
        self.expectedApplicationIdentifier = expectedApplicationIdentifier
    }

    func verify(
        envelopeData: Data,
        supportedOSVersion: String,
        now: Date = Date()
    ) throws -> ReleaseManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard envelopeData.count <= 196_608,
              let envelope = try? decoder.decode(SignedReleaseManifest.self, from: envelopeData)
        else { throw ReleaseManifestFailure.malformedEnvelope }
        guard envelope.schemaVersion == 1 else { throw ReleaseManifestFailure.unsupportedSchema }
        guard envelope.algorithm == "Ed25519" else { throw ReleaseManifestFailure.unsupportedSignatureAlgorithm }
        guard envelope.keyID.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
            throw ReleaseManifestFailure.malformedEnvelope
        }
        guard let keyData = trustedPublicKeys[envelope.keyID] else { throw ReleaseManifestFailure.unknownSigningKey }
        guard let payload = Data(base64Encoded: envelope.payloadBase64), payload.count <= 131_072,
              let signature = Data(base64Encoded: envelope.signatureBase64), signature.count == 64,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw ReleaseManifestFailure.malformedEnvelope }
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw ReleaseManifestFailure.invalidSignature
        }
        guard let manifest = try? decoder.decode(ReleaseManifest.self, from: payload) else {
            throw ReleaseManifestFailure.invalidPayload
        }
        try validate(manifest, supportedOSVersion: supportedOSVersion, now: now)
        return manifest
    }

    func validate(
        _ manifest: ReleaseManifest,
        supportedOSVersion: String,
        now: Date = Date()
    ) throws {
        guard manifest.schemaVersion == 1 else { throw ReleaseManifestFailure.unsupportedSchema }
        guard manifest.applicationIdentifier == expectedApplicationIdentifier,
              Self.isValidBundleIdentifier(manifest.applicationIdentifier)
        else { throw ReleaseManifestFailure.invalidApplicationIdentifier }
        guard Self.isSemanticVersion(manifest.version) else { throw ReleaseManifestFailure.invalidVersion }
        guard Self.isBuildNumber(manifest.buildNumber) else { throw ReleaseManifestFailure.invalidBuildNumber }
        guard Self.isSemanticVersion(manifest.minimumOSVersion),
              Self.isSemanticVersion(supportedOSVersion)
        else { throw ReleaseManifestFailure.invalidMinimumOSVersion }
        guard Self.isHTTPSURL(manifest.downloadURL),
              manifest.releaseNotesURL.map(Self.isHTTPSURL) ?? true
        else { throw ReleaseManifestFailure.invalidURL }
        guard Self.isSHA256(manifest.ipaSHA256) else { throw ReleaseManifestFailure.invalidSHA256 }
        if let fingerprint = manifest.signing.certificateSHA256, !Self.isSHA256(fingerprint) {
            throw ReleaseManifestFailure.invalidSigningFingerprint
        }
        if let teamIdentifier = manifest.signing.teamIdentifier,
           teamIdentifier.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) == nil {
            throw ReleaseManifestFailure.invalidTeamIdentifier
        }
        guard Self.signingClassMatchesMethod(manifest.signing) else {
            throw ReleaseManifestFailure.invalidSigningClass
        }
        let lifetime = manifest.expiresAt.timeIntervalSince(manifest.createdAt)
        guard lifetime > 0, lifetime <= 7_776_000 else { throw ReleaseManifestFailure.invalidDateRange }
        guard manifest.createdAt <= now.addingTimeInterval(300) else { throw ReleaseManifestFailure.futureDated }
        guard manifest.expiresAt > now else { throw ReleaseManifestFailure.expired }
        guard Self.compareVersions(manifest.minimumOSVersion, supportedOSVersion) != .orderedDescending else {
            throw ReleaseManifestFailure.unsupportedMinimumOS
        }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy(valid.contains)
        }
    }

    private static func signingClassMatchesMethod(_ signing: ReleaseSigningInformation) -> Bool {
        switch signing.distributionMethod {
        case .testFlight, .appStore: return signing.signingClass == .appStore
        case .adHoc: return signing.signingClass == .adHoc
        case .enterprise: return signing.signingClass == .enterprise
        case .personalTeam: return signing.signingClass == .personalTeam
        case .directOTA: return [.adHoc, .enterprise].contains(signing.signingClass)
        case .mobileDeviceManagement: return [.appStore, .adHoc, .enterprise].contains(signing.signingClass)
        case .artifactDownload: return signing.signingClass == .unsigned
        }
    }

    private static func isSemanticVersion(_ value: String) -> Bool {
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?"#
            + #"(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isBuildNumber(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[a-fA-F0-9]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
            && url.user == nil && url.password == nil
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ version: String) -> (core: [String], prerelease: [String]?) {
            let withoutBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = pieces[0].split(separator: ".").map(String.init)
            let prerelease = pieces.count == 2 ? pieces[1].split(separator: ".").map(String.init) : nil
            return (core, prerelease)
        }
        func compareNumeric(_ left: String, _ right: String) -> ComparisonResult {
            let l = String(left.drop(while: { $0 == "0" }))
            let r = String(right.drop(while: { $0 == "0" }))
            if l.count != r.count { return l.count < r.count ? .orderedAscending : .orderedDescending }
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
            return .orderedSame
        }
        let left = parts(lhs)
        let right = parts(rhs)
        for index in 0..<max(left.core.count, right.core.count) {
            let l = index < left.core.count ? left.core[index] : "0"
            let r = index < right.core.count ? right.core[index] : "0"
            let order = compareNumeric(l, r)
            if order != .orderedSame { return order }
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, .some): return .orderedDescending
        case (.some, nil): return .orderedAscending
        case let (.some(l), .some(r)):
            for index in 0..<max(l.count, r.count) {
                guard index < l.count else { return .orderedAscending }
                guard index < r.count else { return .orderedDescending }
                let leftPart = l[index]
                let rightPart = r[index]
                let leftNumeric = leftPart.allSatisfy(\.isNumber)
                let rightNumeric = rightPart.allSatisfy(\.isNumber)
                if leftNumeric && rightNumeric {
                    let order = compareNumeric(leftPart, rightPart)
                    if order != .orderedSame { return order }
                } else if leftNumeric != rightNumeric {
                    return leftNumeric ? .orderedAscending : .orderedDescending
                } else if leftPart != rightPart {
                    return leftPart < rightPart ? .orderedAscending : .orderedDescending
                }
            }
            return .orderedSame
        }
    }
}

/// Computes artifact digests without loading the IPA into memory. The URL must
/// resolve to a regular file; symlinks are rejected to avoid hashing a swapped target.
enum ArtifactHashVerifier {
    enum Failure: Error, Equatable {
        case notRegularFile
        case hashMismatch(expected: String, actual: String)
    }

    static func sha256(fileURL: URL, chunkSize: Int = 1_048_576) throws -> String {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.notRegularFile }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let boundedChunkSize = min(max(chunkSize, 1), 4_194_304)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: boundedChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(fileURL: URL, expectedSHA256: String) throws -> String {
        let actual = try sha256(fileURL: fileURL)
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw Failure.hashMismatch(expected: expectedSHA256, actual: actual)
        }
        return actual
    }
}
