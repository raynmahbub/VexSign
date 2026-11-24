import Foundation
import IDeviceSwift
import NimbleExtensions

/// Installation admission reuses the existing component manifest, authenticated
/// profile parser, entitlement authorizer and cryptographic output verifier. It
/// never re-signs, exports a key, contacts an account or excuses a failed seal.
enum PairedInstallationValidation {
    struct Metadata: Sendable {
        let identifier: String
        let version: String
        let build: String
        let authorizationExpiresAt: Date
        let verifiedDeviceOS: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func verify(bundleAt root: URL, expectedIdentifier: String?, expectedVersion: String?,
                       device: AuthorizedDeviceSnapshot) throws -> Metadata {
        try Task.checkCancellation()
        guard let info = SignatureVerifier.readInfo(at: root),
              let identifier = info["CFBundleIdentifier"] as? String, identifier == expectedIdentifier,
              DeviceApplicationInventory.isBundleIdentifier(identifier),
              let version = info["CFBundleShortVersionString"] as? String, version == expectedVersion,
              let build = info["CFBundleVersion"] as? String,
              DeviceApplicationInventory.isVersion(version), DeviceApplicationInventory.isVersion(build),
              let executable = SigningInputValidation.executable(in: root),
              let deviceOS = ExecutablePreflight.packedVersion(device.productVersion) else {
            throw Failure(.localized("Paired installation needs the exact bundle identifier, version and build from a complete device app. Sign a complete copy first."))
        }
        try verifyExecutableCompatibility(executable, deviceOS: deviceOS)
        let plan = SigningPlan.make(appBundle: root)
        guard !plan.validationIssues().contains(where: { $0.severity == .blocking }) else {
            throw Failure(.localized("The app's nested-code manifest is incomplete. No package was submitted."))
        }
        for component in plan.components where !component.isResourceOnly {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(component.path)
            guard let executable = component.kind == .dylib ? url : SigningInputValidation.executable(in: url) else {
                throw Failure(.localized("A nested component's executable is missing. No package was submitted."))
            }
            try verifyExecutableCompatibility(executable, deviceOS: deviceOS)
        }
        var assets: [String: SignatureVerifier.AssetExpectation] = [:]
        var earliestExpiry = Date.distantFuture
        for path in ["."] + plan.profileBoundComponents.map(\.path) {
            try Task.checkCancellation()
            let bundle = path == "." ? root : root.appendingPathComponent(path)
            let profileData = try CertificateInputReader.read(bundle.appendingPathComponent("embedded.mobileprovision"))
            let profile = try ProvisioningProfileParser.parse(profileData)
            guard let componentID = SignatureVerifier.readInfo(at: bundle)?["CFBundleIdentifier"] as? String,
                  let signer = BundleSignature.read(bundleAt: bundle).signer,
                  let signerExpiry = signer.notAfter, signerExpiry.timeIntervalSince1970.isFinite,
                  let team = profile.TeamIdentifier.first, signer.teamIdentifier == team,
                  let authorizedCertificates = profile.DeveloperCertificates,
                  authorizedCertificates.contains(where: { SigningIdentity.fingerprint(of: $0) == signer.fingerprint }),
                  let componentExecutable = SigningInputValidation.executable(in: bundle) else {
                throw Failure(.localized("A component's signer is not authorized by its authenticated embedded profile. Sign the app with compatible assets first."))
            }
            let bytes = try Data(contentsOf: componentExecutable, options: .mappedIfSafe)
            let entitlements = try MachOEntitlements.requiredEntitlements(in: bytes)
            assets[path] = .init(bundleIdentifier: componentID, certificateFingerprint: signer.fingerprint,
                teamIdentifier: team, profileDigest: SigningIdentity.fingerprint(of: profileData),
                entitlements: entitlements, deviceUDID: device.deviceIdentifier)
            earliestExpiry = min(earliestExpiry, min(profile.ExpirationDate, signerExpiry))
        }
        // Expected signers were authorized by authenticated profiles above. The
        // existing verifier now verifies actual CMS/page/resource/DER/entitlement
        // bytes for every component and the selected device's profile coverage.
        var expectation = SignatureVerifier.Expectation.freshlySigned
        expectation.declaredBundleIdentifier = identifier
        expectation.assets = assets
        try SignatureVerifier.verify(bundleAt: root, expectation: expectation).requireVerified()
        try Task.checkCancellation()
        return Metadata(identifier: identifier, version: version, build: build,
            authorizationExpiresAt: earliestExpiry, verifiedDeviceOS: device.productVersion)
    }

    private static func verifyExecutableCompatibility(_ url: URL, deviceOS: UInt32) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 2 * 1024 * 1024 * 1024 else {
            throw Failure(.localized("An executable is not a bounded regular file. No package was submitted."))
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let images = ExecutablePreflight.inspectSlices(bytes), !images.isEmpty,
              images.allSatisfy({ image in
                  image.isArm64 && image.platform == 2 && !image.encrypted
                      && image.minimumOS.map { $0 <= deviceOS } == true
              }) else {
            throw Failure(.localized("A component is not a compatible, unencrypted arm64 iOS-device binary, or its minimum OS could not be established. Watch, simulator and other-platform components are not supported by this installation path."))
        }
    }
}
