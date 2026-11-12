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
| `SecureSecretStore.swift` (companion credential Keychain access) | ✅ | ✅ | ✅ | — | — |
| `WatchSnapshotStore.swift` (app-group hand-off) | — | — | — | ✅ | ✅ |

The shared client uses Foundation, the store adds SwiftUI/Combine, and the small
Keychain primitive uses Foundation/Security. Companion passwords and API tokens
are migrated out of legacy UserDefaults before the legacy entries are removed.
Anything that touches UIKit, Core Data or the signer stays in the iOS target.

## Apple TV

`VexSignTV/` — one screen, focus-first: certificate hero card, four count tiles,
pending updates, library grid.

**Connection:** open VexSign on the iPhone → *Settings → Web Manager* → set a
username and password, turn on **Allow This Network**, then start the server.
Enter its HTTPS address, compare and enter the printed CA fingerprint, and add
the password or API token in the companion. The server listens
on loopback until network access is turned on, and will not start while *Require
Password* is on and the password is empty. The companion reads `/api/status`,
`/api/library` and `/api/updates`, which are behind that password when configured.
There is no auto-discovery: the Web Manager does not advertise a Bonjour service,
and guessing addresses is worse than asking.

**Transport and pairing:** a bare host is treated as HTTPS. In VexSign → Settings
→ Web Manager, compare the displayed **Device CA SHA-256 fingerprint** and enter
that value in the companion before the first connection. The companion accepts
only the matching certificate chain, applies the platform SSL policy for the
requested host/IP (including validity, chain signatures, EKU and SAN matching),
and saves the accepted CA certificate in Keychain, scoped to that HTTPS origin.
Credentials are sent only after validation and the Keychain write succeed. An
invalid, expired, hostname-mismatched or changed certificate fails closed; a
changed fingerprint requires explicitly forgetting the old trust and pairing
again after checking the new value on the iPhone. The CA remains stable across
leaf-certificate renewals, and its leaf includes the current LAN address.

The Web Manager always serves HTTPS; it does not fall back to HTTP. The companion
refuses HTTPS-to-HTTP, cross-host and cross-port redirects. HTTP remains available
only after enabling **Allow unencrypted HTTP on a trusted local network**; this
explicit opt-in has no certificate pairing and exposes credentials and API data
to devices on the network. Do not use it on an untrusted network. A browser may
show a warning for the locally issued certificate; companion pairing does not
install that CA into the browser or operating system's global trust store.

**What it reads:** `GET /api/status`, `GET /api/library`, `GET /api/updates` —
the automation endpoints that already existed. No new server surface was added
for the companions.

**Refresh:** on appear, on demand, and every 30 seconds by default
(`autoRefreshInterval`, settable in the store). A failed refresh keeps the last
good snapshot on screen instead of blanking.

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
runners whenever a companion target, `VexSign/Companion/`, the shared
`VexSign/Security/SecureSecretStore.swift`, `PlatformInfo/`, or the project file changes.

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
- **Browser trust is separate from companion pairing.** The TV/Vision apps pin
  the device CA after the user checks its fingerprint. That does not install the
  CA into Safari/Finder or the device-wide trust store; a browser or WebDAV client
  may require a separate manual trust step for the locally issued certificate.
- **Watch reachability is Apple's call.** Commands may take until the next
  in-range moment; the UI says so instead of pretending they ran.
- **Not device-tested here.** These targets compile in CI (macOS runners) but the
  layout, focus behaviour, complication sizing and WatchConnectivity hand-off
  still need a run on real hardware or simulators.
