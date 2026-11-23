# Tests: what exists, what does not, and how to add one

The test tree is one Xcode target (`VexSignTests`) with four folders. A file's class name is
its suite name, not its folder — `make test SUITE=<ClassName>` selects by class, and a mistyped
name runs zero tests and still exits 0, so read the `Test Suite` line in the output.

| Folder | Files | What belongs there |
| --- | --- | --- |
| `Tests/UnitTests/` | 177 | Behaviour of one type: value objects, policies, parsers, stores, view models. Most of the suite. |
| `Tests/SecurityTests/` | 17 | Things that must not leak or must not be bypassable: Keychain attributes, path traversal, token comparison, entitlements, certificate trust, privacy manifests. |
| `Tests/WorkflowTests/` | 6 | Multi-type journeys: install queue end to end, import → sign → install, backup/restore, Web Manager wiring. |
| `Tests/PerformanceTests/` | 4 | Sendability and shared-state stress under concurrency. Despite the folder name there is no `measure {}`/`XCTMetric` here — the assertions are correctness under load, not timings. The name is legacy and is not worth the churn of a rename: 4 files, and two architecture documents pin the paths. |
| `Tests/Support/` | 4 | Fixtures and helpers, not test cases. |

The packages carry their own targets as well: `make test-packages` runs
`VexSign/Packages/SideSign/Tests` and `VexSign/Packages/NativeSigning/Tests` (~318 cases) on
macOS, which is what `embedded-container.yml` does for a change that touches `Packages/**`.

Running the app suite: `make test` (~2,300 tests, ~30 minutes), `make test SUITE=<Class>[,<Class>]` while
iterating. See [CONTRIBUTING.md](../../../CONTRIBUTING.md#validate-changes) for the full
contract — the short version is that `make verify` is not a build and CI's `build` job is the
first real compiler a change meets.

## Conventions

- **No shared singletons.** Use an in-memory `Storage(inMemory: true)`, a temporary directory,
  or a value type. Three files touch `Storage.shared`; do not add a fourth.
- **Deadlines, not sleeps.** Waiting for something to become true (a Core Data merge on the main
  queue, a file appearing) is a bounded poll with a deadline — `StorageConcurrencyTests` polls
  every 5 ms against a 5 s deadline, which is the main queue getting a turn, not a fixed delay.
  Never `Thread.sleep`/`Task.sleep` to "let" work finish.
- **Skip rather than fail when a capability is missing.** A test that needs a real device, a
  Keychain item or a simulator certificate throws `XCTSkip`; a host that cannot provide the
  capability must not turn into a red build.
- **Pure seams over singletons.** Where a rule lives inside a type that is `@MainActor` and
  touches UI, the pure part is extracted (`InstallQueue.installationMethod(isExport:resolve:)`,
  `WebManagerTransferLimits`) so the rule can be pinned without the rest of the app.
- **UI is not tested here.** There is no XCUITest target; the presentation layer is covered only
  through its view models and value types.

## Known gaps

Recorded so the next person does not have to rediscover them, with the reason each one is still
open. None of these is a licence to skip a regression test for a change in the area.

| Area | Gap | Why it is open |
| --- | --- | --- |
| `InstallQueue` transitions | `advance`, `activate`, `reconcileOnForeground` and `sheetDismissed` have no test call sites (`pause`, `resume` and `canSkip` do). | They run through `InstallQueue.shared`'s collaborators: `UnifiedTaskCenter`, `InstallQueueWindow`, `UIApplication.shared.applicationState` and a live `AppInstaller`. The method mapping they branch on is now extracted and tested (`InstallQueueTransitionTests`); driving the transitions needs a seam that injects those four, which is a refactor of `InstallQueueCore.swift`, not a test. |
| `AppInstaller` execution half | Every reference in `Tests/` is to `AppInstaller.Outcome`; the run itself (method selection, retry, rollback) is untested. | Same cause: no injectable seam. `AppInstaller` builds its own pipeline and reports through the queue. The valuable extraction is a pure "which method, retry or roll back?" decision type — the tests follow it. |
| Web Manager server | No request-level test. `WebManagerAccessTests` covers the policy, and `test_webmanager_wiring.py` greps the source for routes; nothing opens a socket. | The suite would need Vapor linked into the test target (`import Vapor` to build a `Request`) plus a TLS identity from the Keychain, and Vapor's logging bootstrap is process-wide. The transfer bounds that mattered are pure and covered (`WebManagerTransferLimitsTests`); a request test is the next step, and it starts with adding Vapor to the test target's link graph. |
| Tweak pipeline | `TweakExtractor` scanning is covered (`TweakExtractorTests`); `TweakManager` (877 lines) and `TweakHandler` (905) are only covered through `TweakInjectionDefaultsTests`. The archive-format half *is* covered: `ArchiveFormatTests` pins detection, the `.deb` member list and the refusal copy, and `ZstdDecompressionTests` covers the zstd payload path through `extractFile`. | They are `ObservableObject` facades over the filesystem plus a live signing session. The filesystem half is testable next; the session half needs the seam above. |
| `@unchecked Sendable` | Five types assert their own safety: `Download`, `AppFileHandler`, `RemovalUndoLease`, `RepositoryDirectoryClient`, `StreamObservationCancellation`. Each documents its invariant; `RemovalUndoLease` is covered functionally but none is stress-tested. (`StrictHidingSnapshot` and `AppOperationRegistry.Lease` no longer need the escape — the lock and the `@Sendable` closure replaced it.) | A stress test has to run the real callbacks on a second thread; several of these types are only reachable through their owners. `RemovalUndoLease` is the model to copy — offer/undo/expire/discard with the lock held across every mutation. |
| Detached concurrency | `Task.detached` starts work nothing owns: no isolation is inherited, nothing cancels it with its screen, and no diagnostic mentions it. 77 sites across 48 files are inventoried in `detached-task-baseline.json`; each site is either work that must outlive its screen or a stale write waiting to happen, and the baseline cannot tell them apart. | The inventory ratchets (a file may not gain a site, the total may not drop unrecorded), so the next site is a reviewed line rather than an invisible one. Deciding *which* of the 77 can become a stored `Task` needs the owner's cancellation to exist first, one file at a time. |
| The `concurrency` CI job | It reports first-party Swift package diagnostics with `continue-on-error` on the step. | Making it required is a policy change, not a code change: it needs the package graph to be warning-free on a pinned toolchain first, verified on a green run. |

## Gates that keep the tests honest

- `make verify` runs the repository gates (69 of them), including the coverage-reporting check
  (`test_coverage_report.py`), the detached-task inventory
  (`test_detached_task_audit.py`, baseline in `detached-task-baseline.json`) and the accessibility
  gates ([ACCESSIBILITY.md](ACCESSIBILITY.md)).
- CI reports line coverage from the `tests` job (`.github/scripts/coverage_report.py`, uploaded
  as the `coverage-*` artifact, printed in the run summary with its floor and its change against
  `coverage-baseline.json`) and enforces a 20% floor as a separate step. The trend is what catches
  a slow slide; the floor only catches the collapse. The number is not a
  quality bar — a threshold picked to be "about right" mostly measures which files the last
  author touched — but a *collapse* is worth failing on: a suite that stops running, or a target
  dropped from the scheme, otherwise shows up only as a smaller artifact. Raise the floor in
  `.github/workflows/ci.yml` after reading a real run; a number within two points of it produces
  a warning annotation instead.
- Import → artifact is covered end to end by
  `FullSignPipelineIntegrationTests.testImportedBundleRepackagesIntoACompleteArtifact`: a
  synthetic IPA is imported through `PackageImportService`, the library's bundle is re-zipped by
  `AppArchiver`, and the result is checked against `ArchiveSafetyValidator` and the source
  archive's entry list. The producing half — a *verified signed* artifact — needs an
  Apple-authorised identity and a device or a signed simulator entitlement, which this suite does
  not have. `make test-signing-core` covers the native sealer's CodeDirectory construction,
  hashing, DER entitlements and CMS independently, with generated keys and no Apple account.
- `PythonTests/` inside `VexSign/Packages/NativeSigning` generates a Swift package test target
  (`NativeSigningCodecTests`), so the native signing core does have a Swift suite — it just does
  not live in this tree. `make test-signing-core` runs it.
