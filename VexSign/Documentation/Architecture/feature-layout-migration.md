# Feature-oriented source migration

## Repository-wide wrapper cleanup

The current [repository layout audit](repository-layout-audit.md) extends the
platform pass below to all source, service, package, resource, documentation,
test, tool and configuration owners. Twelve further project-owned wrappers are
flattened; only four exact Xcode/vendored-tool wrapper chains remain. Multi-child
parents, target/module identities, dependency locks and original migration
hashes are retained. The audit records every changed directory, current
validation and the unavailable Apple/Docker checks.

## Platform-root flattening (initial pass checkpoint)

Starting from `9513903b3f9604b8d8ce2d5e78d6eb6c46922c93`, app sources and assets
live directly in `VexSign/App/{iOS,TV,Vision,WidgetExtension}/`. Redundant
app-name directories and the widget's `Extensions` wrapper are removed.
`VexSign/App/Watch/{VexSignWatch,VexSignWatchWidgets}/` and
`VexSign/App/SharedPlatformInfo/` remain at their existing paths.

The four moves retain all **806 files**: 805 are byte-identical; the only content
edit inside the moved trees updates a source-path comment. Target/product names,
bundle identifiers, schemes, membership exceptions and runtime behavior are
unchanged. Xcode synchronized roots, all four iOS resource-library search paths
and bridge-relative includes follow the flattened layout. Plists, entitlements
and the bridge header remain centralized under `VexSign/Configuration/`.
CI filters, lint/coverage settings, preparation/source-reading fixtures,
documentation and path-based baselines use the new roots. Package-download
caches used by `make` follow its runner-local `VexSign/SourcePackages` directory,
not the source-tree layout. New layout regressions reject the removed wrappers.

Validation for this follow-up: `make verify`, portable Xcode metadata/input
checks and the original-Git preservation audit pass. The optional Swift grammar
comparison retains 25 pre-existing findings with no new signatures; it is not
Swift type checking. **No Apple build or `make test`/XCTest was run: macOS/Xcode
are unavailable here.** Earlier revision-specific CI/device results below do not
verify this layout follow-up.

The migration JSON retains its original revision, branch, original paths and
all 1,375 before-hashes as provenance; current destinations and derived evidence
follow the flattened tree. The separate root-layout history describes its older
stage and is not a current-path consumer.

## Signing/library checkpoint

The signing/library commit `bf063e7`, based on `8daf7e7`, contains the
[signing/library reliability follow-up](signing-library-reliability.md), including
shared signing readiness, authenticated component resolution, fresh signature
verification, compact Delete and transactional recovery. Its
[device checklist](../DeviceTesting/SIGNING_LIBRARY_ACCEPTANCE.md) is still pending.
The original inventory/hashes remain intact; the added/rewritten inventory and
preservation evidence are refreshed for this working tree.

Portable `make verify`, 36 native core regressions both normally and under
ASan/UBSan, independent plistlib interoperability, 14 identity/readiness/output
wiring checks passed at the recorded implementation checkpoint. Main integration
adds two negative/positive preservation fixtures (**27 total**) and reruns the
Cloud build/14 tests/contracts plus all **216 WebManager tests** on the updated
dependencies. One upstream Starlette/httpx deprecation warning remains.
Swift grammar checks are not type checking. **No local Apple build,
Objective-C++/Security execution, XCTest or device result exists for this candidate.**
Revision-specific CI results later in this document are historical; check new CI
against the exact integrated PR head. Publication and main integration have now
been explicitly authorized, preserving existing published commit history.

### Main dependency integration

The incoming base is `725a2769be00ad60542102f472bbb879c8136f86`. Its FastAPI,
AWS SDK and BullMQ updates are retained in the relocated service owners; the Cloud
lock and WebManager requirements match main byte-for-byte. The Cloud manifest keeps
the already-migrated command paths and otherwise matches main. The
[follow-up report](signing-library-reliability.md#main-integration-and-conflict-resolution)
records exact paths/hashes and the narrowly audited lock exception. Original
migration hashes and dependency-upstream provenance are not regenerated.

## Scope and source of truth

This change implements the physical source layout and consumed-boundary migration
from the [requested architecture](https://chatgpt.com/s/t_6af8130278148191bc92dd1663a4f27b).
It supersedes the earlier eight-root-only organization, not published URLs,
licenses, package pins, target identities or existing execution engines.

- **Branch:** `arena/bf87c593-vexsign`
- **Original revision:** `57d3aa65b0228071fa0d2589c232a00b5517ece2`
- **Original inventory:** 1,375 files; 1,322 relocated; 53 retain their locations.
- **Mapping:** [every original file, destination and before-SHA256](feature-layout-migration-map.json).
- **Preservation evidence:** [Git-blob and grammar comparison](feature-migration-preservation.json).
- **Decision:** [ADR-0001](../Decisions/ADR-0001-feature-layered-source-tree.md).
- **Current guide:** [architecture](ARCHITECTURE.md) and [dependency rules](dependency-rules.md).

All original files have unique existing destinations. The current byte-identical,
rewritten-text and added-file counts are recorded in the linked JSON preservation
evidence, independently compared with the original Git blobs. Added/rewritten
inventories include this working tree, without replacing any original file hash.
Rerun the audit after further edits.

## What changed

1. Main content is under `VexSign/{App,Packages,Services,Tests,Resources,
   Documentation,Tools,Configuration}`. The EmbeddedContainer integration and
   TV/Vision/Watch/widget companions are retained, not removed to fit a diagram.
2. The iOS app at `VexSign/App/iOS/` has App, Presentation, Application,
   Domain, Infrastructure, Platform, Security and Resources owners. Populated
   feature folders replace generic Views/Managers roots. Shared tab/navigation
   presentation remains separate from App routing/composition.
3. Bootstrap, lifecycle and composition have explicit owners. `AppContainer`
   injects the same adapters into the main view tree and independent windows.
4. Domain and Application are Foundation-only. The Library, repository/discovery,
   signing/preferences, certificates, installation/session/batch, files/archive,
   tweaks/entitlements, tasks/recovery, account, backup, cloud configuration,
   repository builder and companion views consume ports/use cases over existing
   implementations. Core Data objects and secret-bearing archive/account state
   do not become UI snapshots.
5. Xcode synchronized groups/membership exceptions, resources, package/header
   paths, build scripts, xcconfig inputs, automation filters, service Docker
   contexts and runtime paths follow the new tree. Target identities, setting
   values, package identities and pins are retained.
6. Validation tools and source-reading fixtures follow real implementation paths.
   A new source-regression suite runs in both `make verify` and CI. Portable
   checks are never substituted for native compilation or device evidence.

## Execution and lifetime safeguards

| Boundary | Ownership and failure behavior |
| --- | --- |
| Library and repository snapshots | Read/resolve on the owning executor; opaque store identity plus UUID/signedness checks. Every app projection, including statically typed signing/batch results and workspace reads, requires a nondeleted permanent row in the exact owning context before reading relationships; reject foreign/stale/temporary records; isolated updates do not save unrelated view edits; failed refresh keeps the last good snapshot. `SourceCatalogStore` remains the existing cache/coalescing owner. |
| Signing | Existing `SigningService`/pipeline/engine/verifier remain authoritative. Invocation IDs reject retired callbacks. Completion actions use the reviewed inputs and registered output, and consume profile/staging capture and cleanup at most once. Success alone cannot synthesize signature verification or installation. |
| Installation and batch | Existing queue/installer remain authoritative. Direct Install owns its task and captures the reviewed mode; dismissal retires request-bound warning callbacks and cancels pre-handoff work. Duplicate admission is refused until the original worker/lease finishes; late registered imports release only their opaque handle, not the committed artifact. Guest and device-submission results stay distinct, including confirmation. Accepted queue/install handoffs survive dismissal. Batch callbacks require the current installer, generation and entry. Stop/skip after handoff preserves delivery and reports an unknown/unconfirmed outcome; a later callback cannot resume the next entry. |
| Certificate mutation and undo | Isolated insert/delete/relink saves; invalid/duplicate UUIDs (including case variants) are refused before Keychain replacement. Failed deletion retains credentials/files; a partial holding move refuses deletion. Undo preserves a nil ordering date, flags and still-eligible signed-app links. Holding uses the existing durable staging journal, not a temporary sweep target. An interrupted undo or failed re-stage retains journal ownership of the restored original until expiry/recovery. Cleanup checks committed and pending replacement UUID owners and defers on unreadable stores. The six-second offer expires independently of the banner and clears its captures. |
| Certificate checks | Results are tied to the original row identity and current generation. Deletion retires checks synchronously before UUID reuse/undo; a late result cannot revive a deleted row. The original protected certificate-directory getter is byte-identical. |
| Task/history/recovery | Immutable records over `UnifiedTaskCenter` and existing journals/download recovery. Actions re-resolve IDs; unconfirmed installation retry requires separate approval. History undo has an owner-enforced deadline. Observation termination releases subscriptions. |
| Files/archive/clone | Original engines remain; cancellation is forwarded and workers are awaited before scope/lease cleanup. Rebuild protects an existing destination, clone claims production before files, and a cancelled explorer cannot submit a new installation. |
| Accounts | Separate status, certificate, registration, profile and key-export approvals remain. Context/app/receipt/expiry checks stay in the adapter/manager. The closed CMS gate runs before quota-affecting operations. No signing or install handoff is introduced. |
| Backup and cloud | UI receives only allowlisted backup preview metadata and an opaque archive ID; existing backup crypto/schema/restore verification remain authoritative. Visibility/operation generations retire late picker, password, restore-alert and Restart callbacks. The owned completion delay is cancellable and its summary is consumed once; hiding the screen does not roll back already committed restore outputs. Cloud observation excludes bearer tokens, retains Keychain ownership and does not enable private-key upload. |
| Companion and temporary sharing | Retain owned output while share extensions or embedded staging read it. Dismissal cancels tracked work and cannot restart the host after completion. Once the host accepts an inbox copy, only the host may discard that independent copy. A staged/exported/shared file is not installation evidence. UIKit presentation/refusal still needs native acceptance. |

The three additional concurrency escapes have written lock/main-thread and
callback-outside-lock invariants in the
[concurrency audit](../../Tools/Validation/security-validation/concurrency-audit.json).
The singleton count did not grow. Optional display/decoding failures are separate
from failed mutations; refused writes/cleanup are surfaced or logged rather
than treated as success.

## Preserved compatibility

| Public/root file | Canonical owner under `VexSign/` |
| --- | --- |
| `icon.png` | `Resources/Assets/icon.png` |
| `app-repo.json` | `Resources/Templates/app-repo.json` |
| `repos.json` | `Resources/Templates/repos.json` |
| `license_plist.yml` | `Configuration/Signing/license_plist.yml` |
| `render.yaml` | `Services/WebManager/Configuration/render.yaml` |

`sync_repo_aliases.py --check` enforces equality. Published feeds and historical
commit-pinned URLs remain intact. The published
[pre-migration combined-host setup URL](https://github.com/raynmahbub/VexSign/blob/main/Integrations/EmbeddedContainer/README.md)
is retained for provenance; current UI links target the relocated integration
guide. Root legal/security/community documents, `.github/`, project/workspace and
normal tool entry points remain discoverable.

All 35 original binary files and ten license texts are byte-identical. The
separate `THIRD_PARTY_NOTICES.md` and both licensing-plist inputs retain their
complete text/settings except relocated repository paths; the root licensing
alias matches its canonical owner. The vendor manifest changes only package
paths, not revisions or attribution. These checks do not claim a complete SBOM
or establish distribution-license compliance.

Of the 28 protected inputs—including original plists, entitlements, model contents,
seven package manifests, all three resolved-pin files, the native input lock,
Cloud lock/OpenAPI, FilePickerFix and the certificate-directory getter—26 remain
byte-identical. One reviewed exception adds public Security-framework linkage
to the app's existing vendor package manifest, without changing its upstream
revision or pins. The original upstream manifest digest remains authoritative for
isolated smoke preparation. The second exception admits only the exact incoming
main Cloud dependency lock and separately records its superseded dependency URLs;
it does not permit arbitrary lock changes or reset any original hash.
Bridge-header edits only relocate the same three unchanged headers.
All seven target objects/products and 157 original Xcode object IDs
remain; the four added IDs are xcconfig references/their group. All 32 declared
configuration setting sets are preserved after path relocation and xcconfig
extraction. This does not evaluate Xcode-expanded settings or bundle placement.

The only rewritten original app resource is the localization catalogue (relocated
path-display text and additive English error/consent/readiness keys); other original
translations are retained. Apart from retaining main's explicitly recorded service
dependency updates, no pin update, license replacement, target renaming or native
promotion is part of this work.

## Architecture ratchet

The guarded whole-Presentation storage, Core Data, direct signing/installation,
consumed engine-owner, raw network, filesystem and managed-record-type matches
are now **zero**. Domain/Application platform/import guards are also clean.
This is a source-level result, not proof that every legacy UI detail has been
redesigned or that all possible dependency edges are covered.

The [baseline](../../Tools/Validation/architecture-rules/architecture-drift-baseline.json)
retains the original `migrationReview` and previous rule/file lists in history.
Zero real debt is allowed; synthetic positive and negative fixtures keep the
rules enabled, including distinguishing `app.isSigned` from a managed-object
cast. CI never regenerates a baseline to make a check pass.

## Historical migration validation record

This section records the earlier migration/native-CI checkpoint through `9aa3046`,
not the signing/library candidate and main integration above. Its counts describe that
checkpoint; current original-blob/grammar evidence is in the refreshed JSON report.

The following portable checks were rerun after the projection, backup and
direct-install lifetime follow-ups. The native-CI repair also reran `make verify`
and the full preservation/grammar audit. The service results are the earlier
completed local checkpoint; they were not rerun for the CI-only repairs. These
checks are not release or physical-device evidence.

| Check | Observed result |
| --- | --- |
| `make verify` | Passed all portable command groups, including the 30-case workspace-boundary source suite and 24 preservation-auditor fixture tests |
| Layout / architecture | 19 layout, 7 original boundary, 30 workspace-boundary and 8 architecture-ratchet tests passed; all 12 ratcheted categories have zero matches |
| Normal quick check | 0 errors; 1 advisory warning because `swiftc` is unavailable; 53 resources checked and 0 Swift files compiler-parsed. The syntax-independent check in `make verify` explicitly skips the compiler |
| Xcode/project/package preservation | Seven unchanged target objects/products; all 157 original object IDs retained, four xcconfig IDs added; all 32 declared configuration setting sets retained. One reviewed generic-resource file-type override is audited below. Workspace/project retain 42 agreeing pins, SideSign retains six; all three resolved-pin files byte-identical. Native findings recorded separately below |
| Error / singleton / concurrency guards | 168 unjustified optional-error sites (14 below the existing allowance), 63 singletons, 7 documented concurrency escapes; no file above its reviewed baseline |
| Localization | Catalogue sync and 12 helper tests passed; three missing keys added without pruning translations |
| Original-file preservation | 1,375 Git originals accounted for; 1,322 relocations; no missing file, changed binary/license, executable-mode loss or removed real public/historical URL; exact counts in the linked JSON audit |
| Swift grammar comparison | 959 original vs 1,139 current Swift files; the same 25 known grammar findings and no new finding signatures. One known finding moved with the file-coordination extraction. This is **not** `swiftc` or type checking |
| Native-signing preparation | 74 offline Python tests; no native compile/link or capability promotion |
| Embedded-container packaging | 31 offline fixture tests; no combined native-host build |
| WebManager | 216 tests passed in the checkout and 216 in an isolated component copy; one upstream Starlette/httpx deprecation warning per run; optional cryptography test dependency installed, no skips |
| Cloud | TypeScript build, 14 tests and contract generation passed; OpenAPI and package-lock bytes remain identical to the original revision |
| `git diff --check` | Passed |
| Local Xcode build / XCTest / simulator | **Not run locally:** no Swift/Apple toolchain in this Linux workspace; remote revision-specific results follow below |
| Physical-device operation | **Not run:** no new device-acceptance evidence |
| Docker image / deployment | **Not run:** service source/build tests are not deployment proof |

Ten new native test files contain 74 XCTest methods for fake-provider signing,
account consent/serialization, backup release/serialization and retired presentation
callbacks, library identity/prevalidation, task/companion intent, observation
lifetime, deadline ownership and Core Data projection admission. Typed foreign-store,
foreign-context, temporary, pending/committed-deleted and detached app rows are covered
alongside valid own-store projections and temporary workspace-read recovery. Three
profile-snapshot tests cover absent vs empty grants, typed entitlement values and
comparison without managed-row refetches. A fake
restore owner can return a committed summary after cancellation without inventing
rollback; the retired screen still cannot present it. Fourteen Direct Install cases
cover overlapping admission, retirement/task cancellation after registration,
lease retention until the worker returns, accepted handoff preservation, unknown
routing, hidden-screen callbacks, stale/double confirmation, captured mode and the
actual guest outcome. Existing archive/catalog/certificate/recovery files add 16 methods for transaction/undo-insert failure, nil-date/relink behavior,
replacement UUID ownership, unavailable stores, interrupted undo, failed
re-stage/erasure and durable journal retention. An archive stream regression
checks that completed edit/undo operations update immutable snapshots through
the existing workspace publisher. Two discovery cases additionally cover accepted
intent/signal ordering and provider refusal without a success signal. Two further native methods pin private device/simulator path redaction without
hiding error codes or public URL paths, for 92 added methods in the current tree.
**At `9aa3046`, the full `VexSignTests` simulator job and all CI jobs pass.**
This validates app launch and the selected suite containing the 92 added methods,
including the Keychain-dependent certificate cases and two path-redaction cases.
The earlier `853238a` run's 1,908 total / 1,900 passed / six failed / two skipped
counts below describe that failed revision, not the final successful run; exact
final per-test totals were not recovered separately from the passing job verdict.
Source-reading fixtures fail
when an expected implementation file is absent; they do not silently skip
migration breakage. In particular, fixture/source passes are not delayed-OCSP,
UIKit, real protected-database, host-copy or actual installer callback acceptance.

### Published revision-specific native CI

The user authorized branch-only commit/push, PR creation and native-CI repairs;
[PR #243](https://github.com/raynmahbub/VexSign/pull/243) is open. Nothing was
merged, released or deployed.

| Revision and run | Observed result |
| --- | --- |
| `45d708d`, [CI 43602852762](https://github.com/raynmahbub/VexSign/actions/runs/43602852762) | Quick syntax/resources/gates passed. The first-party concurrency **report-only** job completed successfully; that does not promote concurrency checking to an enforcing gate. iOS unsigned Debug build and simulator test jobs failed during app compilation. No simulator tests ran. |
| `45d708d`, [companion 43602889231](https://github.com/raynmahbub/VexSign/actions/runs/43602889231) | Existing TV/tvOS, Vision/visionOS and Watch/watchOS unsigned Debug builds all passed. This is companion compilation evidence, not iOS/XCTest/device acceptance. |
| `5b16d1b`, [CI 43604528974](https://github.com/raynmahbub/VexSign/actions/runs/43604528974) | Quick gates passed and the report-only concurrency job completed. iOS build and simulator test jobs still stopped during app compilation; compiler exit 65 is now captured correctly. New actor-warning annotations are enforced rather than silently ignored. No simulator tests ran. |
| `5b16d1b`, [native link smoke 43605185577](https://github.com/raynmahbub/VexSign/actions/runs/43605185577) | Pinned isolated graph preparation, CMS fixture digest check, synthetic native unit regressions, generic arm64 iOS device linking and arm64 iOS Simulator linking all passed. Full combined-host packaging and the optional alternate dependency candidates were intentionally skipped. No Apple login/provisioning or capability promotion occurred. |
| `8066c11`, [CI 43605987685](https://github.com/raynmahbub/VexSign/actions/runs/43605987685) | Quick gates passed and the report-only concurrency job completed. iOS build reported an unavailable Core Data notification member. The simulator build reported a missing clone-sheet container binding and missing NimbleViews import for the installation fallback browser. No simulator tests ran. |
| `2828c00`, [CI 43608316611](https://github.com/raynmahbub/VexSign/actions/runs/43608316611) | Quick gates passed and the report-only concurrency job completed. Debug compilation failed in downloaded-file row inference; three newly enforced warnings were also reported. The simulator build found an entitlement helper still expecting managed certificate rows instead of immutable certificate records. No simulator tests ran (xcresult total 0). |
| `6d3242c`, [CI 43609954036](https://github.com/raynmahbub/VexSign/actions/runs/43609954036) | Quick gates passed and the report-only concurrency job completed. Debug compilation found overlapping read/write access to the optional signing task context. Simulator compilation found an archive adapter attempting to observe a nonexistent journal publisher. No simulator tests ran (xcresult total 0). |
| `4879a1b`, [CI 43611504148](https://github.com/raynmahbub/VexSign/actions/runs/43611504148) | Quick gates passed and the report-only concurrency job completed. Debug failed without a parsed source diagnostic. Simulator compilation reached the linker, which rejected `ellekit.deb` as a Mach-O static archive. No simulator tests ran (xcresult total 0). |
| `c249f3b`, [CI 43613459987](https://github.com/raynmahbub/VexSign/actions/runs/43613459987) | Unsigned iOS Debug build, unchanged warnings gate, bundled-resource byte comparison, unsigned test IPA packaging/upload and download-integrity check all passed. Quick gates passed and the report-only concurrency job completed. Simulator compiled the app, then found three stale `DiscoveryViewModel(downloads:)` constructions in the test target. No simulator tests ran (xcresult total 0). |
| `703550d`, [CI 43615782485](https://github.com/raynmahbub/VexSign/actions/runs/43615782485) | Unsigned iOS Debug build, unchanged warnings gate, resource-byte comparison and unsigned test IPA packaging/download checks passed again. Quick gates passed and the report-only concurrency job completed. Both simulator app and test bundle compiled, but the app trapped before XCTest established a connection. The xcresult reports one host-bootstrap failure, zero passed tests; no authored XCTest method is established as executed. |
| `853238a`, [CI 43618845284](https://github.com/raynmahbub/VexSign/actions/runs/43618845284) | Unsigned iOS Debug/warnings/resource-byte/IPA checks passed. Simulator app now launches and connects to XCTest: 1,908 total, 1,900 passed, six failed, two skipped. Five certificate cases hit the unsigned host’s missing Keychain entitlement (`-34018`); the remaining assertion exposed an unredacted local path in a store-recovery notice. No startup trap was reported. The overall run failed, not accepted as green. |
| `9aa3046`, [CI 43622715168](https://github.com/raynmahbub/VexSign/actions/runs/43622715168) | **Full run passed.** Quick syntax/resources/gates passed (3m11s); unsigned iOS Debug, unchanged warnings gate, resource-byte comparison and test-IPA checks passed (9m31s); the full `VexSignTests` simulator job passed (20m49s); report-only concurrency completed (1m59s). The simulator host uses a local ad-hoc signature without Apple credentials. This is branch/XCTest evidence, not physical-device installation or Release/combined-host acceptance. |

The iOS build reported nonisolated calls to `getSignedApps()` and
`getImportedApps()` in `UpdateMatchingPreferences.toggleAutoUpdate(for:)`. The
simulator build reported the removed `CertificateDashboardViewModel` reference
in scheduled maintenance (and its dependent `.revoked` inference error).
The repair keeps the snapshot readers main-actor isolated, annotates their UI
caller, and moves the existing adapter inspection pass into
`CertificateInspector.inspectAll` so both maintenance and the dashboard use
one non-UI inspection owner. Its report/error, cancellation and OCSP semantics
are retained.

CI follow-up also restores first-party warning classification under `VexSign/`
without changing the warning baseline, warning counts or vendor exclusions.
Regression tests exercise a new warning failing, an existing baseline warning
passing, and a historical path refusing to whitelist a relocated warning.
Build/test pipelines now capture the real compiler exit status under Actions'
`bash -e` shell before exiting; a portable failing-compiler fixture checks both
pipelines. The next run exposed a throwing archive-cleanup call and a caught-`error`
shadowing assignment in `SourcesViewModel`. Cleanup now reports refusal/failure
instead of emitting success, and catalog retention failure updates the model's
error state explicitly. Three new concurrency warnings are repaired without
expanding the baseline: the archive sheet captures its existing immutable
workspace ID for nonisolated `Identifiable` access, and certificate adapter
defaults are resolved inside its main-actor initializer, not in default-argument
expressions. These follow-up repairs need another native run; neither failed
run is acceptance of them.

The next repair uses the SDK's `.NSManagedObjectContextObjectsDidChange`
notification name while preserving the exact-context filter, main-actor hop and
observation teardown. The clone sheet declares its inherited container, and the
installation fallback imports the existing NimbleViews browser wrapper rather
than replacing it. Portable source regressions and the full preservation/grammar
audit pass; these changes still require native revalidation.

An attempted diagnostic-only `-continueBuildingAfterErrors` option was rejected
by the selected Xcode at `f7de470` ([run 43607748458](https://github.com/raynmahbub/VexSign/actions/runs/43607748458),
build exit 64). That run provides no compile/test evidence and was cancelled
once the setup error was established. The unsupported flag was removed from both
commands; regression checks prevent its reintroduction. Compiler exit capture
and the unchanged warnings gate remain enabled.

At `2828c00`, the [next native run](https://github.com/raynmahbub/VexSign/actions/runs/43608316611)
reached the downloaded-file rows. The build exposed their call to a nonexistent
`DownloadedFileItem.formattedSize` property (also present in the original source),
which led SwiftUI to report misleading binding/ForEach inference errors. Rows
now explicitly consume immutable `DownloadedFileItem` values and format their
numeric size in Presentation using the existing file-size formatter. Three newly
enforced warning sites are repaired without expanding the baseline: modern
`onChange` syntax, a bundle-presence check without an unused URL binding, and an
explicitly discarded validation statistic. Backup tree validation still throws
and is awaited; its failure is never suppressed. Tweak scan failures now show an
error instead of being rendered as a successful empty scan. The simulator then
reported three entitlement views passing immutable `CertificateRecord` values to
the legacy managed-row helper; that helper now reads only the selected record's
profile snapshot, without a persistence refetch or raw `CertificatePair` escape.
Three added XCTest methods cover missing/empty grants and value comparison.
These follow-up changes need a new native run; the completed `2828c00` run
executed zero simulator tests.

The `6d3242c` follow-up separates reading the signing-verification verdict from
writing the task's confirmation reason, preserving the distinction between
registered artifacts and verified installation while satisfying Swift's exclusive
access rule. Archive observation now subscribes only to `IPAWorkspace`'s existing
publisher: the plain change journal never had its own publisher. The existing
workspace publishes after successful file edits and undo/reset, plus rebuild and
progress; a main-actor hop reads the post-mutation snapshot and stream teardown
still cancels the subscription. A native archive edit/undo stream regression was
added; portable regressions enforce owner wiring and ordering. These repairs
require another full native run, not inference from the prior failed build.

At `4879a1b` the simulator's linker reported the AR member `debian-binary` inside
`Resources/ellekit.deb` as non-Mach-O. The unchanged Debian archive is consumed
by `TweakHandler` at runtime, not a library to link. An explicit `file` type in
the existing synchronized app group corrects that classification without changing
any binary, target/product, build-setting value or membership exception. Its
SHA256 remains `588ad56c5de5585ca2d66e385cc8f25b4c1d77d5e8fc52baec6d69cb3fa3343d`.
The preservation auditor now rejects all other unreviewed resource-type/folder
metadata changes. CI additionally compares the bundled device-app resource bytes
before packaging its disposable unsigned test IPA; omitting the resource is not
an acceptable way to make linking pass. Device build/resource/IPA checks passed
at `c249f3b` and `703550d`; simulator linking also passed at `703550d`.

The Debug failure's unparsed log-tail annotation was truncated before its useful
final lines. Direct log downloads redirect to an unreachable artifact host in
this workspace. The reporter now surfaces bounded contexts around unlocated
linker/script failures and keeps the final fallback annotation within GitHub's
message cap. The complete tail still goes to the summary, compiler failures
still fail, and no warning baseline or vendor exclusion is changed. Two offline
regressions cover noisy resource tails and failed-build baseline refusal.

The `c249f3b` device app build and artifact checks passed. The simulator reached
the test target, where three discovery fixtures still called the removed
`downloads:` initializer. Those fixtures now inject the existing inward catalog
port through `DiscoveryUseCase`, without starting real sessions, persistence or
notification observers. Download admission consumes the same injected security
policy before any provider call, while the infrastructure transport gate remains
intact. The fake deliberately does not validate URLs, so the original invalid/missing
URL tests still prove production admission rather than duplicating it in a mock.
Accepted-intent/signal ordering and provider-refusal cases were added. The observed
deprecated ZIP writer overload and redundant test `try` were also repaired without
changing dependency pins. The fixture source compiled at `703550d`, but the
host launch trap prevented test execution.

At `703550d`, the simulator host exited with a trap before XCTest connected,
matching a launch-time failure rather than another compiler error. Review found
the always-built `InstallQueuePill` was appended after the root environment
modifiers, outside the subtree carrying its required `InstallationQueueModel`.
The root dependency scope now wraps all overlays and sheets, including onboarding
and self-update, instead of duplicating an incomplete model subset in the sheet
closures. The shared production models and original execution owners are unchanged.
A portable regression pins this ordering. The next native run at `853238a`
launched successfully and executed the suite, instead of trapping before XCTest
connected. A physical-device crash log is still needed to establish that this
is the user's device-specific failure. The observation-lifetime fixture also
uses an equivalent weak capture instead of a compiler-warned weak local.

Failure diagnostics now parse Apple's metadata-plus-multiline IPS records and
older plain-text crash reports instead of attempting to decode only the last
line. Missing-environment and other fatal messages survive unrelated log chatter.
Three additional fixtures exercise those paths (54 workflow-policy tests total);
crash reporting still cannot turn a failed compiler/test run into success.

The six failures at `853238a` were not compiler/launch errors. Five
certificate durability/undo cases need real Keychain writes and fail in the
unsigned simulator host (`errSecMissingEntitlement`, status `-34018`). CI and
`make test` now request a **local ad-hoc simulator signature** (`-`), without an
Apple identity, profile download or credential. Device test-IPA builds remain
unsigned, production entitlement/project bytes remain unchanged, and no Keychain
error is swallowed, mocked away or converted to a skip. A portable workflow
regression pins that separation (55 workflow-policy cases).

The sixth failure is the original store-recovery redaction assertion: known local
device/simulator container roots could remain in a shared recovery notice.
`LogRedaction` now masks those specific filesystem forms, retaining the diagnostic
text/error code and leaving the same segments inside HTTP URLs readable. Two
native cases and a portable production-pattern fixture pin redaction, negative
URL cases and idempotence. Both repairs are validated by the full successful
`9aa3046` native run; no test was disabled or converted into a skip to pass it.

The separate native-signing smoke is not a substitute for the now-passing app
XCTest job. Neither result establishes physical-device/combined-host acceptance
or promotes native Apple-account signing beyond `.notIntegrated`.

The unsigned device test artifact for the validated code revision is available
from [the successful run](https://github.com/raynmahbub/VexSign/actions/runs/43622715168/artifacts/14125770356),
named `VexSign-unsigned-9aa3046b41d08583a852b01a9f75666e9afee294-43622715168-1`.
It is a disposable Debug test IPA, **not a signed release**; it must be re-signed
with a valid compatible identity/profile before device installation. No physical
device was connected here, and an already installed older artifact does not gain
these fixes. The historical documentation-only follow-up changed no execution or
build input from `9aa3046`; the current signing/library draft does.

At that checkpoint GitHub reported PR #243 as conflicting with main at `725a276`,
while read-only local merge-tree diagnostics were clean. This is historical, not
a new mergeability assertion. At that historical checkpoint no merge/rebase/base
sync had been applied, and no current-main service dependency update was copied
over the protected original pins. The subsequently authorized integration is
recorded separately above. The manually dispatched runs test the named branch
revision, not a PR merge commit. Mergeability and physical-device acceptance
remain separate from those branch results.

Reproduce the portable checks from the repository root:

```sh
make verify
make test-server PYTHON=/path/to/python-with-server-test-dependencies
# After npm ci in VexSign/Services/Cloud:
make test-cloud
python3 VexSign/Tools/Validation/architecture-rules/audit_feature_preservation.py
# Optional grammar-only comparison, with tree-sitter and tree-sitter-swift installed:
python3 VexSign/Tools/Validation/architecture-rules/audit_feature_preservation.py --parse-swift
```

The preservation audit is read-only (apart from an explicitly requested JSON
report) and requires the recorded original Git revision locally; it never
fetches, stages or changes a baseline. Its 27 offline fixture tests run in normal
verification/CI without needing that historical Git object. The JSON records its
exact file, legal-index, protected-input, target/configuration and grammar
findings. The two intentionally incomplete URL-prefix sentinels from the old
negative-rewrite test are not exceptions for real URLs; the prior evidence report
is excluded from current URL evidence so it cannot hide a removed source URL.

## Required native/device acceptance

On macOS, build/test this exact working tree after saving it as a reviewed
revision—not an earlier checkpoint:

```sh
make bootstrap
make test
make VexSign
```

Also build the existing TV/Vision/Watch/widget targets and applicable native
signing/combined-host smoke schemes. Inspect bundled assets, strings, Core Data
models, plists, sounds, web data and shared-target membership. Specifically test:

- failed certificate save/undo-insert/re-stage/rollback moves, locked Keychain or
  unreadable protected database, delete/undo/expiry/UUID reuse, interruption after
  files are restored but before row insertion, stale delayed OCSP results and
  signed-app relinking without overwriting a separately changed identity;
- signing failure/cancel/retry, verifier evidence, one-shot input cleanup and
  completion handoff with and without the log sheet;
- installation stop/skip before and after handoff, delayed/double callbacks from
  retired installers, unknown outcomes and explicit retry decisions. Exercise
  Direct Install dismissal during transfer/import and warning presentation,
  reappearance/new requests followed by stale confirmation callbacks, duplicate
  Start and accepted handoffs that must not be revoked;
- cancelled archive rebuild/clone/backup/restore, archive replacement/release,
  cancellation after artifact registration, delayed restore alerts, existing
  destinations and unrelated pending edits preserved;
- sharing refusal/completion and disappearance while a worker or extension reads
  a file; embedded host-copy cancellation/acceptance and dismissal without stale
  session restart. An accepted independent inbox copy remains host-owned.

Follow [device testing](../DeviceTesting/DEVICE_TESTING.md) for actual transports,
background limits and evidence. Native Apple-account signing remains
`.notIntegrated`; free-account/guest-host flows remain experimental. Signing,
artifact registration, export, guest preparation and install submission do not
establish verified installation, unattended renewal or computer-free bootstrap.

Publication and main integration of the current signing/library candidate were
explicitly authorized after the earlier implementation checkpoint. Existing
published commit messages/history are retained; new commits use scoped,
descriptive messages. This does not authorize merging the PR, tagging, releasing,
deploying or changing credentials. Native CI findings must be recorded separately
for the exact revision tested; portable checks do not establish device acceptance.
