# Source-guided architecture decisions

This report records the **specific external sources** used to ground selected architecture decisions in this pass. It is source-level evidence, not a whole-repository audit, not a licence clearance, and not runtime/device validation. The broader pinned inventory and earlier findings are in [`reference-investigation-2026-11-13.md`](reference-investigation-2026-11-13.md) and [`upstream-review-inventory.json`](upstream-review-inventory.json).

**Rule applied:** read and compare specific implementations for a feature; do not copy restricted source into VexSign. VexSign remains an independent implementation. Where a licence is GPL/AGPL/custom-restricted, only policy conclusions were used and no source expression, type or comment was copied. Third-party obligations stay in [`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

## Sources fetched for this architecture pass

| Feature | Source and pinned revision | Licence / restriction | What was inspected | Decision for VexSign |
| --- | --- | --- | --- | --- |
| Local signing engine | `zhlynn/zsign` README at `9299685bab7ef99827e06e5dfda93af747386590` | MIT | IPA/Mach-O re-signing, persistent cache, multi-profile extension signing, certificate/OCSP checks, ad-hoc signing. | Keep the existing `SigningService` → `ZsignEngine` → `Packages/Vendor/Zsign` pipeline as the single owner. `SigningPlan`, `NestedBundleAudit`, `ProfileCompatibility` and `SignatureVerifier` remain the validation boundaries. No second signing engine. |
| Download + signing workflow | `ProStore-iOS/ProStore` `Sources/prostore/signing/DownloadSignManager.swift` at `f244d5397970bd7f31e258811a49e4e408a92054` | MIT | A `@MainActor` download/sign manager with progress portions, one session temp directory, pairing-file preconditions and cancellation/cleanup concerns. | Confirms that typed progress, cleanup and one operation owner matter. VexSign keeps `UnifiedTaskCenter` and `DownloadManager` rather than adding a duplicate `DownloadSignManager`. No source copied. |
| Bootstrap / computer prerequisites | `pwnapplehat/iPASide` README at `6b721393964fd654a8984c22e00ead068e1e3109` | MIT | Apple Devices/iTunes USB requirement, Apple ID sign-in/2FA, plug-in/trust, Settings developer-profile trust. | `Documentation/Distribution/bootstrap.md` must not promise universal computer-free initial installation. Installation capability answers stay separate from success evidence. |
| iOS-version-specific bootstrap | `FrizzleM/SideInstaller` README at `82452dfd2a575b5a031145de2b22b98d4b7b3a76` | Custom noncommercial/educational; official-release redistribution and monetization restrictions; attribution required if source is incorporated. | iOS 27+ `siboot`/Wi-Fi/Developer Mode route; older versions need a PC-created or remote pairing file; below 17.4 unsupported. | Use only as a capability matrix and honesty check. No implementation source was copied and no attribution was added to product UI because no source was incorporated. |
| Deep-link and log boundaries | `FrizzleM/SideInstaller` `LICENSE.md`, `ios-app/DeepLink.swift`, `LogRedactor.swift`, `LogStore.swift`, `ios-tests/LogRedactorTests.swift` at the same revision | Same custom restriction | Bounded base64 staging, key/identifier classes for redaction, redaction-before-export, idempotency/non-overfire tests. | Earlier VexSign work independently added base64 normalization/bounds and extended `LogRedaction`; this architecture pass preserves those boundaries and requires redaction before diagnostic export. |
| Guest-container limitations | `LiveContainer/LiveContainer` README at `9d6ea09b05afa2c8fc537c372795a294db631311` | AGPL-3.0 | Guest apps run inside one host, JIT-less mode signs executables, app extensions are not registered, entitlements from guest are not applied to host. | `EmbeddedContainerRuntime` stays capability-gated. No AGPL source copied and no claim that a guest import equals a normal iOS installation. |
| Certificate revocation policy | `SideStore/SideStore` `SideStore/Core/Certificates/OCSPValidator.swift` at `4f3d18d98c5fbee72c80f787ceb2e8e09ded60a6` | AGPL-3.0 | OCSP error categories, WWDR intermediate handling, status propagation delay note; the source fetches the intermediate over HTTP. | Compare only the need for typed error categories and explicit unknown/revoked states. VexSign keeps its independent `App/iOS/VexSign/Utilities/OCSP/` verifier and must not copy AGPL code or weaken TLS policy. |

`altstoreio/AltServer` remains unreachable from this sandbox in the earlier pinned investigation; no official URL or revision is invented for it.

## Feature-to-owner decisions

| Requested feature area | VexSign owner | Source-guided decision | Status |
| --- | --- | --- | --- |
| IPA validation, archive inspection, nested extensions | `Utilities/Signing/SigningService.swift`, `SigningPlan.swift`, `NestedBundleAudit.swift`, `Utilities/Handlers/` | One shared pipeline; zsign is an engine adapter, not the architecture owner. | Implemented; Build-verified gate still CI-dependent. |
| Imported paid certificates and free-account/native provisioning | `IdentityVault`, `CertificateManagementService`, `Packages/NativeSigning/`, `SigningMethodCapabilities.swift` | Separate identity acquisition from signing execution; keep native account capability `.notIntegrated` until CMS/device evidence. | Honest gate retained. |
| Optional cloud signing | `CloudSigningClient.swift`, `Services/CloudSigning/cloud-signing/`, `Tools/Development/test_cloud_signing_contract.py` | Explicit authorization, OpenAPI contract, isolated worker, `signatureVerified: true`; configured API is not production infrastructure. | Honest gate retained. |
| Download, repository and app lifecycle | `DownloadManager`, `RepositorySyncEngine`, `Storage`, `UnifiedTaskCenter` | One download manager, one registry, one task center; no `DownloadSignManager` clone. | Existing systems retained. |
| Device discovery, pairing, capability, install, verification | `DeviceConnectivity.swift`, `AppInstaller`, `InstallQueue`, `InstallConfirmation` | Capability resolver reports prerequisites; only install confirmation marks an app installed. | Implemented; Device-verified not claimed. |
| Backup, diagnostics, security | `BackupManager`, `BackupCrypto`, `LogRedaction`, `DiagnosticBundleExporter`, policy tests | Encrypted/integrity-checked backups and redacted exports; no secrets or private keys in ordinary logs. | Existing systems retained; drift guard added. |

## Why this is not source copying

- The VexSign code changed in this pass is an independent `WorkspaceSupportEnvironmentProviding` port, a UIKit adapter, an Application use case, XCTest doubles and Python/JSON guardrails.
- No upstream Swift/TypeScript/Python expression, regex, type name, comment or file layout from the fetched sources was inserted into VexSign.
- MIT sources were used for feature limitations and policy comparison; GPL/AGPL/custom-restricted sources were used only for architectural conclusions and honesty checks.
- Pinned revisions and licence metadata are recorded in [`../architecture/component-map.json`](../Architecture/component-map.json) and [`reference-investigation-2026-11-13.md`](reference-investigation-2026-11-13.md).

## Validation boundary

These source reads do not compile VexSign, run XCTest, prove a physical-device workflow or establish that a cloud/backend service is deployed. Those claims are governed by the local checks and CI/device gates in [`architecture-excellence-audit.md`](architecture-excellence-audit.md).
