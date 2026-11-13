# Feature matrix and gap analysis

What VexSign can actually do, compared against the storage/signing ecosystem it interoperates
with, and what is missing. Every status here is derived from reading this repository's source —
no build, test run or device interaction happened while it was written (see
[METHOD](#method) for exactly what was and was not examined).

Status vocabulary:

| Status | Meaning |
| --- | --- |
| **implemented** | Source read: an entry point, a service and a persisted result exist. Not executed. |
| **implemented (partial)** | The path exists but a named part of the capability is absent. |
| **missing** | No implementation in this repository. |
| **platform-limited** | Apple's APIs do not permit it; the limitation is stated in-product rather than worked around. |
| **needs infrastructure** | Requires a server or credentials that are not part of the app. |
| **not inspected** | Exists in the referenced project; this pass did not read it. |

## Method

Examined at source level:

- This repository: `VexSign/`, `VexSignTests/` (124 test files), `AltSourceKit/`,
  `Vendor/IDeviceKitten/`, `.github/workflows/`, `tools/`.
- `altstoreio/AltStore` — `AltStoreCore/Model/StoreApp.swift` read in full where it decides
  which release is current (`versions.first`, `latestSupportedVersion`, `isSupported`), plus its
  file tree. This is the reference implementation of the source format VexSign consumes.
- `khcrysalis/Feather` (canonical name now `claration/feather`) — file tree only. Confirms the
  shared lineage: the same `AltSourceKit`/`IDeviceKitten` packages VexSign vendors.
- `NexSideloading/NexStore` — file tree only. Same lineage, plus
  `Backend/Observable/CertificateStatusManager.swift`.
- Repository metadata (existence, stars, licence, last push) for the other fifteen projects
  named in the brief, plus the NexStore URL check the brief asked for.

**Not examined at source level:** Ksign, RyukSign, KorSign, MySignReincarnated, Odysseus
(both), BatSign, ForgeSign-iOS, ProStore, FeatherPlus, SideStore, LiveContainer, zsign,
libimobiledevice, libusbmuxd, ideviceinstaller. Their entries below say so. The brief asked for a
source-level investigation of all of them; this pass did not do that, and no row claims it did.

Licences observed: GPL-3.0 (Feather, FeatherPlus, Ksign, RyukSign, KorSign, MySignReincarnated,
Odysseus ×2, BatSign), AGPL-3.0 (LiveContainer, SideStore, AltStore), MIT (ProStore, zsign),
LGPL-2.1 (libimobiledevice, libusbmuxd), GPL-2.0 (ideviceinstaller), none declared
(ForgeSign-iOS). **No code was copied from any of them in this pass.**

## A. Signing engine

| Capability | Status | Evidence / note |
| --- | --- | --- |
| IPA signing | implemented | `FR+Signing` → `SigningService` → `ZsignEngine` (vendored zsign, MIT) |
| Certificate + private-key handling | implemented | `CertificateFileHandler`, `IdentityVault`, `CertificateReader` |
| Provisioning profile parsing | implemented | `CertificateReader.decoded`, `ProfileCompatibility` |
| Entitlement resolution | implemented | `MachOEntitlements`, `EntitlementsManager`, tolerant-key list in `SignatureVerifier` |
| Nested extension signing | implemented | `NestedBundleAudit`, `ExtensionSigningRegressionTests` |
| Bundle identifier modification | implemented | `Options.effectiveAppIdentifier`, `InfoPlistPlan` |
| Signature verification | implemented | `SignatureVerifier`, `BundleSignature`, `SignatureVerifierTests` |
| Multiple signing identities | implemented | `SigningIdentityResolution`, per-app `NamedSigningProfileStore` |
| Free Apple ID signing | implemented (partial) | `NativeSigning/`; CMS verifier ships **unavailable by default** and the 7-day ladder has never been run on hardware — see `docs/DEVICE_TESTING.md` |
| Paid certificate signing | implemented | Same pipeline with an imported identity |
| Signing diagnostics | implemented | `SigningErrorMapper`, `TaskTrace`, structured stages |
| Signing history | implemented | `SigningRecordIdentity`, task history; saved-options replay covered by `SigningProfileReplayTests` |
| Re-signing | implemented | Saved options replay, `AutoSignManager`, `BatchJobRunner` |

No gap found in this domain that this pass could verify by reading. The open question is
verification, not capability.

## B. Account and identity

| Capability | Status | Evidence / note |
| --- | --- | --- |
| Account authentication | implemented | `AppleAccountSessionCoordinator`, `AnisetteProvider` |
| Session management | implemented | `AppleAccountAuthenticationState`, resume journal store |
| Free-account provisioning | implemented (partial) | `NativeSigning/` — profile creation path exists; CMS verification is opt-in |
| Certificate import / P12 | implemented | `CertificateFileHandler`, `P12Cracker` |
| Private-key association | implemented | Keychain `…ThisDeviceOnly` tier |
| Profile management | implemented | Stored beside the identity, decoded lazily |
| Device registration | implemented | `NativeSigning` device registration path |
| Expiry monitoring | implemented | `CertificateExpiryMonitor`, `BatchCertChecker` |
| Renewal | implemented (partial) | `RenewalReadiness` + `BackgroundAutomation`; background signing needs a user-issued `UnattendedSigningGrant` (certificate-bound, at most 30 days, revocable); unattended **profile renewal** is not implemented (`SigningMethod.swift`) |
| Identity compatibility | implemented | `ProfileCompatibility`, `SigningIdentityPolicy` |
| Secure backup/restore | implemented | `BackupVerification`, secrets excluded by policy |

**Top gap: unattended profile renewal.** `UnattendedSigningGrant` now gates background signing
with an existing certificate (scope, certificate, expiry, revocation). Renewing a free Apple ID
profile in the background is a different thing: an account operation, security-sensitive, and
still in need of its own design review. The grant does not authorise it and nothing performs it. Complexity: high. Value: high (it is the difference between "remind me
to re-sign" and "keeps working").

## C. Application customisation

| Capability | Status | Evidence / note |
| --- | --- | --- |
| Bundle identifier change | implemented | `InfoPlistPlan`, `NestedBundleAudit.rewrittenIdentifier` |
| Display name | implemented | `Options` name change |
| Icon replacement | implemented | `iconPoc.m`, `SigningHandler`, `SigningAlternativeIconView` |
| Plist modification | implemented | `PlistDiff`, `InfoPlistPlan` |
| Entitlement editing/validation | implemented | `EntitlementsManager` + profile check before signing |
| Dylib injection | implemented | `TweakManager`, `TweakInjectionDefaults` |
| Tweak compatibility | implemented | `TweakRepository`, `TweakModels`; load-time gate in `TweakCompatibility` (architecture, platform, encryption, load paths, rootful/rootless/roothide layout), enforced by `TweakHandler` before anything is placed. Dependencies between packages are not resolved. |
| Cloning | implemented | `CloneWizard` |
| Duplicate bundle management | implemented | `CloneWizard` + `ImportDuplicateReview` (metadata match, keep-both) |
| Nested bundle handling | implemented | `NestedBundleAudit`, `AppExtensionEnumerator` |
| Architecture inspection | implemented | `MachOReader`, `MachOInspector` |
| Dependency analysis | implemented (partial) | linked dylibs are listed; there is no orphan/unresolved-dependency report |

## D. Device management

| Capability | Status | Evidence / note |
| --- | --- | --- |
| Device discovery | implemented | `IDevice/`, `LockdownClient` |
| Pairing / trust | implemented | `HeartbeatManager`, pairing file |
| Authorisation | implemented | `DeviceTLSIdentity`, capability matrix in `DeviceConnectivity` |
| USB / wireless | implemented (platform-limited) | Requires a pairing file and, for idevice transports, a running tunnel |
| Installation | implemented | `AppInstaller`, OTA + paired transport, `InstallEvidenceReporting` |
| Inventory | implemented | `InstalledAppProbe` (local LaunchServices) |
| Uninstallation | implemented (not device-tested) | `DeviceAppRemoval` over the pairing session: refuses VexSign itself and `com.apple.` apps, confirms, then reads the device back. Reports "Removed" only when absence is observed |
| Refresh / re-signing | implemented (partial) | See B: no unattended grant |
| Multiple devices | implemented (partial) | One paired device at a time; the transport is single-session |
| Device-specific provisioning | implemented | `ProfileCompatibility` device check (needs a known UDID — see below) |
| Error recovery | implemented | Deadline budget, unconfirmed-vs-failed separation |

Two verified sub-gaps in this domain, both read from source:

1. **Removal is unverified on hardware.** The vendored `InstallationAppProxy.deleteApp(for:)`
   leaked its client and could not use the RSD tunnel; both are patched locally (see
   `Vendor/manifest.json`). The path is confirm → uninstall → read back → reconcile. The
   read-back uses the local probe, which often cannot tell, so the usual result is
   "Removal requested" rather than "Removed". No part of it has run on a device.
2. **`deviceUDID` is practically always nil.** `ProfileCompatibility`'s device check only runs
   when a caller supplies a UDID, and a jailed app cannot read its own. The check exists and is
   correct; it is rarely reachable.

## E. Repository and discovery

| Capability | Status | Evidence / note |
| --- | --- | --- |
| Source management | implemented | `SourcesView`, `SourcePreferences`, priority view |
| Format support | implemented | AltStore-style sources, ESIGN-key sources (`EsignSourceKey`, `ASDecrypt`) |
| Source validation | implemented | `RepositoryValidator`, `SourceFeedLoader` invalid/failed outcomes |
| Catalogue normalisation | implemented | `CatalogIdentity`, `AltSourceKit` |
| Search and filtering | implemented | `AppStoreView`, premium filters |
| Categories | implemented | `category` field surfaced |
| Screenshots/icons | implemented | lenient `Screenshots` decoder (four formats) |
| Release history | implemented | `versions` decoded; per-release `downloadURL`, `date`, `size`, `minOSVersion` |
| Multi-source dedup | implemented | `CatalogIdentity.bundleKey`, source priority |
| Source health | implemented | `SourceHealthDashboardView`, per-source outcome |
| Offline cache | implemented | snapshot cache keyed by payload hash |
| Update detection | implemented | `AppUpdateChecker`, `VersionOrder` |
| Download integrity | implemented | `DownloadIntegrity` expectations, `FileIntegrity` |

**Gap closed in this pass: OS-compatibility filtering of releases.** See
[IMPLEMENTED](#implemented-release-compatibility) below.

**Remaining gap: build numbers.** `buildVersion` is decoded and never compared. A publisher who
re-uploads the same marketing version with a new build (`2.0 (1)` → `2.0 (2)`) is not offered as
an update. Implementing it needs the installed app's `CFBundleVersion`, which is a bundle read
per library row — the performance work has to be designed with it, not after it.

## F. Application library

| Capability | Status | Evidence / note |
| --- | --- | --- |
| Imported/signed artifacts | implemented | Core Data `Imported`/`Signed`, `LibraryStatusStore` |
| Installed state | implemented | `InstalledAppProbe`, `LibraryInstallationLifecycleTests` |
| Metadata | implemented | writer/reader pair in `Storage` |
| Versions and history | implemented | `VersionOrder`, `LibraryStatusStore.version` |
| Collections/favourites | implemented (partial) | Locking, hiding and strict-hiding exist; there is no user-defined collection |
| Search/sort | implemented | library grid + preferences |
| Duplicate detection | implemented (partial) | metadata match only (`ImportDuplicateReview`); no content digest |
| Updates | implemented | See E |
| Artifact storage | implemented | `LibraryArtifactAvailability`, staged deletion |
| Bulk operations | implemented | `BatchJobRunner` |
| Backup integration | implemented | `LibraryBackupSupport` |

## G. Task orchestration

Central engine `UnifiedTaskCenter` with pure policies (`TaskProgressRule`, `TaskRetryPolicy`,
`TaskSubmissionPolicy`, `TaskMirrorPolicy`), a persisted journal, and mirroring from
`DownloadManager`. Every long-running flow reports into it. **Implemented**, with recorded
divergences: `BatchJobRunner` keeps its own per-item vocabulary, and the Apple-ID certificate
handoff files itself under kind `export`.

## H. Additional capabilities

Shortcuts/AppIntents (implemented), widgets (implemented), notifications (implemented), advanced
diagnostics (`DiagnosticBundleExporter`, redaction), backup/restore (implemented), offline
operation (implemented, snapshot cache), cloud signing (`Backend/CloudSigning` +
`cloud-signing/`), companion services (`CompanionBridge`, TV/vision/watch targets), import/export
(library, repository, backup), preferences, privacy controls (hidden/locked apps, strict mode).

**`cloud-signing/`, `server/` and `AnisetteServer/` remain unaudited** — that is a verification
gap, not a feature gap, and it is the largest one in the product.

## Implemented: release compatibility

`ASRepository.App.currentAppVersion` returned `versions.first`. The source format makes that
order meaningful — AltStore's own `setVersions` reads `versions.first` for the current release —
so the order itself is right. What was missing is that `minOSVersion` was decoded and then
ignored, while AltStore additionally tracks `latestSupportedVersion` (the newest release whose
minimum the device satisfies).

Effect in VexSign before the change: a source whose current release requires iOS 26 offered that
release to an iOS 18 device. The download completed, the import completed, and the install
failed — the failure arriving minutes later, with no mention that the source also published a
compatible release further down the list.

After the change (`AltSourceKit/Sources/AltSourceKit/Models/ASRepository.swift`):

- `OSVersion` is `Comparable` (component-wise) and exposes `OSVersion.running`, computed once so
  a list render does not re-read the system version per row.
- `Version.isSupported(running:)` — no declared minimum means supported, so sources that never
  set one behave exactly as before.
- `App.newestSupportedRelease(running:)` returns the first release in **source order** that this
  OS can install, and `hasSupportedRelease(running:)` says whether any release qualifies.
- `currentAppVersion` uses it with the running OS, so every existing call site — discovery,
  updates, update-all, widgets — inherits the fix without a second code path.
- When nothing is supported, the newest release is still returned. A source with unparsable
  metadata keeps its current behaviour instead of becoming undownloadable.

Covered by `VexSignTests/ReleaseCompatibilityTests.swift` (12 tests): filtering by minimum at
major/minor/patch level, absence of a minimum, the fallback, emptiness, the source-order
contract (`1.10` before `1.9` is *not* re-sorted), agreement between the accessor and the rule,
`OSVersion` ordering, the `running` bridge, and lenient decoding of junk minimums.

## Priority ranking

| # | Opportunity | Value | Reliability | Security | Feasibility | Architecture | Maintenance |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Audit the three backend services | high | high | **high** | medium | none | low |
| 2 | Device removal path (+ vendor fixes) | high | medium | medium | medium | contained | medium |
| 3 | Build-number update comparison | medium | high | none | medium | low | low |
| 4 | Scoped unattended renewal grant | high | high | **high** | low (needs design) | high | high |
| 5 | Content-digest duplicate detection | medium | medium | none | medium (schema) | medium | medium |
| 6 | Collections/favourites | low | none | none | high | low | low |

Ranked this way because 1 and 4 are the only entries that can make the product wrong in a way
users cannot see, 2 is a capability the UI already advertises as absent, and 6 is polish.

## Unsupported by the platform

Stated in-product rather than worked around: arbitrary IPA installation without a user-visible
installation path; unlimited free-account provisioning; guaranteed background execution; JIT
support; guaranteed wireless transport; entitlements Apple has not granted to the signed profile.
VexSign reports these as limits (see `DeviceConnectivity`'s capability matrix and
`SigningCapability`), not as bugs.

## Licensing and attribution

`VexSign/Resources` and `THIRD_PARTY_NOTICES.md` carry the notices for vendored zsign (MIT),
IDeviceKitten/IDeviceSwift (LGPL, vendored under `Vendor/`), AltSourceKit and the local
packages. This pass added **no third-party code**; the only changes are to first-party files
(`AltSourceKit` is a first-party package in this repository) and to tests.
