# VexSign — Stabilization Baseline (Phase 0)

Date: 2026-09-20
Baseline commit: `cf6b4bb` (main), work branch: `arena/01a0c12c-vexsign`

This document is the Phase 0 audit of the VexSign repository **before any
production code is modified**. All findings below are from static inspection
of the checked-out sources, `project.pbxproj`, CI configuration and existing
documentation. No production code was changed in Phase 0.

---

## 1. Environment constraints (read this first)

| Constraint | Impact |
| --- | --- |
| Audit host is a **Linux sandbox (Debian 12)** with **no Xcode, no swiftc, no Docker** | No local `xcodebuild` build or `xcodebuild test` run is possible here. |
| Sandbox network is restricted to **GitHub** (swift.org, docker hub unreachable) | A local Swift toolchain cannot be installed; the Linux `swiftc -parse` gate cannot be reproduced locally either. |
| The project is an iOS/tvOS/visionOS/watchOS app (UIKit/SwiftUI) | Even a Linux Swift toolchain could not build the app targets; only GitHub Actions `macos-15` runners can. |

**Consequence:** the mandatory development loop (build → test → inspect
warnings) is executed through **GitHub Actions CI**, which is the project's
existing and authoritative build oracle:

* `ci.yml` (quick job) — runs on **push to any branch** (fast Linux
  `swiftc -parse` syntax gate + duplicate/resource checks, image
  `swift:6.4-noble`).
* `ci.yml` (build job) — runs on **push to main and PRs to main**
  (full `xcodebuild` Debug build of the `VexSign` scheme on `macos-15`,
  unsigned; first-party warnings are errors unless listed in
  `.github/build-warnings-baseline.json`).
* `platform-check.yml` — PRs touching companion targets / `project.pbxproj`
  (VexSignTV, VexSignVision, VexSignWatch).
* `ecosystem.yml` — PRs touching cloud-signing / repository subsystems
  (Node `npm ci && npm test && npm run contracts` + audit).
* `server-tests.yml` — PRs touching `server/**` (Python pytest).
* `make lint` — SwiftLint auto-fix on PRs (non-blocking).
* `release.yml` — tag-driven release builds (not part of stabilization loop).

Each phase therefore: change → push to `arena/01a0c12c-vexsign` (quick-check)
→ PR to `main` (build-check et al.) → iterate.

**Known CI gap (recorded, not fixed in Phase 0):** no workflow runs
`xcodebuild test` for the `VexSignTests` target. The existing unit test suite
is compiled by the test-target's own CI coverage only when a job builds it;
today **no job builds or runs it on PRs**. Adding a unit-test job is a Phase
15/16 action item.

---

## 2. Project configuration

* Project: `VexSign.xcodeproj` (file-system-synchronized groups,
  `preferredProjectObjectVersion = 77`, Xcode 16+ project format).
* Workspace: `VexSign.xcworkspace` (SPM resolution; `Package.resolved` is
  committed at `VexSign.xcworkspace/xcshareddata/swiftpm/`).
* Project attributes: `LastSwiftUpdateCheck = 2600`,
  `LastUpgradeCheck = 1630`.

### 2.1 Xcode / Swift requirements

* **Xcode 26.x is required.** The code uses iOS 26 SDK APIs (e.g.
  `.glassEffect`), `SWIFT_APPROACHABLE_CONCURRENCY`, and an iOS 26 widget
  deployment target; Xcode 16 cannot build it (documented in
  `.github/workflows/ci.yml`).
* CI builds with the newest Xcode on `macos-15`; the committed warnings
  baseline was generated with **Xcode 26.3** (run 35536522884, 2026-09-20).
* **Swift language mode: `5.0` for every target.** No target uses Swift 6
  language mode yet. `SWIFT_APPROACHABLE_CONCURRENCY = YES` is set **only on
  the widget target** (all 4 configurations).
* The quick-check parse gate uses the Swift **6.4** container image.

### 2.2 Targets (7) and schemes (5)

| Target | Type | SDK | Deployment target | Bundle ID |
| --- | --- | --- | --- | --- |
| `VexSign` | application | iphoneos/auto | **iOS 16.0** | `com.vexsign.app` |
| `VexSignWidgetExtensionExtension` | app-extension | iphoneos | **iOS 26.0** | `com.vexsign.app.widget` |
| `VexSignTests` | unit-test (testTarget = VexSign) | iphoneos | iOS 16.0 | `com.vexsign.appTests` |
| `VexSignTV` | application | appletvos | tvOS 17.0 | `com.vexsign.app.tv` |
| `VexSignVision` | application | xros | visionOS 2.0 | `com.vexsign.app.vision` |
| `VexSignWatch` | application | watchos | watchOS 10.0 | `com.vexsign.app.watch` |
| `VexSignWatchWidgets` | app-extension | watchos | watchOS 10.0 | `com.vexsign.app.watch.widgets` |

Schemes (shared): `VexSign`, `VexSignTV`, `VexSignTests`, `VexSignVision`,
`VexSignWatch`.

Embedding: `VexSign` embeds `VexSignWidgetExtensionExtension` (Plugins) and
`VexSignWatch.app` (Watch folder, which itself embeds
`VexSignWatchWidgets`).

> ⚠️ Noted for later review (not a Phase 0 change): the widget extension's
> deployment target (iOS 26.0) is **higher** than the host app's (iOS 16.0).
> CI currently builds it, but on-device behavior on iOS 16–25 hosts deserves a
> dedicated check in Phase 13/17.

`VexSign` target build phases additionally include:
`Copy Acknowledgements` (LicensePlist build tool), `Build FilePickerFix`
(shell script), plus the package product dependencies below.

### 2.3 Dependencies

**Git submodules** (`.gitmodules`):

| Path | Repo | Pins |
| --- | --- | --- |
| `Zsign/` | `claration/Zsign-Package` (branch `package`) | `6ffe703` |
| `IDeviceKitten/` | `claration/IDeviceKit` | `837cf1e` |

**Local SwiftPM packages in-repo:**

* `Zsign/` → product `ZsignSwift` (the Zsign signing engine boundary).
* `IDeviceKitten/` → products `IDeviceSwift`, `IDevice`.
* `AltSourceKit/` → product `AltSourceKit` (also used by `VexSignTests`).
* `NimbleKit/` → products `NimbleExtensions`, `NimbleViews`, `NimbleJSON`.

**Remote SwiftPM packages** (resolved versions from
`VexSign.xcworkspace/.../Package.resolved`):

| Package | Version | Used for |
| --- | --- | --- |
| `vapor` | 4.104.0 | in-app WebDAV/Web manager + server installer (`VexSign/Backend/Server`) |
| `nuke` | 12.8.0 | image loading |
| `zip` (marmelroy/Zip) | 2.1.2 | archive (de)compression |
| `zipfoundation` | 0.9.20 | ZIP operations |
| `swcompression` | 4.8.7 | compression helpers |
| `licenseplist` | 3.27.1 | license text build tool |

(plus transitive SwiftNIO/certificates/crypto pins)

**Non-Xcode components** (out of scope for the Xcode build, in scope for
repo hygiene):

* `server/` — Python backend (Vapor-like repo host), tested by
  `server-tests.yml` (pytest).
* `cloud-signing/` — Node/TypeScript service, tested by `ecosystem.yml`.
* `Makefile` — device Release build + ad-hoc signing pipeline (`make`).
* `tools/`, `update-repo.sh`, `app-repo.json`, `repos.json` — repository tooling.

---

## 3. Source statistics

| Area | Swift files | Notes |
| --- | --- | --- |
| `VexSign/` (main app) | ~380 | `VexSign/` + `VexSignTests/` ≈ 65,300 lines total |
| `VexSignTV/`, `VexSignVision/`, `VexSignWatch/`, `VexSignWatchWidgets/` | mirror sources | companions mirror the iPhone app (see `docs/PLATFORMS.md`) |
| `AltSourceKit/`, `NimbleKit/` | local packages | ~24k lines |
| **Total (all targets + local packages)** | **434** | |

Main app subsystem layout (`VexSign/`): `Analytics`, `Backend` (AppIntents,
CloudSigning, Companion, Observable, Server, Storage),
`CertificateDashboard`, `CloneWizard`, `Companion`, `Discovery`,
`Ecosystem`, `Extensions`, `OTA`, `RepositoryBuilder`, `RepositorySync`,
`Resources`, `Security`, `Utilities` (FR facade, Handlers incl.
`SigningHandler`, `ZsignHandler`, `TweakHandler`, `ArchiveHandler`,
`BackupCrypto`, `IPAExplorer`), `Views`.

---

## 4. Build / test / warning status

* **Build status (Phase 0):** not run locally (impossible — §1). The
  pristine-state build is validated by CI on push/PR of this branch
  (see §7 results).
* **Test status (Phase 0):** not run locally. Existing suite:
  7 files in `VexSignTests/` (~1,370 lines, ~50 test methods) covering
  companion/widget payloads, ecosystem contracts, import/installation
  helpers, integrity/parsing, provisioning/entitlement logic,
  stability/architecture invariants. **No CI job executes it yet** (§1 gap).
* **Compiler warnings:** gated by
  `.github/build-warnings-baseline.json` (Xcode 26.3, generated 2026-09-20).
  New first-party warnings fail `build-check`; the baseline may only shrink.
* **Lint:** `.swiftlint.yml` present; `make lint` auto-fixes PRs
  (non-blocking).

---

## 5. Static scan — crash/concurrency risk census (record only)

Counts across `VexSign/`, companions, `VexSignTests/`, `AltSourceKit/`,
`NimbleKit/` (Swift files), as of baseline commit:

| Pattern | Count | Assessment |
| --- | --- | --- |
| `try!` | 4 | 2× production (`ServerInstaller+TLS.swift:20-21` — Vapor bootstrap, guarded init path), 2× tests (`StabilityAndArchitectureTests.swift:218-219` — encode/decode round-trip that cannot realistically fail, but should use `XCTUnwrap`-style handling). |
| `as!` | 5 | 3× production in `VexSignApp.swift:587,594,603` — `BGProcessingTask`/`BGAppRefreshTask` casts are safe **by construction** (the `BGTask` subclass is chosen by the class passed to `BGTaskScheduler.shared.appTasks`), but should be `as?` + typed failure handling; 2× in companion test helpers. |
| `fatalError(` | 2 (+1 in comment) | `Storage.swift:110` — "Core Data unrecoverable" path: a **recoverable** corruption condition that today crashes. `DownloadOverlaySheetViewController.swift:25` — `init(coder:)` stub (NSCoding never exercised; low risk). |
| `preconditionFailure(` | 0 | — |
| Force unwraps (`x!.`, `x!(`, `x![`) | ~20 real | Notable production sites: `ServerInstaller+Compute.swift:61`, `ServerInstaller+TLS.swift:160,181` (ifaddr walk), `AppInstaller.swift:125,193,275` (`Bundle.main.bundleIdentifier!`), `DownloadManager.swift:666,675` (`session!`), `SelfUpdateManager.swift:184`, `ArchiveHandler.swift:92` (`_app.name!` / `_app.version!`), `BackupCrypto.swift:48,72`, `ResetView.swift:179`, `SourceAppsView.swift:288`, `SourcesAddView.swift:188` (`sourceURL!`), `TweakExtractionView.swift:324` (`addedIds.first!`). |
| `Task.detached` | 27 | Widely used to hop blocking file/archive/crypto work off the main actor (ArchiveHandler, IPAWorkspace, P12Cracker, StorageManager, BackupManager, AppInstaller, FR, …). Each must be checked for: unstructured lifetime, missing cancellation, captured non-Sendable state. This is the primary Phase 1 surface. |
| `DispatchQueue.main` | 109 | Legacy threading; fine where confined, but each site should keep MainActor isolation of UI state. |
| `DispatchQueue.global` | 20 | Same as above. |
| `withCheckedContinuation` (incl. unsafe) | 10 | Must verify single-resume + error + cancellation paths (Phase 1). |
| `NotificationCenter` uses | 43 | Check observer add/remove pairing for leaks (Phase 1). |
| `Timer(` | 1 | Check invalidation. |
| `@MainActor` annotations | 157 | Good base; audit for missing annotations on UI-facing ObservableObjects. |
| `actor` declarations | 5 | Existing actor-isolated services to extend, not replace. |
| `TODO/FIXME/HACK` in Swift | 0 | — |

---

## 6. Existing stabilization work (do not regress)

The repository already contains a prior hardening pass that this project
builds on:

* `docs/SECURITY_REVIEW.md` — archive-extraction safety (path traversal,
  symlink escape), HTTPS-by-default source policy (`SourceURLPolicy`),
  diagnostics redaction. Covered by
  `StabilityAndArchitectureTests` + `EcosystemTests`.
* `docs/FEATURE_STATUS.md` — setting→persistence→consumer registry enforced
  by `StabilityAndArchitectureTests.testFeatureStatusRegistryCoversCriticalPipeline`.
* Typed error/status models already exist in several subsystems
  (provisioning profile reader, certificate checks, `UnifiedTask`
  phase/failure-stage model, source health tracking).
* `VexSign/Security/` — `CertificateSecrets`, `SecureSecretStore`,
  `AppLockManager` (secret handling primitives).
* `VexSign/Utilities/ArchiveSafetyValidator.swift`,
  `ArchiveHandler.swift` (ZIP/AR safety), `IPAExplorer/IPAWorkspace.swift`
  (temporary workspace for IPA exploration).

Phase 1+ will **verify and extend** these, not reinvent them.

---

## 7. CI baseline runs for this branch

`build-check` compiles the VexSign scheme (Debug, unsigned) and fails on any
compiler error **and** on any first-party warning not in
`.github/build-warnings-baseline.json`. Because xcodebuild stops after the
first failing batch, each red run reveals only a *subset* of the errors —
Debug and Release runs surface disjoint batches, so several rounds were
needed to drain the queue. `quick-check`, `swiftlint --fix`, `syntax ·
duplicates · resources`, `cloud` and `ecosystem` were green throughout and
are omitted below.

| Round | Commit (head) | build-check Debug | Release | Errors surfaced (file:line) |
|-------|---------------|-------------------|---------|------------------------------|
| 1 | pristine `cf6b4bb` tree | **fail** (check 106170079789) | **fail** (check 106170080081) | OnboardingView missing `_importFirstApp`/`_stagePackage` + 3× `Label(verbatim:)` type; InstallQueue `.count`; AppUpdateChecker `String?` dictionary key; VexSignIntents+Actions CVarArg `String?` + 3× `@Parameter` inline-default (`extra argument 'wrappedValue'`); VexSignEntities `identifier` optionality |
| 2 | `45d1b62` | **fail** (check 106172669406) | **fail** (check 106172669501) | VexSignApp:113 unknown `flareAnimations`; UpdatesView:87/137 missing `@State _rulesApp`; PerAppUpdateRulesView:35/54/69/77/89 `NBSection` title + 4× `\$` on computed `Binding`; DiagnosticsCenterView:51/174/223 `'()' is not a View` + `systemImage:` vs `systemName:`; CertificateInspector:115 mutating member on `let` ×2; SourcePreferences:203–226 generic `T` not inferred ×5 |
| 3 | `150518b` | **fail** (check 106177012441) | **fail** (check 106177012353) | HomeView:51 missing `appearance`, :473 `startArchive` result unused; SourcesViewModel:75 `AltSource.isValid` no member; SourceHealthDashboardView:278 `Label(verbatim:)`; PerAppUpdateRulesView:36 `NBSection` title; AppearanceView:109/122/131 `$_fontFamily`/`$_fontScale`/`$_flareAnimations`; FeatureStatusView:25 `NBSection` title |
| 4 | `1507917` (+ empty/nudge) | **not triggered** — the `pull_request` event was lost in a GitHub connectivity outage on the sandbox; no check-run was created for the commit | same | — (see §7.1) |
| 5 | merge `4839eb3` (main `1ca6379`) | **fail** (check 106249665717) | **fail** (check 106249665865) | TaskCenterView:156 unused `stage`; StorageView:135/196 `StorageUsage.isEmpty` no member; SourceHealthDashboardView:287 second `Label(verbatim:)` |
| 6 | `59171ad` (round-5 fixes, rebased) | **fail** (check 106286543727) | **pass** (check 106286543211) | AppStoreHelper:73 `Locale.current.regionCode` deprecated iOS 16 (warnings-as-errors). First real-app error — all prior latent files compiled |
| 7 | `7601f29` (regionCode→`region?.identifier`) | **fail** (check 106290405492) | **fail** (check 106290405871) | StorageView:135/196 `isEmpty` no member **again** — lint-fix bot commit `5511684` (`empty_count` autocorrect) rewrote the round-5 `usage.count > 0` fix into `!usage.isEmpty` on a type without the member |
| 8 | `3841f37` (`StorageUsage.isEmpty` added) | **pass** (check 106293626725) | **pass** (check 106293626701) | — — but the bot then rewrote `isEmpty`'s body `count == 0` into self-recursive `{ isEmpty }` (`330010b`, no CI run) |
| 9 | `6a20b68` (`swiftlint:disable:next empty_count` guard) | **pass** (check 106297896146) | **pass** (check 106297896609) | ✅ **branch fully green** — bot made no follow-up commit; the disable comment is respected |

**Recurring latent classes** (fixed in bulk rather than one-per-round):
`Label(verbatim:)` (a `Text`-only label) appeared in 3 separate files across
3 rounds; `NBSection` was called without its required first title argument;
`startArchive` returns a `Download` and is not `@discardableResult`, so every
call site that discards it is a warning→error; ~137 app-target files call
`String.localized`/`LocalizedStringKey.localized` without importing
`NimbleExtensions` (added in `150518b`).

### 7.1 Operational notes

* **Round 4 was never built.** The `pull_request` synchronize events for
  `1507917`/`fed5853` did not reach the workflows (only the push-triggered
  `quick-check` fired), apparently because the sandbox's GitHub token was
  expired mid-push. An empty commit and a no-op workflow nudge confirmed
  the gap before the token recovered.
* **The owner was fixing `main` in parallel.** While this branch drained
  rounds 1–3, `main` moved from `cf6b4bb` to `1ca6379` with overlapping
  fixes (OnboardingView, `@Parameter(default:)`, InstallQueue `.count`,
  SourcePreferences type annotations). The branch was merged onto that main
  (`4839eb3`), resolving the PR conflict (`MERGEABLE`) and adopting main's
  versions where the two sides fixed the same error; this branch keeps the
  fixes main does not yet have (Core Data schema, the import sweep, and the
  round-3/4/5 view errors).
* **`main` is itself red.** The latest `main` build check (`1ca6379`) also
  fails, so a green `main` is *not* the target — a green *PR* is.

<!-- CI_RESULTS_PLACEHOLDER -->

---

## 8. Open questions / stop-condition flags from Phase 0

1. **Unit tests are not run in CI** — the suite exists but no job executes
   it. Fix in Phase 16 by adding an `xcodebuild test` job (simulator,
   unsigned). No code risk, only CI gap.
2. **Widget deployment target (26.0) > host app (16.0)** — verify intended
   behavior before touching (stop condition: "intended behavior unclear").
3. **`Storage.swift:110` fatalError** — Core Data unrecoverable error today
   crashes the app. Phase 2 must replace with recovery (backup + reset),
   preserving existing user data.
4. **Zsign is a submodule boundary** (`claration/Zsign-Package`). Per Phase 5
   rules it is treated as an external engine; any defect inside the submodule
   is a stop condition (dependency replacement).
5. **`VexSignApp.swift` background-task casts** — safe by construction but
   should be defensive (`as?`) in Phase 1/2.
6. **`lint-fix`'s `empty_count` autocorrect is not type-aware.** It rewrote
   `usage.count > 0` → `!usage.isEmpty` on a struct without that member
   (breaking the build), then rewrote the new `isEmpty` implementation's
   `count == 0` into a self-recursive getter. Mitigation, not config change:
   `StorageUsage` gained a real `isEmpty` whose body is pinned with
   `swiftlint:disable:next empty_count`. Any future count-comparison on a
   custom type will trigger the same bot rewrite — prefer compiling against
   the post-autocorrect spelling or pin it the same way.

## 9. Phase 0 verdict

Baseline **complete**. No production code was modified. The only file
created is this document. Proceed to Phase 1 (build + Swift 6 +
concurrency) with CI as the build/test oracle.
