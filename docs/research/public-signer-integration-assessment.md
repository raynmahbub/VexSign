# Public signer integration assessment

Snapshot: **2026-11-08**. Scope: repository identity, default-branch revision,
license metadata, repository trees and selected feature modules. This is **not**
a complete source/security audit, feature-parity certification or device test.
Earlier comparison notes remain useful but do not establish current runtime readiness.

## Source inventory

GitHub API metadata and source files were fetched at these immutable revisions:

| Repository | Reviewed revision | GitHub license metadata |
| --- | --- | --- |
| [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer/tree/9d6ea09b05afa2c8fc537c372795a294db631311) | `9d6ea09b05afa2c8fc537c372795a294db631311` | AGPL-3.0 |
| [NexSideloading/NexStore](https://github.com/NexSideloading/NexStore/tree/d4c7fc15cf187de1f0704ed6d23b36236e614a16) | `d4c7fc15cf187de1f0704ed6d23b36236e614a16` | GPL-3.0 |
| [Nyasami/Ksign](https://github.com/Nyasami/Ksign/tree/c14dedc0c9dadb669021cce83435b14f781b8412) | `c14dedc0c9dadb669021cce83435b14f781b8412` | GPL-3.0 |
| [SideStore/SideStore](https://github.com/SideStore/SideStore/tree/4f3d18d98c5fbee72c80f787ceb2e8e09ded60a6) | `4f3d18d98c5fbee72c80f787ceb2e8e09ded60a6` | AGPL-3.0 |
| [TomerGamerTV/FeatherPlus](https://github.com/TomerGamerTV/FeatherPlus/tree/9af4713cf6d5c1db3a1f24ddabca53008a46ac5a) | `9af4713cf6d5c1db3a1f24ddabca53008a46ac5a` | GPL-3.0 |
| [claration/feather](https://github.com/claration/feather/tree/31ab6de455f2a6108f6830e343dee826310c03be) | `31ab6de455f2a6108f6830e343dee826310c03be` | GPL-3.0 |
| [faroukbmiled/RyukSign](https://github.com/faroukbmiled/RyukSign/tree/844466cee6f212291913ba5216f8f19a9c016dea) | `844466cee6f212291913ba5216f8f19a9c016dea` | GPL-3.0 |
| [gliddd4/MySign](https://github.com/gliddd4/MySign/tree/c5a41629ad5dba5c804438fc3c2f2e6c421d4633) | `c5a41629ad5dba5c804438fc3c2f2e6c421d4633` | No standard license detected |
| [gliddd4/MySignReincarnated](https://github.com/gliddd4/MySignReincarnated/tree/c21554d69de8821d6fd3a323371badbeb7d764e0) | `c21554d69de8821d6fd3a323371badbeb7d764e0` | GPL-3.0 |
| [korboybeats/KorSign](https://github.com/korboybeats/KorSign/tree/f20892f43177476ef769b2ac76fc038f87d963ec) | `f20892f43177476ef769b2ac76fc038f87d963ec` | GPL-3.0 |
| [mirazbakis/Odysseus](https://github.com/mirazbakis/Odysseus/tree/2664dadedf9aca36fda0925a8aada92e2c79323f) | `2664dadedf9aca36fda0925a8aada92e2c79323f` | GPL-3.0 |

**LCSign remains unresolved.** Search found `Linsy0110/LCsignIT` (empty repository,
no license) and `Callia218/LCSignClone` (described as a skeleton). Neither is
assumed to be the requested LCSign. Obtain the exact repository URL before a port.
“Etc.” is not a defined source list; additional repositories need explicit identity.

## Selected-source inspection and VexSign disposition

Paths below are relative to the pinned repositories above. Existing counterparts
mean code is present, **not** that equivalent behavior or device stability is proven.

| Reference / inspected module | Feature direction | VexSign disposition |
| --- | --- | --- |
| Feather: `Feather/Views/Signing/Shared/SigningOptionsView.swift` | Configurable signing, minimum requirement and appearance | Existing options retained. This batch adds a planned minimum-OS readout before signing using VexSign's own plist merge model. |
| FeatherPlus: `Feather/Utilities/Handlers/ArchiveHandler.swift`; repository backup-oriented description | Packaging; backup portability | Existing `BackupManager`, `BackupCrypto` and `LibraryBackupSupport` cover encrypted selective backup. Cross-app backup-format compatibility is not established. |
| KSign: `Ksign/Views/Library/LibraryCellView.swift` | Library sign/install actions | Already represented by `LibraryAppWorkflowAction`; do not duplicate actions or alter global defaults. |
| RyukSign: `RyukSign/Backend/Observable/DownloadManager.swift` | Background downloads, pause/resume, progress | Existing split `DownloadManager` and Live Activity components; lifecycle/device acceptance remains necessary. |
| KorSign: `KorSign/Utilities/Handlers/ArchiveHandler.swift` | Safe export naming and pairing compression | Existing attributed adaptations: `IPAExportNaming` and `ArchiveTransferPolicy`. Keep non-overwrite semantics and bounded compression preferences. |
| MySignReincarnated: `RyukSign/Backend/Observable/DownloadHistory.swift` | Persisted history and thumbnails | Existing VexSign task/history workflow; no second competing persistence store added. |
| MySign: `mysignipasigner/Tabs/Downloads/DownloadManager.swift` | Download progress/history | Reference only; no standard license detected. No source copied. |
| Odysseus: `Feather/Backend/Certificates/ODOCSPChecker.swift` | Detailed revocation evidence | Existing `CertificateInspector` and OCSP verification retained; do not interpret missing evidence as good. Vendored SideSign requires separate license review. |
| NexStore: `NexStore/Backend/Observable/CertificateStatusManager.swift` | Certificate badges and remote status | Existing local status manager retained. **Do not port the remote checker**: `_fetchAppleStatus` builds a POST containing the P12 and its password. Also do not adopt `revoked != true` as proof of validity. Existing NovaDNS integration remains opt-in; DNS filtering cannot guarantee protection against revocation. |
| SideStore: `SideStore/Core/Certificates/OCSPValidator.swift` | Apple ID provisioning and certificate diagnostics | Existing experimental NativeSigning/embedded paths remain gated. Selected validator allows `.unknown` to return without error; that is not positive validity evidence. No AGPL source copied or pins updated in this batch. |
| LiveContainer: `LiveContainerSwiftUI/Views/AppList/LCDownloadView.swift` | Download progress/cancellation; container workflow | Keep VexSign's existing download ownership rather than importing another downloader. Existing embedded host remains experimental, not promoted by this review. No AGPL source copied or runtime pins updated. |

## First implementation batch

`SigningCustomizationView` now displays the planned `MinimumOSVersion` using
`MergedInfoPlist.effective`, the existing model shared with plist editing. It
reflects managed options, removals, explicit user overrides and final removals in
signing order. Missing/unreadable metadata is not displayed as a fabricated version.
The UI explicitly says this is **not a compatibility check**: changing a plist
cannot supply missing APIs or lower a Mach-O deployment target.

The identifier summary also shows the normalized override actually consumed by
the signing pipeline. The editor retains the raw input so it remains editable.
No new dependencies, services, signing engines, credentials or upstream source
code are introduced by this batch. Tests cover preview/signing agreement for the
original minimum, managed changes, removal, user override and final removal.

## Remaining acceptance gates / next batches

1. **Apple build and tests:** compile the changed SwiftUI view and run the new
   XCTest cases. Portable checks cannot establish Apple-platform compilation.
2. **Device UX:** inspect imported/signed apps with readable/missing plists; change
   minimum requirement, override and removal settings, then compare with exported
   Info.plist. Test VoiceOver and large text. Do not claim runtime compatibility.
3. **Downloads/imports:** compare suspend, resume, cancellation, app relaunch and
   background expiration against existing VexSign tests before changing lifecycle code.
4. **Signing and installation:** retain confirmed-install reporting, profile and
   entitlement checks, symlink rejection and CMS verification. Capability promotion
   requires the device matrix; never weaken `requireCMSVerification()`.
5. **Native account/container work:** evaluate upstream diffs against pinned host
   inputs in a separate batch. Audit licenses and corresponding-source obligations
   before any AGPL code adoption; then run the existing build/device gates.
6. **LCSign:** identify the intended licensed source before assessing unique features.

No claim is made that all upstream features have been integrated, that all source
files have been audited, or that any implementation is flawless. Favor measured,
small integrations over importing overlapping managers and undocumented guarantees.

See [comparison notes](public-signer-comparison.md),
[adaptation notices](../THIRD_PARTY_ADAPTATIONS.md),
[device acceptance](../DEVICE_TESTING.md), and
[embedded-host limitations](../../EmbeddedContainer/README.md).

## Additional discovery: user-supplied zsign topic

The user supplied <https://github.com/topics/zsign>. Direct topic-page retrieval
returned HTTP 504; the GitHub repository search API (`topic:zsign`, sorted by
updated, first 50 results) provided the following additional candidates. This is
**metadata-only discovery**, not a source audit, license clearance or integration.
Descriptions below are upstream claims, not verified capabilities.

| Candidate / pinned head | GitHub license metadata | Assessment direction |
| --- | --- | --- |
| [8yy/BatSign](https://github.com/8yy/BatSign/tree/d60dbee57228e74d4502c24ff825f154fa33c45b) | GPL-3.0 | Advertises automatic updates/background signing; compare lifecycle, cancellation and install-confirmation handling with existing VexSign queues. “Silent installs” needs platform/entitlement verification. |
| [ihateios/SignOs](https://github.com/ihateios/SignOs/tree/a424b3542590ebab0ec46f6bfaf458556f2b11cb) | GPL-3.0 | Advertises automatic updates and cloning; check for actual gaps rather than duplicating existing VexSign update rules and Clone Wizard. |
| [ProStore-iOS/ProStore](https://github.com/ProStore-iOS/ProStore/tree/f244d5397970bd7f31e258811a49e4e408a92054) | MIT | Alternative-store candidate; unique implemented features still need source inspection. |
| [pwnapplehat/iPASide](https://github.com/pwnapplehat/iPASide/tree/f31250e9123d586526393a31d1d31468a9ad33d5) | MIT | Described as Windows Apple-ID sideloading; not a drop-in on-device iOS backend. Inspect protocol boundaries before proposing reuse. |
| [Mesutcydev/ForgeSign-iOS](https://github.com/Mesutcydev/ForgeSign-iOS/tree/a08e67910cf9a74e38d71d65835ef4f97d29d6b3) | Unclassified | Advertises certificate countdown/library/OTA workflows. Resolve actual licensing before copying code. |

Topic membership alone is not endorsement, proof of source availability, or proof
of stability. This discovery does not identify LCSign and does not change native
capability flags, runtime pins, certificate disclosure policy or signing defaults.

## Second review batch: confirmed list and GitHub IPA import

The user explicitly added **NuzProjects/Feather** alongside the original Feather,
BatSign, SignOs, iPASide, ForgeSign and ProStore. These names extend the inventory;
LCSign still needs an exact source URL. The following modules were fetched and
inspected at pinned revisions, upgrading these entries from metadata-only discovery:

| Repository / revision | Selected modules | Decision |
| --- | --- | --- |
| [NuzProjects/Feather](https://github.com/NuzProjects/Feather/tree/1436e8609053d836f7c69e771b56b06dca52dcda), GPL-3.0 | `Feather/Core/ReleaseRules.swift`, `Feather/Features/Library/GitHubImportView.swift` | Integrate a manual GitHub release/IPA chooser. Do not copy its subscriptions or automatic update tracking in this batch. |
| BatSign, revision listed above | `Feather/Backend/Observable/AutoUpdateManager.swift`, `Feather/Utilities/BSInstallWatcher.swift` | Review automation preferences and build-identity installation evidence against existing VexSign behavior. Keep existing automation defaults and confirmed-install requirements; no watcher or renewal-policy port claimed. |
| SignOs, revision listed above | `Feather/Backend/Observable/AutoUpdateManager.swift` | Per-source/per-app automation and expiry renewal are useful reference areas. No replacement of VexSign's existing update policy or unattended-renewal promotion. |
| iPASide, revision listed above | `src/iPASide.Engine/ipaside_engine/doctor.py`, `ipa.py` | Environment diagnostics, platform/architecture and encrypted-binary inspection are reference inputs. Windows service/USB diagnostics are not directly reusable on jailed iOS; no Python engine embedded. |
| ForgeSign, revision listed above | `App/Services/IPAPreflight.swift`, `App/Services/Refresh/RefreshPlanner.swift` | Read-only preflight and refresh-readiness explanations are useful design references. Code copying deferred while license remains unclassified. No native account capability promoted. |
| ProStore, revision listed above | `Sources/prostore/signing/DownloadSignManager.swift`, `Sources/prostore/certificates/certChecker.swift` | Pipeline and per-session workspace compared; retain VexSign's existing ownership. Checker uses a remote multipart certificate service; do not port credential disclosure. |

### Implemented: Library → Import from GitHub

- Accepts `owner/repository` or an HTTPS GitHub repository URL, including a `.git`
  suffix. Rejects credentials, ports, query strings, fragments, extra path segments
  and non-GitHub hosts. This is a repository chooser, not a general URL importer.
- Fetches the first 20 releases from GitHub's public API without authentication,
  using an ephemeral session without cookies or stored credentials, a timeout,
  cancellable byte streaming and a 2 MiB metadata bound. It does not crawl all pages.
- Excludes drafts; prereleases require an explicit toggle and are labelled.
  Every eligible IPA is listed for explicit selection, not guessed by filename.
- Restricts asset links to HTTPS GitHub release-download paths in the chosen
  repository. Normal GitHub asset delivery redirects are handled by the existing
  downloader; no new bypass of archive inspection or signing validation is added.
- Passes declared size and SHA-256 digest to VexSign's existing integrity checks.
  Malformed or unsupported declared digests and negative sizes are not silently
  downgraded to unverified assets. Metadata integrity is not publisher authenticity.
- Reuses `DownloadManager.startDownload` with manual-import ownership. Existing
  Game Mode, download constraints, integrity-mismatch review, import and optional
  auto-sign preferences continue to apply. No new automatic behavior is enabled.
- Closing the chooser cancels metadata loading. Input/toggle changes clear results
  so a list cannot be mistaken for a different repository or prerelease choice.
- Does **not** persist GitHub subscriptions, poll releases in the background,
  auto-select assets across versions, or add third-party certificate providers.

Implementation: `Utilities/GitHubIPAReleases.swift`,
`Views/Library/GitHubIPAImportView.swift`, and the Library import menu.
`GitHubIPAReleasesTests` covers repository parsing, unsafe inputs, request shape,
draft/prerelease filtering, explicit multi-IPA choices, asset boundaries, integrity
metadata, malformed JSON and response-size limits. These are added XCTest cases,
not evidence they have executed on this Linux host.

### Acceptance still required

On macOS, compile and run the new XCTest suite. On iOS, test a repository with
multiple IPAs, no IPAs and prereleases; API 403/404/429 and offline states; close
while loading; an IPA download redirect; cancellation during download/import;
existing auto-sign on/off; integrity mismatch review; and an end-to-end authorized
IPA import/sign/install. Run VoiceOver and large-text checks. Until then, this is
implemented but **Apple-platform and device-unverified**, not a stability claim.
