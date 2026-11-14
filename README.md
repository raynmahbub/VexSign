<div align="center">
  <img src="Resources/Branding/icon.png" alt="VexSign icon" width="96">
  <h1>VexSign</h1>
  <p><b>Import → inspect → sign → install. One on-device IPA workspace.</b></p>
  <p>
    <a href="https://github.com/raynmahbub/VexSign/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/raynmahbub/VexSign?label=latest%20release"></a>
    <a href="https://github.com/raynmahbub/VexSign/blob/main/LICENSE"><img alt="GPL-3.0 license" src="https://img.shields.io/badge/license-GPL--3.0-blue.svg"></a>
    <a href="https://github.com/raynmahbub/VexSign/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/raynmahbub/VexSign/actions/workflows/ci.yml/badge.svg"></a>
  </p>
  <p><a href="#download">Download</a> · <a href="Documentation/README.md">Guides</a> · <a href="Documentation/Engineering/BUILD.md">Build</a> · <a href="CONTRIBUTING.md">Contribute</a></p>
  <a href="Documentation/Design/assets/hero.svg"><img src="Documentation/Design/assets/hero.svg" alt="VexSign: sign, install, and manage apps on device" width="100%"></a>
</div>

VexSign combines local IPA signing, app management, repository discovery and
inspection tools in a native SwiftUI app for iPhone and iPad.

> **Know the limits:** installation requires a valid signing identity and a
> compatible device/profile. Native Apple ID provisioning and guest-host
> packaging are experimental. TV, Watch and Vision apps are **companions**, not
> standalone signers. No tool can bypass Apple's certificate or provisioning rules.

## Why choose VexSign?

Choose it when you want **local control and an integrated workflow**, rather than
switching between a signer, archive inspector, repository browser and file manager.
Local signing uses the bundled Zsign engine; optional companion/cloud paths are
separate, opt-in flows. Open source means you can inspect the implementation and
self-host the optional services—not that every feature is production-ready.

## Features

Every capability listed here has an implementation in this repository; the
[architecture guide's feature coverage table](Documentation/Architecture/ARCHITECTURE.md#readme-feature-coverage)
maps each area to the code that provides it. That mapping is a presence check, not
device acceptance — the caveats in each section still apply.

### ✍️ Signing & installation
<details>
<summary><strong>✍️ Signing & installation</strong></summary>


- **On-device IPA signing** powered by Zsign.
- **Batch signing and install queues** for processing multiple apps with per-app settings.
- **Reusable signing profiles** and named presets for repeat workflows.
- **Signing options and entitlement management**, with preflight checks and signing logs.
- **Local HTTPS installation** using `itms-services://`, plus paired installation through the AFC / `installd` backend.
- **Signing Live Activities** to follow progress on supported devices.
- **Auto-sign workflows** and **Update All** for re-signing source updates.

</details>

### 🧩 Customization & IPA tools
<details>
<summary><strong>🧩 Customization & IPA tools</strong></summary>


- **Tweak injection** for `.dylib`, `.deb`, `.framework`, `.bundle` and `.appex` inputs, with ElleKit support.
- **Tweak management** to organize injection components, with dependency-aware ElleKit injection and legacy Substrate replacement.
- **Mach-O thinning** to remove non-target architectures from supported universal binaries.
- **Document picker fixes**, keychain isolation and optional JIT entitlement settings. Entitlements alone do not guarantee JIT availability on a device.
- **IPA Explorer** for browsing app contents and editing `Info.plist`, files and images.
- **Clone Wizard** to create 1–20 numbered clones from a library app, rewriting identifiers and display names.
- **Clone icon badges** when a writable PNG icon is available; cloned apps still need compatible signing options and profiles.
- **File manager**, document browsing, QuickLook previews and file/compression settings.

</details>

### 📚 Sources, discovery & updates
<details>
<summary><strong>📚 Sources, discovery & updates</strong></summary>


- **GitHub IPA import** — browse up to 20 public releases from a repository and choose an IPA; prereleases are opt-in and existing download/auto-sign settings apply.
- **AltStore-compatible repositories** through AltSourceKit, including the existing encrypted ESign parsing support.
- **GitHub release sources** — add a public GitHub repository with exactly one `.ipa` asset in its latest release. GitHub releases do not publish bundle IDs, so automatic update matching may be unavailable for these entries.
- **Source management and preferences**, repository refresh and app update tracking.
- **HTTPS-only repository transport**, with an explicit opt-in for local HTTP repositories.
- **Source health dashboard** — last successful refresh, failure reasons, retry counts, rate-limit status, priority and duplicate-app resolution.
- **Discovery** with multi-term search, suggestions, favorites, categories and collections.
- **Featured, recommended, locally ranked trending and recently updated views** with app cards and carousels.
- **Bundle-ID grouping and multi-source version selection** for apps offered by multiple repositories.
- **Offline repository catalog** — the last successful snapshot of every source is kept on disk, clearly marked as a saved copy when a refresh fails, so browsing keeps working with no network.
- **Conditional repository sync** using ETag / Last-Modified, unchanged-content detection and coalesced refreshes.
- **Last-known-good source retention** when refreshes fail, plus opt-in startup/background refresh.
- **Per-app update rules** — ignore a version, ignore or prefer a source, pin a certificate, disable automatic updates and preserve custom signing options across updates.
- **Premium activation, restore and device recovery** through the configured backend, with premium catalog filters.
- **App self-update checking**, with a one-time local notification when a newer release appears, and controls for skipped source updates.

</details>

### 🛠️ Repository Builder & sharing
<details>
<summary><strong>🛠️ Repository Builder & sharing</strong></summary>


Available from **Settings → Ecosystem**.

- Create, edit, save and delete repository projects.
- Import repository JSON from files or HTTPS URLs.
- Export `source.json` and `apps.json`, with format selection and conversion for supported public JSON fields.
- Validate entries, probe links and apply supported URL/screenshot fixes.
- Generate and export **OTA manifests, installation links and QR codes**.

> OTA export does not upload your files or configure hosting. Installation requires a reachable HTTPS host and a correctly signed IPA. Repository conversion supports a common public JSON subset, not every provider-specific field.

</details>

### ⬇️ Downloads & file transfer
<details>
<summary><strong>⬇️ Downloads & file transfer</strong></summary>


- **Background downloads** with progress, speed tracking, pause/resume/stop controls, Live Activities and Dynamic Island support where available. Download controls are not a promise of resumable IPA extraction.
- **Wi-Fi-only and charging-only download conditions**.
- **HTTPS/WebDAV file transfer** through the built-in web manager.
- **SHA-256 hashing** in download logs and file verification against a supplied hash.
- **Game Mode** to pause downloads and background work.

</details>

### 🔐 Certificates & security
<details>
<summary><strong>🔐 Certificates & security</strong></summary>


- Import and manage signing certificates and provisioning profiles.
- **Certificate status monitoring**, batch checks and expiry reminders.
- **Certificate Dashboard** with profile payloads, entitlements, team information, expiry countdowns and device/bundle scope.
- **Local trust / OCSP checks**, status indicators and opt-in best-effort daily checks and alerts.
- **Local HTTPS trust setup** using a device-generated TLS identity; no shared certificate pack is downloaded by the normal build.
- **P12 password recovery tools** for your own password-protected certificates.
- **Face ID / passcode app lock** when the app leaves the foreground.
- **Keychain-backed secret storage and migration** for supported passwords and API credentials.
- **Profile compatibility, nested-bundle coverage and output verification** to surface identity/extension mismatches and invalid signed outputs.
- **Signed source metadata verification** for supported publisher signatures; a verified publisher is not proof that an IPA is safe.
- **Authenticated Web Manager** with explicit network access, API-token controls and separate certificate-export permission.
- **Anti-Revoke DNS profile tools** for verification-host filtering; these do not guarantee protection from certificate revocation.

</details>

### ⚡ Automation, cleanup & backup
<details>
<summary><strong>⚡ Automation, cleanup & backup</strong></summary>


- **Scheduled automation** with hourly-to-daily best-effort frequency, update-check/sign policy, per-app and per-source auto-update controls, Wi-Fi-only enforcement, certificate selection, optional install-queueing and completion summaries. iOS controls actual background execution times.
- **Siri & Shortcuts**: App Intents for signing a chosen app, installation, repository refresh, certificate checks, URL downloads, section navigation, Game Mode, Update All, cleanup and signing the latest download; library-summary actions expose status to automations. See **Settings → Siri & Shortcuts**.
- **Widgets**: certificate/update status **and a configurable Repository Apps widget** (pick a repository, sort by name or updates-first, tap a row to open that app), plus **Live Activities** for supported signing/download workflows.
- **Automatic post-install cleanup**, delete-after-install/cache settings, cleanup history, storage breakdown and cleanup previews. Batch-install behaviour still needs device acceptance.
- **Encrypted `.vexbackup` backup and restore**.
- **Local analytics** with daily, weekly and monthly charts for recorded signing/install activity, certificate/source events and storage gauges.
- **Console and signing logs** for troubleshooting, plus diagnostic ZIP export with secret-redaction filters. Review diagnostics before sharing.

</details>

### 📺 Companion platforms
<details>
<summary><strong>📺 Companion platforms</strong></summary>


Apple TV, Apple Vision Pro and Apple Watch apps mirror what the phone is doing.
They cannot sign or install — no certificate, no IPA storage, no `installd` — so
they show certificate health, library and update state instead, and the watch can
trigger a refresh, a certificate check, Update All or a cleanup on the phone.

- **Apple TV** (tvOS 17+): focus-first status screen over the Web Manager API.
- **Apple Vision Pro** (visionOS 2+): spatial glass panels, same data.
- **Apple Watch** (watchOS 10+): certificate countdown, counts, four remote
  commands over WatchConnectivity, plus a complication widget.

See [companion platforms](Documentation/Engineering/PLATFORMS.md) for pairing, build commands and the
limits.

</details>

### 🌐 Web tools
<details>
<summary><strong>🌐 Web tools</strong></summary>


Served by the backend under `/tools`, and linked from **Settings → Ecosystem →
Web Tools**:

- **Signer Console** — queue IPAs in a browser and get signed ones back; the
  page relays to the phone's Web Manager, so signing still happens on-device.
- **Repository Creator** — build, validate and export a source feed plus OTA
  manifests in the browser.
- **Repository Decoder** — read any feed (AltStore, SideStore, flat schema,
  `apps.json`, legacy appdata XML), see what it contains, export it in another
  dialect.
- **App Installer** — turn a hosted IPA into an `itms-services://` link and
  probe the URL so a spinner that never resolves is caught here instead.
- **Certificate Status Checker** — expiry, team, entitlements and device scope
  from a provisioning profile; never accepts a `.p12` or a password.
- **UDID Grabber** — one-time enrolment profile, in-memory session, no storage.

See [web tools](Documentation/Engineering/WEBTOOLS.md) for endpoints and the privacy stance.

</details>

### 🎨 A native workspace
<details>
<summary><strong>🎨 A native workspace</strong></summary>


- SwiftUI navigation, search, material surfaces and availability-gated Liquid Glass styling.
- System, Midnight Violet, Graphite, Paper, OLED, Luna and Flare appearances, tint and app-icon settings.
- Dynamic Type, VoiceOver and Reduce Motion support; setup health and searchable settings.
- Configurable launch tab, tab visibility/order (Home and Settings remain available), and an icon-only tab bar option.
- Ecosystem tools grouped in a dedicated settings entry point.

<details>
<summary><strong>Developer components & implementation status</strong></summary>

This repository also contains optional services and experimental tooling beyond the everyday signing workflow:

- **Native account provisioning:** experimental Apple-account authentication/provisioning and anisette-provider configuration; not a complete, device-validated Apple ID signer.
- **Guest-host packaging:** a separately built LiveContainer/SideStore prototype with pinned inputs; not the normal VexSign IPA. See [current scope](Integrations/EmbeddedContainer/README.md).

- **Python backend:** premium key validation, device binding, recovery, gated feeds, admin key management and IPA catalog endpoints. See [`Services/API/server/`](Services/API/server/).
- **Native cloud bridge:** endpoint/token configuration and connection testing, with client methods for remote signing jobs. Requires a compatible deployed backend.
- **Cloud-signing infrastructure:** a separate TypeScript/Fastify API with JWT authorization, PostgreSQL, Redis/BullMQ queues, private S3 storage, worker contracts, webhook retries and OTA endpoints. See [`Services/CloudSigning/cloud-signing/`](Services/CloudSigning/cloud-signing/).
- **OTA server pages:** manifest/download endpoints, installation links and QR codes, with optional app images, screenshots and changelogs.
- **Tests and CI:** iOS test sources, backend tests and cloud-service tests alongside build/deployment tooling.

**Cloud signing is not a turnkey feature:** no signing engine/sandbox launcher is bundled. The native client bridge and settings do not by themselves provide a deployed signing service. It requires infrastructure, a signer integration and end-to-end validation. Discovery rankings are local, not global popularity statistics; background schedules are controlled by iOS.

For detailed feature boundaries, security caveats and remaining device/release testing, read the [architecture](Documentation/Architecture/ARCHITECTURE.md), [native-signing status](Documentation/Architecture/NATIVE_SIGNING_ARCHITECTURE.md) and [device acceptance guide](Documentation/QA/DEVICE_TESTING.md).

</details>

For upstream changes and porting considerations, see the
[upstream integration assessment](Documentation/Research/public-signer-integration-assessment.md).

</details>

## Download

Download an IPA or add the VexSign source to a compatible signer:

[![Download IPA](Documentation/Design/assets/download-ipa.svg)](https://github.com/raynmahbub/VexSign/releases/latest)
[![Add Source](Documentation/Design/assets/add-source.svg)](https://celloserenity.github.io/altdirect/?url=https%3A%2F%2Fraw.githubusercontent.com%2Fraynmahbub%2FVexSign%2Fmain%2Fapp-repo.json)

- **Stable:** the download button opens the latest stable release; choose its IPA asset.
- **Nightly:** browse [all releases](https://github.com/raynmahbub/VexSign/releases) for dated pre-releases.
- **Temporary CI build:** open [CI runs](https://github.com/raynmahbub/VexSign/actions/workflows/ci.yml),
  select a completed full run and download its **`VexSign-unsigned-…`** artifact.
  GitHub sign-in may be required to download artifacts. The artifact contains the
  Debug IPA, commit/version metadata and SHA-256 checksums, expires
  after **14 days**, and is not a public release. Check the build **and** test
  jobs; an available artifact alone does not mean all tests passed. Quick-only or
  failed-build runs do not produce an IPA. Older runs may have no IPA or a shorter retention period; the 14-day setting applies to new uploads.

The **Add Source** button uses a third-party link helper. If it cannot open your
signer, paste the source URL below manually.

#### Add the VexSign source directly

Already using a compatible signer? Open one of these links to add the stable VexSign feed:

- [Add to VexSign](vexsign://source/https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json)
- [Add to AltStore](altstore://source?url=https%3A%2F%2Fraw.githubusercontent.com%2Fraynmahbub%2FVexSign%2Fmain%2Fapp-repo.json)
- [Add to SideStore](sidestore://source?url=https%3A%2F%2Fraw.githubusercontent.com%2Fraynmahbub%2FVexSign%2Fmain%2Fapp-repo.json)

If a link does not open your app, copy the stable source URL shown below and add it manually.

### Start signing

Download an **unsigned IPA** from [Releases](https://github.com/raynmahbub/VexSign/releases)
and sign it with an existing sideloading tool/identity. Existing VexSign users can
sign an update in-app. Stable source URL:

```text
https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json
```

Read [Free Apple ID setup](Documentation/Security/FREE_APPLE_ID_SETUP.md),
[installation/companion limits](Documentation/Distribution/COMPANION_SIGNING.md) and
[Web Manager setup](Documentation/Engineering/WEBTOOLS.md) before enabling those flows.

## Build & test

Use macOS and an Xcode with the SDK required by the current branch (the app uses
iOS 26 SDK APIs). `make bootstrap` validates your environment and resolves packages.

```bash
git clone https://github.com/raynmahbub/VexSign.git
cd VexSign
make bootstrap
open VexSign.xcworkspace   # VexSign scheme; choose your development team
make                      # unsigned packages/VexSign-<version>.ipa
make verify               # portable checks; no Xcode required
make test                 # iPhone simulator tests (macOS/Xcode)
make help                 # all supported entry points
```

See [Build](Documentation/Engineering/BUILD.md) for toolchain selection and troubleshooting.

## Quality & releases

- **CI:** relevant PRs/main changes get portable policy checks, an unsigned build
  and simulator tests. Component workflows validate their own paths separately.
- **Stable:** reviewed version bump, matching `v<MARKETING_VERSION>` tag or manual
  Release run, validation/build/tests, protected publishing and a stable-source update PR.
- **Nightly:** daily **03:00 UTC**, immutable dated pre-release, build/tests and
  checksums; never promoted into the stable source listing.
- **Autopilot:** grouped dependency PRs, every-4-hours validation/merging of narrow green
  bot updates, weekly localisation maintenance and failure triage. Reviewed version
  bumps can trigger stable releases automatically; risky changes stay manual.
  See [operations, one-time setup and free-only limits](Documentation/Engineering/MAINTENANCE.md).

[Release/version rules](Documentation/Releases/RELEASING.md) · [Automation policy](Documentation/Engineering/MAINTENANCE.md)

## Trust, contribution & VexSign ownership

Local signing keeps signing work on-device; optional remote flows have different
trust boundaries. Archives are validated before extraction, and the local install
server uses a device-specific TLS identity. Report vulnerabilities privately as
explained in [SECURITY.md](SECURITY.md); do not put credentials in issues.
See the [threat model](Documentation/Security/THREAT_MODEL.md) for data-flow and trust-boundary
notes, including optional network features.

[Contributing](CONTRIBUTING.md) · [Code of conduct](CODE_OF_CONDUCT.md) ·
[Changelog](CHANGELOG.md) · [GPL-3.0 license](LICENSE) ·
[Third-party notices](THIRD_PARTY_NOTICES.md)

VexSign is an independent first-party workspace: its app container, signing and
installation pipeline, task center, storage and presentation layers are maintained under the
VexSign name. Third-party components are identified only where their licences and notices
require it; see [third-party notices](THIRD_PARTY_NOTICES.md),
[vendored-component licences](Packages/Vendor/README.md) and the
[ElleKit licence](LICENSE_ELLEKIT). Not affiliated with Apple.
