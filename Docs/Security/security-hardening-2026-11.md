# Security hardening and application integrity work — 2026-11-26

This is an implementation note, not a compliance certificate. It records what was
audited, what was changed, what evidence exists, and what was **not** verified.
No Git commit, push, merge, rebase, reset, force-push or release was performed;
all edits remain on the working branch.

## 1. Repository state at the start of the audit

- Branch: `arena/d2c05cf4-vexsign` (the user requested `feature/security-hardening`;
  branch creation is a manual Git operation and was not performed).
- HEAD: `2fad3a996bd8642779f7fede484be8c94ec54037` (unchanged).
- Worktree: 121 dirty entries from earlier, already-reviewed work; no security
  production edits had been made in this task before the audit.
- Recent history: the only commit shown by `git log --oneline -5` was
  `2fad3a9 fix(services): harden job recovery, cleanup, and repository layout`.
- No dependency, submodule, lockfile or Git remote configuration was changed.

## 2. Audit scope and exact local sources inspected

Certificates, secrets and persistence:

- `VexSign/Storage/Keychain/SecureSecretStore.swift` — Keychain generic passwords,
  `AfterFirstUnlockThisDeviceOnly`, read-through defaults migration.
- `VexSign/Storage/Keychain/CertificateSecrets.swift` and
  `VexSign/Security/Credentials/CertificatePasswordMigration.swift` — secure write
  before clearing a legacy plaintext column.
- `VexSign/Services/Identity/IdentityVault.swift` — Keychain/file/defaults tiers;
  the device UUID and premium flags are deliberately mirrored, and credential
  keys are Keychain-only. This is a documented compatibility trade-off, not a new
  change in this task.
- `VexSign/Security/Certificates/ProtectedCertificateFiles.swift`,
  `VexSign/Services/Identity/CertificateInspector.swift`,
  `VexSign/Services/Identity/CertificateManagementService.swift`,
  `VexSign/Services/CertificateVault/VaultKeychain.swift`.

Cryptography and integrity:

- `VexSign/Security/Cryptography/BackupCrypto.swift` — AES-GCM envelopes and the
  VEXBK3 stream, random salt/nonce, 200k PBKDF2-HMAC-SHA256 iterations through
  Apple `CommonCrypto`, per-record GCM tags, AAD binding, terminal record.
- `VexSign/Security/Cryptography/FileIntegrity.swift` and
  `VexSign/Security/Policies/ReleaseManifestVerifier.swift` — streaming SHA-256
  and Ed25519 release-manifest verification.
- `VexSign/Security/CodeSigning/SignatureVerifier.swift`,
  `SignatureVerifier+Seals.swift`,
  `VexSign/Services/Signing/Verification/SigningVerificationReportBuilder.swift`,
  `VexSign/Services/Signing/Execution/SigningHandler.swift`,
  `PackageSigningCoordinator.swift` — post-sign verification and
  `requireVerified()` before library registration.
- `Packages/NativeSigning/Signing/NativeDesignatedRequirement.swift` and
  `NativeResourceSealVerifier.swift` — `Insecure.SHA1` here is a CodeDirectory /
  resource-seal encoding requirement, not an integrity-policy choice. No change.

Provisioning, archive, transport and platform configuration:

- `VexSign/Security/Provisioning/ProvisioningProfileParser.swift` and
  `ProfileCompatibility.swift` — authenticated Apple CMS is required; expiry,
  App ID, nested bundles, entitlements, team, certificate membership, devices and
  profile type are evaluated with distinct verdicts.
- `VexSign/Security/ArchiveValidation/ArchiveSafetyValidator.swift`,
  `VexSign/Services/Import/Extraction/IPAExtractor.swift` — entry limits, path
  traversal, symlinks, duplicate/case/Unicode collisions, path-type conflicts,
  CRC and re-validation before every write.
- `VexSign/Networking/Downloads/PackageDownloadRedirectDelegate.swift`,
  `VexSign/Security/Policies/PackageDownloadURLPolicy.swift`,
  `SourceURLPolicy.swift`, `VexSign/Networking/HTTP/BoundedResponseFetch.swift`,
  `Packages/NimbleKit/.../NBFetchService.swift` — HTTPS default, local-only opt-in,
  redirect downgrade refusal, credential-header stripping and bounded bodies.
- `Config/BuildSettings/iOS/Info.plist` — ATS uses only `NSAllowsLocalNetworking`;
  no global `NSAllowsArbitraryLoads`. Companion plist was checked too.
- `VexSign/Services/Diagnostics/FileLogger.swift`, `LogRedaction.swift`,
  `StdoutCapture.swift`, `SubsystemDiagnosticsLog.swift`,
  `VexSign/Features/Dashboard/About/DiagnosticsCenterView.swift` — before this
  task there was no security-status section in the diagnostics UI.
- Tests and CI: `VexSignTests/SecurityTests/*`,
  `Tools/Validation/security-validation/*`, `Tools/Audit/test_device_acceptance.py`,
  `Makefile` `verify`, `.github/workflows/ci.yml`, `Package.swift` and
  `Package.resolved`. No new dependency was added.

External input boundaries reviewed: custom URL schemes and document types
(`DeepLinkRouterUseCase`), repository JSON, release-feed JSON, IPA/ZIP entries,
backups, paired-device transport, and native tool stdout.

## 3. External references actually inspected

Nothing was copied from these repositories; they were read as design references.
Licence positions previously recorded in this workspace: AltStore/SideStore AGPL-3.0,
Feather GPL-3.0, KSign GPL-3.0. No reference code or binary was added as a dependency.

| Reference | Exact source inspected | What it informed |
|---|---|---|
| OWASP MASVS | `OWASP/owasp-masvs` `Document/05-MASVS-STORAGE.md`, `06-MASVS-CRYPTO.md`, `08-MASVS-NETWORK.md`; `controls/MASVS-STORAGE-1.md`, `STORAGE-2`, `CRYPTO-1`, `CRYPTO-2`, `NETWORK-1`, `NETWORK-2`, `PLATFORM-*`, `RESILIENCE-*` (tree listing and the listed control/chapter files read) | Requirement families for the checklist below; no claim of full MASVS coverage. |
| OWASP MASTG | `OWASP/owasp-mastg` `Document/0x06d-Testing-Data-Storage.md`, `0x06e-Testing-Cryptography.md`, `0x06g-Testing-Network-Communication.md` | iOS test areas mapped to existing and new regression tests. |
| Apple Security / Keychain | `https://developer.apple.com/documentation/security/keychain-services` | Small secrets in the encrypted keychain; this repo already uses it for passwords and keys. |
| Apple LocalAuthentication | `https://developer.apple.com/documentation/localauthentication` | The app's existing App Lock uses the system policy; biometrics are not a substitute for keychain storage. |
| Apple CryptoKit | `https://developer.apple.com/documentation/cryptokit` | Prefer CryptoKit; AES-GCM, SHA-256, Curve25519 and Secure Enclave are first-party primitives. CommonCrypto PBKDF2 remains an Apple API used for compatibility with existing backup containers. |
| Apple ATS | `https://developer.apple.com/documentation/bundleresources/information_property_list/nsapptransportsecurity` | No global plaintext exception; local networking is a narrow, documented exception. |
| Apple File Protection | `https://developer.apple.com/documentation/foundation/fileprotectiontype` | Applied to staged key material and diagnostic logs where the volume supports it. |
| Apple Platform Security | `https://support.apple.com/guide/security/welcome/web` | Hardware/system/app security model; no jailbreak or code-signing bypass attempted. |
| zsign | `zhlynn/zsign` `src/signing.cpp`, `src/certcheck.cpp`, `src/archo.cpp` | `signing.cpp` shows dual SHA-1/SHA-256 CodeDirectory and page-hash handling and CMS `cdhashes` constraints; `certcheck.cpp` uses OpenSSL PKCS12/CMS/OCSP. Confirms SHA-1 is a format field, not permission to weaken hashes generally. |
| AltStore | `AltStore/Operations/VerifyAppOperation.swift`, `AltStoreCore/Components/Keychain.swift` | Post-resign verification and keychain-wrapped credentials; no code copied. |
| SideStore | `SideStore/Core/Certificates/CodeSignValidator.swift`, `OCSPValidator.swift` | Explicit `expired/revoked/missingProfile/privateKeyLost` verdicts and revocation error states; this repo already distinguishes similar states. |
| Feather | `Feather/Utilities/Handlers/ZsignHandler.swift`, `Feather/Backend/Storage/Storage+Certificate.swift` (tree) | Native zsign invocation shape and certificate storage layout; its plaintext `cert.password` pattern was **not** adopted. |
| KSign | `Ksign/Backend/Server/ServerInstaller+TLS.swift`, `Ksign/Backend/Storage/Storage+Certificate.swift` (tree) | Local installer TLS setup; this repo keeps its own pinned companion trust instead. |
| Existing VexSign | `VexSign/Security/*`, `VexSign/Services/Import/*`, local docs and tests | IPA trust boundary and existing controls; no new external dependency. |

## 4. Requirements → MASVS → checklist → evidence

This is a project checklist, not a formal attestation. Each row names the local
evidence; rows without an automated check are labelled.

| Requirement | MASVS family | Local control / checklist | Evidence |
|---|---|---|---|
| Small secrets in Keychain, no plaintext credential copies | STORAGE-1, CRYPTO-2 | `SecureSecretStore`, `CertificateSecrets`, `IdentityVault`, migration gates | `test_signing_identity_policy.py`, `test_cross_file_privacy.py`, `test_private_defaults_policy.py` |
| Deep-link private key is protected and removed on every outcome | STORAGE-1 | `decodeAndWrite` protected write; consent alert reports cancel; router discards staged files | new `CertificateLinkConsentCleanupTests`, `DeepLinkBase64StagingTests`, new Python hardening gate |
| Platform cryptography, safe key lifecycle | CRYPTO-1/2 | CryptoKit AES-GCM/SHA-256/Ed25519, Apple PBKDF2, random salt/nonce | `BackupCrypto` tests, `ReleaseManifestVerifier`, `VexSignTests/SecurityTests` |
| Authenticated Apple provisioning profile and entitlement checks | PLATFORM-1, CRYPTO-1 | `ProvisioningProfileParser`, `ProfileCompatibility`, `SignatureVerifier` entitlement checks | existing security tests; new diagnostics profile check |
| Malicious archive containment | RESILIENCE-1, STORAGE-1 | `ArchiveSafetyValidator`, `IPAExtractor`, new POSIX mode cap | `ArchiveTraversal/*`, `test_archive_extraction_policy.py`, new `ArchiveFileAttributesTests` |
| Independent post-sign verification | RESILIENCE-1/2 | `SignatureVerifier.verify` + `requireVerified()` before registration | `SigningHandler`, `PackageSigningCoordinator`, signing tests |
| HTTPS and safe redirects | NETWORK-1/2 | URL policies, ATS, bounded fetch, credential-header stripping | `test_network_timeout_policy.py`, URL validation tests |
| Logs do not leak or forge | STORAGE-2 | `LogRedaction`, protected `FileLogger` file, newline folding | `LogRedactionTests`, new hardening gate |
| Diagnostics distinguish pass/warn/fail/unknown/unsupported | (project requirement) | `SecurityDiagnosticsService` + Diagnostics Center section | `SecurityDiagnosticsTests`, new hardening gate |
| Device install and launch | PLATFORM-2 | `AppInstaller`, paired validation, device acceptance suite | `test_device_acceptance.py` (portable contract only; hardware not run here) |

MASTG test chapters above map to: `VexSignTests/SecurityTests/CredentialRedaction/*`,
`CertificateValidation/*`, `ArchiveTraversal/*`, `URLValidation/*`, and the portable
Python gates. No MASVS category is claimed "fully compliant"; resilience and
platform controls have not all been evaluated or evidenced.

## 5. Changes made, with code and evidence

### HIGH — deep-link certificate import left a private key behind on decline

- Code: `SubsystemBoundaries.swift` gained `presentImportConsentAlert(..., onCancel:)`
  with a compatibility default; `UIKitPlatformAdapter.swift` presents a real
  cancel action and fails closed when no presenter exists;
  `DeepLinkRouterUseCase.swift` now calls `discardStagedCertificateFiles` from
  the cancel path as well as the completion path.
- Evidence: new `VexSignTests/SecurityTests/URLValidation/CertificateLinkConsentCleanupTests.swift`
  (decline and confirm cases), updated
  `Tools/Validation/security-validation/test_signing_identity_policy.py`.

### HIGH — staged certificate/profile payloads were written unprotected

- Code: `Packages/NimbleKit/.../FileManager+shortcuts.swift` writes staged
  base64 payloads with `.completeFileProtection`, sets `0o600`, and returns nil
  on a failed protected write.
- Evidence: new `testStagedPrivateKeyPayloadIsOwnerOnly` in
  `DeepLinkBase64StagingTests.swift` and the Python hardening gate.

### MEDIUM — archive mode bits could grant setuid/setgid/sticky or group write

- Code: new `VexSign/Security/ArchiveValidation/ArchiveFileAttributesPolicy.swift`
  masks special bits and caps rwx at `0o755`; `IPAExtractor.swift` uses it for
  both file and directory metadata.
- Evidence: `ArchiveFileAttributesTests.swift` (four tests), archive extraction
  policy gate, Python hardening gate (including the `0o764 → 0o744` case).

### MEDIUM — secrets in deep-link URLs and forged log lines

- Code: `LogRedaction.swift` masks `p12=`/`mobileprovision=`/`certificate_p12=`/
  `provisioning_profile=` query values, folds embedded CR/LF, and adds the new
  key names to its sensitive-key list. `FileLogger.swift` now creates the log
  directory at `0700`, applies Data Protection and `0600` to the log file, and
  tolerates only the simulator's unsupported-protection error via the existing
  `ProtectedCertificateFiles.applyProtectionAttributes`.
- Evidence: `LogRedactionTests.swift` (two new tests), Python hardening gate.

### MEDIUM — remote release JSON could offer an arbitrary-scheme asset URL

- Code: `SelfUpdateManager.swift` parses `browser_download_url` only after
  `PackageDownloadURLPolicy.validateInitialURL` accepts it.
- Evidence: Python hardening gate asserts ordering and the policy call. A
  simulator/Xcode test of GitHub's live feed is deliberately not fabricated.

### PROCESS — signed release manifests had no independent trust input; no diagnostics UI

- Code: new `ReleaseManifestTrustStore.swift` loads pinned Ed25519 keys only
  from a build-provided `ReleaseManifestKeys.plist`; no development key is
  embedded. New `SecurityDiagnosticsService.swift` calls the real verifiers,
  returns per-check states (passed/warning/failed/unknown/unsupported) and is
  wired through `AppContainer` into a new "Security Verification" section in
  `DiagnosticsCenterView.swift`. There is no global score.
- Evidence: `SecurityDiagnosticsTests.swift` (four tests), Python hardening gate.
  With no `ReleaseManifestKeys.plist` in this checkout the manifest trust row is
  honestly `unsupported`, not `passed`.

## 6. Validation results (local, exact)

- `make verify`: **82 gate(s) passed** after all edits; the single advisory
  warning is the skipped Swift syntax check (no `swiftc` in this Linux sandbox).
- `python3 Tools/Audit/test_security_hardening_contracts.py`: **7 tests OK**.
- `python3 Tools/Audit/test_notification_automation_contracts.py`: **6 tests OK**.
- `python3 Tools/Audit/test_device_acceptance.py`: **39 tests OK** (portable
  contract checks, not a physical device run).
- Tree-sitter parse of 187 changed Swift files: 0 errors in the files changed by
  this task; one pre-existing parser limitation in
  `VexSign/Services/Injection/Planning/InjectionTargetAuthorization.swift`
  (`for name where …` is valid Swift that this grammar reports as an error).
- `git diff --check`: clean.
- `sync-strings.py --check`: clean (26 new keys added, then verified).
- `error-discipline.py`: 136 unjustified `try?` across 62 files, none above baseline.

### GitHub Actions

`gh run list --branch arena/d2c05cf4-vexsign --limit 5` returned **no runs**
(RC 0) both at audit start and at the end of this work. The new portable gate
was added to `Makefile` and `.github/workflows/ci.yml` locally, but **no remote
CI result is claimed**: no commit was pushed and no workflow was triggered.

## 7. Remaining risks and explicit limitations

- No Xcode/macOS toolchain here: the new Swift tests were not compiled or run;
  portable gates and tree-sitter parsing are the only local evidence.
- No physical iPhone: actual install/launch, Data Protection classes, Keychain
  accessibility on a locked device and background behaviour remain unverified.
- No production Ed25519 release key is provisioned. Signed release manifests
  cannot be verified in this build; the diagnostics row reports `unsupported`.
- Release-manifest verification is not yet part of an automatic self-update
  install decision; the verifier and trust store exist and are diagnosable, but
  the update flow still relies on its existing local-signing and in-place policy.
- `IdentityVault` still mirrors the device UUID and premium flags to a
  protected file and `UserDefaults` for entitlement durability. This predates
  the task and was preserved deliberately; it remains a bearer-token risk for a
  attacker with full container access.
- SHA-1 remains only in Apple code-signature/resource-seal and OCSP encodings
  that require it. No SHA-1-based general integrity decision was introduced.
- No formal MASVS/MASTG compliance is claimed: platform and resilience controls
  have not all been evaluated, and several checks need hardware evidence.
- Reference repositories were read only. None of their AGPL/GPL code was copied.

## 8. Manual security tests recommended before release

1. On a device, send a `vexsign://import-certificate?...` link with a fixture
   p12; tap Cancel and confirm no staged `.p12` remains in the app's temporary
   directory (`Logs` and file sharing must not show its bytes).
2. Confirm the consent alert's Cancel action and the no-presenter path both
   remove staged files; confirm Import still installs the identity.
3. Import a fixture IPA whose ZIP entries declare `04777`, `02777` and `01777`
   modes; confirm extraction succeeds only with those bits stripped and the
   executable bit retained where needed.
4. Export diagnostics after deliberately triggering a signing failure; search
   the bundle for a fixture password, p12 base64, bearer token and device UDID.
5. In Diagnostics Center, verify each row shows its true state with no release
   key provisioned (`unsupported`), and that enabling local HTTP changes only
   the transport row to `warning`.
6. On a device with a provisioned `ReleaseManifestKeys.plist`, verify a valid
   signed manifest passes and a tampered payload/expired manifest fails.
7. Run a paired-device install and confirm the existing signature-verification
   report still gates registration and that actual install/launch is recorded
   separately from a signature verdict.

## 9. Recommended next task

Add a device-backed release-integrity path: provision the pinned Ed25519 release
key through the release pipeline, verify a signed manifest before offering an
artifact, and bind the manifest's SHA-256 to the downloaded IPA *and* the locally
signed copy before any install is offered. Pair that with on-device XCTest cases
for the new consent, archive-mode and redaction checks, and report the MASVS
controls that remain unevaluated rather than asserting blanket compliance.
