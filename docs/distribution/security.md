# Distribution security and threat model

## Assets and trust boundaries

- **Private signing identity and P12 password:** remain on device/Keychain or protected release automation only. Never in Git, ordinary preferences, public metadata, logs, or release ZIPs.
- **IPA archives and imported profiles:** untrusted input. `ArchiveSafetyValidator`, existing archive inspection, certificate/profile validators and signature auditors must fail closed before signing or installation.
- **Release metadata:** attacker-controlled until the detached Ed25519 signature is checked against an embedded trusted key. GitHub transport and SHA256SUMS alone do not authenticate the publisher.
- **IPA payload:** bind it to the authenticated manifest with SHA-256, then independently inspect Apple's signature, bundle IDs, profile and entitlements.
- **iOS install prompt:** user/platform action. URL opening or a download is not proof the app installed.
- **GitHub Actions:** PR code is untrusted. Keep production signing/upload secrets in protected environments and never expose them to PR jobs.

## Implemented verification foundation

`VexSign/Distribution/Security/ReleaseManifestVerifier.swift` verifies a detached Ed25519 envelope before parsing the signed payload, then validates bundle ID, version/build syntax, HTTPS URLs, digest syntax, signing fingerprint syntax, date validity and minimum OS. `ArtifactHashVerifier` streams the file in bounded chunks, rejects non-regular/symlink URLs, and compares SHA-256. `tools/sign-release-manifest.mjs` uses Node's built-in crypto to sign the exact canonical JSON payload with a PKCS#8 Ed25519 key supplied through a protected environment secret; it hashes the IPA itself and atomically refuses manifest overwrite. `node --test tools/test-release-manifest.mjs` covers signing/validation behavior without a production key.

This is not production trust configuration: no release signing key or key-rotation policy is configured or embedded, and `.github/workflows/release.yml` does not call the signer. Existing workflow checksums and provenance are unsigned. Do not treat them as a secure OTA update source until key generation, restricted signing, public-key pinning, signed envelopes, rotation/revocation and cross-platform negative tests are finished.

For a future protected environment, generate a dedicated Ed25519 key outside the repository (for example, OpenSSL PKCS#8 PEM), store only the private PEM in the protected GitHub environment as `VEXSIGN_RELEASE_MANIFEST_PRIVATE_KEY`, and configure `VEXSIGN_RELEASE_MANIFEST_KEY_ID`. Convert and review its 32-byte public key for the app's pinned trust store. Keep the private key in offline backup/approved secret management; never commit it or include it in build artifacts. A manifest with `distributionMethod: artifactDownload` and `signingClass: unsigned` authenticates a download only—it grants no iOS installation capability.

## Required safeguards

- Use a bounded ZIP parser; reject traversal, duplicate/ambiguous paths, symlinks, decompression bombs, malformed Info.plists and unsupported archive layouts.
- Use TLS with default certificate validation. Never add trust-all delegates or arbitrary-load exceptions for release fetches.
- Validate URL scheme/host, redirect policy, status, response length, disk space, and hash before finalizing. Write to unique temporary files and atomically move only after complete validation.
- Expire signed metadata, reject future-dated/replayed manifests, enforce anti-downgrade channel/version/build rules, and maintain controlled signing-key rotation.
- Keep temporary signing content in protected app storage; clean only inactive task-owned directories. Never delete source inputs or prior known-good outputs on failure.
- Redact secrets and credentials from `UnifiedTaskCenter`, OSLog, server errors, task history and exported diagnostics.
- Avoid account credential collection, developer portal scraping, private APIs, arbitrary script execution and public access to signing service credentials.

## Threats / residual risks

A compromised release key can authorize malicious metadata; mitigate with offline/HSM custody, approvals, limited signing access, revocation/rotation and incident response. A compromised GitHub release can replace artifacts; signature+hash stops substitution only when the key remains protected. A valid manifest cannot make an incompatible or revoked Apple signature install. Device-level malware/OS compromise is outside this app's trust boundary. Certificate revocation may be delayed/unavailable; unknown is not valid. Background transfer and installation callbacks may not run after termination; persist state and recover as interrupted/unconfirmed, never fabricate success.
