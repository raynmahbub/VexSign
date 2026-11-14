# Automation, workflows and extensibility

What VexSign automates today, where it refuses to automate, and the one rule that changed in
this pass: **an automation pass that did not run must not report that there was nothing to do.**

No Swift was compiled and no test was executed while this was written.

## The existing surface

| Layer | Implementation | What it does |
| --- | --- | --- |
| Task engine | `UnifiedTaskCenter` + `TaskProgressRule` / `TaskRetryPolicy` / `TaskSubmissionPolicy` / `TaskMirrorPolicy` | One record per long-running operation, persisted, with duplicate suppression and retry rules |
| Scheduled pass | `BackgroundAutomation.run(fromBackground:)` | Self-update check, GitHub release review, source refresh, update comparison, optional sign + queue, cleanup. Always run under a BGTask or a user action; iOS decides when |
| Signing automation | `AutoSignManager` | Saved options per bundle, serialized (`_tail`), identity-substitution notice, cleanup after success |
| Update-all | `UpdateAllManager` | Progress and cancellation for a whole-library pass |
| Batch | `BatchJobRunner` | Screen-scoped sign/install over a selection |
| Install queue | `InstallQueue` / `InstallQueueCore` | Sequential installs with deadlines, verification and honest `unconfirmed` states |
| Per-app rules | `PerAppUpdateRules`, `UpdateMatchingPreferences`, `SkippedUpdatesManager` | Which apps may update, how they are matched, which are ignored |
| Policy | `BackgroundAutomationPolicy` (notify only / sign & queue), `BackgroundAutomationInterval` | The only "automation config" that exists, and it is typed |
| Shortcuts | `Backend/AppIntents/` — 12 intents, 10 Siri phrases | Thin calls into the managers above |
| Notifications | `DownloadNotificationBuilder`, `SelfUpdateNotifier`, `CertificateExpiryMonitor`, `EcosystemMaintenance` | Download completion/failure, VexSign updates, certificate expiry, ecosystem housekeeping |
| Live Activity / widgets | `DownloadLiveActivity`, `SigningLiveActivity`, `VexSignStatusWidget`, `VexSignRepoAppsWidget` | Progress and counts only |
| History | `AutomationHistoryStore` | Counts and outcomes per pass — no app names, credentials or source URLs |

There is **no scripting engine**, no user-supplied code, and no third-party automation hook. That
is deliberate and stays that way: the configuration model is typed (`Options`, `PerAppUpdateRules`,
`BackgroundAutomationPolicy`, `SigningProfileStore`), which is what makes a Shortcut safe to expose.

## Gap found and fixed: "Everything is up to date" for a pass that never ran

`BackgroundAutomation.run` returns `nil` for five different reasons — automation off, a pass
already running, Update All running, Game Mode on, cancelled — and records each one in
`AutomationHistoryStore`. `UpdateAllIntent` read `nil` as "found nothing" and answered:

> Everything is up to date.

That sentence is true only of a pass that compared every source. For a pass that never started it
is false, and it is exactly the kind of false success a Shortcut log turns into a wrong belief.
The same intent also dropped the `failed` counter, so "signed 2" could mean "signed 2, failed 3".

`AutomationAvailability` and `AutomationDialogue` (new, pure) replace both:

- `blocker(enabled:running:gameMode:updateAllRunning:)` returns the first reason that applies, in
  the order `run` checks them (disabled before busy: enabling automation is the user's next step).
- `message(for:)` explains the blocker. No message may contain "up to date", and a test enforces
  that for every case.
- `AutomationDialogue.message(found:signed:failed:blocked:)` reports a finished pass: up to date
  only when nothing was found *and* nothing failed; otherwise the counts, with failures appended
  beside the successes.
- `AutomationDialogue.unfinished` is used when a pass returned nothing after its guards passed
  (cancellation): it says the pass did not finish and claims nothing.

`UpdateAllIntent` now asks for a blocker before running, and reports `unfinished` instead of a
success sentence when `run` returns nil anyway. `BackgroundAutomation.isRunning` became
`static private(set)` for that question; nothing else about the pass changed.

## Intent coverage, and what is deliberately absent

Present: update all, clean now, sign latest download, open IPA explorer, sign app, install app,
refresh sources, check certificates, open VexSign, download from URL, game mode, library summary.

Absent on purpose:

- **Background signing.** `UpdateAllIntent` runs inside a Shortcut, which is a foreground
  user action. There is no intent that promises to sign while the app is suspended, because iOS
  does not grant that.
- **Silent installation.** `InstallAppIntent` queues; installation still needs the user and,
  for OTA, the on-screen prompt.
- **Anything over a private key.** No intent reads a password, a `.p12` or a Keychain item, and
  none returns one. Intents return counts and sentences.
- **Arbitrary URL download into the library without validation.** `DownloadFromURLIntent` goes
  through the same admission, scheme policy and integrity checks as the UI.

## Notifications

Existing uses are completion/failure and expiry — events that happened. There is no notification
for "queued", "pending" or "in progress", because a notification is the wrong place to suggest iOS
has done something it has not.

## Widgets and Live Activity

Widgets show counts and repository entries; Live Activities show download and signing progress.
Neither renders certificate details, account state or app names beyond what the user already put
on their Home Screen, and neither performs work — a widget timeline reload is not an execution
mechanism.

## Extensibility without plugins

The extension points are internal and typed: services are singletons with narrow interfaces
(`SigningService`, `DownloadManager`, `InstallQueue`, `Storage`, `UnifiedTaskCenter`), flows report
into the task center rather than owning their own state, and cross-feature policy lives in pure
types (`VersionOrder`, `ProfileCompatibility`, `TaskSubmissionPolicy`, `AutomationAvailability`)
that a new caller can use without learning a view.

What is intentionally not offered: a plugin marketplace, an interpreted workflow language, or a
hook that runs code from repository metadata or an imported IPA. The threat model for that is not
"a powerful feature"; it is "untrusted code execution inside a process that holds signing
identities", and none of the automation in this app needs it.

## Tests

`App/Tests/VexSignTests/AutomationAvailabilityTests.swift` — 12 tests, all pure: blocker precedence
(disabled > busy > game mode), both running passes mapping to `busy`, an available pass having no
blocker, every blocker message avoiding a success claim, a blocked pass never reporting up to date,
the empty pass reporting up to date, updates-without-signing naming the setting, the signed count,
failures reported beside successes, a failed pass with no updates not claiming success, and the
unfinished sentence claiming nothing.

**Not executed** — no Swift toolchain in the authoring environment.

## Still unverified

- Nothing about Shortcuts on a device: Siri phrase registration, the Shortcuts gallery entry,
  parameter pickers over the library entity, and Confirmation behaviour have never been observed.
- Notifications have never been observed being delivered from a scheduled BGTask pass.
- Widget timelines have never been observed refreshing after a signing run.
- The combined-host layout cannot register the host's background handlers (`RuntimeCapabilityReport`
  reports `scheduledGuestTasks` unavailable there), so automation in that build is foreground only.

## Next steps that are worth taking

1. A `LibrarySummaryIntent`-style **task status** intent, so a Shortcut can ask what is running
   without opening the app — read-only, no confirmation needed.
2. An intent that returns **signing readiness** for one app (identity present, profile covers it,
   device provisioned) using `ProfileCompatibility`, which already answers it.
3. Audit which intents should declare `IntentAuthenticationPolicy.requiresAuthentication`. None do
   today; for anything that signs or installs, unlocking the device first is a reasonable floor.
