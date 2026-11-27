//
//  ReleaseManifestTrustStore.swift
//  VexSign
//
//  `ReleaseManifestVerifier` checks an Ed25519 signature, but a signature is only
//  evidence when the public key is trusted independently of the payload. This store
//  is that independent input: a build-specific `ReleaseManifestKeys.plist` supplied
//  by the release owner, mapping key identifiers to base64-encoded 32-byte
//  Curve25519 public keys.
//
//  No development key is embedded in the repository. A build without the resource
//  reports `unprovisioned`; it never falls back to a key carried by the manifest or
//  by the same server that served the artifact.
//
//  Format:
//    <dict>
//      <key>release-2026</key>
//      <string>BASE64_OF_32_BYTE_ED25519_PUBLIC_KEY</string>
//    </dict>
//

import CryptoKit
import Foundation

struct ReleaseManifestTrustStore {
    static let resourceName = "ReleaseManifestKeys"

    enum Provisioning: Equatable, Sendable {
        case provisioned(keyIDs: [String])
        case unprovisioned
        case malformed
    }

    let verifier: ReleaseManifestVerifier
    let keyIDs: [String]

    /// Reads the pinned keys from the app bundle. `applicationIdentifier` defaults
    /// to this app's bundle identifier so a manifest for another app cannot be
    /// accepted even with a valid signature.
    static func load(
        bundle: Bundle = .main,
        applicationIdentifier: String? = nil
    ) -> ReleaseManifestTrustStore? {
        guard case .provisioned(let keyIDs) = inspect(bundle: bundle),
              let url = bundle.url(forResource: resourceName, withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url) as? [String: String],
              let identifier = applicationIdentifier ?? bundle.bundleIdentifier,
              !identifier.isEmpty
        else { return nil }

        let keys = plist.compactMapValues { raw -> Data? in
            guard let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  data.count == 32,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil // try? ok: invalid key bytes make the entry malformed
            else { return nil }
            return data
        }
        guard !keys.isEmpty else { return nil }
        return ReleaseManifestTrustStore(
            verifier: ReleaseManifestVerifier(
                trustedPublicKeys: keys,
                expectedApplicationIdentifier: identifier
            ),
            keyIDs: keyIDs.sorted()
        )
    }

    static func inspect(bundle: Bundle = .main) -> Provisioning {
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url) as? [String: String],
              !plist.isEmpty
        else { return .unprovisioned }

        let validIDs = plist.keys.filter { keyID in
            guard keyID.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil,
                  let data = Data(base64Encoded: plist[keyID] ?? "",
                                  options: .ignoreUnknownCharacters),
                  data.count == 32,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil // try? ok: invalid key bytes make the entry malformed
            else { return false }
            return true
        }
        return validIDs.isEmpty ? .malformed : .provisioned(keyIDs: validIDs.sorted())
    }

    func verify(
        envelopeData: Data,
        supportedOSVersion: String,
        now: Date = Date()
    ) throws -> ReleaseManifest {
        try verifier.verify(
            envelopeData: envelopeData,
            supportedOSVersion: supportedOSVersion,
            now: now
        )
    }
}
