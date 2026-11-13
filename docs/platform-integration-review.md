# Platform integration review

This is a partial engineering review of checkout `f05d4a1bd0fc7b27d9013e301870207b8806e354` on `arena/6978685a-vexsign`, not a completion report for the requested platform. The checkout was clean at the start of the review. The requested alternate branch name is not the active session branch.

## Repository map

- iOS application and SwiftUI presentation: `VexSign/`; Core Data storage: `VexSign/Backend/Storage/`. The project has VexSign, TV, visionOS, watch, widget and test targets. The iOS deployment target is 17.0; the CI workflow notes an iOS 26 SDK requirement.
- Signing: existing `VexSign/Utilities/FR+Signing.swift`, signing handlers and vendored `Vendor/Zsign`; `NativeSigning/` adds account, identity, profile and output-verification components. Its account handoff is explicitly gated and does not itself replace normal signing.
- Sources and discovery: `SourcesViewModel`, `SourceFeedLoader`, `RepositorySnapshotCache`, `DiscoveryViewModel`, `AppUpdateChecker`. A separate `RepositorySyncEngine` and SQLite `EcosystemDatabase` exist for repository-builder/ecosystem flows; these are distinct cache paths and are not evidence of a unified source service.
- Downloads/import: `DownloadManager`, `DownloadIntegrity`, and storage import handlers; signing and installation report into `UnifiedTaskCenter` in some workflows. A universal task integration has not been established.
- Security-sensitive storage: `VexSign/Security/` and `NativeSigning/Security/`; archive handling and safety policy live under `VexSign/Utilities/`. Backups, device flows, external runtimes and installation have existing implementations, but their complete end-to-end behavior was not audited here.
- Existing CI includes `.github/workflows/ci.yml`, `platform-check.yml`, `services.yml` and `release.yml`. `make verify` covers portable project and policy checks. Swift/Xcode builds and simulator tests require a macOS runner.

## Implementation map

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Single-source refresh preserving unrelated catalogs | Implemented but not fully validated | The Shortcuts intent supplies the complete configured set separately from its target set. Snapshot prefill and retention use the configured set; only targets are fetched. New tests require an Xcode run. |
| Cancelled or reset source refresh | Implemented but not fully validated | Generation and cancellation checks prevent a superseded fetch from publishing its catalog or health/snapshot changes after suspension. The callback-based network request itself is not necessarily cancelled. `SourceFeedLoader` also records provenance before the caller's generation check; review cancellation semantics for that separate side effect. |
| Offline catalogs | Existing but incomplete | Valid snapshots are retained on ordinary failed refresh. Cache is capped at 64 snapshots and snapshot writes are best-effort. Source changes during an in-flight fetch and concurrent retention deserve further tests, especially when a new source is added during a refresh. |
| Repository refresh status | Fixed, not fully validated | The Shortcuts dialog no longer claims successful refresh when the loader records failure or skips a rate-limited source; it directs users to health information. |
| Download integrity | Existing but incomplete | `DownloadIntegrity` checks published size/hash when supplied; missing expectations are explicitly unverified. Full source-to-device artifact provenance and end-to-end verification were not established. |
| Signing, profile and identity | Existing but incomplete | Existing Zsign and `NativeSigning` integrations require device/identity testing and a complete architecture/security audit; no replacement engine was added. |
| Account provisioning and installation | Requires real-device validation | Apple account/profile paths have explicit consent and trust gates; ordinary iOS cannot be assumed to perform silent arbitrary IPA installation. Supported transports and paid/free-account behavior have not been verified here. |
| Library, task center, customization, backup and runtime handoff | Existing but incomplete | Components and tests exist; shared identity, complete task coverage, transactional restore, runtime observations and cross-workflow integration remain to be verified. |
| Apple platform limitations | Unsupported / requires companion infrastructure | USB host/desktop device services, arbitrary silent installation, guaranteed background refresh and universal JIT cannot be assumed on ordinary iOS. Each actual transport and entitlement needs separate verification. |

Additional risks to audit: credential handling and redaction across all networking paths; authenticated redirect behavior; archive extraction bounds; provisioning trust and revocation; lifecycle race conditions; memory and responsiveness with large IPAs; and whether source/application/artifact identities survive update and signing workflows. These are audit targets, not findings that each subsystem is defective.

## Reference investigation and licensing

The requested full reference-source investigation is **not complete**. No third-party code was copied in this change. The VexSign top-level license is GPL-3.0; in-tree notices also identify AGPL-3.0 components and additional component licenses. Consult `THIRD_PARTY_NOTICES.md` and the exact component licenses before distribution or reuse; licensing compatibility is not established by this review.

A limited source inspection of Feather revision `31ab6de455f2a6108f6830e343dee826310c03be` covered `Feather/Views/Sources/SourcesViewModel.swift`, `Feather/Backend/Storage/Storage+Sources.swift`, `Feather/Utilities/Handlers/ZsignHandler.swift`, `Feather/Views/Signing/SigningTweaksView.swift`, and its top-level `LICENSE`. The inspected source uses batched source fetches, a Zsign wrapper and tweak selection; its inspected source loader clears its displayed catalog before a fetch. VexSign's existing last-known-good approach should be retained instead of replacing it with that behavior. The examined top-level license is GPL-3.0. Its dependency licenses and entire test/build graph were not independently reviewed.

FeatherPlus, KSign, RyukSign, KorSign, MySignReincarnated, both Odysseus repositories, BatSign, ForgeSign-iOS, both candidate NexStore repositories, SideInstaller, Sideloader, iPASide, LiveContainer, SideStore, AltStore, ProStore, upstream Zsign, libimobiledevice, libusbmuxd and ideviceinstaller have **not** been investigated at the requested source-code level in this review. Their exact revisions, licenses, dependency graphs, useful/rejected approaches and NexStore upstream identity remain open. Apple documentation was not independently reviewed in this session. Do not treat product claims about those projects as verified.

## Validation

- `make verify`: passed on Linux, including portable policy, repository structure, localization, package graph, and Python preparation/packaging checks. This explicitly skips Swift syntax compilation.
- Added `VexSignTests/SourceRefreshScopeTests.swift`: targeted failed-refresh preservation, reset/late-result and deletion-during-refresh cases. **Not run**: no Swift or Xcode toolchain is installed here.
- Compilation, iOS unit/integration tests, simulator tests, real-device tests and release build: **not run**. GitHub Actions: **not run during the initial review**; consult the pull request checks for results on the committed changes.
- `git diff --check`: passed during the initial review. No tags or release-version changes were made.

## Manual iPhone acceptance checklist

1. Configure two sources with known catalogs; pin the second and disable its automatic updates.
2. Run the Refresh Repositories shortcut selecting only the first. Confirm the second remains visible, its preferences are unchanged, and no request is made to it.
3. Make the first source unavailable, refresh it, and confirm its prior catalog remains visible and marked stale; check the health error and the Shortcut's non-success wording.
4. Start a slow refresh, background and reopen the app while it is pending, then refresh again. Confirm a late result from the earlier operation does not overwrite the current catalog or loading state.
5. Delete a source during a slow refresh and check that its catalog does not reappear. Repeat with a new source added during refresh and check snapshot retention; investigate any failure before release.
6. Separately exercise import, identity/profile compatibility, signing/output verification, the supported installation method, update preference replay, encrypted backup/restore and runtime handoff on the intended iOS version and device. Record prerequisites and actual results; this checklist is not proof of those workflows.

## Draft pull request description

**Title:** `feat(platform): build a unified iOS signing and application management platform`

**Summary / motivation:** A limited first integration change prevents a single-source Shortcut refresh from treating other configured repositories as deleted, and avoids presenting an unconditional refresh-success claim. Superseded fetches no longer publish their catalog or health results after a reset.

**Architecture / UI / security:** Reuses the existing source loader, snapshots and source preferences; no new signing engine, dependency, UI screen or external source code. Refresh selection is separate from the full configured source set. Source health remains the authority for per-source results. No comprehensive security review was completed.

**Testing / CI:** Portable `make verify` passes. New Swift tests are unrun; iOS compile, simulator, device and release results were unavailable during the initial review; consult pull request checks for subsequent CI results.

**Limitations / known issues:** This is not the requested complete unified platform; reference investigation, end-to-end lifecycle testing, and broad architecture, UI/accessibility and security work remain. A reset does not guarantee network cancellation, and provenance recording plus concurrent source addition need further review. See the checklist above.

**Licensing:** No third-party code added; existing GPL/AGPL and component notices remain applicable and require independent distribution review. This description reflects the limited scope of this change, not completion of the full platform.
