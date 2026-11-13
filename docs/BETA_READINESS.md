# Beta readiness: capabilities, limits and what must be true before distributing

This is the disclosure document for a controlled beta. It states what the app does, what Apple's
public APIs allow, and what a tester or reviewer will actually observe. Every claim below was
checked against the source; where the evidence is missing, it says so instead of implying success.

`tools/test_capability_disclosure.py` fails if a declared background mode, usage description or
entitlement stops being disclosed here, so this page cannot drift away from `Info.plist`.

## 1. Declared platform capabilities and their real limits

| Declared | Where | What it actually buys, and its limit |
|---|---|---|
| `UIBackgroundModes: audio` | `VexSign/Resources/Info.plist` | **Not audio playback.** `BackgroundTaskManager` activates an `AVAudioSession(.playback)` and re-arms a background task assertion so an in-flight install, download, signing or Web Manager session survives the app leaving the foreground. iOS may still suspend the app at its own discretion, and an audio interruption (a call, Siri, another app taking the session) stops the keep-alive: `handleAudioInterruption` calls `stop()` when it cannot resume playback. Apple documents the audio mode for apps that play audio for the user; declaring it for a non-audio purpose is a distribution risk (see §3). Long operations should be treated as **best-effort while backgrounded**, and they resume or reconcile when the app returns. |
| `UIBackgroundModes: download`, `fetch`, `processing` | same | Standard background `URLSession` and `BGTaskScheduler` work. iOS decides when refresh/processing runs; the automation UI says so rather than promising a schedule. |
| `UIBackgroundModes: remote-notification` | same | Notification delivery, not silent remote execution. |
| `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_http._tcp`, `_webdav._tcp`) | same | The in-app Web Manager and companion discovery on the LAN. Apple's limit: a locked or backgrounded phone may suspend the server unless the keep-alive above holds, and the user must grant the Local Network permission. |
| `NSFaceIDUsageDescription` | same | App Lock. No biometric data leaves the device. |
| `NSUserNotificationUsageDescription` | same | Not a key iOS reads — notifications ask for permission at runtime. It is declared here so this page accounts for everything in `Info.plist`; the permission text the user actually sees is supplied by `UNUserNotificationCenter`. |
| `NSAppTransportSecurity → NSAllowsLocalNetworking` | same | Only local-network cleartext is permitted. There is **no** `NSAllowsArbitraryLoads`; remote sources must be HTTPS. |
| `com.apple.security.application-groups` → `group.com.vexsign.app` | `VexSign/Supporting Files/VexSign.entitlements` | Shared container for the app, widget and extensions. |
| `get-task-allow = false` | same | Correct for distribution; a debug build overrides this. |

## 2. What VexSign cannot do, on any device

- **No background installation.** Installation is driven by `installd` through the device
  connection while the app is running; there is no supported API to install while suspended.
- **No automatic re-signing of an already-installed app.** Re-signing requires importing and
  signing a package again; the app does not patch installed binaries.
- **No JIT installation, no sandbox escape, no signature bypass.** Anything advertised by other
  tools in this space that requires private APIs is out of scope here.
- **Free Apple ID accounts expire.** A provisioning profile from a free account lasts about seven
  days and allows a small number of app IDs; VexSign surfaces expiry rather than working around
  it. Signing with an expired certificate or profile fails, by design.
- **Cloud signing is not a bundled feature.** `cloud-signing/` needs its own deployment, an
  identity provider, PostgreSQL, Redis and object storage, and a signing engine the operator
  supplies. `CloudSigningClient.signRemotely` refuses to upload a private key until a consent
  surface exists, so the current build offers no remote signing at all.
- **App Review applies to external testers.** Internal TestFlight testers do not require review;
  external testers do.

## 3. Distribution risks a beta must accept explicitly

1. **The audio background mode (highest risk).** The app declares `audio` and uses it to extend
   background time for non-audio work. Review guidance does not permit that use, and it is the
   most likely cause of a review rejection or a question about the app's stated purpose. A
   review-safe build would remove `audio`, stop the keep-alive, and accept that long operations
   pause when the app is backgrounded. That is a product decision with real UX cost, so it is
   **not** made here.
   Mitigation for a beta: distribute to **internal** testers, and tell them long operations may
   stall when the app is backgrounded.
2. **Two repository fetch paths.** `RepositorySyncEngine` validates and keeps a last-known-good
   snapshot; `FR.fetchRepositories` (used by the add-source screens) does not cap size or validate
   the schema. Behaviour differs by screen; see the integration report.
3. **Web Manager TLS is locally issued.** Browsers and companion devices must trust the device CA
   separately; the in-app flow explains this and does not claim otherwise.

## 4. Evidence status at the time of writing

| Evidence | Status |
|---|---|
| Linux gates (`quick_check`, `tools/`) | Pass locally and in CI's `quick` job |
| iOS build (`build · VexSign Debug (unsigned)`) | **Unverified.** The last run that executed it (workflow run 43375869813 on `cb17579`) **failed**; every later run left the macOS jobs queued. No passing build exists for the current HEAD. |
| Simulator tests (`tests · VexSignTests`) | **Unverified.** Same runs: one failure, then queued. |
| Physical-device acceptance | **Pending.** `docs/QA_DEVICE_ACCEPTANCE.md` is prepared; nothing in it has been run. |

## 5. What a beta tester should be told

- Install only from the distributed build; the app is not on the App Store.
- Signing needs a certificate and a matching profile; free accounts expire in about a week.
- Long operations may pause if you switch away; reopen the app and check the Task Center, which
  reports what actually happened.
- Repository feeds are user-supplied URLs; VexSign does not vet their contents.
- Backups contain certificate material and are protected by the archive password; store them
  accordingly.
