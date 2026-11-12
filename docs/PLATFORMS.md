# Companion platforms: Apple TV, Apple Vision Pro, Apple Watch

VexSign's signing engine lives on iPhone/iPad: that is where the certificate, the
IPA storage, Zsign and `installd` are. The three targets in this document are
**companions** — they show what the phone is doing and can trigger work on it.
None of them signs, installs or stores apps, and none of them pretends to.

| Target | Platform | What it is | How it talks to the iPhone |
| --- | --- | --- | --- |
| `VexSignTV` | tvOS 17+ | Big-screen mirror: certificate countdown, counts, pending updates, library | Web Manager REST API over the local network |
| `VexSignVision` | visionOS 2+ | Spatial mirror with glass panels and an ornament control bar | Web Manager REST API over the local network |
| `VexSignWatch` | watchOS 10+ | Wrist mirror plus four remote commands | WatchConnectivity (push snapshot, queue commands) |
| `VexSignWatchWidgets` | watchOS 10+ | Complication: certificate days left, app/update counts | Reads the app group the watch app fills |

## Shared code

`VexSign/Companion/` is compiled into several targets through the same
membership-exception mechanism the widget extension already uses:

| File | iOS | tvOS | visionOS | watchOS | watch widget |
| --- | :-: | :-: | :-: | :-: | :-: |
| `CompanionModels.swift` (wire format) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `CompanionClient.swift` (Web Manager reader) | ✅ | ✅ | ✅ | — | — |
| `CompanionStore.swift` (view model) | ✅ | ✅ | ✅ | — | — |
| `CompanionSecretStore.swift` (Keychain for password/token) | ✅ | ✅ | ✅ | — | — |
| `WatchSnapshotStore.swift` (app-group hand-off) | — | — | — | ✅ | ✅ |

These files import Foundation (plus SwiftUI/Combine in the store) and nothing
else, which is what keeps them portable. Anything that touches UIKit, Core Data
or the signer stays in the iOS target.

## Apple TV

`VexSignTV/` — one screen, focus-first: certificate hero card, four count tiles,
pending updates, library grid.

**Pairing:** open VexSign on the iPhone → *Settings → Web Manager* → set a
username and password, turn on **Allow This Network**, then start the server and
enter the printed address (plus the username/password, and the API token if one is
set) in *Settings → Companion Devices → Apple TV & Vision Pro*… or simply type it
into the TV app's connect screen. The server listens on loopback until network
access is turned on, and it will not start at all while *Require Password* is on
and the password is empty — the companion reads `/api/status`, `/api/library` and
`/api/updates`, which are behind that password when one is configured. There is no
auto-discovery: the Web Manager does not advertise a Bonjour service, and guessing
addresses is worse than asking.

**What it reads:** `GET /api/status`, `GET /api/library`, `GET /api/updates` —
the automation endpoints that already existed. No new server surface was added
for the companions.

**Refresh:** on appear, on demand, and every 30 seconds by default
(`autoRefreshInterval`, settable in the store). A failed refresh keeps the last
good snapshot on screen instead of blanking.

**Transport.** The companion client speaks HTTPS. An address typed without a
scheme gets `https://`, and a `http://` address is refused unless
**Allow HTTP on this network** is on *and* the host is a local-network address
(private IPv4, IPv6 link-local/unique-local, `*.local` or loopback). Plain HTTP is
the case where the password and API token travel in cleartext, so it is an
explicit choice for a home network — never a fallback for a failed HTTPS
connection, and never valid for a public host. Redirects are refused outright,
because `URLSession` forwards request headers (including `Authorization`) when it
follows one.

**Credential storage.** The password and API token live in the Keychain
(`CompanionSecretStore`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), not
in `UserDefaults`. Values written by an earlier build are migrated on first launch
and the plaintext copy is removed only after the Keychain write succeeds, so a
locked Keychain leaves a working credential instead of losing it. A Keychain
failure is shown in the connect screen; it is never logged and never silently
treated as an empty password.

## Apple Vision Pro

`VexSignVision/` — a spatial window: certificate panel and counts on the left,
updates and library in a scrollable glass column on the right, with an ornament
holding *Refresh* and *Connection*. Same client, same endpoints, same store as
Apple TV; only the views differ.

Immersive spaces and volumes are deliberately not used: there is nothing to show
in 3D that a panel cannot show better, and an immersive space would hide the
numbers this app exists to display.

## Apple Watch

`VexSignWatch/` — certificate countdown, app/signed/update counts, and four
buttons that run on the phone:

| Command | What runs on the iPhone |
| --- | --- |
| Refresh repositories | `SourcesViewModel.fetchSources(refresh: true)` |
| Check certificates | `BatchCertChecker.checkAll(online: false)` — local only |
| Update all apps | `BackgroundAutomation.run(fromBackground: true)` |
| Clean now | `CleanupManager.cleanNow()` |

Each is the same call the matching App Intent makes, so there is one
implementation per action, not two.

**Transport:** `CompanionBridge` (iPhone) pushes a `CompanionSnapshot` with
`updateApplicationContext`, so the watch has numbers even if its app was never
opened, and sends a direct message when reachable. The watch replies with
`sendMessage` when the phone is reachable and `transferUserInfo` otherwise, so a
command pressed out of range is queued rather than dropped.

**Opt-in:** the bridge only activates when *Settings → Companion Devices → Apple
Watch companion* is on. It is off by default because activating a `WCSession` on
every launch is not free.

**Complication:** `VexSignWatchWidgets` renders the certificate countdown in the
circular, rectangular, corner and inline families. Widget extensions cannot open
a `WCSession`, so the watch app mirrors every snapshot into the
`group.com.vexsign.watch` app group (`WatchSnapshotStore`) and the complication
reads it from there.

## Building

```sh
xcodebuild -workspace VexSign.xcworkspace -scheme VexSignTV \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -workspace VexSign.xcworkspace -scheme VexSignVision \
  -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -workspace VexSign.xcworkspace -scheme VexSignWatch \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

`.github/workflows/platform-check.yml` runs exactly these three builds on macOS
runners whenever a companion target, `VexSign/Companion/` or the project file
changes.

The watch app is embedded in the iPhone app by an *Embed Watch Content* build
phase on the `VexSign` target, and the watch widget is embedded in the watch app
by its own *Embed Foundation Extensions* phase — so building the iOS app builds
the watch pair with it.

## Known limits (honest list)

- **No signing anywhere but iOS.** Zsign, the certificate store and `installd`
  are iOS-only. A companion that claimed to sign would be lying.
- **No app icons in the new asset catalogs.** `VexSignTV/`, `VexSignVision/`,
  `VexSignWatch/` and `VexSignWatchWidgets/` ship an empty `Assets.xcassets`;
  Xcode uses its placeholder icon. Add real icons before shipping.
- **Provisioning.** The new targets use `CODE_SIGN_STYLE = Manual` with an empty
  team, like the widget target, so unsigned CI builds work. Distributing them
  needs profiles for `com.vexsign.app.tv`, `.vision`, `.watch` and
  `.watch.widgets`, plus the `group.com.vexsign.watch` app group on the two watch
  bundles.
- **The TV/vision companions need the Web Manager running.** iOS suspends the
  server when the phone locks unless *Keep alive* is on; a companion then shows
  the last snapshot and a staleness indicator rather than fresh data.
- **The Web Manager itself serves HTTP.** It is a Vapor HTTP listener (`transport:
  .http`), so a companion reaching it over HTTP has no server-side TLS to negotiate;
  the HTTPS path is the one the local install server provides. Treat the pairing
  credentials as readable by anyone on the network that can sniff it, which is why
  the HTTP opt-in is local-only and off by default.
- **Watch reachability is Apple's call.** Commands may take until the next
  in-range moment; the UI says so instead of pretending they ran.
- **Not device-tested here.** These targets compile in CI (macOS runners) but the
  layout, focus behaviour, complication sizing and WatchConnectivity hand-off
  still need a run on real hardware or simulators.
