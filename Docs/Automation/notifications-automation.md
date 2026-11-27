# Notifications, background processing and automated maintenance

This document describes what the code in this branch actually does. It is not a claim of
background execution on a simulator or of notification delivery in CI.

## Feature-to-source map

| Concern | Owner |
| --- | --- |
| Authorization, categories, stable IDs, dedupe, preference gating, payload allow-list, history, action routing | `VexSign/Services/Notifications/VexSignNotificationService.swift` and supporting models |
| Persisted topic and per-milestone switches | `VexSign/Services/Notifications/NotificationPreferences.swift` |
| Certificate/profile expiry planning | `VexSign/Services/Notifications/ExpiryReminderScheduler.swift` |
| Real metadata source | `VexSign/Services/Notifications/ExpiryReminderSource.swift`, `CertificateInspector.inspectAll` |
| Update decision and dismissal | `VexSign/Services/Updates/UpdateAvailabilityEvaluator.swift`, existing `SelfUpdateManager` |
| Verified task events | `VexSign/Services/Automation/AutomationDomainEvents.swift`, `AutomationEventCoordinator.swift` |
| Durable jobs, eligibility, overlap, backoff | `VexSign/Services/Automation/PersistentAutomationEngine.swift` |
| System scheduling and exactly-once completion | `VexSign/App/AppDelegate+BackgroundTasks.swift`, `BackgroundTaskCompletionGate` |
| Background download recovery | existing `DownloadManager`, `DownloadManager+Recovery.swift`, `BackgroundDownloadRunner.swift` |
| UI | `NotificationTopicsSettingsView`, `AutomationJobStatusView`, existing settings screens |

## Notification contract

Local notifications are announcements, not code execution. The service registers categories with
Review/Dismiss actions; an action only navigates (certificates, updates, tasks or sources). No
action signs, installs, updates, deletes or grants permission. Notification payloads are built
from allow-listed keys and values that look like credentials, email addresses, UUIDs or long hex
strings are dropped. Full diagnostics stay in the authenticated app UI and history.

Requests use stable identifiers. A repeated identifier replaces its own pending request; an
already-delivered immediate event is additionally deduped with a persisted hash for seven days.
Posting requires `.authorized` or `.provisional` authorization and the matching persisted topic.
When authorization is denied, the settings screen explains that iOS — not VexSign — controls
delivery and offers the system Settings route.

## Expiry reminders

Milestones are 30, 14, 7, 1 day and expired; each has its own switch. Dates come from the stored
profile expiry and the inspected leaf certificate's `notAfter`. Day counts use `Calendar` date
components between start-of-day values, so DST and time-zone changes do not shift a reminder by a
day. Future milestones are scheduled once at `expiry - N days`; when the app first opens after a
milestone, only the most urgent overdue milestone posts immediately. A missing date is `unknown`
and produces no reminder. Nothing claims a certificate was renewed: the app only reports a date.

Import commits post a `.certificateImported` event (metadata only) and replacement/removal posts
`.certificateRemoved`; the scheduler then reconciles stable identifiers, cancelling reminders for
rows that no longer exist. Inspection from scheduled maintenance supplies both certificate and
profile dates.

## Updates

`UpdateAvailabilityEvaluator` matches by normalized bundle identifier, verifies a download exists
in the source, applies the caller's compatibility check and compares version then build using the
existing `VersionOrder`. Invalid strings, downgrades and name-only matches are never announced as
updates. Dismissals are stored per stable digest and cleared for a bundle after an installed
release is confirmed. A notification only opens the review screen; installation always requires a
separate, explicit user action.

## Background work

`Info.plist` declares the permitted task IDs (`...maintenance`, `...refresh`, `...download`,
`com.vexsign.ecosystem.refresh`) and the fetch/processing/download/remote-notification modes.
The app registers each handler at launch. Every handler installs an expiration handler that
requests cancellation and closes the shared `BackgroundTaskCompletionGate`; the first completion
wins and duplicates are dropped. Resubmission replaces a pending request and is skipped when its
precondition is off. The embedded-container build does not submit guest tasks.

System scheduling is discretionary: an `earliestBeginDate` is the earliest time, not a promise of
hourly or continuous execution. Local notifications can appear while the app is closed, but they
cannot run VexSign's signing or network logic. Opening the app reconsiders eligible jobs as a
foreground fallback. `BGContinuedProcessingTask` requires an entitlement that sideloaded profiles
do not carry; registration is version-gated and submission is not claimed as available.

## Background downloads

The existing single background `URLSession` (`com.vexsign.app.background`) owns transfers and its
delegate. Recovery journal entries, stable recovery IDs, task-center transitions, integrity checks
and the app delegate's `handleEventsForBackgroundURLSession` completion handler remain the
authority. Completion notifications are posted only from delegate paths that already hold a final
service result; progress callbacks never announce success.

## Reference study

Apple documentation consulted: User Notifications overview and local scheduling (authorization,
categories/actions, stable requests, cancellation), Choosing Background Strategies and Using
background tasks to update your app (registration, expiration, exactly-once completion),
Downloading files in the background (fixed session ID, launch events, delegate completion), and
SwiftUI `BackgroundTask` (scene handlers). Apple documentation is the authority for iOS limits;
no private API or simulated background launch is used.

Reference projects were inspected for patterns only; no source was copied and no new dependency
was added:

| Project | Default branch | Licence | Pattern observed |
| --- | --- | --- | --- |
| altstoreio/AltStore | `marketplace` | AGPL-3.0 | Operation-based refresh; no code reused |
| SideStore/SideStore | `develop` | AGPL-3.0 | Stable expiration-warning IDs, cancelled before rescheduling; concept only |
| claration/feather | `main` | GPL-3.0 | Source/certificate storage separation; no code reused |
| Nyasami/Ksign | `main` | GPL-3.0 | Feather-derived layout; no code reused |
| NexSideloading/NexStore | `main` | GPL-3.0 | Certificate status snapshot with explicit unknown state; concept only |
| FrizzleM/SideInstaller | `main` | custom `NOASSERTION` | Source/pairing flow; not relicensed or reused |
| murk-sus/SayoSign | default | repository metadata reviewed | On-device signer surface; no notification implementation reused |
| LiveContainer | `main` | AGPL-3.0 | Guest-runtime limitation informed container guards |
| Odysseus / FeatherPlus | — | — | No authoritative iOS source identified; no assumptions made |

## Evidence boundaries

`make verify`, the portable contract test in `.github/workflows/ci.yml` (`quick` job), the macOS
`build` job and the simulator `tests` / `ui-tests` jobs are the automated evidence. A simulator
cannot prove background scheduling, background URLSession relaunch, lock-screen delivery or
expiration handling. Those require the physical-device steps below.

## Manual iPhone verification (exact steps)

1. Build the current branch with a development team and a profile that includes the app group;
   sideload onto a physical iPhone running iOS 17 or later. The entitlement
   `com.apple.developer.background-tasks.continued-processing` is not assumed.
2. Settings → Notifications → VexSign → allow alerts, sounds and badges. In VexSign open
   Settings → Notifications & Live Activities → VexSign notification types and reminders and
   turn on the topics and expiry milestones to test.
3. Import a real certificate/profile pair with a known expiration. Confirm that only the enabled
   milestones appear as pending requests and that the 30-day reminder is not delivered twice on
   repeated checks.
4. Remove that identity and confirm its reminders disappear; import a replacement and confirm new
   IDs are created. An identity with no readable expiration must show Unknown and post nothing.
5. Start a download, background the app immediately, then terminate it from the app switcher.
   Reopen: the task must resume or be explicitly recoverable, with no success banner before
   integrity verification completes.
6. Enable Settings → Automation, choose a short interval, background the app and lock the screen.
   Observe that iOS decides whether a pass runs. Check Settings → Automation → Automation Status
   for the last verified result, next eligible time and backoff after a forced failure.
7. Trigger a notification action from the lock screen. It must open the relevant screen and must
   not sign, install or update anything.
8. Deny notifications in iOS Settings, return to the app and confirm the explanation and Settings
   route appear while the persisted topic switches remain intact.

Record the device model, iOS version, build number, exact times and screenshots separately from
CI artifacts. Do not describe simulator results as physical-device evidence.
