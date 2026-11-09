# VexSign: upstream comparison and reliability work

> Latest validation: full macOS unsigned build, IPA checks and simulator XCTest
> passed for `3ae30e2` in [CI run 42602611745](https://github.com/raynmahbub/VexSign/actions/runs/42602611745).
> See the [completion handoff](remaining-roadmap-implementation.md) for superseding
> implementation details and remaining physical-device acceptance. Earlier local-only
> validation notes below are historical checkpoints, not the final CI status.


**2026-11-08 — implementation branch, not device acceptance.**

## Scope and evidence

Reviewed selected feature modules from 17 public repositories, compared with the
local VexSign checkout, and retrieved all **38 workflow YAML files** listed by
those repositories' pinned recursive Git trees for workflow-policy comparison.
The [inventory](upstream-review-inventory.json) records exact revisions, modules
and workflow paths. Refer to the [integration assessment](public-signer-integration-assessment.md)
for pinned links and earlier decisions.

**Not completed:** a line-by-line security audit of every file/submodule, every
script invoked by those workflows, all release binaries, runtime benchmarking or
iOS device testing. Workflow retrieval/pattern inspection is not proof of CI
safety. Features from different forks overlap substantially; copying all managers
would make ownership, persistence and background behavior less reliable.

This batch preserves VexSign's identity and architecture. Required licenses,
provenance and copyright notices are not removed. Public GitHub access is not
permission to treat all source as newly written or freely relicensable.

## Project-by-project comparison

“Present” below means code exists, **not device-verified parity**.

| Reference | Useful reference area | VexSign comparison / action |
| --- | --- | --- |
| NuzProjects/Feather | GitHub releases, update subscriptions, signing UX | Manual GitHub IPA chooser added in this branch. Persistent GitHub sources/update tracking remains a separate feature; no claim of full fork parity. |
| BatSign (`8yy/BatSign`) | Automation, queue handling, install/build evidence | VexSign has automation, per-app rules and install confirmation. Fix admission/ownership first; validate identical-build and unknown-build cases before expanding automation. |
| SignOs (`ihateios/SignOs`) | Renewal scheduling, per-source/per-app update controls | Existing VexSign update rules and background automation overlap. Add a truthful per-app renewal-readiness report rather than copying certificate-expiry-based promises. |
| iPASide (`pwnapplehat/iPASide`) | Environment diagnostics, architecture/encryption inspection | Existing Setup Health/native inspection overlap. Windows services/USB tooling are not a jailed-iOS backend. Surface relevant facts through a shared preflight report. |
| ForgeSign (`Mesutcydev/ForgeSign-iOS`) | Read-only IPA preflight, explicit refresh capability, validated packaging | Useful design reference; license metadata remains unclassified, so no code copying. VexSign needs clearer refresh-readiness UX; packaging validation strengthened independently. |
| ProStore (`ProStore-iOS/ProStore`) | End-to-end progress and temporary workspace ownership | Existing VexSign workflow/lease infrastructure retained. Added unique download staging names. Do not adopt remote P12/password certificate checking. |
| Feather (`claration/feather`) | Core certificate signing and options | Already present; shared option normalization and truthful coverage checks addressed in this branch. Minimum-OS preview added, explicitly not a compatibility guarantee. |
| FeatherPlus | Backup/transfer convenience | VexSign already has encrypted selective backups. Cross-app format compatibility requires explicit schema, version, path, key and rollback rules—not copying app directories. |
| KSign (`Nyasami/Ksign`) | Library sign/install actions | Existing adapted workflow actions retained; no duplicate menus or global-default changes. |
| RyukSign | Downloads, tweak management, Live Activities, file transfer | Existing VexSign counterparts retained. Download concurrency, task ownership and size-scanning work is more useful than adding another manager. |
| KorSign | Import controls, safe exports, pairing compression | Existing adaptations/controls retained; device benchmarks still needed before advertising speed gains. |
| MySignReincarnated | Persistent history/thumbnails | VexSign task history and icons already cover this area. Prefer crash recovery improvements over adding another history database. |
| MySign | Browse/download/history UX | Reference only while licensing remains unclear. No source copied in this batch. |
| Odysseus | Certificate diagnostics / revocation evidence | VexSign has consent-based inspection and verified OCSP handling. Preserve unknown versus valid and explicit network disclosure. |
| NexStore | Certificate-status UI and NovaDNS | VexSign already has local status/NovaDNS counterparts. Reject the inspected remote checker that transmits the P12 and password; DNS filtering is not a revocation guarantee. |
| SideStore | Apple-ID provisioning and refresh infrastructure | Existing experimental NativeSigning/embedded path remains gated. Full native-account/CMS acceptance is not established by this comparison. AGPL obligations apply to code adoption. |
| LiveContainer | Guest/container runtime and lifecycle | Existing pinned host prototype remains experimental. Guest app execution is not equivalent to normal installation; no silent pin bump or acceptance promotion. AGPL obligations apply. |

The latest user list does not provide additional exact repositories for “etc.”;
those are not assumed to be inspected.

## Findings addressed in the current coding batch

These were identified through static source inspection. Fixes and tests are
implemented, but their Swift compilation/runtime behavior still needs Apple CI.

| Priority | Finding and consequence | Change / acceptance criterion |
| --- | --- | --- |
| P0 | `DownloadManager.startDownload` announced the parallel limit but still resumed a new task. | Suspended tasks now enter FIFO admission; cap applies to new and resumed tasks. Test multiple URLs at cap 1, slot release, pause/resume and Stop All. |
| P0 | Duplicate URL requests called resume on an already running task, replacing the tracked task pointer. | Active/queued ownership is idempotent; suspended transfers retain their task on pause/resume. An old callback cannot release a replacement task's slot. Repeated taps must produce one transfer. |
| P1 | `AppUpdateChecker.precomputeAllUpdates` passed `FetchedResults`/managed objects to `Task.detached`. | Capture immutable library and matching-preference snapshots on the main actor; workers receive values only. Cancel stale workers and prevent older generations from publishing over newer scans. Test with Core Data concurrency diagnostics on Apple CI. |
| P1 | Library size sorting recursively measured both apps inside each comparator call on the UI path. | Directory measurements now run off-main, once per snapshot/identity, and sorting uses cached integers. Verify responsiveness with hundreds of apps; date/identity changes and view re-entry refresh the snapshot. |
| P1 | Different downloads with the same suggested filename used the same staging destination and removed any existing file there. | UUID-prefixed, bounded, sanitized filenames; moving does not delete another download. Test concurrent same-name IPAs, long Unicode names and traversal-looking suggestions. |
| P1 | Resumed transfers bypassed charging/Wi-Fi admission checks; the network monitor's shared Boolean had unsynchronized access and initially allowed unknown connectivity. | One admission policy for start/resume/drain; monitor access synchronized and unknown path blocks Wi-Fi-only admission. Test policy changes while queued/paused. This does not certify every mid-transfer network transition. |
| P2 | A successfully verified source SHA-256 caused a second full-file hash solely for logging. | Reuse the verified digest for the audit log; undeclared hashes and explicit mismatch overrides still get independently audited. Never reuse the expected digest as actual evidence after a mismatch. |
| P1 | Packaged byte integrity was not fully covered by checking staged app/version metadata. | Release IPA checks now reject duplicate ZIP member names and CRC failures. CI's disposable device IPA gets the same container check before checksums/upload. A corrupt fixture must fail even if its Info.plist is valid. |

Also retained the earlier four bug fixes in this branch: typed file-protection
assertion; unknown nested coverage reporting without changing which entries block;
single-pass protection traversal; and shared identifier normalization across
preflight/signing/plist updates. These are implemented, not yet device-accepted.

### Important limitations of the download changes

Network task admission and URLSession delegate callbacks are serialized on the
main queue. Heavy archive extraction and hashing remain worker operations. Queue
membership is in-memory: this batch does not introduce a durable transfer journal
or certify force-quit/background restoration. Task suspension preserves in-session
ownership; resume-data persistence on termination remains best effort because iOS
does not guarantee that termination callbacks run. System URLSession networking,
import cancellation and auto-signing still have separate owners.

## Features to implement next, in order

1. **Per-app refresh/renewal readiness.** Explain retained source availability,
   credential availability, profile expiry/scope, bundle identity, device coverage
   and usable install transport. Distinguish “can prepare,” “needs interaction,”
   “can reinstall,” and “verified update-in-place.” Do not infer readiness from
   certificate expiry alone, or promise app-data preservation without testing.
2. **Unified signing preflight.** Surface encrypted executable detection, supported
   architectures/platforms, Mach-O minimum OS versus plist minimum, nested bundle
   requirements, entitlement compatibility and disk-space requirements together.
   Reuse existing native inspection where applicable; do not claim the default
   Zsign path has every native inspection gate until its call sites are verified.
3. **GitHub source subscriptions.** Persist an explicit repository/release/asset
   identity, conditional caching and rate-limit/backoff state. Require user choice
   when assets are ambiguous; do not auto-switch apps based on filename similarity.
   Honor per-app update preferences. Manual chooser is not this full feature.
4. **Durable download/verification/import recovery.** Persist transfer ownership
   and retry points; give verification its own cancellable, single-flight owner.
   Fault-inject process death, storage exhaustion, retries, hash failure, cleanup
   and relaunch. Existing task-history persistence alone is not a transfer journal.
5. **Repeatable performance fixtures.** Benchmarks for large IPA import, nested
   apps, many small files, tweak injection, hundreds of library entries and large
   source catalogs. Track elapsed/p95 time, peak memory, bytes read and cancellation
   latency. Establish real-device baselines before setting numerical targets.
6. **Validated backup portability.** Explicit supported import formats, credential
   consent, bounds, collision/rollback tests and migration reports. No blanket
   “restore everything from every signer” promise.

## Remaining fixes / risks to investigate before calling this stable

- **Verification single-flight/cancellation:** `handlePackageFile` only guards
  `isImporting` before asynchronous verification; verify overlapping lifecycle
  retries cannot start multiple verification/import workers. Cancellation should
  prevent a late verdict from resurrecting a removed download.
- **Source-independent maintenance:** `BackgroundAutomation.run` returns at
  `noSources` before later profile-renewal/cleanup work. Decide and test independent
  maintenance scheduling; preserve native readiness gating.
- **Update matching scalability:** workers now avoid managed objects, but matching
  still scans library arrays and may match by configurable names. Index exact
  identifiers and handle ambiguous matches explicitly before automated updates.
- **Network policy transitions:** validate Wi-Fi→cellular, charging changes,
  monitor startup, resumed-data requests and session restoration. Admission checks
  are not proof of continuous enforcement on every restored URLSession task.
- **Progress callback overhead:** the existing delegate creates short background
  assertions per data chunk. Measure energy/callback volume and compare a single
  owned assertion with throttled progress publication; do not remove required
  lifecycle ownership without device tests.
- **Size-cache invalidation:** in-place file changes without a stored date/identity
  change can leave the current view's measured sizes stale until view re-entry.
  A shared mutation-generation signal is a follow-up, not solved by sorting alone.
- **Apple validation:** all current Swift edits require compilation/tests; native
  provisioning, CMS and host runtime remain subject to their existing device gates.

## Workflow comparison and retained decisions

Useful upstream patterns observed include Nuz's portable core checks, ForgeSign's
native invariants plus simulator/device packaging validation, iPASide's separate
engine/UI/platform tests and helper-binary inspection, and KorSign's staged release
validation. VexSign already has separated portable/native/service jobs, pinned
input/checksum controls, warning gates, simulator testing, build-only artifacts,
release provenance and host-build isolation. Those should be retained, not replaced
with simpler build-and-upload workflows.

**Added here:** CRC/duplicate-member checks on the actual IPA before CI artifact
upload, and inside release IPA validation. Regression fixtures cover corruption
outside the plist and duplicate archive entries.

**Not adopted:** destructive cleanup of release/history records; bundled shared TLS
private-key packs; disabling checksum/CMS validation; broad cache reuse across
incompatible SDK/native inputs; copying Windows setup steps into an iOS workflow;
or treating an unsigned artifact upload as proof that simulator/device tests passed.
No action versions were blindly upgraded based on another project's YAML.

Workflow-policy inventory is not an audit of every referenced action, reusable
workflow, shell script or secret boundary. Pinning and least privilege still need
individual review. Third-party attribution stays in the existing notices/register.

## Build and device handoff

Finish coding/review first, then run the existing build and simulator jobs—do not
publish a release just to obtain a test IPA. This sandbox has no Swift/Xcode, so it
cannot produce an Apple build. Portable checks and ZIP fixtures are not a substitute.

On a physical device test, in order:

1. Cap=1 with three downloads; repeated taps on the same URL; pause/resume/Stop All.
2. Two servers supplying the same filename; cancel one without damaging the other.
3. Wi-Fi-only, Game Mode and charging policies on new, paused and queued transfers.
4. Background/foreground, network loss, force-quit/relaunch and partial resume data.
5. Rapid source refreshes while library entries change; run Core Data concurrency diagnostics.
6. Size-sort/scroll a large library; mutate/delete apps during measurement.
7. Import/sign/install an authorized IPA with extensions; verify failure/cancel logs
   and confirm installed identity/version, not just transfer progress.
8. Repeat with integrity mismatch, insufficient storage, expiry and profile mismatch.

Record device/iOS/build identity, actual outcome, peak memory and timings. Only
promote native capabilities after the relevant matrix passes; never weaken
`requireCMSVerification()` to obtain a green run.

### Local validation result for this batch

After the coding changes, `make verify` passed, including 41 workflow-policy tests,
the corrupt/duplicate ZIP fixtures, 31 embedded-container portable tests and 74
native-preparation Python tests. String-catalog coverage and `git diff --check`
passed. An initial portable packaging fixture failed because it did not provide
`GITHUB_WORKSPACE`; the fixture now supplies that actual Actions environment value
and the full portable gate was rerun successfully.

No Swift compiler or `xcodebuild` is installed here. The new download-admission,
library-snapshot and GitHub-import XCTest cases have **not** run, and no Apple IPA
was built or device behavior verified. No release was published and no capability
was promoted by this work.

## Follow-up: owned verification and per-app retained-input readiness

Implemented after the prioritized review:

- Each `Download` has a lock-protected verification owner. The main queue claims it before scheduling any hash work; duplicate lifecycle retries cannot start another verifier or importer. Cancellation is terminal, and verdicts must present the current token to hand off exactly once.
- SHA-256 streaming now supports throwing checkpoints between 1 MiB chunks. Pause/cancel use the existing import control. Cancelled verification waits for the worker to close its handle before removing its staged file and row; late verdicts cannot show a mismatch alert or restart import.
- Verification has an explicit phase in download UI and Live Activities, including paused verification. Hashing for audit evidence runs under the same ownership, rather than an independent uncancellable read.
- A mismatched download is retained by a manager-owned pending-decision entry (not just weak alert captures). Only that exact entry can accept one explicit override. Delete/cancel invalidate the decision. The audit log uses the computed digest, never a mismatched expected digest.
- Library app details now offer **Check retained renewal inputs**. The snapshot reports library bundle presence, saved settings, saved identity vs current-selection fallback, recorded expiry/revocation, and the selected installation method's existing prerequisite report. Checks run on explicit refresh, not on each SwiftUI body evaluation. No recursive bundle walk or private-key operation is added.
- This is deliberately not an automatic-renewal eligibility or native-capability promotion. A certificate record is not proof of private-key usability, profile compatibility, source freshness, update-in-place/data preservation, or successful installation. The existing repeat-sign review and native/CMS gates remain in place.

Added Apple-side tests for verification ownership, stale tokens, one-time mismatch decisions, terminal cancellation, per-chunk hash cancellation, synchronous manager ownership, and renewal evidence/fallback classification. These XCTest cases have **not** run here: this environment has no Swift/Xcode toolchain.

Portable validation: `make verify` passed after these changes; log: `/home/user/verification-readiness-verify.log`. Localization coverage and `git diff --check` passed. This is not an Apple compilation result. Device acceptance should include cancelling/pausing a large IPA during verification, repeated foreground/background transitions during hashing, both mismatch decisions, missing saved certificates, and changed installation settings followed by readiness refresh.

## Further roadmap implementation

See [remaining-roadmap implementation and acceptance handoff](remaining-roadmap-implementation.md)
for the subsequent maintenance, matching, policy, recovery, preflight, GitHub
tracking, backup-validation and performance-fixture changes. That status table
supersedes the corresponding investigation bullets above; its remaining
acceptance limits are intentional and must not be treated as completed tests.
