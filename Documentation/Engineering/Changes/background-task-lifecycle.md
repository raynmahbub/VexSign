# Background task lifecycle: one owner per completion

**Status: code change complete; iOS compile and device acceptance still required.**
Scope: the three P0 findings in the optimization audit — double completion, the
`wasExpired` data race, and blocking polling. Nothing else in the background or
download stack was restructured.

## What was wrong

`App/iOS/VexSign/AppDelegate+BackgroundTasks.swift` had two writers for one `BGTask`
completion:

| Handler | Expiration handler | Worker |
| --- | --- | --- |
| `_handleBackgroundDownload` | `pauseAllDownloads()` then `setTaskCompleted(success: false)` | a `DispatchQueue.global()` loop calling `setTaskCompleted(success: true)` |
| `_handleContinuedProcessing` | set `wasExpired`, then `setTaskCompleted(success: false)` | a global-queue loop calling `setTaskCompleted` again |
| `_handleBackgroundRefresh` | `setTaskCompleted(success: false)` | `setTaskCompleted(success: true)` |

Three consequences, all reachable in normal use:

1. **Two completions per task.** When the system expired a task mid-download, the
   expiration handler reported failure and the worker later reported success. The
   system saw a contradictory outcome and the work kept running untracked.
2. **An unsynchronised flag.** `var wasExpired` was written by the expiration
   handler and read by a worker loop with no synchronisation. `false` was also
   the value that made the loop *keep* running, so a stale read meant a loop that
   never noticed expiry.
3. **Off-actor reads of published state.** Both workers read
   `DownloadManager.shared.downloads` from a global queue. `downloads` is
   `@Published` state on an `ObservableObject`, and `Download` is a mutable
   `@unchecked Sendable` class, so that was an unsynchronised read of main-thread
   state.

`_handleMaintenance` had already been fixed to the single-owner pattern; these
three handlers were the remaining instances.

## What changed

New, testable pieces in `App/iOS/VexSign/Backend/Services/`:

- `BackgroundTaskCompletionGate` — the only caller of `setTaskCompleted`.
  First `finish(success:)` wins; later attempts are counted and dropped.
  `expire()` can never overwrite a result that already landed, and a late worker
  can never complete twice. State is in an `OSAllocatedUnfairLock`, and the
  completion closure is invoked after the lock is released, so re-entrancy from
  `setTaskCompleted` cannot deadlock.
- `BackgroundWorkCancellation` — holds the monitoring task for the non-async
  expiration handler. An expiration that arrives before the task is adopted is
  remembered and applied immediately.
- `BackgroundDownloadWork` — an immutable, `Sendable` sample (`itemCount`,
  `activeCount`, `averageProgress`, `hasUnfinishedWork`) copied on the main
  actor. No `Download` reference crosses an actor boundary.
- `BackgroundDownloadMonitor` — a `@MainActor` protocol plus
  `DownloadManagerBackgroundMonitor`, which is the production adapter. The
  protocol is the seam that makes the loop testable without a second download
  manager.
- `BackgroundDownloadMonitorPolicy` — the pure `finished / timedOut / keepMonitoring`
  decision, including the boundary case where work finishes exactly at the
  deadline (that is a success).
- `BackgroundDownloadRunner` — a `@MainActor` loop using `Task.sleep` instead of
  `Thread.sleep`, and `ContinuousClock` instead of `Date()` for a monotonic
  deadline. `pauseOnCancellation` is explicit: the processing task pauses on
  expiry, the continued-processing task does not, because keeping the download
  alive is its purpose.

Behaviour deliberately preserved:

- The processing task still resumes downloads on entry and uses a 4-minute budget.
- The continued-processing task still reports `BGTask.progress` and does not pause.
- `_handleBackgroundRefresh` still schedules a processing task when work remains.
- Downloads are paused on expiry of a processing task, leaving them resumable.

One intentional correction: the old processing worker reported
`success: true` even when it hit its own timeout with downloads still running.
The runner now reports `false` in exactly that case, so the system can reschedule.

## Tests

`App/Tests/VexSignTests/BackgroundTaskCompletionTests.swift` (24 tests) covers the cases the
audit asked for:

- expiration immediately **before** worker completion — worker's late success is dropped;
- worker success **before** expiration — the success stands, expiration is a no-op;
- expiration **during** completion — a re-entrant `expire()` from inside the
  completion closure does not deadlock;
- 32 concurrent completions from different threads produce exactly one
  `setTaskCompleted` call;
- the runner: drains to success, times out truthfully with work left, pauses once
  on cancellation, and ignores an expiration that arrives after success.

## A note on what "verified" means in this document

No Apple toolchain was reachable from the review environment: `xcodebuild` and
`swiftc` are absent, `download.swift.org` is blocked, and GitHub's Swift releases
publish no Linux compiler asset. So `deinit`, `@MainActor`-closure and `Sendable`
questions in this branch were resolved by reading the code, not by compiling it.
Where a claim rests on a language rule rather than a test, the design was
changed to avoid depending on the rule rather than to assert it holds.

This is also why the one reported portable failure is now closed: the device
acceptance suite runs `git rev-parse HEAD`, and it passes in a checkout with git
metadata (12/12). The ZIP had no `.git` directory; there was never a code
regression.

## Validation performed here

- `make verify` — pass (documentation, icon assets, repository policy, workflow,
  release asset and embedded-container test groups).
- `python3 .github/scripts/quick_check.py --root . --no-swiftc` — no build-breaking problems.
- `python3 Tools/Development/concurrency-discipline.py` — 6 escapes across 5 files, **none above
  baseline**. No `@unchecked Sendable` or `nonisolated(unsafe)` was added.

## Not validated here

This environment has no Apple SDK, so the app target and the new tests have not
been compiled. Before merging, the Build and simulator jobs must confirm:

- [ ] the new files compile under Swift 5 language mode with no **new** warnings
      (`.github/build-warnings-baseline.json` gate);
- [ ] `BackgroundTaskCompletionTests` passes on a simulator;
- [ ] `make strict-concurrency` runs to a real result on a macOS runner (it
      previously failed immediately on the removed `-warnings-as-errors=false`
      argument, which is also fixed here).

## Related, not addressed in this change

- `make strict-concurrency` only builds `AltSourceKit` and `NimbleKit`; the app
  target itself is still guarded by the counting gate rather than the compiler.
- The six existing concurrency escapes and the incomplete Swift 6 adoption are
  unchanged. This change adds none.
- `DispatchQueue.main.sync` at the `DownloadManager` boundary, and full
  `@MainActor` adoption of `DownloadManager`, remain separate work — converting
  the whole type is not a safe change to fold into a background-lifecycle fix.
- No iPhone performance baseline exists yet, so no throughput claim is made here.

---

# Phase 2: state ownership and the strict-concurrency tooling

The second audit priority was "make `DownloadManager` state ownership thread-safe
and repair strict-concurrency tooling". Inspecting the code first changed the
scope substantially: the concurrency problem named in the audit was already fixed
in the base revision, and the parts that remain are tooling and design, not a
manager rewrite. This phase therefore does **not** convert `DownloadManager`.

## What the inspection found

**Every URLSession delegate already runs on the main queue.** Both sessions are
created with `delegateQueue: .main`
(`DownloadManager.swift:125`, `:138`). Every `downloads.append` / `.remove` /
`.removeAll` is inside a delegate callback, a `DispatchQueue.main.async` block, or
a main-thread method. There is no longer any global-queue block that touches
`downloads` — the previous phase removed the last two.

So the audit's "never read mutable published arrays from an arbitrary worker
queue" is now satisfied at the call sites, including the new
`BackgroundDownloadMonitor`, which copies values on the main actor.

**The `main.sync` sites are not equal, and most are guards rather than bugs:**

| Site | Reached off-main? | Verdict |
| --- | --- | --- |
| `DownloadManager.startDownload` (`:511`) | Only if a caller is on a background queue; no current caller is (delegates are `.main`, App Intents are `@MainActor`, all `startArchive` paths reach it via `DispatchQueue.main.async`) | Defensive; deadlock is impossible today because every off-main entry does `main.async` first. Still a synchronous cross-queue hop if a future caller is off-main. |
| `DownloadManager.handlePackageFile` (`PackageImport.swift:16`) | Only via `DownloadManager+Delegates.swift:70`, which runs on `.main` | Same. Prefer `precondition(Thread.isMainThread)` over `main.sync` so a wrong caller traps instead of deadlocking. |
| `FR.swift:417` | Yes — inside a `NSExtra`/NBFetch callback on a global queue | Real hop, but the closure exists for a Core Data view-context insert. |
| `CertificateAutoImporter.swift:117` | Yes — the whole importer runs on a utility queue | Real hop on the app-launch path. |

`Storage.getAllCertificates()` (used from `CertificateAutoImporter`) is
`performAndWait` on the *viewContext*: called off-main, Core Data hops to the
main queue itself. Converting that method to `@MainActor` is not a local change —
it has 12+ callers including background server paths (`WebManagerServer+HTTP`,
`CompanionBridge`, `BackupManager`), and several of those already hop to the main
queue for the same reason. That is the "audit all call sites first" case the
audit warns about, and it belongs in its own reviewed change with a compiler in
the loop.

## What did change

- **`make strict-concurrency` actually runs.** The two `swift build` lines lost
  the invalid `-warnings-as-errors=false` argument. The target builds
  `AltSourceKit` with `-strict-concurrency=complete` and `NimbleKit` in Swift 6
  language mode, and prints diagnostics.
- **A `concurrency` CI job runs it.** Previously nothing invoked the target, so
  deleting the broken flag alone would have fixed a command nobody ran. The job
  is macOS-only (AltSourceKit imports SwiftUI), reads the shared package cache,
  and is **report-only** (`continue-on-error`) with a warning summary in the job
  summary: its first job is to produce a list on a branch still being cleaned up.
  Promote it to a gate once it is green on `main`.
- **The runner cannot leave a task uncompleted.** An earlier revision of this
  branch added a `deinit` safety net that completed the gate. It was removed:
  reaching the gate from `deinit` needs either a main-actor read from a
  nonisolated context or a new escape, and this branch must not add escapes.
  `AppInstaller.deinit` shows the safe precedent — cancel stored task handles,
  touch no isolated state. The protection is structural instead: `run()` has no
  early return that skips a `finish`, every cancellation path funnels through
  `finishCancelled()`, and `start()` takes its strong reference at the moment the
  loop begins. A test covers double-`start()` not stacking monitors.
- **`onProgress` is a plain closure.** It briefly carried `@MainActor` as well,
  which was redundant: the runner is already `@MainActor`, so the closure is
  main-actor-isolated where it is called, and the type system does not have to
  check a `BGTask` capture against a `Sendable`-typed closure.

## Recommended next step, in order

1. Turn `startDownload` and `handlePackageFile`'s `main.sync` hops into
   `precondition(Thread.isMainThread)` + an explicit `DispatchQueue.main.async`
   wrapper at the single off-main caller. That removes a deadlock *class* without
   touching `DownloadManager`'s ownership model.
2. Move `CertificateAutoImporter`'s main-thread work into a `@MainActor` method
   that the utility-queue scan awaits, so the launch path has one hop instead of
   a blocking `sync`.
3. Only then consider `@MainActor` on `Storage`'s synchronous view-context
   accessors, with the compiler confirming every call site.

## Not claimed

No performance improvement is claimed for this phase. Nothing here was compiled
or measured on a device.

---

# Phase 3: the six concurrency escapes, audited

The audit's Issue 6 asked for each escape to be audited and its synchronisation
invariant documented, explicitly *not* to raise the baseline to quiet warnings.
All six were read in full; every one holds today. Two deserve attention.

## Result

| Type | File | Verdict |
| --- | --- | --- |
| `AppOperationRegistry` | `Backend/Services` | **Sound.** Lock held in essentially every method, no call-outs while held. |
| `AppOperationRegistry.Lease` | `Backend/Services` | **Sound.** Immutable closure; `deinit` release is thread-safe. |
| `Download` | `Backend/Observable` | **Sound but fragile — medium risk.** |
| `UnifiedTask` | `Backend/Observable` | **Sound.** Owner is `@MainActor`, no detached tasks in the file. |
| `TaskHistoryJournal` | `Backend/Services` | **Sound.** Serial queue is the synchronisation. |
| `AppFileHandler` | `Utilities/Handlers` | **Sound.** Sequential per-instance pipeline. |

## The one that could stop being true

`Download` is the escape most likely to become a real data race, because the
assumption is about *call sites*, not the type.

The verification path in `DownloadManager+PackageImport.swift` runs
`DownloadIntegrity.verify` on a `DispatchQueue.global(qos: .utility)` queue. That
worker never writes a `@Published` property directly — every mutation
(`dl.isVerifying`, `dl.verificationAuditHash`, progress) is inside a
`DispatchQueue.main.async` block. Both `URLSession`s deliver delegates on
`delegateQueue: .main`, so the rest of the model is main-thread too.

That is correct today, and it is one careless line from being wrong: a future
`dl.progress = x` placed in the utility block would publish a `Combine` change
from a background thread and race the main actor. This is also why
`BackgroundDownloadMonitor` copies values on `@MainActor` instead of handing
`Download` references to a worker — the same class of mistake, in the code this
branch added.

`AppFileHandler` has a milder version of the same shape: `_ipa` and
`uniqueWorkDirPayload` are only safe because its pipeline is sequential per
instance. Two steps running concurrently on one handler would race.

## What was added

A count cannot tell a reviewer *why* an escape is safe or what would break it, so
the count is now paired with a reason:

- **`Tools/Development/concurrency-audit.json`** — one entry per escape with its `invariant`,
  plus `risk` and, where relevant, a `watch` note naming what would break it. The
  `Download` entry records the main-thread rule and the exact file that depends
  on it.
- **`Tools/Development/test_concurrency_audit.py`** — fails when an escape has no entry, when
  an entry outlives its escape, when a field is missing, or when `risk` is not one
  of `low/medium/high`. It also has a `--self-test` that drives the checks with
  fixtures, so the gate is proven to fail on drift rather than assumed to.
- Wired into `make verify` and the CI quick job, both with `--self-test`.

Verified by hand: adding a throwaway `final class Probe: @unchecked Sendable {}`
fails the new gate *and* the existing counting gate; removing it restores both.

## Where the roadmap stands

| Phase | State |
| --- | --- |
| Background task reliability | Done; uncompiled |
| DownloadManager ownership | Found already correct; documented instead of rewritten |
| Strict-concurrency tooling | `make` target fixed, CI job added (report-only) |
| Concurrency escape audit | Done; now enforced by a gate |
| Signing performance | Not started — blocked on a device baseline, not on code |
| Storage and recovery faults | Not started |
| Installation reliability | Not started |
| iPhone benchmarks | Not started |

The remaining phases need either a compiler (phases 1–3 all carry uncompiled
risk) or a physical device (performance). Continuing to add code here would grow
the unverified surface.

---

# Phase 4: a measured allocation fix in the library hot path

The audit's SwiftUI section listed "avoid recalculating directory size in SwiftUI
sorting" as a likely hotspot. Reading the code, that one is **already fixed** and
should not be touched: `_sizeSnapshot` is a dictionary read inside the comparator,
the directory walk runs in `LibrarySizeSnapshot.measure` on a `.utility` detached
task, and `.task(id:)` gates it. The existing design is correct.

The investigation found a different, provable defect in the same hot path.

## The defect

`LibraryView.sizeMeasurementKey` — the id `.task(id:)` uses to decide whether to
re-measure — built a joined string:

```swift
_sizeGeneration.uuidString + (signed.map { "s:\($0.uuid ?? ""):\($0.date?.timeIntervalSince1970 ?? 0)" }
    + imported.map { ... }).joined(separator: "|")
```

`.task(id:)` evaluates its id on **every body evaluation**, and `LibraryView`'s
body reads `filteredSignedApps` / `filteredImportedApps` / `hasNoContent` about a
dozen times per paint (lines 157, 314, 377, 390, 394, 568, 575, 581, 602, 609,
615, 807, 817, 850, 854). Each of those recomputes a filtered array *and* sorts
it, and the source comment itself notes that "search/layout changes do not
rescan disk" — yet the key is rebuilt in full for every one of them.

For a 900-app library that is roughly:

| Per body evaluation | Cost |
| --- | --- |
| String interpolations for the key | ~900 |
| Joined key size | ~46 KiB |
| Filtered array materialisations | ~12 |
| Sort comparator calls | ~9k |

All on the main thread, to answer one `==` that almost never changes. It also
matters for typing latency: `_searchText` is in the same state, so each keystroke
re-pays it.

## The fix

`LibrarySizeMeasurementKey` (in `Utilities/`) is a `Sendable` value type holding
the generation UUID plus one entry per row. `==` short-circuits on the
generation before touching the entry list, and nothing is interpolated or joined.

It is allocation-only, not behavioural — deliberately:

- order stays significant (the old key joined in array order);
- signed and imported stay distinct (the old `s:` / `i:` prefixes);
- a missing uuid still collapses to `""`;
- `nil` date no longer collapses to the epoch. The old *string* key used `?? 0` and could not
  tell them apart; a value type keeps them distinct. That is a representation change, not a
  behaviour change — swapping a `nil` date for an epoch date on a row genuinely is an input change,
  and the old key would have skipped re-measuring it. Both forms are individually stable, so this
  cannot cause repeated measurement.

Each of those is pinned by a test in `LibrarySizeMeasurementKeyTests`, including
the two collapsing rules, so a future "cleanup" cannot silently change when
measurements fire.

## What is NOT claimed

**No measured speedup.** The table above is arithmetic from the code, not an
Instruments trace, and this environment cannot run one.

**Also not O(1).** An earlier draft of this section said the key comparison became
"O(1) for the common case". That was wrong and is corrected here: `==` compares the
generation UUID first, but when generations match it still compares every entry. The
change removes the per-element **string interpolation and join**, so the constant
factor is much smaller and no allocation happens per row — but the comparison stays
O(n) in the library size, as any correct content comparison must. The honest summary
is "cheaper by a large constant factor, same asymptotics", not "constant time".

Whether even that is visible on a device depends on library size and paint
frequency — which is exactly what the iPhone benchmark suite the audit recommends
would settle.

Anyone replacing this with a claim of "faster library scrolling" would need a
trace from a real device first.

---

# Phase 5: the same defect class, found by pattern instead of by eye

Phase 4 fixed one computed-property hot path in `LibraryView`. Rather than eyeball
three large files next, the pattern was searched for: computed array properties
whose body does `filter`/`sorted`, ranked by how many times the same file reads
them.

## What the sweep found

| refs | body | property | verdict |
| --- | --- | --- | --- |
| 7 | 8 | `StorageDetailView._all` | Not a cost — dictionary lookup; the expensive `_entries` is read once. |
| 7 | 55 | `AppStoreView.sortedAndFilteredApps` | Not a cost — aliases a cached `@State` array rebuilt through explicit generations. |
| 4/4/3 | 1–2 | `TweaksView._autoTweaks` / `_uncategorized` / `_folders` | **Real.** See below. |
| 2–3 | ≤19 | `AppLibraryPicker`, `SourcesView`, `SettingsView` | Small collections; not worth the indirection. |

Two of the three obvious candidates were already correct, which is worth recording:
`AppStoreView` in particular has a deliberate `catalogGeneration` /
`catalogFilterGeneration` scheme and should not be "optimised" again.

## The defect in `TweaksView`

`_allFiltered` filtered **and sorted** the entire tweak collection on every read,
and one paint of `_listContent` reads it five times (results header, list, empty
check, and twice more via `_visibleSelectableIds`), with `_autoTweaks` and
`_uncategorized` each re-deriving it again. A non-search paint therefore did about
six full filter+sort passes. Worse, `_matches` trimmed `_query` **once per
element per pass**, calling `localizedCaseInsensitiveContains` against name, notes
and every auto-inject bundle id.

At 60 tweaks that is roughly 540 element visits and ~1,700 sort-comparator calls
per paint, all to produce the same four arrays.

## The fix

The derived arrays are computed once into `@State` and refreshed from a key that
contains **every input they depend on**: the tweak array, the folder array, the
query and the sort. Both models are `Equatable` structs, so this is a plain value
comparison, and `comparator()` is pure over `SortableItem` properties — it reads no
view state.

Two mistakes made and corrected while writing it, both worth recording because
they are the failure modes of this pattern:

1. **A key that could never change.** The first draft used
   `ObjectIdentifier(manager.tweaks as AnyObject)`. Bridging the array to `AnyObject`
   creates a fresh object every call, so the identity would differ on every body
   evaluation and the key would never be stable — the list would have re-derived
   constantly, and a variant of the same idea (keying on a copy that happens to be
   stable) would have frozen the list instead. Comparing the values cannot drift
   from what `_derive` reads.
2. **A dead method shadowing the new one.** The old instance `_matches` was left
   behind after the static one was added. Removed.

## A regression I shipped in the first version of this fix

Worth recording, because it is the characteristic failure of cached derived state:
the first version cached into `@State` and refreshed from `.onAppear` / `.onChange`.
The **first** paint renders before either runs, so `_listContent` read empty arrays
and showed "Nothing here" until a second render. It would also have run the whole
derivation again on every `@State` write.

The fix is that the cache now validates on **read**: `_current` compares the current
inputs against the key that produced the stored value and recomputes on a miss.
There is no window where the cache can be consulted without a matching comparison,
so it cannot be read unseeded. Two supporting details:

- The cache sits behind a reference held by `@State`, so filling it during `body`
  mutates the box rather than the state value. Assigning `@State` during view
  evaluation is the "Modifying state during view update" hazard; this avoids it.
- The query is trimmed in the key, so the key sees exactly what the derivation
  filters on.

The earlier `ObjectIdentifier` mistake and this `onAppear` mistake are the same
error in two forms: a key that does not describe the inputs. Validating on read
is what makes the key's completeness checkable rather than hoped for.

## Still not claimed

No measurement. The counts above are arithmetic from the code. The verifiable
statement is that a paint no longer does work proportional to the collection on
every read, and that the invalidation key cannot drift from the computation. A
device trace is still the only thing that could turn that into a speed claim.

---

# Phase 6: re-auditing phases 1–5 for the mistake I kept making

Two regressions were found in this branch's own work (an unusable cache key, then a
cache populated after first render). Both were the same error: **an assumption that
did not hold at a lifecycle boundary.** So the whole diff was re-read looking
specifically for that shape, rather than for new work. Two more were found.

## Finding 1 — a background task could be completed zero times

All three handlers did:

```swift
Task { @MainActor in
    ...
    task.setTaskCompleted(success: ...)
}
```

The gate guarantees *at most* one completion. Nothing guaranteed *at least* one.

The main-actor hop is exactly the kind of boundary that breaks: the app can be
suspended or terminated between the `BGTaskScheduler` launch handler returning and
the main-actor task running. In that window no runner exists, so no `finish` is
reachable, and the expiration handler only cancelled — it never completed. The
task is then never completed at all, which holds the app's background budget open
until the system kills it.

This is the mirror image of the original bug. Phase 1 fixed *two* completions; it
left *zero* possible.

**Fix:** `BackgroundTaskOwnership` is a single claim shared between the runner and
the expiration handler.

- The runner claims immediately as it starts, before any suspension point in its
  loop — from then on every path reaches a `finish`, so expiration must not act.
- If expiration arrives and nobody claimed, no runner will ever run, so expiration
  completes the task itself.

Five tests pin the handshake, including repeated expiration (completes once) and a
runner starting after expiration (does not resurrect a closed task).

The refresh handler is a special case worth its own note: its entire body *is* the
main-actor hop, so ownership tracking would have nothing to claim with. Expiration
completes directly there, which is safe because the gate is idempotent.

## Finding 2 — a false complexity claim in Phase 4's documentation

Phase 4 said the new key comparison became "O(1) for the common case". It did not.
`==` short-circuits on the generation UUID, but when generations match it compares
every entry — it must, since the key exists to detect content changes. The
improvement is the removal of per-row string interpolation and joining (a much
smaller constant factor, no per-row allocation), with the same asymptotic
behaviour.

Corrected in place. The original claim would have been the kind of thing that gets
repeated in a review as if it were measured.

## What this phase says about the rest of the branch

Two of six phases contained self-inflicted defects, and both were at a boundary
between "set up" and "used" — first render, first completion. Every remaining claim
in this document that rests on a lifecycle boundary has now been re-read. The ones
that rest on the compiler still have not been checked by anything but careful
reading, and that is the residual risk this branch carries.

---

# Phase 7: the Sendable claims, checked instead of assumed

The app target sets no `SWIFT_STRICT_CONCURRENCY` (verified: zero occurrences in
`project.pbxproj`), so it compiles under Swift 5 **minimal** checking. That matters
because a class declared `Sendable` is checked even in minimal mode: every stored
property must itself be `Sendable`.

## A conformance that could not be satisfied

Phase 6 introduced `final class BackgroundTaskOwnership: Sendable` holding a
`BackgroundTaskCompletionGate`. That gate holds the `BGTask` through its completion
closure, and `BGTask` is not `Sendable` in the SDK. A `Sendable` class with a
non-`Sendable` stored property is a compile error — an assumption, not a
measurement, and one I had written without checking.

The conformance was removed. The safety is real and unchanged (the only mutable
state is an atomically claimed lock-backed flag; the gate is lock-protected), but
expressing it as a conformance would require `@unchecked` — a new entry in the
tracked escape baseline, which this branch must not add. The reasoning now lives in
the type's documentation and beside the equivalent note on the gate.

## What is genuinely `Sendable`

Removing that one conformance made the rest worth checking properly:

| Type | `Sendable`? | Why |
| --- | --- | --- |
| `BackgroundDownloadWork` | yes | all `Int`/`Double`/`Bool` |
| `BackgroundTaskCompletionGate.Outcome`, `.Source` | yes | value types |
| `BackgroundWorkCancellation` | yes | holds only `OSAllocatedUnfairLock<State>` |
| `BackgroundWorkCompletionFlag` | yes | holds only `OSAllocatedUnfairLock<Bool>` |
| `LibrarySizeMeasurementKey` (+`.Entry`) | yes | `UUID`, `String`, `Double`, `Bool` |
| `BackgroundTaskCompletionGate` | no | captures `BGTask` |
| `BackgroundTaskOwnership` | no | holds the gate |

`BackgroundTaskSendabilityTests` pins the top half with a `T: Sendable` generic
constraint, so removing one of those conformances stops the test file compiling.

## A negative test that proved nothing, removed

The first version of that file also tried to assert `BackgroundTaskCompletionGate`
does **not** conform:

```swift
XCTAssertFalse(BackgroundTaskCompletionGate.self is any Sendable.Type)
```

That is not a conformance test. `T.self is any Sendable.Type` inspects the
*metatype's* type — `T.Type` is always `Sendable`-shaped here — so it returns the
same answer for every `T`. It would have passed no matter what the gate conformed
to. Negative conformance cannot be asserted in Swift, so the test was deleted
rather than left as something that looks like evidence. The class note explains
why, and points at the concurrency test that does provide real evidence.

This is the same lesson as Phase 6's "O(1)" claim: a statement that reads like a
verified fact is worse than no statement.

---

# Phase 8: the tests are code too

Phases 1–7 audited the app target. The test files are also uncompiled code, and they
are the *only* thing that will exercise the new logic — a broken test is worse than a
missing one, because it fails for a reason that looks like a real regression.

Applying the same reference check found two problems.

## Finding 1 — a reference to a type that does not exist

`BackgroundTaskSendabilityTests` asserted:

```swift
requireSendable(BackgroundDownloadWork.Entry?.self)
```

`BackgroundDownloadWork` has no nested `Entry`; only `LibrarySizeMeasurementKey`
does. This would not have compiled. Removed.

That is the sixth self-inflicted defect in this branch, and the first found in a
*test* — which is the category least likely to be caught by review, because test
failures get attributed to the code under test rather than to the test.

## Finding 2 — a comment describing behaviour that had moved

Both handlers' expiration comments still described the pre-Phase-6 design, where
expiration called `gate.expire()`. After ownership was introduced, expiration calls
`ownership.expired()`, and `gate.expire()` is reached only from the runner's
cancellation path.

The **order** in the handler is what makes it correct, and it was undocumented:
cancel the monitor first, then ask ownership. If a monitor was running its
cancellation path closes the gate and `expired()` is a no-op; if the hop never ran,
no monitor exists and `expired()` completes. Reversed, an expiration could close the
gate while a live monitor still believed it owned the result — reintroducing, in a
narrower window, exactly the contradiction Phase 1 removed.

Comments corrected to describe the order and why it matters.

## What was checked and found correct

- Every type the three test files reference resolves to a declaration in the app
  target or the standard library (after excluding comments and string literals).
- Every member they call exists, with `isSet` and `measure` confirmed as a computed
  property and a `LibrarySizeSnapshot` member respectively rather than omissions.
- `private` nested types inside `TweakLibraryList` are legal: the containing type is
  file-internal, and Swift's access rule is applied at the enclosing declaration.

## Status of the branch

Eight phases. Six self-inflicted defects, all found by re-reading, none by tooling.
Three of those six would have failed the build or produced visibly wrong behaviour.

Everything portable is green. Nothing has been compiled.

---

# Phase 9: what CI actually found

This branch was opened as a pull request after eight phases of reading. CI found
things reading had not, in both directions.

## Defects in this branch, found by the compiler and the tests

| What | Caught by | Note |
| --- | --- | --- |
| `BGProcessingTask.progress` does not exist | build | Only `BGContinuedProcessingTask` publishes progress. I wrote it from memory. |
| `completedPercent` reported 100 while work remained | simulator test | My own test asserted the right rule and failed. |
| Two tests encoded the old behaviour | simulator test | Both written this branch, both corrected to the new rule. |
| `nil`-date key test asserted a premise the type does not have | simulator test | The doc claimed the collapse was "preserved"; it was not, and is now corrected. |

None of these were visible to `make verify`. The build error in particular — a
member that does not exist on a type — is exactly the class the earlier phases
could only guess at.

## A pre-existing build break that blocked everything

`CertificateExporter.swift` did not compile on `main` at the base commit:

```
error: call can throw, but it is not marked with 'try' and the error is not handled
```

`requireSigningPassword()` is `throws`. `main`'s build job has been red since
`a989867`. Fixed here because the PR could never go green otherwise: the export
returns `nil` and logs, rather than writing a password-less archive.

## Two pre-existing test failures, not caused by this branch

Both fail in files this PR does not touch, and neither references anything it
changed:

- `WebDAVTransferPolicyTests.testExistingSymlinkCannotAliasSourceOrEscapeInbox`
  — `XCTAssertFalse` on the alias/outside cases.
- `LibraryInstallationLifecycleTests.testAnAttemptIsBelievedForExactlyItsBound`
  — `XCTAssertTrue(store.isInstalling(identifier))` after anchoring an attempt at
  epoch 2,000,000.

**The first is now fixed.** `activeInstallation(identifier:now:)` accepted a clock
but `isInstalling` called it without passing one, so it fell back to `Date()`. The
attempt was 56 years stale by the real clock, so the timeout branch deleted it and
`isInstalling` returned `false` — while `activeInstallation` asked about the same
synthetic instant returned the attempt. The test was right; the two accessors
disagreed. `isInstalling` now forwards `now`, and the test asks both accessors
about the same instant, which is the property it was always trying to express.

**The second is not fixed, and is worse than it looked.** `WebDAVTransferPolicy`
and `WebDAVTransferPolicyTests` were both introduced by the base commit
`a989867` — there is no earlier revision of either. So the test has never passed,
and the policy it covers is untested rather than regression-tested. Modelled in a
scratch reproduction, all three assertions should hold, so the cause is
environment-specific (symlink resolution semantics under the simulator's
container) and guessing at it would be worse than leaving it visible.

# Environment note: the Linux job's Python

`quick` began failing in its *toolchain* step, not its checks: `python3` was
absent from the job's container, and `apt-get install python3` reported
`E: Unable to locate package python3` even after `apt-get update` exited 0.

Everything pointed the same way. `/usr/bin` held no interpreter at all, so the
container was not the documented `swift:6.4-noble` (which installs
`libpython3-dev` and ships `python3.12`); `/var/lib/apt/lists` was empty, which
its **slim** variant produces by ending the build with `rm -r /var/lib/apt/lists/*`;
and `QUICK_CHECK_SWIFT_IMAGE` was unset, so nothing in the repository explained
the difference. Rerunning `main`'s own `a989867` — which passed `quick` at 05:52
UTC — failed the same step with no workflow change in between.

The fix is not to repair that container but to stop needing one. `ubuntu-24.04`
provides Swift 6.4.2 and Python 3.12.3 directly, which is all this job uses, so
the container dependency and the `QUICK_CHECK_SWIFT_IMAGE` knob are both gone.
The step now asserts that both tools exist and names whichever is missing,
instead of invoking `apt-get` and reporting its generic exit code.
