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

Three later symptoms in the same subsystems — a re-sign with saved settings that stops in Customize,
a valid signed copy whose details read "Failed", and an install card that stays on "Verifying
installation" — are recorded further down, under
[Follow-up](#follow-up--re-signing-with-saved-settings-the-record-of-a-signed-copy-and-install-verification).
Where that follow-up supersedes a statement below, the statement says so.

A second follow-up closes a limitation the first one recorded — a sign that succeeds and leaves no
copy in the library — and two cleanup paths found beside it. It changes what Auto Cleanup's "Delete
Signed App" does, and what a re-sign does with the copy it was started from. It is recorded last,
under [Follow-up 2](#follow-up-2--what-a-successful-sign-leaves-in-the-library), and the statements
of the first follow-up that it supersedes say so.

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
  cannot disagree about which run they describe. *Superseded for the details screen by the
  follow-up (Issue 5):* the newest run **started from** a copy is the right answer for the sheet
  and the wrong one for a screen describing the copy, which now asks `signingRecords(forCopy:)`.
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

Since the follow-up (Issue 4), `.signing` is reported when customization ends — before the
nested-bundle audit and the certificate check — rather than when the engine starts. A refusal by
either therefore lands on Sign, not on Customize. A "modify without signing" run still never
reports the stage.

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

  Added by the follow-up (Issue 6):
    Limits.evidenceGrace       10 s  an unanswered check this soon after an answered one
                                     is a missed check, not "no evidence"
    Limits.monitoringBackstop 390 s  payload served → any terminal outcome, counted while
                                     the app is running   (_armMonitoringBackstop)
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

---

## Follow-up — re-signing with saved settings, the record of a signed copy, and install verification

Three further symptoms in the subsystems above, investigated at `67fd3f3`:

| # | Symptom | Where it came from |
|---|---|---|
| 4 | "Re-sign with Last Settings" (and Update All) stops, and the workflow reads "Customize: Failed, Sign: Not run" | Saved settings replayed the paths of one-time tweak files that no longer existed; "Sign Anyway" was not forwarded; a refusal by the certificate or profile was reported on the wrong step |
| 5 | The details of a valid signed copy read "Last recorded signing result: Failed" | The screen showed the newest run **started from** the copy, not the run that **produced** it |
| 6 | The install card stays on "Verifying installation" | Nothing outside the polling loop bounded the attempt once the payload was served, the loop ran at background priority, one unanswered check could end verification, and a declined install left its task record open for the next app |

**Read this first.** Every root cause below was established by reading the code. Nothing in this
follow-up was run on a device, and the parts that need the iOS SDK were not compiled; what was and
was not executed is listed under [Validation (follow-up)](#validation-follow-up). Where a statement
is an inference rather than something the code states outright, it says so.

### Issue 4 — "Re-sign with Last Settings" stops in the Customize step

#### Root cause

Three defects, any one of which produces the symptom, and a fourth found while tracing how staged
files disappear:

1. **One-time tweak files were saved by path.** `SigningTweaksView` stages each file added "just for
   this sign" under `tmp/VexSignTweak_<UUID>/` and appends the URL to `Options.injectionFiles`.
   - `TweakHandler` handed those URLs to its job, which **moves** a `.dylib`, `.framework` or
     `.bundle` into the app bundle. After one run the URL named nothing. A second attempt in the
     same sheet — after any failure later in the run — stopped in `.injecting`.
   - On success `SigningProfileStore` saved the options, URLs included, as the app's last-used
     settings. A `NamedSigningProfile` preset kept them too, and presets can be exported.
   - Whatever the engine had not moved — a `.deb` is read in place — was removed later:
     `StorageManager.purgeStaleTemporary()` empties the temporary directory at every launch
     (download staging aside), and Auto Cleanup's "Clear Temporary Files" does so after a sign or
     an install.
   - "Re-sign with Last Settings" (`AutoSignManager`), Update All with preserved signing options
     (`UpdateAllManager`) and an applied preset then replayed URLs that named nothing.
     `FileManager.moveItem` threw a Cocoa "no such file" error while the stage was `.injecting`,
     which the workflow shows as Customize. It failed every time, on a signed copy that was valid.
2. **"Sign Anyway" was not forwarded.** Library details runs the preflight, lists the blocking
   issues in "Review repeat signing" and offers **Sign Anyway** — then called
   `AutoSignManager.sign(app)`, which had no way to say the issues were accepted. The run stayed in
   strict mode, and the nested-bundle audit — or, for other issues, the post-sign verifier — stopped
   it on the issue the user had just confirmed.
3. **A signing refusal was reported as a customization failure.** `SigningHandler.modify()` reported
   `.signing` only when the engine started. The nested-bundle audit (a profile that does not cover a
   retained extension) and the missing-certificate check both ran before that, so they failed while
   the last reported stage was still a Customize one: "Customize: Failed, Sign: Not run" for a
   bundle whose customization had finished.
4. **Automatic cleanup could empty the temporary directory under a running operation.** Every sign
   works in the temporary directory, and an install packages the archive it hands to iOS there.
   `CleanupManager.flush` (after an install) and `runAfterSign` cleared the directory whenever "Clear
   Temporary Files" was on, whatever else was still running — so one operation finishing could
   delete the work files of another. This is a defect on its own reading; it is **not** shown to be
   what the report hit, because that depends on settings that are not known.

#### Changes

- `OneShotTweakFiles` (new; no UIKit) holds the rules: `stage(_:into:)` copies every file
  into a per-run slot and names every missing file in one `Unavailable` error; `unavailable(_:)`,
  `names(_:)`, `merged(_:)`; and `replayNotices(for:)`, the sentence a run logs when it reuses
  settings that once had such files.
- `TweakHandler.getInputFiles()` refuses a missing file **by name, before anything is injected**,
  injects **its own copies**, and removes its staging directory when it returns, on success and on
  failure. The files the sheet staged are no longer consumed, so a second attempt has its inputs.
- `SigningView` discards the staged files once a run has succeeded and the sheet is closing. They
  are kept after a failure on purpose: that is what lets the next attempt start.
- `SigningProfile.replayable()` drops the staging URLs and keeps the file names in a new optional
  `oneShotFileNames`. It is applied in `save` **and** in `profile(forBundleID:)`, because profiles
  written by earlier versions are already on disk with dead URLs.
- `NamedSigningProfile` never captures one-time files, and `withoutOneShotFiles()` is applied on
  `save`, on `importJSON` and when the stored presets are loaded.
- `PreflightChecks` adds a blocking issue, "Tweak file unavailable", naming each file that cannot be
  read — before the long copy rather than after it.
- `SigningRequest.notices`, passed through `FR.signPackageFile(notices:)`, are written to the
  signing console as warnings **after** the pipeline has reset it. `AutoSignManager` and
  `UpdateAllManager` use them to say which one-time files a replay left out; the "Review repeat
  signing" alert lists the same sentence.
- `AutoSignManager.sign(_:overridingBlockingIssues:)` forwards the accepted override, and Library
  details passes `checks.hasBlocking` when the user chose **Sign Anyway**. Every caller that shows no
  review leaves it `false` and keeps the strict behaviour.
- `SigningHandler.modify()` reports `.signing` as soon as customization ends, for runs that sign.
  `disinject()` moved ahead of the nested-bundle audit so that it stays on the Customize side; it
  edits load commands in the main executable and does not affect what the audit reads.
- `AppOperationRegistry.hasActiveOperations`, and `CleanupManager.automaticCategories(_:operationsActive:)`:
  an automatic pass leaves `.temporary` alone while any operation holds a lease. Leases are released
  before the after-sign and after-install passes run, so a lone sign or install still clears the
  directory as before. **Clean Now** is a deliberate user action and is not guarded.
  *Superseded by [Follow-up 2](#follow-up-2--what-a-successful-sign-leaves-in-the-library): the rule
  is `CleanupPassPolicy.plan` now, it defers leftovers as well, and **Clean Now** follows it.*
- The Library row's context-menu **Re-sign with Last Settings** now calls the same
  `_resignLastOrPresent()` as the swipe action. It used to discard the result, so a failure from
  that menu said nothing; it now passes the app-lock check and reports success or failure.

### Issue 5 — a valid signed copy reads "Failed" in Library details

#### Root cause

A signing run has two identities, and they belong to different library records:

- `subjectID` — the copy it was **started from**;
- `context.artifactID` — the copy it **produced**, set only when it completes.

`LibraryInfoView` looked a run up with `latestSigningTask(subjectID:)` and labelled it "Last
recorded signing result". For a signed copy that answers the wrong question twice over. The run
that produced the copy was never found, because its subject was the copy it started from. And a
later re-sign that failed **was** found, and shown as this copy's result — although a failed run
signs a working copy and registers nothing, so the copy on screen was exactly as it had been.

#### Changes

- `SigningRecordIdentity.select(copyID:from:)` (new, pure) sorts recorded runs into a `Selection`:

  | Field | Meaning |
  |---|---|
  | `produced` | The newest **completed** run whose `artifactID` is this copy |
  | `latestStarted` | The newest run whose `subjectID` is this copy, whatever its outcome |
  | `unfinishedAttempt` | `latestStarted`, only when it did not complete — running, failed, cancelled or interrupted |

  A missing or empty identifier matches nothing. A run that did not complete cannot claim a copy,
  even if its record carries an artifact identifier.
- `UnifiedTaskCenter.signingRecords(forCopy:)` applies it to live tasks and history.
  `latestSigningTask(subjectID:)` stays, documented as what it is: the lookup for the **source** of
  a run, which is what the signing sheet resumes from.
- `LibraryInfoView` shows, for a signed copy:
  - **Signing result for this copy** — the producing run, with its trace;
  - **Latest re-sign attempt from this copy** — only when there is an unfinished attempt: its phase
    and date, its redacted reason, "That attempt did not change this copy." once it is terminal,
    and its own trace under "Steps of that attempt" (`A11y.Signing.attemptWorkflow`, so two traces
    on one screen do not share an identifier).

  An imported copy is only ever a source, so it keeps "Last recorded signing result" unchanged.
- `TaskReceipt`'s outcome for a failed or cancelled **signing** task now reads "This signing attempt
  did not produce a signed copy. The library copy it started from was not changed." An interrupted
  task keeps the interruption sentence, and other task kinds are unaffected.
- `SigningWorkflowView` takes a title and an accessibility identifier, defaulting to the old ones.

### Issue 6 — the install card stays on "Verifying installation"

#### Root cause

Seven gaps. Which of them the report hit cannot be told without a device log; each is a defect on
its own reading.

1. **A declined install left its task record open.** `.success(.cancelled)` went straight to
   `_abandon()`. When it was the last app, the record was then marked **Completed**. When it was
   not, `activate()` found a record already open and ran the **next** app on it: a record still
   titled with the declined app went through the next app's phases, "Verifying installation"
   included, and the app really being installed had no record of its own.
2. **The polling loop ran at `.background` priority.** That loop is what applies every limit of the
   install and what moves the card on. Background-priority work is the first the system defers.
   (That iOS actually held it back in the reported case is plausible and unverified.)
3. **Nothing outside the loop bounded the attempt once the payload was served.**
   `_armPromptDeadline` covers the time before the payload is served, and
   `_armVerificationDeadline` covers verification once the loop has **reported** verification. A loop
   that stopped making progress while waiting for iOS to start, or while the counter ran, left a
   card with nothing that would ever take it down.
4. **Polling was flat and blind.** One check a second, each lookup given one second, no count and
   nothing in the log. A lookup that needed longer than a second was abandoned every time, so a slow
   device looked exactly like a device that hides the answer — and a card still waiting could not be
   told apart from one whose checks had stopped. (That lookups do take longer than a second on some
   devices is plausible and unverified.)
5. **One empty reading ended verification.** Past the 30-second no-evidence deadline, a single
   lookup that returned nothing ended the attempt as unconfirmed — even directly after a reading
   that showed iOS still writing the app. The probe refuses a lookup while another is in flight and
   abandons a slow one, so an empty reading between two good ones is routine.
6. **The deadlines kept beside the loop ran out while the app was suspended.** Each was one long
   sleep. After a suspension both it and the loop's own deadline are overdue at once; the sleep
   needs one hop to act and the loop has to ask the device first, so the sleep wins. An install
   that finished while the user was on the Home Screen, with the card already verifying, was closed
   as "Not confirmed" a moment before the check that would have confirmed it. **This is reasoned
   from the code and was not observed.**
7. **A deadline-driven finish left the loop running.** `_finishConfirmed` clears `_progressTask`
   before `_finish` could cancel it, so the watcher kept asking the device about an install nobody
   was waiting on.

#### Changes

- `InstallVerificationPolicy` (new; no UIKit) is a schedule and nothing else — it holds no
  evidence and reaches no verdict. It paces **verification** only; while iOS has not started, or
  the counter is running, the watcher still samples once a second as before:
  - the pause after a check grows from 0.5 s by ×1.6 to a 3 s ceiling (0.5, 0.8, 1.28, 2.05, 3, 3 …),
    and is cut short so that a check still lands **on** each engine deadline;
  - the time one lookup may take grows from 1 s to 4 s (1, 1.6, 2.56, 4 …), and is cut to the time
    left before the next deadline, though never below the 1 s the first lookup gets;
  - the number of checks is capped at the densest schedule the window allows plus 16 spare (60 for
    the standard 120 s window), so the loop still ends when the clock cannot be trusted — the engine
    measures against the device clock, and a clock set back mid-install would otherwise keep every
    deadline out of reach. A healthy run always reaches its deadline first;
  - `statusLabel(attempt:)` is "Verifying installation" for the first check and "Verifying
    installation (check N)" from the second.
- `InstallConfirmation`:
  - `Limits.evidenceGrace` (10 s): an unanswered check counts as "no evidence" only when the device
    has not answered for that long. A device that never answers still ends at 30 s, exactly as
    before;
  - `Limits.monitoringBackstop` (`start + 2 × verify + 30` = 390 s);
  - `secondsUntilNextDeadline(at:)` and `endVerificationUnconfirmed()` — running out of checks is
    the same verdict as running out of time: not a rejection, and never a success.
- `InstallWatcher.watch` and `confirm` take the policy, an attempt callback and the clock as new
  trailing parameters with defaults. Every existing call site passes labelled arguments, so
  `SelfUpdateManager` and the existing tests are source-compatible. A zero `interval` — how the
  tests replay scripted readings — keeps back-to-back checks with no cap.
- `SelfUpdateManager` is not edited, but it uses the same watcher and so gets the same schedule
  inside its own 600 s window (a cap of 220 checks). Its limits are unchanged, and the monitoring
  backstop below is armed only by `AppInstaller`.
- `AppInstaller`:
  - the watcher runs at `.utility`;
  - `verificationAttempt` is published, logged ("installation check N") and included in the
    "install not confirmed" log line;
  - `_armMonitoringBackstop()` is armed when an OTA payload has been served and bounds everything
    after it. Reaching it ends the attempt as `.timedOutVerifying` with the reason
    `installation-monitoring-deadline` — unconfirmed, neither a success nor a rejection;
  - both actor-side deadlines count **running** time through `InstallDeadlineBudget`, and both
    cancel the watcher before they finish the attempt.
- `InstallDeadlineBudget` (new; Foundation only) spends a deadline in 5-second waits. A wait that
  took more than 5 s longer than planned means the process was stopped; what is left is then at
  least 15 s, so a watcher that works is the one that answers. The grace can be granted at most
  eight times: a deadline has to end, whatever else happens.
- `InstallQueue` closes a declined install's own record as **Cancelled** before it moves on, and
  copies the check count to `TaskContext.verificationAttempts` (optional, so older history loads).
- `TaskReceipt` prints `Installation checks: N` for an install task, and allows
  `installation-monitoring-deadline` as result evidence.
- `InstallCardView` shows the counted label.

#### What bounds an install now

For an OTA install, with the default limits:

| Bound | Value | Covers | Applied by |
|---|---|---|---|
| `Limits.start` | 120 s | prompt → payload served | `AppInstaller._armPromptDeadline` |
| `Limits.start` | 120 s | payload served → iOS starts | the watcher |
| `Limits.verify` | 120 s | counter running without finishing | the watcher |
| `Limits.verify` | 120 s | progress ended → device evidence | the watcher, and `_armVerificationDeadline` beside it |
| `Limits.unavailableEvidence` | 30 s | the same, when the device gives no answer at all | the watcher |
| `Limits.evidenceGrace` | 10 s | how long after an answer a missed check is only a missed check | the watcher |
| `Limits.settle` | 20 s | the version string catching up | the watcher |
| check cap | 60 | the verification loop, when time cannot be trusted | the watcher |
| `Limits.monitoringBackstop` | 390 s | payload served → any terminal outcome | `AppInstaller._armMonitoringBackstop` |

A watcher that is working answers within about 370 s of the payload being served (each phase at its
limit, each limit noticed one sample late, the last lookup waited out), so the backstop is not what
ends a healthy install. `_armVerificationDeadline` and `_armMonitoringBackstop` are counted in
running time, and each can be extended by at most 8 × 15 s across suspensions.
`_armPromptDeadline` is unchanged and is still one sleep.

### Files modified (follow-up)

Production (28 files; the four marked *new* use no UIKit, which is what lets them be unit-tested):

| File | Change |
|---|---|
| `VexSign/Utilities/Handlers/OneShotTweakFiles.swift` | *new* — staging, missing-file error, replay notice |
| `VexSign/Utilities/Handlers/TweakHandler.swift` | names a missing file, injects copies, removes its staging directory |
| `VexSign/Utilities/Handlers/SigningHandler.swift` | `.signing` reported when customization ends; `disinject()` before the audit |
| `VexSign/Backend/Observable/SigningProfileStore.swift` | `replayable()`, `oneShotFileNames`, applied on save and read |
| `VexSign/Backend/Observable/NamedSigningProfileStore.swift` | `withoutOneShotFiles()` on capture, save, import and load |
| `VexSign/Backend/Observable/PreflightChecks.swift` | blocking "Tweak file unavailable" |
| `VexSign/Utilities/Signing/SigningService.swift` | `SigningRequest.notices`, logged after the console reset |
| `VexSign/Utilities/FR.swift` | `notices:` parameter |
| `VexSign/Backend/Observable/AutoSignManager.swift` | `overridingBlockingIssues`; replay notices |
| `VexSign/Backend/Observable/UpdateAllManager.swift` | replay notices when options are preserved |
| `VexSign/Views/Signing/SigningView.swift` | discards staged files after a successful run |
| `VexSign/Backend/Services/AppOperationRegistry.swift` | `hasActiveOperations` |
| `VexSign/Backend/Observable/CleanupManager.swift` | `automaticCategories(_:operationsActive:)` — replaced by `CleanupPassPolicy.plan` in Follow-up 2 |
| `VexSign/Backend/Services/SigningRecordIdentity.swift` | *new* — which runs describe a copy |
| `VexSign/Backend/Observable/UnifiedTaskCenter.swift` | `signingRecords(forCopy:)` |
| `VexSign/Views/Library/Info/LibraryInfoView.swift` | per-copy record rows; forwards "Sign Anyway"; replay notice in the review |
| `VexSign/Views/Library/LibraryCellView.swift` | context-menu re-sign reports its result |
| `VexSign/Views/Signing/SigningWorkflowView.swift` | title and identifier parameters |
| `VexSign/Utilities/AccessibilityIdentifiers.swift` | `Signing.attemptWorkflow` |
| `VexSign/Utilities/Installing/InstallVerificationPolicy.swift` | *new* — check schedule, cap and status wording |
| `VexSign/Utilities/Installing/InstallDeadlineBudget.swift` | *new* — a deadline counted in running time |
| `VexSign/Utilities/Installing/InstallConfirmation.swift` | `evidenceGrace`, `monitoringBackstop`, deadline helpers; watcher uses the policy |
| `VexSign/Backend/Observable/AppInstaller.swift` | `.utility` watcher, `verificationAttempt`, monitoring backstop, budgeted deadlines |
| `VexSign/Backend/Observable/InstallQueue.swift` | declined install closes its own record; check count recorded |
| `VexSign/Backend/Services/TaskTrace.swift` | optional `TaskContext.verificationAttempts` |
| `VexSign/Backend/Services/TaskReceipt.swift` | signing-attempt outcome sentence; `Installation checks`; new evidence reason |
| `VexSign/Views/Library/Install/InstallCardView.swift` | counted verification label |
| `VexSign/Resources/Localizable.xcstrings` | 10 new keys, appended by `tools/sync-strings.py --write` as `extractionState: manual` — English values, no machine translation |

Tests (9 files):

| File | Change |
|---|---|
| `VexSignTests/OneShotTweakFilesTests.swift` | new — 12 tests |
| `VexSignTests/SigningProfileReplayTests.swift` | new — 9 tests |
| `VexSignTests/SigningRecordIdentityTests.swift` | new — 11 tests |
| `VexSignTests/CleanupOperationGuardTests.swift` | new — 7 tests (15 since Follow-up 2) |
| `VexSignTests/TaskReceiptOutcomeTests.swift` | new — 13 tests |
| `VexSignTests/InstallVerificationTests.swift` | new — 22 tests |
| `VexSignTests/InstallDeadlineBudgetTests.swift` | new — 14 tests |
| `VexSignTests/AccessibilityIdentifiersTests.swift` | expected-identifier list gained the new ID |
| `tools/test_workflow_trace_policy.py` | 6 new source pins (16 in the file; 25 since Follow-up 2) |

`InstalledAppProbe.swift`, `LibraryStatusStore.swift` and `SelfUpdateManager.swift` are unchanged.
No `.xcodeproj` edit is needed, for the reason given under [Files modified](#files-modified).

### Regression tests added (follow-up)

88 new XCTest methods and 6 source pins.

**One-time tweak files — `OneShotTweakFilesTests` (12)** · Staging copies and leaves the original
in place · a second attempt still has its input after the engine consumed the first copy · two
files with one name are both staged · a directory is copied with its contents · nothing to stage
creates nothing · a missing file is named and nothing is copied · only what is not on disk is
listed as unavailable · the error names the file and never its path · names keep order and drop
duplicates · merged lists drop empty and repeated names · the replay notice is silent for settings
that never had such files and names them once otherwise.

**Saved settings — `SigningProfileReplayTests` (9)** · A profile without one-time files is replayed
unchanged · replay drops the staging URLs and keeps their names · every other option survives ·
applying it twice changes nothing · names recorded earlier are kept and not repeated · a profile
written before the name field existed still decodes · the replayed profile survives another round
trip · a new preset never carries one-time files · a stored or imported preset is cleaned when read.

**Which run describes a copy — `SigningRecordIdentityTests` (11)** · A failed re-sign is not the
result of the copy it started from · a freshly signed copy reports the run that produced it · an
imported copy reports the newest run started from it · a run still in flight is an unfinished
attempt · only the newest attempt is reported · a later success supersedes an earlier failure · a
record of another copy is never reported · a copy without an identifier matches nothing · a run that
did not complete cannot claim a copy · the newest producing record wins · no records, no claim.

**Cleanup guard — `CleanupOperationGuardTests` (7)** · The registry is idle until something is
acquired and active until the last lease is released · an operation without a stored copy still
counts · a refused acquire leaves nothing behind · an automatic pass leaves the temporary directory
alone while an operation runs, clears everything enabled once nothing runs, and never adds a
category the user did not enable. Follow-up 2 moved that rule to `CleanupPassPolicy` and rewrote
these last three tests for it; the file has 15 tests now.

**Receipts — `TaskReceiptOutcomeTests` (13)** · A failed signing attempt is not reported with the
general sentence, and a cancelled one says the same · an interrupted one keeps the interruption
sentence · only signing attempts get the sentence · an attempt still running is not called
unchanged · an install receipt carries the number of device checks, says nothing when the device was
never asked, and leaves out a count that cannot be real · only an install reports checks · the
monitoring deadline is exported as its own evidence · the count survives the history file · a
context written before the count existed still decodes, and one without a count does not write one.

**Verification schedule and engine — `InstallVerificationTests` (22)** · Pauses grow from half a
second to three · a pause is cut short to land on the next deadline · a lookup is given longer on
later checks but never past a deadline · back-to-back checks never pause, escalate or run out · the
check cap grows with the window (30, 60 and 220 checks for 30, 120 and 600 seconds), and a healthy
verification reaches its deadline before the cap ·
the status line counts from the second check · a missed check between two answers does not end
verification · evidence that stops arriving ends once the grace has passed · a device that never
answers keeps the short deadline · the grace never outlives the verification window · an unanswered
check never becomes a success · the next deadline walks through settle, unavailable and verify ·
running out of checks is unconfirmed and never a success · the monitoring backstop outlasts every
phase limit · then, with the watcher driven on scripted time: every device check is reported in
order · a missed check does not stop it · evidence that stays away ends it unconfirmed · a device
that never answers ends it at the short deadline · the check cap ends verification when the clock
stands still · an install that lands on the last allowed check is still installed · checks are
reported through the public entry point.

**Deadlines in running time — `InstallDeadlineBudgetTests` (14)** · The budget is spent in short
waits · a wait that took as long as planned grants nothing · a spent budget has no next wait · a
long wait near the end leaves the grace period · a long wait with plenty left changes nothing · an
overrun within the tolerance is not treated as a suspension · the grace is granted a fixed number of
times · no pattern of long waits outlasts the longest possible run · without extensions a long wait
never adds time · unusable values still give a budget that ends · the monitoring backstop stays
longer than every phase limit · waiting returns true once spent, at once when empty, and false when
cancelled.

**Source pins — `tools/test_workflow_trace_policy.py` (6 new)** · These cover wiring in files that
cannot be unit-tested without the iOS SDK, and run in `make verify` and CI's quick job:
`.signing` is reported before the identity and profile checks · one-time tweak files are copied for
a run and never replayed · reviewed repeat signing forwards the accepted override · Library details
describe the copy, not the last run started from it · a declined install closes its own task record
· install monitoring is bounded outside the watcher (no `.background` watcher, no plain sleep in the
deadlines, both deadlines cancel the watcher).

### Validation (follow-up)

These are the results as they were recorded when this follow-up was written. Follow-up 2 has since
changed some of the files named here, `CleanupManager` and `CleanupOperationGuardTests` among them,
and removed `automaticCategories`; the counts that moved and the current results are under
[Validation (follow-up 2)](#validation-follow-up-2).

**Run in this workspace and passing:**

| Gate | Result |
|---|---|
| `make verify` | exit 0 |
| `.github/scripts/quick_check.py --no-swiftc` | ✅ 0 errors, 0 warnings — including `duplicate-types` and `duplicate-filenames`, which is what the four new production files and seven new test files could have tripped |
| `make verify` gate self-tests | ✅ 271 Python tests, all OK (265 before the six new pins) |
| `make docs-check` | ✅ file links OK; 3 documentation tests OK. It does not check heading anchors; the 10 anchored links in the six changed documents were resolved with a separate script, none broken |
| `tools/test_workflow_trace_policy.py` | 16 tests OK. The 6 new pins were also run against an export of the base commit: all 6 fail there and the other 10 pass, so they pin the change rather than restate the old code |
| `tools/sync-strings.py --check` | ✅ 472 Swift files · 3285 distinct literals · 3565 catalogue keys — every literal has a key |
| `tools/concurrency-discipline.py` | ✅ 6 escapes across 5 files — at baseline, none added |
| `tools/singleton-freeze.py` | ✅ 62 singletons across 61 files — at baseline, none added |
| `tools/error-discipline.py` | ✅ 239 unjustified `try?` across 95 files — unchanged, 5 below baseline; not regenerated |
| `make test-server` | 166 passed, 1 skipped (the component was not changed) |
| `make test-cloud` | build, 12 tests and the contract drift check pass (the component was not changed) |
| Syntax | all 35 changed or new Swift files parse with a Swift 6.4 frontend in Swift 5 language mode |

**Executed, but not on the iOS toolchain.** There is still no `swift`, `swiftc` or `xcodebuild` here.
The code that needs no UIKit was compiled and run with a Swift-to-WebAssembly toolchain (Swift 6.4)
kept outside the repository. The files under test are the repository's own, with `import` lines for
unavailable modules removed and `.localized` replaced by the identity. What those files need from
sources that do not build there was supplied separately:

- **copied from the repository by script, and compared with it afterwards:** the evidence types
  `InstalledApp` and `InstalledState`, the task model (`UnifiedTask`, its kind and phase,
  `TaskRecoveryGuide`, `SigningStage`), `StorageCategory`'s cases and the body of
  `automaticCategories`;
- **minimal stand-ins:** `Options` (only the members the staged files and tests use), `Storage`,
  `CertificatePair`, `AppInfoPresentable`, `ObservableObject`/`@Published`,
  `OSAllocatedUnfairLock`, `SHA256`, `LogRedaction`, and `installedAppWithTimeout`. The real
  wrapper hops to a queue and races the lookup against a timer; the stand-in calls the test's
  scripted device directly, so that hop and that timer did not run. No test here reaches
  LaunchServices, on any toolchain.

A test that passed against a stand-in has not been shown to pass against the real type.

| Suite | Result |
|---|---|
| `OneShotTweakFilesTests`, `SigningProfileReplayTests`, `SigningRecordIdentityTests` | 32 pass |
| `InstallVerificationTests`, `InstallDeadlineBudgetTests` | 36 pass |
| Existing engine tests that need no iOS-only type (39 of 53 in `InstallConfirmationTests`, 7 of 12 in `InstallEvidenceReportingTests`, 5 engine tests from other suites) | 51 pass against the changed engine |
| `CleanupOperationGuardTests` | 7 pass, against the real `AppOperationRegistry` and the extracted `automaticCategories` |
| `TaskReceiptOutcomeTests` | 13 pass, against the real `TaskReceipt` and `TaskTrace` and the extracted task model |

The ten production files those suites compile — `OneShotTweakFiles`, `SigningProfileStore`,
`NamedSigningProfileStore`, `SigningRecordIdentity`, `InstallConfirmation`,
`InstallVerificationPolicy`, `InstallDeadlineBudget`, `AppOperationRegistry`, `TaskTrace` and
`TaskReceipt` — type-check there without a warning.

Each new rule was also checked by taking it away, in a copy of the source outside the repository,
and confirming that the tests notice:

| Change made to the copy | Result |
|---|---|
| The old rule restored: one unanswered check ends verification at the short deadline | 8 assertions fail in 4 `InstallVerificationTests` |
| The policy's check cap three checks higher | `testTheCheckCapGrowsWithTheWindow` fails |
| The watcher allowed three checks past the cap | `testTheCheckCapEndsVerificationWhenTheClockStandsStill` fails |
| A deadline budget that never restores the grace | 7 assertions fail in 3 `InstallDeadlineBudgetTests` |
| A deadline budget that restores the grace without limit | 12 assertions fail in 5 `InstallDeadlineBudgetTests` |
| The previous `TaskReceipt.swift` | 7 assertions fail in 5 of the 13 `TaskReceiptOutcomeTests` |

This is evidence about the logic, **not** about the iOS build. The app target is compiled by a
different compiler version against a different SDK; a clean run here does not show that it compiles
there, and it says nothing about the warnings gate.

**Not run, and not claimed as run:**

- Any compile against the iOS SDK. `AppInstaller`, `InstallQueue`, `CleanupManager`,
  `UnifiedTaskCenter`, `SigningHandler`, `TweakHandler`, `AutoSignManager`, `UpdateAllManager`,
  `PreflightChecks`, `FR` and every view were parsed and hand-checked against the declarations in
  this repository, and nothing more.
- `make test` — XCTest results for the 88 new tests and for the existing suite on the simulator are
  unknown. The 51 existing tests above are the only existing tests that were executed.
- CI's `build` job and its warnings gate, `make strict-concurrency`, `make lint`, the IPA build.
- Anything on a physical device. **No on-device verification was performed**, so none of the three
  symptoms has been reproduced, and none of the fixes has been observed to remove one.

The commit this follow-up starts from, `67fd3f38ae4866fe0ee39be125de853b8509d601`, passed
[CI run 42803798777](https://github.com/raynmahbub/VexSign/actions/runs/42803798777) — quick, the
unsigned Debug build and the simulator tests. That is evidence about the starting point only. No CI
run of the follow-up is recorded here; when one exists, a failure in any of those three jobs is
attributable to this change.

`make test` runs the whole suite. For a first signal, this runs the new files, the test file that
was edited and the two existing engine suites, with the destination resolved the way `make test`
resolves it:

```bash
SIM_ID="$(python3 .github/scripts/select_simulator.py --print-id)"
xcodebuild test \
  -workspace VexSign.xcworkspace \
  -scheme VexSignTests \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$TMPDIR/TestDerivedData" \
  -only-testing:VexSignTests/OneShotTweakFilesTests \
  -only-testing:VexSignTests/SigningProfileReplayTests \
  -only-testing:VexSignTests/SigningRecordIdentityTests \
  -only-testing:VexSignTests/CleanupOperationGuardTests \
  -only-testing:VexSignTests/TaskReceiptOutcomeTests \
  -only-testing:VexSignTests/InstallVerificationTests \
  -only-testing:VexSignTests/InstallDeadlineBudgetTests \
  -only-testing:VexSignTests/InstallConfirmationTests \
  -only-testing:VexSignTests/InstallEvidenceReportingTests \
  -only-testing:VexSignTests/AccessibilityIdentifiersTests \
  -parallel-testing-enabled YES \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  COMPILER_INDEX_STORE_ENABLE=NO ONLY_ACTIVE_ARCH=YES
```

### Remaining limitations (follow-up)

1. **Where iOS filters the lookup, an OTA install still ends "Not confirmed" after 30 seconds.**
   Nothing here can read what iOS will not expose. The follow-up makes that outcome arrive when it
   should and stops it arriving when it should not; it does not turn it into a confirmation.
2. **One-time tweak files are not carried into a later run, by design.** A copy that was signed with
   them still contains them. A re-sign of that copy keeps what is already in the bundle; an
   **updated** app is a new bundle and does not have them. The run says so in its log and the review
   alert lists the names, but the tweak is not there unless it is added again — or installed as a
   managed tweak, which is kept.
3. **Closed by [Follow-up 2](#follow-up-2--what-a-successful-sign-leaves-in-the-library).** As it
   was recorded here: a successful re-sign can leave no copy at all. `AutoSignManager` deleted the
   source copy when the run succeeded, signed or not, and then applied Auto Cleanup; with "Delete
   Signed App" on and saved settings that do not install afterwards, the new copy was removed as
   well. The Library row actions show no review, and re-signs that used to fail on a missing tweak
   file now succeed and so reached it. The change suggested here — `keepsSignedApp: true` for a
   signed source — is not the one that was made: no flow and no setting can delete the copy a run
   produced any more, and the copy a re-sign was started from stays unless "Delete Signed App"
   asks for it to go.
4. **Files staged in an open signing sheet are not protected from cleanup that runs while nothing is
   in flight.** An automatic pass after an unrelated operation, or **Clean Now**, can still remove
   them. The result is now a named preflight issue instead of a failure halfway through the run.
   Since Follow-up 2, **Clean Now** leaves the temporary directory alone while an operation is
   running, as an automatic pass does; with nothing running it clears it as before.
   Staged files are also left in the temporary directory when the sheet is cancelled, until the
   next launch clears it.
5. **`InstallQueue._reset()` drops an open task record without closing it.** Every caller today
   closes the record first — each one requires a finished queue, or calls `_finishUnifiedTask()`
   itself — so this is latent, not reachable. A new caller that resets mid-install would leave that
   install's record open until the next launch marks it interrupted. Unchanged.
6. **A declined install's receipt uses the existing "monitoring stopped" wording.** Its record is
   now closed correctly; the sentence was not specialised.
7. **A signing record that carries an artifact identifier but did not complete shows no "Signing
   result for this copy" row.** Deliberate: a record cannot claim a copy it did not finish producing.
8. **Not changed, and each still worth a device check:** the 120-second prompt deadline can fire
   during a slow payload transfer; the decline check two seconds after VexSign regains focus can
   misread a prompt that was accepted; an install suspended while still waiting for iOS to start can
   end "Install Never Started" on return; the 120-second limit on the counter phase is short for a
   very large app; once the counter has run, a same-version reinstall is confirmed by a reading that
   the copy already on the device would also give; and `FR.signPackageFile` logs its
   certificate-identity warning before the pipeline resets the console, so the warning reaches the
   log file but not the console of the run it is about.
9. **The priority change and the lookup timeouts are judgement, not measurement.** `.utility` and a
   1–4 s lookup window follow from how the code can fail. Whether either was the limiting factor on
   a real device has not been measured.

### Required on-device acceptance (follow-up)

These continue the list above. None of them has been performed.

**Re-signing with saved settings**

21. In the signing sheet, add a `.dylib` under Tweaks ("just for this sign") and sign. Then re-sign
    the signed copy three ways: **Re-sign with last settings** in Library details, **Re-sign Last**
    in the row's swipe actions, and **Re-sign with Last Settings** in the row's context menu. Each
    must succeed, and the signing log must carry a warning naming the file that was not injected
    again. This is the case that used to stop in Customize. Since Follow-up 2 a run keeps the copy
    it was started from unless Auto Cleanup's "Delete Signed App" is on, so with that switch off
    all three can be started from the same copy, and each adds a signed copy to the library.
22. Repeat 21 after force-quitting and relaunching VexSign between the first sign and the re-sign.
23. Upgrade over a build that already saved settings with a one-time tweak file, without signing
    again first, and re-sign. It must succeed: the stored profile is cleaned when it is read.
24. Add a one-time tweak file, make the first attempt fail (for example with a profile that does not
    cover an extension), fix the cause and sign again **in the same sheet**. The second attempt must
    inject the file.
25. Hard to reach by hand, because the signing sheet is modal. If a staged one-time file can be
    removed while the sheet is still open — for example by letting an install of another app
    finish, with Auto Cleanup and "Clear Temporary Files" on, after the file was added — tap Sign.
    The review must list "Tweak file unavailable" with the file's name, and **Sign Anyway** must
    stop with an error that names the file, not with a Cocoa "no such file".
26. Save a named preset from a sheet that has a one-time tweak file, export it, and import it on a
    second device. Applying it must not fail on a missing file.
27. With a profile that does not cover a retained extension, use **Re-sign with last settings** in
    Library details and choose **Sign Anyway**. The run must proceed past the audit. Started from
    the row instead — its actions show no review and so carry no override — the same run must stop,
    and the copy's details must then show the attempt with **Sign: Failed**, not Customize.
28. With Update All and preserved signing options, update an app whose saved settings had a
    one-time tweak file. The update must sign, and the log must say the file was left out.
29. With Auto Cleanup and "Clear Temporary Files" on, sign a large app while another app is
    installing. Neither may fail with a missing-file error when the other finishes.

**The record of a signed copy**

30. Sign an imported app and open the **signed** copy's details. It must show "Signing result for
    this copy: Completed" with the trace — before this change a signed copy showed no result here.
31. Make a re-sign of that signed copy fail. Its details must still show the completed result, and
    below it "Latest re-sign attempt from this copy: Failed" with the reason, "That attempt did not
    change this copy." and the steps of the failed attempt. Export the failed task's receipt: it
    must say the attempt did not produce a signed copy.
32. Re-sign it successfully. The new copy's details must show its own completed result and no
    attempt row. Since Follow-up 2 the source copy stays unless "Delete Signed App" is on; its
    details must then show the result of the run that produced it and no attempt row either,
    because a completed re-sign belongs to the copy it produced.

**Install verification**

33. Install over OTA and watch the card through verification. From the second check it must read
    "Verifying installation (check N)" with N increasing, and the checks must visibly spread out.
34. On a device where the installed-app lookup is **not** filtered: install, accept the prompt and
    go to the Home Screen as soon as the card says "Verifying installation". Return after the app
    has finished installing, at least two minutes later. The card must end **Installed**, not
    "Installation Not Confirmed". If iOS terminated VexSign in the meantime the step does not
    apply; repeat it.
35. Repeat 34 in Low Power Mode.
36. Queue two apps and decline the prompt for the first. In Task Center, the first app's record
    must read **Cancelled** and the second app must have a record of its own under its own name.
37. Decline the prompt for the last app in a queue. Its record must read Cancelled, not Completed.
38. On a device where the installed-app lookup is filtered, an OTA install must end "Installation
    Not Confirmed" after about 30 seconds — not earlier and not as a failure — and the exported
    receipt must carry `Installation checks:` with the number of checks made.
39. Install the largest app available and confirm the card never outlives the bounds in the table
    above, and that a completed install is never reported as unconfirmed by the 390-second bound.

---

## Follow-up 2 — what a successful sign leaves in the library

Three defects in what happens to library copies when a sign finishes and when cleanup runs. This
follow-up was made on top of the first one; both start from `67fd3f3`.

| # | Defect | Where it came from |
|---|---|---|
| 7 | A sign succeeds and the library holds neither the copy it was started from nor the copy it produced | A re-sign with saved settings deleted its source as soon as the run succeeded, and Auto Cleanup's "Delete Signed App" then deleted the output; the signing sheet deleted its own output under the same setting |
| 8 | A copy that was just signed or imported is in the library without its bundle | A leftovers pass could judge the copy's folder between the moment the bundle was moved into the library and the moment its row was committed |
| 9 | "Keep only the newest signed copy" removes the copy that was just signed | The rule compared versions only, and a re-signed copy has the version of the copy it was started from |

Issue 7 is limitation 3 of the first follow-up. Issues 8 and 9 were found while following every
path that can delete a signed copy. **Neither 8 nor 9 has been reported or reproduced**: they are
what the code allowed.

**Read this first.** Every root cause below was established by reading the code. Nothing in this
follow-up was run on a device, and nothing was compiled against the iOS SDK; what was and was not
executed is listed under [Validation (follow-up 2)](#validation-follow-up-2).

### What changes for the user

This follow-up changes what a documented setting does. That is the decision limitation 3 left
open, so it is stated here before the code.

1. **The copy a successful run produced stays in the library.** Nothing that runs when a sign
   finishes can delete it, whatever the settings are. (VexSign updating itself is the one flow
   that still removes what it signed, on purpose: see the end of the changes for Issue 7.)
2. **"Delete Signed App"** (Settings → Auto Cleanup → After Signing) **removes the signed copy a
   re-sign was started from**, once the new copy is in the library. It used to delete the *new*
   copy whenever the run was not set to install it.
3. **A re-sign with saved settings keeps the copy it was started from**, unless Auto Cleanup and
   "Delete Signed App" are both on. It used to replace that copy on every run. With the defaults
   (Auto Cleanup on, both After Signing switches off) the library therefore gains a signed copy per
   re-sign where it used to keep one.
4. **A batch job honours "Delete Signed App"** for the signed copies it re-signs. It never removed
   a signed source before.
5. **Clean Now leaves temporary files and leftovers alone while a sign or an install is running**,
   and says that it did. It used to clear both.
6. **"Keep only the newest signed copy" keeps the newest of two copies with the same version.**
   Which of the two it kept used to depend on the order the rows were read in.

What each flow does with the copy it was started from. "Removed" always means: after the new copy
is confirmed to be in the library, and only when the deletion is not refused.

| Flow | Source is an import | Source is a signed copy |
|---|---|---|
| Saved settings, no sheet: **Re-sign with last settings** in Library details and in a Library row, the Shortcuts actions, auto sign after import, the web API | removed — unchanged | kept; removed with Auto Cleanup + Delete Signed App — **was: always removed** |
| Signing sheet | kept; removed with the sheet's "Delete After Signing", or with Auto Cleanup + Delete Unsigned App — unchanged | kept; removed with Auto Cleanup + Delete Signed App — **was: kept, and under that setting the *new* copy was deleted** |
| Batch job | as the sheet — unchanged | kept; removed with Auto Cleanup + Delete Signed App — **was: always kept** |
| Update All | removed — unchanged | does not occur: the source is the copy imported for the update |
| IPA Explorer, "Sign & Install" | removed — unchanged | removed — unchanged: the copy was edited in place and no longer matches its signature |

A signed source reaches the first row only from the Library row and Library details actions and
from the Shortcuts action "Sign App". Auto sign after import, "Sign Latest Download" and the web
API always start from an import, so for them nothing changes except that the copy they produce can
no longer be deleted by "Delete Signed App".

### Issue 7 — a successful sign can leave no copy in the library

#### Root cause

Each flow settled the two copies of a run itself: five call sites, each with its own rule, and no
place where the two deletions could be seen together.

1. **A re-sign with saved settings deleted its source unconditionally.**
   `AutoSignManager._perform` — behind "Re-sign with last settings" in Library details and in a
   Library row, both Shortcuts signing actions, auto sign after import and the web API's sign
   endpoint — called `Storage.shared.deleteApp(for: app)` as soon as the run succeeded, whether
   `app` was an import or a signed copy.
2. **Auto Cleanup then deleted the output.** The same function went on to call
   `CleanupManager.runAfterSign(source: nil, signed: signed, keepsSignedApp:
   options.post_installAppAfterSigned)`, and `runAfterSign` deleted `signed` when Auto Cleanup and
   "Delete Signed App" were on and `keepsSignedApp` was false. Each step was the documented
   behaviour of its own switch — the setting's footer said it "removes the signed copy from your
   library" when the app "is not being installed or exported right after signing". Together, for a
   re-sign whose saved settings do not install: the source is deleted, the output is deleted, and
   the run is reported as a success.
3. **The signing sheet deleted its own output the same way.** `SigningView` took `keepsSignedApp`
   from `SigningCompletionAction.keepsSignedApp(automaticInstall:)`, which answers false for `.done`
   without an automatic install — and the sheet closes itself with `.done` when a sign succeeds. So
   with the same switches and "Install After Signing" off, every sign from the sheet deleted the
   copy it had just produced. The source stayed in this case; the run still had no result.
4. **Callers went on to use a copy that could already be gone.** `AutoSignManager.sign` returns the
   signed copy to its caller. Under the settings in 2 that copy had been deleted before the
   function returned; the web API's sign endpoint, for one, goes on to package it.
5. **Nothing tied the deletion of a source to the existence of the output.** Every flow deleted on
   the strength of the pipeline's `.success`, without asking whether the output had a row and a
   bundle at the moment of the deletion.
6. **A deletion that was refused was reported as done.** `CleanupManager.delete` built its summary
   and then ignored the result of `Storage.deleteApps`, which refuses the whole request when a copy
   in it is in use by another operation. The toast and the cleanup history then named an app that
   was still in the library. `pruneDuplicateSignedApps` did the same.

#### Changes

- **`PostSignArtifacts`** (new; no UIKit and no storage layer) holds the rule for every flow.
  `requestedRemoval(_:settings:)` says whether a rule asks for the source to go and which one:
  `.consumedByFlow` (an import that only existed to be signed, or the explorer's edited copy),
  `.runOption` (the run's own "Delete After Signing") or `.cleanupSetting` (an Auto Cleanup
  switch, and only while the master switch is on). `decision(for:settings:outputIsInLibrary:)`
  then keeps the source when nothing asked (`.notRequested`), when it has no identifier
  (`.sourceUnidentified`), when source and output are the same copy (`.sameCopy`), and when the
  output has no identifier or is not in the library (`.outputNotConfirmed`).
- **The output cannot be named.** `Decision` has two cases, `keepSource` and `removeSource`.
  `finish(_:settings:outputIsInLibrary:removeSource:)` deletes only through a closure that takes
  no identifier and that the caller binds to the source. No setting and no caller can make this
  code delete the output, because there is no parameter that carries it to a deletion.
- **The output is confirmed at the moment of the decision**, not when the run reported success:
  `outputIsInLibrary` is asked only when a rule wants the source removed, and
  `CleanupManager._holdsSignedCopy` answers true only for a signed row with that identifier whose
  bundle directory is on disk.
- **`CleanupManager.finishSign(source:output:origin:runDeletesSource:sweepsStorage:)`** replaces
  `runAfterSign` and carries the rule out. `runAfterSign`, `deletesSourceAfterSign` and
  `SigningCompletionAction.keepsSignedApp` are removed, so no entry point is left that accepts a
  signed copy to delete. A failed or cancelled run never reaches `finishSign`: every caller is
  inside its `.success` branch.
- **A refused deletion leaves both copies and reports nothing.** `CleanupManager.delete` returns
  an empty summary unless `Storage.deleteApps` returned true, and `Outcome.sourceRemoved` is true
  only then. This also applies to the pass after an install. `Storage.deleteApps` still shows its
  own "in use" message.
- **What is reported as a cleanup.** Only a removal an Auto Cleanup switch asked for goes into the
  toast and the cleanup history, as before. A flow using up its own import and a run's own option
  stay as quiet as they were. A batch settles each app without a toast and its removals are
  written to the history — they used to be recorded nowhere.
- **The five flows call the one function**, each with its own origin:

  | Caller | Call |
  |---|---|
  | `AutoSignManager._perform` | `finishSign(source: app, output: signed, origin: .savedSettings)` |
  | `SigningView` | `finishSign(source: app, output: signed, origin: .sheet, runDeletesSource: _temporaryOptions.post_deleteAppAfterSigned)` |
  | `BatchJobRunner` | `finishSign(source: app, output: signed, origin: .batch, runDeletesSource: options.post_deleteAppAfterSigned, sweepsStorage: false)` per app, then one `sweepAfterSigning()` after the loop |
  | `UpdateAllManager` | `finishSign(source: app, output: signed, origin: .update)` |
  | `IPAWorkspace` | `finishSign(source: target, output: signed, origin: .explorer, sweepsStorage: false)` — the explorer never swept storage |

- **One caller of the signer is not among them, and was not changed.**
  `SelfUpdateManager.installViaIDevice` imports VexSign's own update, signs it, packages the signed
  bundle and then deletes both entries: they are scratch entries that were never meant to appear
  in the library, and the package is what gets installed. It never called cleanup. A source pin
  now lists every file that calls the signer, so a seventh flow cannot be added without deciding
  how it settles its copies.

- **The wording follows the rule.** The "Review repeat signing" alert in Library details said
  "repeat signing replaces this source copy". Its line is now built by
  `PostSignArtifacts.repeatSigningNotice(settings:)` from the same `requestedRemoval` the run will
  follow, so it says either that the copy stays, and which switch would remove it, or that it is
  removed because "Delete Signed App" is on. The footer under After Signing in Settings → Auto
  Cleanup describes the setting as it now behaves.

### Issue 8 — a leftovers pass can delete a copy that is being produced

#### Root cause

A copy enters the library in two steps: its bundle is moved into the library's `Signed` or
`Unsigned` directory under the copy's identifier, and then its row is committed. A leftover is a
folder in one of those directories that no row accounts for — which is what a copy is between the
two steps.

1. **The rows are read once and the folders are judged later.** `LibrarySnapshot` is built from
   one fetch. `StorageScanner.leftovers` then walks the directories and measures every folder
   before it asks whether the folder is known, and `StorageManager.purge` does that walk twice. For
   a large library the judgement of a folder can come seconds after the rows were read; when the
   Storage screen clears a category it also runs on a detached task.
2. **So there are two windows, not one.** The bundle is in place and the row is not committed when
   the rows are read; or the rows are read first and the copy is moved in — or moved in *and*
   registered — before its folder is reached. In both the folder is judged a leftover and deleted,
   and the library is left with a row whose bundle is gone.
3. **A pass can run while a copy is being produced.** An automatic pass runs when *any* operation
   finishes, so the sign or install that finished is not the one in the window: an install
   finishing while a sign runs, or one sign finishing while the next download is being imported.
   Clean Now is called by the button, by Shortcuts, by the web API, by the companion and by
   background automation, at moments nobody chose. The first follow-up guarded the temporary
   directory on automatic passes only; leftovers and Clean Now were not guarded.

Removing leftovers after a sign or an install needs "Remove Leftovers" to be on. Clean Now removes
them when that switch is on and also when no storage switch is on at all.

#### Changes

- **`AppOperationRegistry` knows which copies are being produced.** `claimProduction(of:)` returns
  a claim that lasts as long as it is held; `confirmProduction(of:)` records that the copy's row is
  committed and keeps the copy known until the app quits; `knowsProduction(of:)` answers for both.
  A claim is not an operation on a stored copy: it makes nothing busy and does not count in
  `hasActiveOperations`. A claim given up without a confirmation — a run that failed or was
  cancelled — ends the protection, so what that run left behind is a leftover again.
- **Why a confirmed copy is remembered.** It has a row by then, but a pass that read the rows
  before the commit does not have it, and the claim ends with the run. The memory is what still
  says the folder is wanted when such a pass reaches it.
- **`SigningHandler` and `AppFileHandler` take the claim in `init`**, before any folder with that
  identifier exists, and confirm it on the line after the row is committed. Imports are claimed as
  well because an import holds no lease: the sweep after one sign can run while another download
  is between its two steps.
- **`LibrarySnapshot.productions`** carries the registry, and `owns(_:signed:)` asks it when a
  folder is judged, not when the snapshot is taken. This covers every user of the snapshot,
  including the Storage screen. Certificate folders are not affected.
- **`CleanupPassPolicy.plan(_:operationsActive:)`** (new, in `CleanupPolicy.swift`) replaces
  `CleanupManager.automaticCategories`. While any operation holds a lease it defers `.temporary`
  **and `.leftovers`**, and it never adds a category that was not asked for. Every pass that goes
  through `CleanupManager` uses it — after a sign, after an install, the batch's sweep, and
  **Clean Now**.
- **Clean Now says what it left.** `CleanupSummary.deferred` lists the deferred areas and
  `deferralNotice` puts them in one sentence: "Not cleaned while an operation is running: Temp
  Files and Leftovers". The button shows it as a toast, after the usual "Cleanup freed …" when
  something else was cleaned, and instead of "Nothing to clean up". The Shortcuts action appends it
  to its answer. What was deferred is cleared by the next pass that finds nothing running, and the
  temporary directory at the next launch.

### Issue 9 — "Keep only the newest signed copy" could keep the older copy

#### Root cause

1. `StorageRules.pruneDuplicateSignedApps` — run by Clean Now when the rule is on — sorted an app's
   signed copies by version alone and kept the first. A re-signed copy has the version of the copy
   it was started from, so the two tied and the order the rows were fetched in decided which one
   was deleted. With issue 7 fixed, two signed copies of one version is what a re-sign leaves by
   default, so this rule would have been the remaining way to lose the copy that was just signed.
2. Versions were compared as strings of zero-padded components. "1.2" and "1.2.0" compared as
   different versions, and a component of more than six digits broke the padding.
3. One copy in use made `Storage.deleteApps` refuse the whole set, and the names and sizes of all
   of them were returned as removed (cause 6 of issue 7).

#### Changes

- **`SignedCopyRetention.surplus(among:)`** (new, in `CleanupPolicy.swift`) is the rule: for every
  app with several signed copies, all but one. The copy kept has the highest version, compared
  number by number with trailing zeros dropped; among copies of one version it is the one added
  last; copies that tie on both are settled by identifier, so the same library always gives the
  same answer. A copy without a readable version ranks below the others and one without a date is
  treated as the oldest.
- **`pruneDuplicateSignedApps` uses it**, leaves out copies that are in use so that one busy copy
  does not keep every other duplicate, and returns nothing unless `Storage.deleteApps` returned
  true.
- The footer under Rules in Settings → Auto Cleanup says which copy is kept among equal versions.

### Files modified (follow-up 2)

Production (18 files; the two marked *new* use neither UIKit nor the storage layer, which is what
lets them be unit-tested):

| File | Change |
|---|---|
| `VexSign/Backend/Services/PostSignArtifacts.swift` | *new* — the rule for the two copies of a run; the review wording |
| `VexSign/Backend/Services/CleanupPolicy.swift` | *new* — `CleanupPassPolicy`, `SignedCopyRetention` |
| `VexSign/Backend/Services/AppOperationRegistry.swift` | `claimProduction`, `confirmProduction`, `knowsProduction` |
| `VexSign/Backend/Services/SigningCompletionAction.swift` | `keepsSignedApp` removed |
| `VexSign/Backend/Observable/CleanupManager.swift` | `finishSign`, `sweepAfterSigning`; `delete` reports only what was deleted; every pass defers through `CleanupPassPolicy`; `CleanupSummary.deferred` and `deferralNotice`; `PostSignArtifacts.Settings.stored(in:)`. `runAfterSign`, `deletesSourceAfterSign` and `automaticCategories` removed |
| `VexSign/Backend/Observable/CleanupHistory.swift` | `pruneDuplicateSignedApps` on `SignedCopyRetention`; busy copies left out; a refused deletion is not reported |
| `VexSign/Backend/Observable/StorageManager.swift` | `LibrarySnapshot.productions`; `owns` asks it |
| `VexSign/Backend/Observable/AutoSignManager.swift` | `finishSign`, origin `.savedSettings` |
| `VexSign/Backend/Observable/UpdateAllManager.swift` | `finishSign`, origin `.update` |
| `VexSign/Backend/Observable/BatchJobRunner.swift` | `finishSign`, origin `.batch`; one `sweepAfterSigning()` |
| `VexSign/Utilities/IPAExplorer/IPAWorkspace.swift` | `finishSign`, origin `.explorer` |
| `VexSign/Views/Signing/SigningView.swift` | `finishSign`, origin `.sheet` |
| `VexSign/Utilities/Handlers/SigningHandler.swift` | claims its output in `init`, confirms it after the row is committed |
| `VexSign/Utilities/Handlers/AppFileHandler.swift` | the same for an import |
| `VexSign/Views/Settings/Cleanup/CleanupView.swift` | After Signing and Rules footers; Clean Now shows the deferral |
| `VexSign/Backend/AppIntents/VexSignIntents.swift` | the Clean Now action reports the deferral |
| `VexSign/Views/Library/Info/LibraryInfoView.swift` | the review line comes from the rule |
| `VexSign/Resources/Localizable.xcstrings` | 5 new keys, appended by `tools/sync-strings.py --write` as `extractionState: manual` — English values, no machine translation. The 3 keys of the sentences they replace are removed: they were `manual` entries with an English value only, no source names them any more, and the weekly maintenance job prunes only keys Xcode has marked stale. They were removed with the tool's own writer, so the rest of the file is unchanged |

Tests (6 files):

| File | Change |
|---|---|
| `VexSignTests/PostSignArtifactsTests.swift` | new — 18 tests |
| `VexSignTests/SignedCopyRetentionTests.swift` | new — 12 tests |
| `VexSignTests/CleanupOperationGuardTests.swift` | 7 → 15 tests: production claims; the pass rule moved to `CleanupPassPolicy` |
| `VexSignTests/StorageLibrarySnapshotTests.swift` | 8 → 14 tests: copies being produced |
| `VexSignTests/DesignSystemTests.swift` | one test rewritten: `keepsSignedApp` no longer exists |
| `tools/test_workflow_trace_policy.py` | 9 new source pins (25 in the file) |

`InstalledAppProbe.swift`, `LibraryStatusStore.swift` and `SelfUpdateManager.swift` are unchanged.
No `.xcodeproj` edit is needed, for the reason given under [Files modified](#files-modified).

### Regression tests added (follow-up 2)

44 more XCTest methods than before, 4 existing ones rewritten — three for the pass rule's new
home, one because `keepsSignedApp` no longer exists — and 9 source pins.

**The two copies of a run — `PostSignArtifactsTests` (18)** · Every flow has a table of all sixteen
combinations of Delete Signed App, Auto Cleanup, install after signing and a signed or unsigned
source · in all eighty rows the signed copy stays and the source is settled as the table lists · a
re-sign that does not install no longer leaves no copy · no other setting removes the signed copy
either · a run that failed or was cancelled deletes nothing · an output without a row blocks the
deletion of the source · so does an output whose bundle is missing · the output is confirmed
before the source is deleted · an output without an identifier is never confirmed · the library
is not asked when nothing wants the source removed · a source that is also the output is never
deleted · a source without an identifier is left alone · a source that is in use stays and is not
reported as removed · the master switch turns both cleanup switches off · each cleanup switch only
reaches its own kind of source · the run's own option removes an unsigned source only in the sheet
and in a batch · the cause says who asked for the source to go · the review says what the run will
do with the copy it starts from, compared with the catalogue keys.

**Which duplicate is kept — `SignedCopyRetentionTests` (12)** · A re-signed copy outlives the copy
it was started from · every re-sign of one version leaves only the latest · the highest version is
kept even when an older one was added later · versions are compared as numbers · trailing zeros
are not a higher version · a copy without a readable version ranks below the rest · a copy without
a date is the oldest · copies that tie on everything are settled the same way every time · copies
of different apps are not duplicates · a single copy is never removed · a copy listed twice is not
its own duplicate · every app keeps exactly one copy whatever the order of the rows.

**Claims and the pass rule — `CleanupOperationGuardTests` (15; 8 more, 3 rewritten)** · A copy is
known from the moment it is announced · a claim given up without a row ends with the run · a
registered copy stays known after its run is over · two claims on one copy need both given up · a
claim is not an operation on a stored copy, and an operation is not a claim · a pass leaves the
temporary directory and leftovers alone while an operation runs, clears everything enabled once
nothing runs, and never adds a category the user did not enable · nothing that was asked for is
lost between the two lists · only those two areas are ever deferred.

**Leftovers — `StorageLibrarySnapshotTests` (14; 6 more)** · A copy being produced is not a
leftover · a copy produced and registered since the snapshot is not a leftover · what a failed run
left behind is a leftover again · a folder nothing accounts for is still a leftover · copies being
produced do not make a certificate folder owned · a snapshot with nothing to ask judges by its rows
alone.

**`DesignSystemTests` (1 rewritten)** · Completion actions install only when asked to.

**Source pins — `tools/test_workflow_trace_policy.py` (9 new)** · These cover the wiring in files
that cannot be unit-tested without the iOS SDK, and run in `make verify` and CI's quick job: every
signing flow settles its copies through the one rule, compared argument for argument, with one sweep
after a batch's loop, and no file outside the known flows calls the signer · no flow can ask for the
signed copy to be dropped (the three removed entry points stay removed, and `finishSign` deletes
nothing but its source) · the cleanup switches reach the rule as stored · reporting and the sweep
follow the caller · a removal that was refused is not reported · a copy being produced is announced
before its folder exists and confirmed after its row · every cleanup pass defers what a running
operation uses · duplicate pruning uses the retention rule, on signed copies only, and leaves busy
ones out · the repeat-signing review is worded by the rule the run follows.

### Validation (follow-up 2)

**Run in this workspace and passing:**

| Gate | Result |
|---|---|
| `make verify` | exit 0 |
| `.github/scripts/quick_check.py --no-swiftc` | ✅ 0 errors, 0 warnings, including `duplicate-types` and `duplicate-filenames` |
| `make verify` gate self-tests | ✅ 280 Python tests, all OK (271 before the nine new pins) |
| `make docs-check` | ✅ file links OK; 3 documentation tests OK. It does not check heading anchors; the anchored links in the changed documents were resolved with a separate script, none broken |
| `tools/test_workflow_trace_policy.py` | 25 tests OK. Run against the tree as it stood before this follow-up, the 9 new pins do not pass (7 fail; 2 stop on a function that is not there) and the other 16 pass |
| `tools/sync-strings.py --check` | ✅ 474 Swift files · 3287 distinct literals · 3567 catalogue keys — every literal has a key (3565 keys before: 5 added, 3 removed) |
| `tools/concurrency-discipline.py` | ✅ 6 escapes across 5 files — at baseline, none added |
| `tools/singleton-freeze.py` | ✅ 62 singletons across 61 files — at baseline, none added |
| `tools/error-discipline.py` | ✅ 239 unjustified `try?` across 95 files — unchanged |
| Syntax | all 22 changed or new Swift files parse with a Swift 6.4 frontend in Swift 5 language mode |

**Executed, but not on the iOS toolchain.** As in the first follow-up, the code that needs no UIKit
was compiled and run with a Swift-to-WebAssembly toolchain kept outside the repository, with
`import` lines for unavailable modules removed and `.localized` replaced by the identity. Because
of that replacement, a wrong sentence is noticed there and a missing `import NimbleExtensions` is
not; the imports were checked by reading.

| Suite | Result |
|---|---|
| `PostSignArtifactsTests`, `SignedCopyRetentionTests`, `CleanupOperationGuardTests`, `StorageLibrarySnapshotTests` | 59 pass (18 + 12 + 15 + 14), no warnings — against the real `PostSignArtifacts`, `CleanupPolicy` and `AppOperationRegistry`, with `LibrarySnapshot` and `StorageCategory` copied out of `StorageManager.swift` by script |
| The rewritten `DesignSystemTests` method | passes, copied out by script: the rest of that file needs SwiftUI |
| From the first follow-up, run again: `OneShotTweakFilesTests`, `SigningProfileReplayTests`, `SigningRecordIdentityTests`, `TaskReceiptOutcomeTests` | 45 pass (32 + 13) |

`CleanupManager.swift` and `CleanupHistory.swift` type-check there without a warning, together with
the three files above, against stand-ins for `Storage`, `StorageManager`, `Toast`, the options and
the app model — and for Foundation's `ListFormatter`, which that toolchain does not have and which
the deferral sentence is the first code in the app to use. That is a check of those two files
against the *shape* of what they call, not against the real declarations.

**A harness that is not in the repository.** The rule is tested by the suites above; what
`CleanupManager` does with it is not something XCTest can reach without the real database and
file system. To check that wiring, the real `CleanupManager.swift` and `CleanupHistory.swift` were
compiled against recording stand-ins and driven by 21 tests kept outside the repository: all the
setting combinations through `finishSign` for every origin, a refused deletion, an output without
a row or without a bundle, what is reported and what is swept for each caller, the deferral in
every pass and the prune. All 21 pass. They are evidence about that file's logic; they are not
part of the repository's tests and will not run in CI.

**Each rule was also checked by taking it away**, one change at a time in a copy of the source
outside the repository, confirming that the tests notice:

| Changes made to the copy | Noticed by |
|---|---|
| 10 to the rule in `PostSignArtifacts`: confirmation skipped, the same-copy check skipped, saved settings replacing again, either switch ignoring the master switch, the switches crossed, the run's option reaching signed sources, a missing output identifier accepted, the result of the deletion ignored, the review wording inverted | `PostSignArtifactsTests` — all 10 |
| 5 to `SignedCopyRetention`: a tie keeping the oldest, the date ignored, versions compared as strings, the lowest version kept, trailing zeros counted | `SignedCopyRetentionTests` — all 5 |
| 4 to the pass rule and the snapshot: nothing deferred, leftovers not deferred, the temporary directory not deferred, the snapshot ignoring productions | `CleanupOperationGuardTests`, `StorageLibrarySnapshotTests` — all 4 |
| 5 to the registry: confirmation doing nothing, a claim not counted, never released, one release ending every claim, a claim making its copy busy | `CleanupOperationGuardTests`, `StorageLibrarySnapshotTests` — all 5 |
| 21 to `CleanupManager` and `CleanupHistory`: the output deleted, the output always confirmed, a refused removal reported, every cause reported, a sweep where none belongs, the pass after Clean Now or after a batch unguarded, the stored switches swapped, the prune attempting busy or unsigned copies, and the like | the harness outside the repository — all 21. **The repository's XCTest files do not notice these**; in the repository that wiring is held by the source pins |
| 69 to the wiring, in a scratch copy of the tree: a flow deleting its source itself, the wrong origin, the copies swapped, a flow's own option dropped, a batch sweeping per app or never, a claim not taken or confirmed before the row, the review with fixed wording, the old entry points back, a new flow that signs and deletes its own output | `tools/test_workflow_trace_policy.py` — all 69 |

Two of the 45 were not noticed at first — a missing output identifier, and the two review
sentences swapped — and seven of the 69. The tests were extended until they were: a test for an
output without an identifier, the review compared with the catalogue keys rather than with itself,
a pin that compares each flow's whole call, and the list of every file that calls the signer.

This is evidence about the logic, **not** about the iOS build. The app target is compiled by a
different compiler version against a different SDK; a clean run here does not show that it compiles
there, and it says nothing about the warnings gate.

**Not run, and not claimed as run:**

- Any compile against the iOS SDK. `AutoSignManager`, `UpdateAllManager`, `BatchJobRunner`,
  `SigningHandler`, `AppFileHandler`, `IPAWorkspace`, `SigningView`, `CleanupView`,
  `LibraryInfoView`, `VexSignIntents` and `StorageManager` outside `LibrarySnapshot` were parsed and
  hand-checked against the declarations in this repository, and nothing more.
- `make test` — XCTest results for the new tests and for the existing suite on the simulator are
  unknown.
- CI's `build` job and its warnings gate, `make strict-concurrency`, `make lint`, the IPA build.
- `InstallVerificationTests`, `InstallDeadlineBudgetTests` and the 51 existing engine tests listed
  in the first follow-up were not run again. None of the files they compile was changed here.
- `make test-server` and `make test-cloud`: those components were not changed and were not re-run.
- Anything on a physical device. **No on-device verification was performed**, so none of the three
  defects has been reproduced, and none of the fixes has been observed to remove one.

No CI run of this follow-up is recorded here; the base commit's run is the one named under
[Validation (follow-up)](#validation-follow-up). For a first signal on the simulator, use the
command given there with these suites:

```bash
  -only-testing:VexSignTests/PostSignArtifactsTests \
  -only-testing:VexSignTests/SignedCopyRetentionTests \
  -only-testing:VexSignTests/CleanupOperationGuardTests \
  -only-testing:VexSignTests/StorageLibrarySnapshotTests \
  -only-testing:VexSignTests/DesignSystemTests \
```

### Remaining limitations (follow-up 2)

1. **A re-sign leaves two signed copies unless a setting says otherwise.** That is the change, and
   it is the safe direction, but someone who relied on a re-sign replacing its copy now collects
   copies until they turn on "Delete Signed App" or "Keep only the newest signed copy". If
   replacing should stay the default for the flows without a sheet, it is one line: the
   `(.savedSettings, true)` case in `PostSignArtifacts.requestedRemoval`. The source would still go
   only after the output is confirmed.
2. **"Delete Signed App" no longer discards a signed copy that was not installed.** Nothing takes
   that over. Removing a signed copy after it has been *installed* is "Delete Installed App", which
   is unchanged — and with it on and "Delete Signed App" off, a re-sign that installs leaves the
   older signed copy in the library, where the old code left none.
3. **"Keep only the newest signed copy" can still remove a copy a run produced**, later and by its
   own rule: it keeps the highest version, so re-signing an older version while a higher one of the
   same app is in the library makes the new copy the surplus one at the next Clean Now. Unchanged;
   it is now the only path that does this, and it does not run when a sign finishes.
4. **A source that is in use when its run finishes stays, and nothing removes it later.** A run
   holds the copy it was started from until the moment it reports its result, so this needs
   another operation to take that copy in the instant before the run is settled. When it happens,
   `Storage.deleteApps` shows its "in use" message, cleanup reports nothing, and both copies remain
   until the user removes one or "Keep only the newest signed copy" does.
5. **Only signing and importing claim what they produce.** A clone is covered by the deferral while
   its source's lease is held, which protects it from every pass except the Storage screen's Clear.
   A library restored from a backup, a certificate being imported and a file arriving in the web
   manager's inbox have no claim, and a leftovers pass at the wrong moment can still take what they
   are writing. Unchanged.
6. **The Storage screen's Clear is not deferred.** It is an explicit action on a named category. It
   judges leftovers through the same snapshot, so a copy being signed or imported is safe, but it
   will empty the temporary directory under a running operation. Unchanged.
7. **Only the button and the Shortcuts action say what Clean Now left.** The web API's
   `/api/cleanup`, the companion and background automation report what was freed and nothing about
   what was deferred. Their next call with nothing running clears it.
8. **A produced copy is remembered until the app quits.** If its row were deleted and its folder
   somehow stayed — `Storage.deleteApps` moves the folder away first, so this is not expected — the
   folder would not count as a leftover until the next launch.
9. **What is stored per copy stays with that copy.** The favourite mark and the auto-update switch
   are kept by copy identifier, and the signing record belongs to the copy a run produced. A new
   copy starts without them, as before; with the source kept, they now remain on the older copy
   instead of being lost with it. Library details that are open on a copy when it is removed keep
   showing it, as before.
10. **The strings are English only.** The five new sentences have no translations yet. The three
    they replace had none either, and their keys are removed.

### Required on-device acceptance (follow-up 2)

These continue the list above. None of them has been performed.

**What a sign leaves in the library**

40. With the defaults (Auto Cleanup on, "Delete Unsigned App" and "Delete Signed App" off), open a
    signed copy's details and choose **Re-sign with last settings**. The review must say that this
    copy stays and that "Delete Signed App" would remove it. After the run, Library → Signed must
    hold both copies.
41. Turn on Auto Cleanup's "Delete Signed App" and turn "Install After Signing" off in the signing
    options, then repeat 40. The review must say that this copy is removed because "Delete Signed
    App" is on. After the run there must be exactly one signed copy of the app, the new one — its
    details show "Signing result for this copy: Completed" for the run just made — and a cleanup
    message naming the app that was removed. **This is the case that used to leave no copy.**
42. Repeat 41 from **Re-sign Last** in the row's swipe actions, from **Re-sign with Last Settings**
    in the row's context menu, and from the Shortcuts action **Sign App**.
43. With the settings of 41, open the signing sheet on an **imported** app and sign. When the sheet
    closes, the signed copy must be in Library → Signed. It used to be deleted at that moment. The
    import stays, because "Delete Unsigned App" is off.
44. With the settings of 41, open the signing sheet on a **signed** copy and sign. Afterwards the new
    copy is in the library and the copy the sheet was opened on is gone.
45. Turn "Delete Signed App" on and then turn the Auto Cleanup master switch off. Repeat 40: the
    review must say the copy stays, and both copies must remain.
46. Run a batch job over two signed copies with "Delete Signed App" on. Both new copies must be in
    the library and both sources gone. No message appears per app; the two removed apps are listed
    under History in Settings → Auto Cleanup, and at most one cleanup message follows the batch,
    for the storage that was swept. With "Delete Signed App" off, all four copies remain.
47. Use IPA Explorer's **Sign & Install** on a library app. The signed copy must be in the library
    and queued for install, and the copy that was edited must be gone, as before.
48. Not expected to be reachable by hand: a run holds the copy it was started from until the moment
    it reports its result, so another operation can take that copy only in the instant before the
    run is settled; an install of that copy that starts while the run is still going fails with "in
    use" instead. If it is ever seen with "Delete Signed App" on — an install of the source copy
    starting at exactly that moment — both copies must remain, VexSign must say the app is in use,
    and no cleanup message may name it. Until then the case rests on
    `testASourceThatIsInUseStaysAndIsNotReportedAsRemoved` and on the harness described under
    [Validation (follow-up 2)](#validation-follow-up-2).

**Leftovers and Clean Now**

49. Turn on "Clear Temporary Files" and "Remove Leftovers". Start **Re-sign Last** on a large app
    from its Library row, go to Settings → Auto Cleanup and tap **Clean Now** while it is still
    signing. A message must say "Not cleaned while an operation is running: Temp Files and
    Leftovers". The sign must finish, and the new copy must open in details, list its files under
    **Browse Files** and install.
50. Tap **Clean Now** again once nothing is running. It must not show that message: it reports what
    it freed, or "Nothing to clean up".
51. Run the Shortcuts action **Clean Now** while a sign or an install is running. Its answer must
    include the same sentence.
52. With "Remove Leftovers" on and auto sign after import on, download or import several large apps
    one after another. Every imported and every signed copy must open its details and list its
    files; none may be an entry without a bundle.
53. While a large app is being imported or signed, open Settings → Storage and clear **Leftovers**.
    The copy that was being produced must be complete afterwards. This path is not deferred, so it
    exercises the claim alone.

**Keep only the newest signed copy**

54. Turn on "Keep only the newest signed copy" with "Delete Signed App" off. Re-sign a signed copy,
    so that two copies of one version exist, and tap **Clean Now**. The copy that remains must be
    the one just signed.
55. With signed copies of two versions of one app whose order differs as text and as numbers — 1.9
    and 1.10 — **Clean Now** must keep 1.10.
