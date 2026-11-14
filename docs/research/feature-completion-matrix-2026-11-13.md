# Feature completion matrix — 2026-11-13

Deliverable **C**. Statuses use the requested Definition-of-Done vocabulary. A row may carry
several statuses; `Blocked (Build-verified, Device-verified)` means the code and portable tests
exist but the named gates have not run. No row claims a physical-device result, a current-branch
Xcode build, or a feature that is still gated.

## Legend

| Status | Meaning |
| --- | --- |
| `Implemented` | Source exists in this checkout. |
| `Integrated` | Wired into the product workflow / composition root / persisted state. |
| `Tested` | Automated tests exist and the portable/service subset ran green locally. |
| `Build-verified` | Compiled by macOS/Xcode CI on the current branch. **Not achieved here.** |
| `Device-verified` | Confirmed on a physical iPhone with recorded evidence. **Not achieved here.** |
| `Gated` | Deliberately unavailable until explicit evidence/infrastructure exists. |
| `Blocked` | Real work remains and a named dependency prevents completion. |
| `Not implemented` | No implementation in this checkout. |

## A. Phase 1 vertical slice: paid certificate → install confirmation

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Imported paid P12 + mobileprovision | `Implemented · Integrated · Tested · Blocked (Build-verified, Device-verified)` | `CertificateManagementService`, `IdentityVault`, `CertificateReader`; portable policy tests pass. Real import/install needs Xcode + device. |
| IPA import / archive safety / Info.plist / nested bundles / entitlements | `Implemented · Integrated · Tested · Blocked (Build-verified, Device-verified)` | `ArchiveHandler`, `NestedBundleAudit`, `InfoPlistPlan`, `EntitlementsManager`; `tools/test_archive_extraction_policy.py` and XCTest exist. |
| Signing identity selection and preflight | `Implemented · Integrated · Tested` | `SigningCapabilityResolver`, `PreflightChecks`, `SigningIdentityPolicy`, `SigningExecutionGate`. |
| Zsign signing pipeline | `Implemented · Integrated · Tested` | `SigningService` → `SigningHandler` → vendored `Vendor/Zsign`; post-sign `SignatureVerifier.Expectation.freshlySigned`. |
| Signature verification before library registration | `Implemented · Integrated · Tested` | `SigningHandler.modify/move`, `SignatureVerifier`, `tools/test_workflow_trace_policy.py`. |
| Installation handoff (OTA / pairing / guest) | `Implemented · Integrated · Tested · Blocked (Build-verified, Device-verified)` | `AppInstaller`, `ServerInstaller`, `InstallQueueCore`; manifest fallback now refused rather than faked. |
| Installation state distinction (started/requested/accepted/confirmed/launch verified) | `Implemented · Integrated · Tested` | `InstallConfirmation`, `InstalledAppProbe`, `UnifiedTaskModels`; positive-only probe never converts filtered false into absence. |
| Installation confirmation / evidence report | `Implemented · Integrated · Tested` | `InstallConfirmation`, `InstallEvidenceReporting`, `TaskReceipt`; no fabricated success. |
| End-to-end slice on a real iPhone | `Blocked (Build-verified, Device-verified)` | Requires user commit/push → green `ci.yml`, then the [acceptance guide](device-acceptance-guide-2026-11-13.md). |

## B. Signing and provisioning

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Paid certificate signing | `Implemented · Integrated · Tested` | `SigningMethodCapabilities.importedCertificateSigning: .implemented`. |
| Multiple identities / per-app pinned certificate | `Implemented · Integrated · Tested` | `SigningIdentityResolution`, `NamedSigningProfileStore`. |
| Profile compatibility (expiry, device, app ID, entitlements) | `Implemented · Integrated · Tested` | `ProfileCompatibility`, `NativeProvisioningProfileValidator`. |
| Re-sign / update / batch / automation | `Implemented · Integrated · Tested` | `AutoSignManager`, `BatchJobRunner`, `UpdateAllManager`, `UnattendedSigningGrant`. |
| Unattended free-account **profile renewal** | `Not implemented` | Background signing is gated; account renewal needs its own design review. |
| Free Apple account signing end-to-end | `Gated` | `nativeAppleAccountSigning: .notIntegrated`; requires genuine Apple CMS, negative/tamper tests, full device ladder and production `.appleCMS()` wiring. |
| Cloud signing | `Gated` | `CloudSigningClient.privateKeyUploadDisabled`; strict `signatureVerified: true`; no real safe infrastructure deployed. |
| Embedded container / guest runtime | `Gated` | `EmbeddedContainerRuntime.isAvailable`; no AGPL/LiveContainer source copied. |

## C. Native account and CMS gates

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Apple-root-pinned CMS verifier | `Implemented · Integrated · Tested` | `NativeAppleProfileCMSVerifier.swift`, strict DER/CMS v1/RSA-SHA-256 subset, 3-certificate chain, `.unspecified` trust, cancellation-safe fail-closed. |
| Native profile validator fail-closed without CMS verifier | `Implemented · Integrated · Tested` | `NativeProvisioningProfileValidator.swift`. |
| Production `.appleCMS()` selection requirement | `Implemented · Integrated · Tested` | `tools/check-native-handoff.py`. |
| Native promotion evidence ladder | `Gated` | `tools/native-promotion-evidence.py` requires genuine Apple CMS, full device evidence, no fixture/secret markers. |
| Native account capability promotion | `Blocked (Build-verified, Device-verified)` | No genuine fixture, no physical-device evidence; do not change `.notIntegrated`. |

## D. Installation and bootstrap honesty

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Local OTA server + `itms-services` handoff | `Implemented · Integrated · Tested` | `ServerInstaller`, `ManifestService`, `AppInstaller`; external manifest now must be positively verified. |
| Pairing-file / idevice transport with diagnostics | `Implemented · Integrated · Tested` | `PairingBridge`, `HeartbeatManager`, `DeviceConnectivity`, setup health UI. |
| Device-app removal with read-back | `Implemented · Integrated · Tested · Blocked (Device-verified)` | `DeviceAppRemoval`; "Removed" only on observed absence. |
| Computer-free bootstrap explanation with prerequisites | `Implemented · Integrated` | `docs/distribution/bootstrap.md`, capability strings, `SigningMethodCapabilities.swift`. |
| Production-signed TestFlight / Ad Hoc / Enterprise / MDM / marketplace portal | `Not implemented` | Requires App Store Connect, signing credentials, HTTPS portal, protected Ed25519 release key. |
| Arbitrary IPA self-install from an unsigned release IPA | `Not implemented` | Ordinary iOS apps cannot self-install; release workflow publishes an unsigned IPA. |
| iOS 27+ `siboot` / PC-created pairing prerequisite enforcement | `Gated` | Upstream prerequisite recorded; VexSign does not claim unrestricted computer-free install. |

## E. Repositories, downloads and library lifecycle

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Source management / repository parsing | `Implemented · Integrated · Tested` | `AltSourceKit`, `RepositoryCatalogService`, bounded timeouts. |
| Download integrity / cancellation / recovery | `Implemented · Integrated · Tested` | `DownloadIntegrity`, `UnifiedTaskCenter`, `TaskHistoryJournal`; no blind resume. |
| Update matching / exact identity / version order | `Implemented · Integrated · Tested` | `VersionOrder`, `AppUpdateChecker`, `GitHubSubscriptionStore`. |
| App lifecycle states / duplicate review | `Implemented · Integrated · Tested` | `UnifiedTaskModels`, `ImportDuplicateReview`, `LibraryIntegrityAudit`. |
| Backup / restore integrity without silent deletion | `Implemented · Integrated · Tested` | `BackupManager`, `BackupVerification`, `CoreDataStoreRecovery`. |
| Proprietary third-party backup format adapters | `Not implemented` | Out of scope; existing schema 1–3 support retained. |

## F. Task, storage and privacy reliability

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Persistent task descriptors / restart recovery | `Implemented · Integrated · Tested` | `TaskHistoryJournal`, `UnifiedTaskCenter.recoverAfterRestart`; corrupt originals preserved. |
| Certificate / identity secure storage / redaction | `Implemented · Integrated · Tested` | `IdentityVault`, `LogRedaction` extended in this pass; no secrets in logs. |
| Shared diagnostic log privacy (new key/identifier rules) | `Implemented · Integrated · Tested` | `LogRedaction.swift`, `LogRedactionTests.swift`, `tools/test_integration_contracts.py`. |
| Deep-link base64 normalization and size bound | `Implemented · Integrated · Tested` | `FileManager+shortcuts.swift`, `DeepLinkBase64StagingTests.swift`. |
| Public URL SSRF guard with port/IPv6 validation | `Implemented · Integrated · Tested` | `server/url_guard.py`, 36 new pytest cases. |
| Exactly-once crash-safe import/database commit | `Blocked` | Conservative recovery is documented; crash window remains. |

## G. Architecture, performance and UI

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Presentation → Application → Domain ← Infrastructure/Platform | `Implemented · Integrated · Tested` | `tools/test_architecture_boundaries.py`, `AppContainer`. |
| No duplicate signing engine / task system / new dependency | `Implemented · Integrated · Tested` | `tools/check-package-graph.py`, `tools/singleton-freeze.py`, `tools/error-discipline.py`. |
| Swift 6 build diagnostics fixed and guarded | `Implemented · Integrated · Tested · Blocked (Build-verified)` | `tools/test_swift6_build_regressions.py`; fresh macOS CI run outstanding. |
| Onboarding tied to real actions / capability disclosure | `Implemented · Integrated · Tested` | `OnboardingView`, `tools/test_capability_disclosure.py`. |
| Real-device performance / energy / p95 measurements | `Blocked (Device-verified)` | `tools/performance-fixtures.py` provides portable corpora only; no device numbers fabricated. |

## H. CI, release and verification

| Capability | Status | Evidence / next gate |
| --- | --- | --- |
| Portable `make verify` / docs / policy / workflow gates | `Implemented · Integrated · Tested` | `make verify` exit 0; 309 tool tests. |
| Server pytest / cloud-signing Node tests / contracts | `Implemented · Integrated · Tested` | `215 passed, 1 skipped`; `14 pass`; `make test-cloud` drift check. |
| Current-branch macOS `build` + `tests` CI run | `Blocked (Build-verified)` | Baseline run `43513058621` failed; PR #235 was later opened and CI checks started, but no green result had been observed at the time this matrix was published. |
| Generic unsigned iOS build / simulator XCTest on current branch | `Blocked (Build-verified)` | Requires a green PR-triggered macOS CI build and simulator XCTest run. |
| Physical iPhone acceptance | `Blocked (Device-verified)` | See deliverable E; no fabricated results. |
| Release / tag / deployment | `Not implemented` | The user controls release actions; a PR was opened but no merge, release, tag or deployment was executed. |
