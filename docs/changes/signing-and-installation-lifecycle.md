# Signing workflow, installation status and install queue lifecycle

Three reported defects, one shared cause: three screens each derived their own idea of "what is
happening" from whatever local state they happened to hold, instead of all reading one
authoritative lifecycle. Signing evidence lived in the signing sheet's `@State`; installation
state lived in a device-probe reading with no vocabulary for "in flight"; the install sheet's
presentation lived in an `if` chain in a view body. Each was locally plausible and each produced a
claim the system had no evidence for.

This change keeps the existing subsystems — `SigningService`, `SigningHandler`, `FR`,
`UnifiedTaskCenter`, `LibraryStatusStore`, `InstallQueue`, `AppInstaller`, `InstallConfirmation` —
and makes the state they already produce authoritative and observable. No task-management system
was duplicated and no screen was rewritten except the two whose display logic was the defect.

The ten-area major-bug investigation that followed this change — native signing, private APIs,
identity matching, nested bundles, concurrency, cancellation, archive extraction, cloud signing,
guest-host packaging and CI coverage — is reported separately in
[`major-bug-investigation.md`](major-bug-investigation.md). Four of its findings interact with the
work described here: the install-lifecycle attempt guards (area 6), the shared archive validator
(area 7), the Open button on library rows whose install state is unknown (area 2), and the native
tests that compile the Apple-account sources this change touched (area 10).

## Issue 1 — the Signing workflow reads "Not run" after signing ran

### Root cause

The transport was sound end to end. `SigningHandler.onStage` → `SigningPipeline`'s `reporting`
closure → an unbounded `AsyncStream` → a `Task { @MainActor }` inside `SigningService.sign` →
`FR.signPackageFile`'s `onStage` → `SigningView`. Stages were never dropped, never delivered off
the main actor, and never reordered. Four separate defects sat downstream of it:

1. **Success was read from the wrong property.** `SigningView` passed
   `succeeded: _postSignAction != nil` into the workflow. `_postSignAction` only exists to hand off
   a deferred action when the log sheet happens to be open; on a normal successful run it is `nil`.
   So the terminal step resolved `.pending` — "Not run" — at the exact moment signing worked.
2. **The trace had no lifetime beyond the sheet.** `_reachedStages` and `_currentStage` were view
   `@State`. A run dismisses the sheet on success, and "Sign & Install", Update All, batch jobs and
   self-update sign without ever presenting it. Every one of those left the workflow with no
   evidence to render, so "Not run" was the honest answer for a screen that had been asked about a
   run it never saw.
3. **Verify was inferred from overall success.** Reaching `.registering` is not verification:
   `SigningHandler` skips `_verifySignedBundle` entirely in "modify without signing" mode and still
   emits `.registering`.
4. **The completed workflow was never visible.** The sheet dismisses on success, so even a correct
   panel was gone before it could be read.

### Changes

- `SigningStage` is now `Codable`. Its raw values are the on-disk form and are unchanged.
- `SigningEvent.signatureVerified` — a new non-terminal event, emitted by `SigningHandler` only
  after `_verifySignedBundle` returns without throwing. It is the only evidence that may complete
  the Verify step.
- `SigningWork`'s contract documents the rule: report `.signatureVerified` only when the engine's
  own verification accepted the bundle, never as a side effect of finishing.
- `TaskSigningTrace` (`stages`, `stoppedAt`, `verified`, `outcome`) is recorded on
  `TaskContext.signingTrace` by `FR` as events arrive, bounded at 32 stages and de-duplicated. The
  field is **optional**: synthesized `Decodable` only tolerates a missing key for an optional, and
  `UnifiedTaskHistory.json` written before this field existed must keep loading.
- `UnifiedTaskCenter.latestSigningTask(subjectID:)` and `signingTrace(subjectID:)` are the single
  lookup used by the signing sheet, the app's details screen and the task receipt, so the three
  cannot disagree about which run they describe.
- `SigningWorkflowSnapshot` is a value type built either from the live sheet's state or from a
  persisted trace. `SigningWorkspaceStep.status(_:)` resolves each step from evidence only.
- `SigningWorkflowView` renders from the snapshot. `LibraryInfoView` shows the persisted trace, so
  the workflow survives dismissal and is readable for apps signed by any flow.
- `TaskReceipt` prints the stage sequence and the verification result, so an exported receipt says
  which steps actually ran rather than only which phase the task reached.

### Step-status precedence

`Install` is a separate lifecycle and is always `.separate`. For the other four steps, in order:

| # | Condition | Status |
|---|---|---|
| 1 | No reached stage maps to this step | `.pending` — "Not run" |
| 2 | This is the current step and the run is in flight | `.active` |
| 3 | This is the current step and the run failed | `.failed` |
| 4 | This is the current step and the run was cancelled | `.cancelled` |
| 5 | `Verify`, and the engine reported `.signatureVerified` | `.completed` |
| 6 | `Verify`, and it did not | `.pending` |
| 7 | Any other step, and a later step was reached, or the run succeeded | `.completed` |
| 8 | Otherwise | `.pending` |

Rule 3/4 deliberately outranks rule 7: a run that verified the signature and then failed while
registering the artifact failed *at Verify*, and that is the step the user needs to see.

Nothing is inferred from elapsed time. Nothing is inferred from the run succeeding overall, except
through the compatibility entry point `status(reached:current:running:succeeded:failed:cancelled:)`,
which maps `succeeded` to `verified` because a run can only finish successfully when
`_verifySignedBundle` accepted the bundle — and which the live sheet no longer uses.

### State transition diagram — signing

```
                        ┌──────────┐
                        │  queued  │
                        └────┬─────┘
                             │  FR.signPackageFile
                             ▼
      ┌──────────────────────────────────────────────────┐
      │ signing                                          │
      │                                                  │
      │  .copying ──► Prepare      completed             │
      │  .modifying ┐                                    │
      │  .thinning  ├► Customize   completed             │
      │  .injecting ┘                                    │
      │  .signing ──► Sign         completed             │
      │  .verifying ► Verify       active                │
      │       │                                          │
      │       └─ signatureVerified ─► Verify completed   │
      │  .registering ► (still Verify; NOT evidence)     │
      └───────┬───────────────┬──────────────┬───────────┘
              │ .finished     │ .failed      │ .cancelled
              ▼               ▼              ▼
        ┌──────────┐    ┌──────────┐   ┌───────────┐
        │  signed  │    │  failed  │   │ cancelled │
        └────┬─────┘    └──────────┘   └───────────┘
             │  artifact registered; Install is NOT touched
             ▼
       ┌───────────┐
       │ completed │
       └───────────┘

  Trace persisted on TaskContext.signingTrace at every arrow above, so the
  workflow is reconstructable after the sheet is dismissed.
```

## Issue 2 — a signed app reads "Not installed" while iOS is installing it

### Root cause

`InstalledState` had no vocabulary for "in flight": `installed`, `installedOtherVersion`,
`notInstalled`, `unknown`. The install path only ever contacted `LibraryStatusStore` from
`AppInstaller._finish` → `recordConfirmedInstallation`, and only when the outcome counted as an
install. So for the entire window between the installer starting and a confirmation arriving, the
row's state was whatever the last device read said.

That window is exactly when the app returns to the foreground from iOS's install prompt, and
`VexSignApp` runs `LibraryStatusStore.refreshKnown()` on `scenePhase == .active`. The refresh
force-read every visible row, and a mid-install LaunchServices lookup answers "not there yet" — so
the store published a stale negative over an installation that was genuinely running.

### Changes

- `InstalledState.installing` plus `isTransient`. `InstalledState.derive` never returns it: a probe
  answers "what is on the device", and the transient state is a lifecycle fact owned by the queue.
- `InstalledBadge` gained `.installing` ("Installing", `arrow.triangle.2.circlepath`) and a new
  `.active` tone, rendered as `Color.userTint` — neither the green of a verdict nor the orange of a
  caution.
- `InstallationAttempt { identifier, attemptID, taskID?, startedAt }` keyed by bundle identifier,
  with a 900 s backstop (`LibraryStatusStore.attemptTimeout`) that only exists so a registration
  whose owner died cannot pin a row on "Installing" forever. Every real path ends the attempt
  explicitly.
- `LibraryStatusStore.beginInstallation(identifier:attemptID:taskID:now:)` publishes `.installing`
  to **every** known request carrying that identifier, so several library entries sharing one bundle
  identifier all follow the same attempt.
- `endInstallation(identifier:attemptID:)` returns `false` for a stale attempt ID — an abandoned
  attempt can neither clear nor rewrite the attempt now in flight. It drops only the transient
  state, then applies any confirmation receipt, then forces a fresh read.
- `resetInstallations()`, `isInstalling(_:)` and `activeInstallation(identifier:)`.
- `applyingActiveInstallation(to:request:now:)` is applied as the last step in **three** places:
  `request` seeding, `recordConfirmedInstallation`, and the `_flush` delivery of a background read.
  A read already in flight when an install started therefore cannot publish the negative it was
  about to. It is also self-cleaning: with no live attempt it downgrades a lingering transient
  state to `.unknown` rather than returning it unchanged.
- `request` skips dispatching a device read entirely while an attempt owns the answer. The read it
  skips is requested again by `endInstallation`, so nothing is left unread. `refreshKnown()`,
  `invalidate(bundleIdentifier:)` and forced refreshes all funnel through `request`, so the fence
  covers every one of them.
- `invalidateAll()` clears attempts alongside confirmations and statuses.
- `InstallQueue` registers the attempt at the moment the installer really starts — never when an
  install was merely requested, and never from a signing success. Attempt IDs carry the run
  generation and the task record. An export (`entry.archive`) and a guest import
  (`installationMethod == 2`) are not registered: neither touches iOS's installed-app registry.
- `AppInstaller._finish` records the confirmation **before** invoking `completion?`, so the
  queue ends the attempt into an already-recorded receipt and the row goes straight to `.installed`.
- `LibraryCellView` hides "Open" while an attempt is in flight; a button that can only fail is not
  a way in.

### State transition diagram — installation

```
  requested (user taps Install)
        │
        ▼
  queue accepted ────────────────► library row: unchanged (no claim yet)
        │
        ▼
  installer prepared / packaging ─► library row: unchanged
        │
        │  InstallQueue._beginInstallationAttempt
        │  beginInstallation(identifier, attemptID, taskID)
        ▼
  ┌─────────────────────────────────────────────────────┐
  │ installation started        library row: INSTALLING │◄───┐
  │                                                     │    │ fenced:
  │   iOS prompt accepted (or not — the prompt is       │    │ probe reads,
  │   unobservable; VexSign does not treat acceptance   │    │ forced refresh,
  │   as an outcome and keeps monitoring)               │    │ refreshKnown,
  │                                                     │    │ invalidate,
  │   device verification ─ InstallConfirmation         │    │ in-flight read
  └───┬──────────┬───────────┬───────────┬──────────────┘    │ results,
      │          │           │           │                   │ stale
      ▼          ▼           ▼           ▼                   │ completions
 installed  otherVersion  failed   unconfirmed ──────────────┘
      │          │           │           │
      │  endInstallation(identifier, attemptID) — stale attemptID is rejected
      ▼          ▼           ▼           ▼
  INSTALLED  INSTALLED   NOT INSTALLED  UNKNOWN
             (other ver)  / FAILED      (never a guessed negative,
                                         never a guessed positive)

  cancel / skip / stop / queue reset ─► endInstallation or resetInstallations
                                        ─► transient state cleared, row re-read
  attempt older than 900 s with no owner ─► pruned, row falls back to UNKNOWN
```

The signing lifecycle never enters this diagram. `.signed` and `.completed` on a signing task
register an artifact; they do not touch the installation state.

## Issue 3 — the install sheet spins, or dismisses at the wrong moment

### Root cause

Three separate gaps:

1. **The OTA prompt window was unbounded.** `_armDeclineWatch` only armed from `.sendingManifest`,
   and `startTimeoutEnabled` reports `_hasServedPayload`, which suppresses the confirmation
   engine's own start timeout until the payload is served. Between opening `itms-services://` and
   the payload being served, nothing was counting. A dismissed prompt, or iOS failing to reach the
   local server, left the card showing "Installing" with no exit but Skip.
2. **The card never said which app it was installing.** `InstallCardView` showed an icon and a
   status. In a queued batch there was no way to tell whose turn it was — or to notice that a stale
   completion had left the previous app on screen.
3. **Presentation and race decisions lived in a view body.** `InstallQueueSheet` resolved its
   content through an `if` chain, with a blank-colour fallback, and the scheduled advance and
   deferred dismissal had no guard against a run that had been reset and restarted underneath them.

### Changes

- `AppInstaller._armPromptDeadline()`, armed in `_openInstall` and cancelled in `deinit`, `stop()`
  and `_finish()`. It fires `_finishConfirmed(.timedOutWaiting)` only while `!_hasFinished &&
  !_hasServedPayload`, reusing `InstallConfirmation.Limits().start` (120 s) rather than inventing a
  second bound. The outcome is "the install never started" — not a success, and not a claim that
  iOS rejected anything.
- `InstallQueueSurface`, a pure enum (`hidden`, `finished`, `report`, `installing`, `paused`,
  `preparing`) with `resolve(...)` replicating the sheet's exact chain, plus `isMonitoring` and
  `isActionable`. The sheet renders from it and matches on the entry ID, so a completion from an
  abandoned run cannot put a stale card back on screen. The same rules are now assertable without a
  window, an installer or a device.
- `InstallQueue.runGeneration`, bumped by `_reset()`. `_scheduleAdvance` and `_dismissFinishedQueue`
  both capture the generation they were created under, and their guards are factored into
  `mayRunScheduledWork(...)` and `mayDismissFinishedRun(...)`. An old queue's completion cannot
  advance, dismiss or rewrite a newly started one.
- `InstallQueue.FailureKind` separates four situations that used to collapse into two:

  | Kind | Trigger | Title | Recorded as failure? | Sheet |
  |---|---|---|---|---|
  | `needsTrust` | `ServerInstaller.LocalInstallError.unavailable` | HTTPS Setup Required | yes | held |
  | `neverStarted` | `.timedOutWaiting` | Install Never Started | yes | held |
  | `unconfirmed` | `.timedOutVerifying` | Installation Not Confirmed | **no** | released |
  | `failed` | anything else | Install Failed | yes | held |

  The two that were wrong before: a genuine failure told the user the app "may already be
  installed", and an install that never started was titled "Installation Not Confirmed" as though
  iOS had been asked and stayed silent. Each summary is now something the user can act on.
- `InstallerStatusViewModel.displayedPercentage(phase:overall:isCompleted:)` is pure and returns a
  number only when a counter produced one: `.downloading` with `0 < overall < 1`, or `isCompleted`
  → 100. `waitingForStart` has no counter; `verifying` deliberately holds the ring below 1.0 until
  the device answers. The ring keeps animating — only the text is withheld.
- `InstallCardView` shows the app name (`app.name ?? .localized("Application")`, tagged
  `A11y.Install.appName`) and the percentage when there is one.
- `AccessibilityIdentifiers` gained `A11y.Signing.workflow` and `A11y.Install.appName`.

### What is *not* treated as an outcome

Accepting iOS's install prompt is not a terminal outcome and does not dismiss the sheet. iOS never
reports the answer back, so monitoring continues until a genuine terminal outcome or a bounded
unconfirmed one. `.timedOutVerifying` is the only unconfirmed verdict; it releases the sheet so the
app is not held behind an unobservable spinner, keeps the report and its recovery actions reachable
in Activity and the queue pill, and does **not** record a failure the device never reported.

### State transition diagram — install sheet

```
                    resolve(isPresented, isFinished, failureTitle,
                            hasInstaller, isPaused, currentEntryID)

  isPresented == false ─────────────────────────────► hidden
  isFinished ───────────────────────────────────────► finished(succeeded, failed)
                                                       monitoring: no   actionable: yes
  failureTitle != nil ──────────────────────────────► report(title, entryID)
                                                       monitoring: no   actionable: yes
  hasInstaller && currentEntryID ───────────────────► installing(entryID)
                                                       monitoring: yes  actionable: yes
  isPaused && currentEntryID ───────────────────────► paused(entryID)
                                                       monitoring: yes  actionable: yes
  otherwise (packaging) ────────────────────────────► preparing
                                                       monitoring: yes  actionable: no
                                                       (transient: ends in a card or a report)

  Every presented surface either monitors something real or offers a way out.

  Bounded above by:
    Limits.start  120 s  prompt → payload served   (_armPromptDeadline)
    Limits.verify 120 s  progress ended → evidence
    Limits.settle  20 s  version to catch up
    Limits.unavailableEvidence 30 s  filtered/unreadable lookup
    LibraryStatusStore.attemptTimeout 900 s  abandoned registration backstop
```

## Files modified

Production (20 files):

| File | Change |
|---|---|
| `VexSign/Utilities/Signing/SigningService.swift` | `SigningStage: Codable`; `SigningEvent.signatureVerified` + `isTerminal`; `SigningWork` contract; `SigningPipeline` wiring |
| `VexSign/Utilities/Handlers/SigningHandler.swift` | `onSignatureVerified`, fired only after `_verifySignedBundle` returns |
| `VexSign/Backend/Services/TaskTrace.swift` | `TaskSigningTrace`; optional `TaskContext.signingTrace`; recording helpers |
| `VexSign/Utilities/FR.swift` | `onVerified:` parameter; records stage, verification and outcome on the task |
| `VexSign/Backend/Observable/UnifiedTaskCenter.swift` | `latestSigningTask(subjectID:)`, `signingTrace(subjectID:)` |
| `VexSign/Backend/Services/TaskReceipt.swift` | signing-stage and verification lines |
| `VexSign/Views/Signing/SigningWorkflowView.swift` | `SigningWorkflowSnapshot`; evidence-only `status(_:)`; legacy wrapper retained |
| `VexSign/Views/Signing/SigningView.swift` | `_signingSucceeded`, `_signatureVerified`, `_workflowSnapshot`, observed task center, reset in `_beginSign` |
| `VexSign/Views/Library/Info/LibraryInfoView.swift` | persisted-trace workflow panel; shared task lookup |
| `VexSign/Utilities/Installing/InstalledAppProbe.swift` | `InstalledState.installing`, `isTransient`, `.title` |
| `VexSign/Utilities/Installing/InstallConfirmation.swift` | exhaustive `.installing` case in `record(probe:)` |
| `VexSign/Backend/Observable/LibraryStatusStore.swift` | `InstallationAttempt`, attempt registry, lifecycle API, overlay in three places, read fence, `.active` badge tone |
| `VexSign/Backend/Observable/InstallQueue.swift` | attempt registration and fencing, `runGeneration`, scheduled-work guards, `FailureKind`, `InstallQueueSurface` |
| `VexSign/Backend/Observable/AppInstaller.swift` | `_armPromptDeadline()` and its cancellation in `deinit`/`stop()`/`_finish()` |
| `VexSign/Backend/Observable/InstallerStatusViewModel.swift` | pure `displayedPercentage` |
| `VexSign/Views/Library/Install/InstallQueueWindow.swift` | sheet renders from `InstallQueueSurface`; `_summary` extracted |
| `VexSign/Views/Library/Install/InstallCardView.swift` | app name and honest percentage on the card |
| `VexSign/Views/Library/LibraryCellView.swift` | `.active` tint; "Open" gated on `!isTransient` |
| `VexSign/Utilities/AccessibilityIdentifiers.swift` | `Signing.workflow`, `Install.appName` |
| `VexSign/Resources/Localizable.xcstrings` | 7 new keys, appended by `tools/sync-strings.py --write` as `extractionState: manual` — no machine translation |

Tests (4 files):

| File | Change |
|---|---|
| `VexSignTests/SigningWorkflowTraceTests.swift` | new — 25 tests |
| `VexSignTests/LibraryInstallationLifecycleTests.swift` | new — 20 tests |
| `VexSignTests/InstallQueueSheetLifecycleTests.swift` | new — 28 tests |
| `VexSignTests/AccessibilityIdentifiersTests.swift` | expected-identifier list gained the 2 new IDs |

No `.xcodeproj` edit is required: the project uses `PBXFileSystemSynchronizedRootGroup`, so new
`.swift` files under the synchronized roots are included automatically. `tools/check-pbxproj.py`
confirms the structure is unchanged and valid.

## Regression tests added

73 new tests. Stubs are private and uniquely named across the `VexSignTests` module
(`_VerificationWork`, `_AnswerProbe`, `_GatedProbe`) because the module's `duplicate-types` gate is
per-module and `StubProbe`/`ControlledLibraryProbe` are already taken in `BundleSignatureTests`.

**Signing workflow — `SigningWorkflowTraceTests` (25)**

Every step "Not run" with no evidence and with an empty trace · a step the engine never reported
stays "Not run" · the active step is the one being reported · steps moved past stay completed ·
a failure lands on the step it stopped at · a cancellation lands on the step it stopped at · a
failure after verification lands on Verify, not an earlier step · reaching Verify does not complete
it · Verify stays "Not run" when the run succeeds without ever verifying (the modify-only case) ·
Verify completes only on `.signatureVerified` · a successful run completes Prepare/Customize/Sign/
Verify but Install stays `.separate` · Install is separate while running and after a failure · the
legacy flag-based entry point still maps overall success to verified, and an unfinished run does not
· `TaskContext` records the trace as the engine reports it · repeated stages are not duplicated ·
the trace is bounded at 32 stages · the trace survives `UnifiedTask.Snapshot` JSON round-trip ·
a `TaskContext` written before the field existed still decodes · the center keeps the trace after
the run finishes and leaves the active list · an app that was never signed has no workflow ·
`.signatureVerified` is non-terminal · stages and verification reach the main-actor subscriber in
order with zero events delivered off the main thread and exactly one terminal event · the recorded
trace matches what the subscriber received.

**Installation status — `LibraryInstallationLifecycleTests` (20)**

A row is unknown before an attempt and never guesses installed · a genuine negative before an
attempt is still "Not installed" · one attempt publishes "Installing" to two rows sharing a bundle
identifier · `installing` is its own state and its own badge, distinct from every verdict · the
device probe never derives the transient state itself · a probe reading cannot overwrite an active
attempt · a forced refresh, `refreshKnown()` and `invalidate()` dispatch **zero** device reads while
an attempt is live · a read already in flight when the attempt started cannot publish its negative
· a confirmed install becomes "Installed" only when the attempt ends (confirmation alone keeps
"Installing") · a confirmed install at a different version says so · an unconfirmed attempt ends
"Unknown", never "Not installed" and never "Installed" · a failed attempt clears the transient state
· a cancelled attempt clears it · ending the same attempt twice is inert · a queue reset forgets
every attempt · an attempt with no identifier or no attempt ID is not registered · a stale attempt
can neither clear nor rewrite a newer one, and its confirmation stays unpublished · an attempt for
one identifier does not leak to another · a row mounted mid-attempt reads "Installing" immediately ·
an expired attempt stops pinning the row.

**Install sheet — `InstallQueueSheetLifecycleTests` (28)**

An idle queue presents nothing · an installation in flight stays visible and actionable · packaging
before an installer exists is not an empty sheet · a finished run transitions to the summary · a
finished run outranks a leftover installer · a failure presents recovery instead of a spinner · a
failure outranks the installer card · a paused queue stays actionable · an unconfirmed outcome
releases the sheet but keeps the report · no presented surface monitors forever without either an
installer or a way out · the four failure kinds are kept apart and trust outranks the verdict · an
unconfirmed install is not recorded as a failure and does not read as one · an install that never
started does not imply it might have worked · a genuine failure keeps its recovery actions on screen
· every failure kind has a distinct title and summary · a failure presentation carries its recovery
context · a percentage is only shown when a counter produced it · degenerate progress values
(NaN, ±∞, negative, a stale full counter) never become a percentage · attempt identifiers are unique
per run and entry · a stale completion cannot end the attempt in flight · scheduled work from an
abandoned run cannot advance a newer one · a finished run cannot dismiss a queue started after it ·
Skip ignores stale taps and failure actions stay available · Retry cancels the pending success
advance · a reset cancels every pending transition · the prompt window is bounded so the sheet
cannot spin forever · an install that never started is not reported as installed · an unbounded wait
produces a terminal verdict, not a success.

## Validation

**Run in this workspace and passing:**

| Gate | Result |
|---|---|
| `make verify` | exit 0 |
| `.github/scripts/quick_check.py --no-swiftc` | ✅ 0 errors, 0 warnings across all 9 checks (`repository-layout`, `tool-syntax`, `conflict-markers`, `duplicate-types`, `duplicate-filenames`, `cross-module-imports`, `resources`, `pbxproj`) |
| `tools/sync-strings.py --check` | ✅ 467 Swift files · 3272 distinct literals · 3552 catalogue keys — every literal has a key |
| `tools/check-pbxproj.py` | ✅ 42 pins agree across workspace and project; structure OK |
| `tools/concurrency-discipline.py` | ✅ 6 escapes across 5 files — at baseline, none added |
| `tools/singleton-freeze.py` | ✅ 62 singletons across 61 files — at baseline, none added |
| `tools/error-discipline.py` | ✅ 239 unjustified `try?` across 95 files — 5 **below** baseline |
| `make verify` gate self-tests | ✅ 250 Python tests, all OK (264 since the ten-area investigation added three gates — see [`major-bug-investigation.md`](major-bug-investigation.md)) |
| `make docs-check` | ✅ file links OK; 3 documentation tests OK |

`tools/error-discipline.py` was **not** run with `--write`: the baseline was not regenerated, so the
improvement stays visible rather than being folded into the floor.

No new singleton, no new `@unchecked Sendable` and no new `nonisolated(unsafe)` were introduced in
production code. Bracket balance and comment/string stripping were checked mechanically over all 23
changed and new Swift files.

**Not run, and not claimed as run:**

There is no Swift toolchain in this workspace — no `swift`, `swiftc` or `xcodebuild`, on Debian 12.
The following were therefore **not performed**:

- `make test` (`xcodebuild -workspace VexSign.xcworkspace -scheme VexSignTests`) — XCTest results
  for the 73 new tests and the existing suite are unknown.
- Any compile of the changed Swift. Every edit was hand-checked for exhaustiveness, overload
  resolution, actor isolation and API signatures against the declarations in this repository, but
  that is not a compiler.
- `make strict-concurrency`, `make lint`, the IPA build, `make device-smoke`.
- Anything on a physical device. **No on-device verification was performed.**

To run them on macOS:

```bash
cd VexSign
make verify                 # portable gates, no Xcode needed
make test                   # XCTest: app simulator scheme VexSignTests
make strict-concurrency     # local packages with concurrency diagnostics
make lint                   # optional SwiftLint report
```

Or the focused XCTest run for just these three files (same destination resolution `make test`
uses, so it works on whatever iPhone simulator the installed Xcode actually ships):

```bash
SIM_ID="$(python3 .github/scripts/select_simulator.py --print-id)"
xcodebuild test \
  -workspace VexSign.xcworkspace \
  -scheme VexSignTests \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$TMPDIR/TestDerivedData" \
  -only-testing:VexSignTests/SigningWorkflowTraceTests \
  -only-testing:VexSignTests/LibraryInstallationLifecycleTests \
  -only-testing:VexSignTests/InstallQueueSheetLifecycleTests \
  -parallel-testing-enabled YES \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  COMPILER_INDEX_STORE_ENABLE=NO ONLY_ACTIVE_ARCH=YES
```

If a failure needs triage, `.github/scripts/surface_test_failures.py` and
`.github/scripts/xcodebuild_report.py` are the repo's own parsers for the output.

Because the project uses synchronized root groups, no Xcode project change is needed for the three
new test files to be picked up.

## Remaining limitations

1. **The prompt window is bounded, not observable.** iOS shows its own install alert and never
   reports the answer. `_armPromptDeadline` guarantees the card resolves within
   `Limits.start` (120 s) instead of spinning forever, but it cannot distinguish "the user dismissed
   the prompt" from "iOS could not reach the local server". Both become `.timedOutWaiting` — an
   honest "the install never started" with recovery actions, not a diagnosis.
2. **Unconfirmed is a real terminal state, not a gap to paper over.** `.timedOutVerifying` ends
   monitoring without claiming either outcome. The library row returns to `Unknown` and is re-read;
   if iOS installed the app, the next read says so. Until then VexSign says it does not know.
3. **One attempt per bundle identifier.** `InstallQueue` runs one installer at a time, so a second
   start for the same identifier replaces the first rather than racing it. Two genuinely concurrent
   installs of the same bundle identifier would need the registry keyed by attempt rather than by
   identifier. That is not a reachable state today.
4. **The 900 s attempt backstop is a floor, not a mechanism.** Every real path ends its attempt
   explicitly. The backstop only prevents a registration whose owner died from pinning a row
   forever; it should never fire in normal operation, and if it does, something upstream leaked.
5. **`SigningStage` raw values are now an on-disk format.** Renaming a case would silently orphan
   traces already written to `UnifiedTaskHistory.json`. Treat them as stable.
6. **The trace is capped at 32 stages.** A pathological run that emitted more would lose its oldest
   entries. Real runs emit 4–6.
7. **Legacy `status(reached:current:running:succeeded:failed:cancelled:)` still equates success with
   verification.** It is retained so `DesignSystemTests` and any future caller with only the old
   flags keep working, and the equivalence is true for the live sheet. Callers with the engine's own
   verdict should build a `SigningWorkflowSnapshot` instead.

## Required on-device acceptance

Run these on a physical iPhone; see [DEVICE_TESTING.md](../DEVICE_TESTING.md) and
`make device-smoke`. None of them has been performed.

**Signing workflow**

1. Sign an app normally, from the signing sheet. Watch Prepare → Customize → Sign → Verify advance;
   Verify must only turn green after the engine's own verification, and Install must read
   "Separate installation step" throughout.
2. Let the sheet dismiss on success, then open the app's details in Library. The workflow panel must
   still show the completed trace — this is the case that used to read "Not run" everywhere.
3. Sign with "modify without signing". Verify must stay "Not run" even though the artifact was
   registered successfully.
4. Stop during copy, during modification, during signing and during verification. The failure or
   cancellation must land on the step that was actually in flight, not on an earlier one.
5. Sign via "Sign & Install", via Update All and via a batch job — flows that never present the
   sheet. Each must leave a readable trace in the app's Library details and in the exported task
   receipt.
6. Kill and relaunch the app after a successful sign. The restored history must still carry the
   trace (this exercises the optional-field decode path against a real journal).

**Installation status**

7. Install over OTA. Return to VexSign from iOS's prompt while the install is still running: the
   Library row must read "Installing", not "Not installed". This is the exact moment the
   `scenePhase == .active` refresh used to publish a stale negative.
8. While that install runs, pull to refresh and scroll the row off and back on. Neither may flip the
   row to "Not installed".
9. Import an unsigned app and sign it, leaving two Library entries with one bundle identifier. Both
   rows must show "Installing" together, and both must resolve together.
10. Complete an install. The row must go to "Installed" — or to the version footnote when the device
    reports a different version — and never through a "Not installed" frame.
11. Let an install go unconfirmed (for example, filter the app out of the inventory). The row must
    read "Unknown", never "Not installed" and never "Installed".
12. Skip mid-install, then Stop after a failure, then reset the queue. No row may be left on
    "Installing".
13. Retry the same app immediately after a failure. The new attempt must publish "Installing" again,
    and a late completion from the abandoned attempt must not disturb it.

**Install sheet**

14. Queue three apps. The card must name the app it is installing, and the name must change with the
    entry.
15. Watch a real transfer: a percentage may appear. Watch the verify phase: it must not. No
    percentage may appear before the counter produces one.
16. Dismiss iOS's install prompt without answering. The card must resolve within about two minutes
    with "Install Never Started" and a Retry action — it must not spin indefinitely.
17. Break local HTTPS trust (Settings → Installation → Server & SSL). The sheet must say "HTTPS
    Setup Required" with the certificate-trust instructions, not a generic failure.
18. Let an install go unconfirmed. The sheet must release, and the report with its recovery actions
    must still be reachable in Activity and the queue pill.
19. Tap Skip twice quickly, and tap Skip just as a success lands. Neither may advance a different
    app or resurrect a finished card.
20. Start a new queue inside the ~0.6 s window after a previous run finished. The old run's deferred
    teardown must not dismiss or clear the new one.
