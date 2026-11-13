# Comprehensive stability resolution

Bug fixing only: no new features, no redesign, no dependency or version changes. Nothing in this
change set has been committed, pushed or opened as a pull request.

**Read this first**

- The crash has a root cause that is established from source, not from a symbolicated trace:
  `RepositoryRow` read `source.value(forKey: "apps")` on an `AltSource`, an entity that has no
  `apps` property. That read is present in the reporter's build (tag `v1.2.1`, `e930ceb`) and is the
  only string-keyed read of a managed object in it. It is removed.
- **None of the Swift in this change set has been compiled or run.** The sandbox has no Swift
  toolchain and this task forbids pushing, so CI has not seen it. Local validation is a syntax
  parse and the repository's Python gates. The 13 new XCTest cases have never executed.
- `main` at `0d262ae` (PR #223) builds; its XCTest run had not finished when this was written.
- Nothing here has been validated on a device.
- The two attachments named in the request (`VexSign-main 2(1).zip`,
  `VexSign_crash_report_sanitized_20261111.txt`) were not present in the workspace. The crash
  details used are the ones quoted in the request and in the 2026-11-11 comment on issue #137.

## 1. Baseline

| Item | Value |
| --- | --- |
| Branch | `arena/4cd75b9b-vexsign` |
| Base commit | `0d262ae29108cbf8b947e3ff40b22b65a832653f` (`main`, merge of PR #223) |
| Reporter's build | VexSign 1.2.1 = tag `v1.2.1` = `e930ceb7e037dcc375db5959c2ed8eb3d4a1f338`, released 2026-11-07 |
| App version in tree | `MARKETING_VERSION = 1.2.1` (unchanged) |
| Toolchain in sandbox | none (no `swiftc`, no Xcode, no C++ toolchain for the vendored signer) |

CI state of the base commit and its predecessors:

| Commit | Workflow / run | Result |
| --- | --- | --- |
| `0d262ae` | CI [`43485642809`](https://github.com/raynmahbub/VexSign/actions/runs/43485642809) | quick gates success; **build success**; tests still running; concurrency report queued |
| `0d262ae` | Platform check [`43485642735`](https://github.com/raynmahbub/VexSign/actions/runs/43485642735) | one of three platform builds success; two not finished |
| `0d262ae` | Documentation `43485642824` | success |
| `0d262ae` | Combined native host | no run exists for this commit |
| `9ed6633` (PR #223 head) | CI `43483936798` | cancelled before build or tests finished |
| `9ed6633` | Combined native host `43483941236` | cancelled |
| `c60f98d` (PR #220) | CI `43460323088` | **tests success**; build job never got a runner ("not acquired by Runner of type hosted") |
| `c60f98d` | Combined native host `43460323188` | success |
| `d5ea397` | CI `43460000997` | tests failed: 8 of 1701 (see §2.3) |

So the last commit with a passing XCTest run is `c60f98d`. PR #223 was merged before its tests had
ever completed, and that is still true.

## 2. Issue register

Status vocabulary: *fixed and validated* · *implemented, not sufficiently tested* · *partially
implemented* · *reproduced, unresolved* · *not reproduced* · *cannot reproduce* · *obsolete*.
"Validated" is used only where a CI test run or a device run exists. No issue was closed.

### 2.1 Human-reported issues

| # | State | Subject | Status | Code | Evidence |
| --- | --- | --- | --- | --- | --- |
| 137 | open | Extension signing with a certificate whose profile does not cover the extension; plus the consolidated 2026-11-11 report | **Implemented, not sufficiently tested** | PR #223: `ProfileApplicationIdentifierMatcher`, `AdditionalProfiles`, `ZsignEngine`, `NestedBundleAudit`, vendored zsign multi-profile path | 70+ unit tests exist for matching, assignment and preflight; their run on `0d262ae` is unfinished; no device run. Keep open. Sub-items are in §2.2 |
| 130 | closed | Bug after signing; crash when adding to the library | **Not reproduced** from the issue text alone | Import path (`AppFileHandler`, `Storage.addImported`) | The library insert moved to a write context before 1.2.1. The crash described is not distinguishable from the Core Data crash in §3 without a trace |
| 123 | closed | "another to fix" | **Cannot reproduce** — the issue carries no steps I can map to code | — | — |
| 113 | closed | Signing | **Cannot reproduce** — same reason | — | Superseded by #137 |
| 149 | open | Package audit | **No action, by decision** (§6) | `Package.resolved` | No bug or advisory ties to any pending update |

### 2.2 Items in the 2026-11-11 report (issue #137 comment)

| Item | Status | What was found | Change |
| --- | --- | --- | --- |
| Crash, `valueForUndefinedKey:` in a SwiftUI update | **Root cause established from source; fix implemented, not compiled, not device-validated** | §3 | `AppStoreRepositoryRows.swift` |
| Apps / Repositories tab freezes or goes blank | **Explained by the crash for one path; otherwise not reproduced** | The crashing row is drawn on the Repositories list whenever a repository has no loaded catalogue. No second cause was found by reading the navigation code; a hang that is not this exception needs a device spindump | none beyond §3 |
| `0.9.9 → v0.9.9` offered as an update | **Fixed on `main` after 1.2.1; regression test added, not run** | 1.2.1 compared `split(".").compactMap(Int.init)`: `v0.9.9` → `[9, 9]`, `0.9.9` → `[0, 9, 9]`, 9 > 0. Replaced by `VersionOrder` in `fde7b0e` (2026-11-10). Three text comparisons of an "ignored version" and the self-update comparator still bypassed it | `VersionOrder.isSame`; `AppUpdateChecker`, `PerAppUpdateRules`, `GitHubSubscriptionStore`, `SelfUpdateManager.compare` |
| ~500 MB IPA import crashes | **Not reproduced; one memory defect found by inspection and fixed** | Extraction is already streamed (256 KiB buffers) and staged. Hashing was not bounded: see §4 | five read loops |
| Repository refresh message does not say which repository | **Implemented, not compiled** | Per-repository reasons already exist in Source Health; the banner said "some repositories" | `RepositoryRefreshNotice` |
| Signing panel stays open after success | **Plausible cause fixed; not proven on device** | With auto-show logs on, closing the sheet depended solely on the log sheet's `onDismiss` | `SigningView` fallback |
| Install panel stays open | **Implemented on `main` since 1.2.1; not device-validated** | Prompt, verification and monitoring deadlines plus `_dismissFinishedQueue` (PRs #220, #223). No further hole found | none |
| Entitlement editor | **Two defects fixed; not compiled** | §5 | `EntitlementsManager`, editor |
| One-Tap Install / installed state | **Finding recorded, not changed** | §7.1 | none |

### 2.3 Automated failure issues

43 issues were opened by `repo-maintenance.yml`, one per failing workflow run on `main`. They are
never closed by automation, so most describe commits that later commits already repaired.

| Group | Issues | Cause | Status |
| --- | --- | --- | --- |
| CI, tests only | #136, #143, #214, #215, #218, #222 (open); #115, #126, #128 (closed) | Real test failures. Latest, `d5ea397` (#222): 8 of 1701 — `testLegacy32BitImageIsParsedWithTheSmallerHeader`, `testFindingsAreSortedByRowThenCode`, `testFactsOfARealBundleAreAvailable`, three signing-method availability expectations. `a4e6035` (#218): `testDeletedSourceDoesNotReappearAfterFetch` ("date is a required value"), two concurrent-write count tests | **Obsolete for the commits named**: tests pass on `c60f98d`. Whether `0d262ae` is green is unknown |
| CI, build and tests | #148, #159, #172, #177, #192, #199, #201, #202, #204, #205, #206, #210, #211 (open); #118 (closed) | Compile errors on intermediate commits (both jobs fail together) | **Obsolete**: `0d262ae` builds |
| CI, quick gates | #156, #161 | Gate failures on intermediate commits | **Obsolete**: gates pass on `0d262ae` |
| Platform check | #178, #180, #195, #217, #221 | tvOS / visionOS builds; #221 lists no failed job (runner not acquired) | **Not verified**: the `0d262ae` run is unfinished |
| Combined native host | #141, #147, #151, #164, #191 | Build failures on intermediate commits | **Obsolete** as of `c60f98d` (success); no run on `0d262ae` |
| Release / maintenance / repository update | #98, #103, #104, #120, #101, #109, #97, #107 (all closed) | Release and bot workflows | **Obsolete** |
| Upstream radar | #30, #32, #33, #34, #35, #45 (closed) | Not bugs | **Obsolete** |

Recurring non-code cause: hosted macOS runners are frequently unavailable; jobs sit queued for
20–60 minutes and are sometimes abandoned. Such a run is reported as a failure and gets an issue.

### 2.4 Pull requests

| PR | Result | Note |
| --- | --- | --- |
| #133 | not re-audited in this pass | — |
| #220 (`c60f98d`) | merged; tests passed on its merge commit | The only one of the three with a completed test run |
| #223 (`0d262ae`) | merged; builds; tests unfinished | Merged with checks pending |

## 3. Crash investigation

**Signature (from the request):** `-[NSManagedObject valueForUndefinedKey:]` raised during a
SwiftUI view-graph update; iPhone 17 Pro; iOS 27.2 / 27.2.1; VexSign 1.2.1; 20 crashes.

**Method.** `NSManagedObject` raises that exception in one situation: key-value access with a
string key that is not a property of the object's entity. Typed `@NSManaged` accessors cannot do
it. So the search was for string-keyed access to managed objects, in the tree as it was at the tag
the reporter ran.

**Result at `v1.2.1` (`e930ceb`):**

```
VexSign/Views/TabView/AppStoreRepositoryRows.swift:83   let count = repository?.apps.count ?? source.appsCount
VexSign/Views/TabView/AppStoreRepositoryRows.swift:202  var appsCount: Int {
VexSign/Views/TabView/AppStoreRepositoryRows.swift:203      (value(forKey: "apps") as? Set<NSManagedObject>)?.count ?? 0
```

- `source` is an `AltSource`. At that tag, and today, the entity has exactly `date`, `iconURL`,
  `identifier`, `name`, `sourceURL`. There is no `apps` attribute or relationship. The model file
  did not change between `v1.2.1` and `0d262ae`.
- Line 83 is inside `RepositoryRow.body`. The right-hand side runs only when `repository` is nil —
  the catalogue for that repository is not in memory: first launch before the fetch returns, no
  network with no saved snapshot, or a repository that fails to load.
- It is the only `value(forKey:)` on a managed object in `VexSign` and `NimbleKit` at that tag. The
  other string-key hits are `InstalledAppProbe` (an `LSApplicationProxy`, guarded by
  `responds(to:)`) and `NBVariableBlurView` (a `CAFilter`). Sort descriptors and predicates use
  `sortIndex`, `uuid`, `identifier`, `date`, all of which exist.
- The line was introduced on 2026-09-20 (`6c3bb40`) and survived the `4851b27` file split.

That is: undefined key, on an `NSManagedObject`, evaluated in a SwiftUI body, on a screen the
reporter says misbehaves, under a condition (repository not loaded) that is intermittent — which is
why most sessions do not crash.

**What is not proven.** There is no symbolicated frame that names `RepositoryRow.body`. No dSYM,
build artefact or original `.ips` was available, and the sanitized report file was not in the
workspace. The conclusion rests on there being a single candidate in the shipped source. If the
attached report contains a frame from another view, this section needs revisiting.

**Fix.** The read is deleted. The row shows a count only when the decoded catalogue is present
(`RepositoryRow.appCount(in:)`), and no count otherwise. No Core Data attribute was added, the
store is not reset, no migration is involved, and no exception is caught or suppressed.

**Regression tests** (`StabilityRegressionTests`): the `AltSource` entity's property set is
pinned, so adding `apps` later is a deliberate act; a repository without a catalogue has no count;
every string key the storage layer uses is a real property of its entity.

## 4. Large IPA import

Read end to end: `FR.handlePackageFile` → `AppFileHandler.copy / extract / move / addToDatabase`
→ `IPAExtractor`.

- The transaction is already staged: work happens under a temporary directory, the payload is moved
  into the library only after extraction and CRC checks, the database row is written last, and
  `clean()` removes a moved-but-unregistered payload.
- Extraction streams through a 256 KiB buffer and checks free space against expanded size.

One defect was found. Five loops read a file with `FileHandle.read(upToCount:)` and no autorelease
pool: `FileIntegrity.sha256` (download verification, 1 MiB chunks), `BackupVerification.digest`,
`ReleaseManifestVerifier.sha256`, `CompanionIPAStager`, `CloudUploadBody.write`. The buffers that
call returns are autoreleased, and these loops run on background queues and tasks where nothing
drains a pool until the loop ends, so peak memory approaches the file size. `BackupCrypto` already
wraps the same read in `autoreleasepool` for this reason. Each loop now drains a pool per chunk.

**Limits of this finding.** It was not measured: there is no device, and no memory graph. It
applies to a downloaded IPA that carries an integrity expectation, and to the other four paths; a
file imported from Files is not hashed, so if the reporter's crash was a Files import this change
does not explain it. That case stays *not reproduced* and needs a jetsam report or an Instruments
trace of a 500 MB import.

## 5. Other changes

| Area | Defect | Change |
| --- | --- | --- |
| Version comparison | An ignored version was compared as text, so ignoring `0.9.9` did not ignore `v0.9.9`; `SelfUpdateManager.compare` treated `1.3.0-beta` as equal to `1.3.0` and a `V`-prefixed component as 0 | `VersionOrder.isSame`; the self-update comparator defers to `VersionOrder.precedence` and keeps its old arithmetic only for strings that are not versions |
| Repository refresh | Banner said "Some repositories couldn't be refreshed" | Names up to two repositories and counts the rest; reasons stay in Source Health (no new health store) |
| Signing completion | The sheet closed only from the log sheet's `onDismiss` when logs were showing | After 0.8 s the pending hand-off is taken if it is still there; both paths take-and-clear, so it runs once |
| Entitlement editor | "Add Preset" replaced existing values although the preset contract says existing keys win — adding *App Groups* overwrote the user's groups with a placeholder | `EntitlementsPreset.merging(into:)` |
| Entitlement editor | A JSON import containing `null` was accepted, after which every save failed with only a log line; the screen kept showing edits that were not stored | Such a file is refused at import; `save` reports failure and the editor shows it |
| Feature status | Per-extension profiles (PR #223) had no registry entry, so nothing marked them unvalidated | Entry `extension-profiles`, status `needsDevice` |

Files: `AppStoreRepositoryRows.swift`, `AppStoreView+Discover.swift`, `VersionOrder.swift`,
`AppUpdateChecker.swift`, `PerAppUpdateRules.swift`, `GitHubSubscriptionStore.swift`,
`SelfUpdateManager.swift`, `FileIntegrity.swift`, `BackupVerification.swift`,
`ReleaseManifestVerifier.swift`, `CompanionIPAStager.swift`, `CloudUploadBody.swift`,
`EntitlementsManager.swift`, `SigningEntitlementsEditorView.swift`, `SigningView.swift`,
`FeatureStatusRegistry.swift`, `Localizable.xcstrings` (3 keys), and the new
`VexSignTests/StabilityRegressionTests.swift` (13 tests).

## 6. Dependencies (#149)

No dependency was changed.

| Package | Pinned | Available | Decision |
| --- | --- | --- | --- |
| vapor | 4.122.3 | current | — |
| Zip | 2.1.2 | current | — |
| Nuke | 12.8.0 (exact) | 13.2.3 | Major version; no bug in this audit traces to Nuke |
| LicensePlist | 3.27.1 (exact) | 3.28.3 | Build-time tool only |
| SWCompression | 4.8.6 | 4.8.7 | No reported defect in the `.deb` path |
| ZIPFoundation | 0.9.19 | 0.9.20 | Extraction is the import path; no failure was tied to the library. Worth reading its changelog before the next release, not upgrading blind |

## 7. Not done, and why

### 7.1 Findings left unchanged

- **"Download, Sign & Install" changes global settings.** Choosing it from one app's menu
  (`DownloadButtonView`) calls `CleanupManager.setOneTapInstall(true)`, which permanently turns on
  auto-sign, install-after-sign, delete-after-install and clear-cache. Every later plain "Download"
  then signs and installs too. This may be what the report means by One-Tap state, but the comment
  in the code says it is intended, and making it per-download is a behaviour decision. Yours to
  make.
- **GitHub subscriptions and re-published releases.** `reviewable(_:for:)` lists releases until it
  meets the tracked release id. If that release is deleted and re-published under the same tag, the
  id never matches and every cached release is offered. Derived from the code, not reported, not
  changed.
- **Swipe-to-delete in the entitlement editor skips the confirmation** that the trash button
  shows. Inconsistent rather than broken.

### 7.2 Scope not covered in this pass

- The 16 debugging questions for #137 were not answered one by one, and the PR #223 signing path
  was not re-verified beyond listing its tests. The specific tests requested for wrong team,
  certificate-not-in-profile, expiry, missing key and final-IPA verification were not checked for
  existence individually.
- `docs/changes/*.md` and `docs/research/signer-file-audit-2026-11.md` were not re-read line by
  line against the code. Nothing touched here overlaps the signer, the install-evidence logic or
  the Undo work those documents cover.
- PR #133 was not re-audited.
- The navigation code was read for a second freeze cause without finding one; that is not the same
  as showing there is none.

## 8. Validation

| Check | Commit / tree | Result |
| --- | --- | --- |
| Syntax parse (tree-sitter) of all 17 changed Swift files | working tree on `0d262ae` | parses — this is not a compile |
| `quick_check.py` | working tree | pass (its Swift syntax step is skipped without `swiftc`) |
| `check-pbxproj`, `error-discipline`, `singleton-freeze`, `concurrency-discipline`, `check-docs`, `check-native-handoff`, `check-package-graph` | working tree | pass |
| `sync-strings.py --write` | working tree | 3 keys added |
| `git diff --check` | working tree | clean |
| iOS build | working tree | **not run** |
| XCTest | working tree | **not run** |
| tvOS / watchOS / visionOS, native host | working tree | **not run** |
| Device | — | **not run** |

Compile risks I could not rule out by reading: closure type inference around the five
`autoreleasepool` loops, and main-actor isolation of `RepositoryRow.appCount` (declared
`nonisolated` for that reason).

## 9. Device acceptance

Nothing below has been run. The cases this change set makes worth running first:

| Case | Expectation |
| --- | --- |
| Repositories tab, airplane mode, fresh install with one repository added | List draws, row shows no count, no crash |
| Repositories tab with one unreachable and one healthy repository | Banner names the unreachable one; healthy row shows its count |
| Installed `0.9.9`, repository lists `v0.9.9` | No update offered on the detail screen or in Updates |
| Ignore version `0.9.9`, repository lists `v0.9.9` | Stays ignored |
| Download a ~500 MB IPA that carries a SHA-256 | Memory stays flat during "Verifying"; import completes |
| Import a ~500 MB IPA from Files | Completes; if it does not, capture the jetsam report |
| Sign with "show logs automatically" on | Sheet closes after success, once; install starts once if enabled |
| Entitlements: set App Groups, then Add Preset → App Groups | Own groups kept |
| Entitlements: import a JSON file with a `null` value | Refused with a message |
| App with a widget, certificate with an added extension profile | Installs; widget launches (the open question in #137) |

## 10. Prepared pull request

**Title:** `fix(stability): resolve reported crashes and complete existing workflows`

**Body:**

> Fixes the Core Data crash reported against 1.2.1 and several defects from the same report.
> Refs #137 (not closed by this PR).
>
> - **Crash:** `RepositoryRow` read `value(forKey: "apps")` on `AltSource`, which has no such
>   property, whenever a repository's catalogue was not loaded. Removed; the count comes from the
>   decoded catalogue only. Root cause established from the `v1.2.1` source; no symbolicated trace
>   was available.
> - **Versions:** ignored-version rules and the self-update comparison use the shared
>   `VersionOrder`, so `0.9.9` and `v0.9.9` are one version everywhere.
> - **Memory:** five chunked file-read loops drain an autorelease pool per chunk.
> - **Repositories:** the saved-copy banner names the repositories that failed.
> - **Signing sheet:** closes after success even if the log sheet's dismissal callback is lost.
> - **Entitlements:** presets no longer overwrite existing values; unsaveable JSON is refused and
>   a failed save is reported.
> - **Feature status:** per-extension profiles listed as needing device validation.
>
> **Not validated:** written without a Swift toolchain. This PR's CI run is the first build and
> the first execution of `StabilityRegressionTests`. No device testing.

**Suggested commits:**

1. `fix(store): stop reading an undefined Core Data key in the repository row`
2. `fix(updates): compare ignored and self-update versions with VersionOrder`
3. `fix(io): drain an autorelease pool per chunk when reading large files`
4. `fix(store): name the repositories behind the saved-copy banner`
5. `fix(signing): close the signing sheet when the log sheet's callback is lost`
6. `fix(entitlements): keep existing values on preset merge; report failed saves`
7. `docs(stability): engineering report and feature-status entry for extension profiles`
