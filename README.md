<div align="center">

<img src="icon.png" alt="VexSign app icon" width="140">

# VexSign

### Your apps. Your tweaks. Your device.

Sign, customize and install IPAs on your iPhone or iPad.<br>
An on-device signing toolkit built with SwiftUI, powered by open source.

[![Release](https://img.shields.io/github/v/release/iamsmmh/VexSign?style=for-the-badge&color=c96fad)](https://github.com/iamsmmh/VexSign/releases)
[![Downloads](https://img.shields.io/github/downloads/iamsmmh/VexSign/total?style=for-the-badge&color=6366f1)](https://github.com/iamsmmh/VexSign/releases)
![iOS](https://img.shields.io/badge/iOS-16%2B-18181b?style=for-the-badge&logo=apple&logoColor=white)
![tvOS](https://img.shields.io/badge/tvOS-17%2B-0f0f14?style=for-the-badge&logo=appletv&logoColor=white)
![visionOS](https://img.shields.io/badge/visionOS-2%2B-1e1b4b?style=for-the-badge&logo=applevisionpro&logoColor=white)
![watchOS](https://img.shields.io/badge/watchOS-10%2B-111827?style=for-the-badge&logo=applewatch&logoColor=white)
[![License](https://img.shields.io/badge/License-GPL--3.0-22c55e?style=for-the-badge)](LICENSE)

**[Download IPA](https://github.com/iamsmmh/VexSign/releases) · [Add source](#install) · [Explore features](#features) · [Build it yourself](#build)**

<sub>Built on <a href="https://github.com/claration/Feather">Feather</a> · No jailbreak required · iPhone & iPad</sub>

</div>

---

## At a glance

**SIGN** with your certificate → **CUSTOMIZE** apps and tweaks → **INSTALL** on device → **MANAGE** updates, sources and backups.

VexSign brings signing, IPA editing, repository discovery and device utilities into one native app. Use `.p12` certificates and `.mobileprovision` profiles with Zsign, organize your library, and automate repeat tasks without a desktop in the everyday signing workflow.

> **Requirements:** iOS 16 or later, a valid signing certificate and a compatible provisioning profile. Installation and entitlement support depend on your device and signing setup. Newer system UI and Live Activity features require supported iOS versions and hardware.

<a id="features"></a>
## ✨ Explore the toolkit

### ✍️ Signing & installation

- **On-device IPA signing** powered by Zsign.
- **Batch signing and install queues** for processing multiple apps with per-app settings.
- **Reusable signing profiles** and named presets for repeat workflows.
- **Signing options and entitlement management**, with preflight checks and signing logs.
- **Local HTTPS installation** using `itms-services://`, plus paired installation through the AFC / `installd` backend.
- **Signing Live Activities** to follow progress on supported devices.
- **Auto-sign workflows** and **Update All** for re-signing source updates.

### 🧩 Customization & IPA tools

- **Tweak injection** for `.dylib`, `.deb`, `.framework`, `.bundle` and `.appex` inputs, with ElleKit support.
- **Tweak management** to organize injection components, with dependency-aware ElleKit injection and legacy Substrate replacement.
- **Mach-O thinning** to remove non-target architectures from supported universal binaries.
- **Document picker fixes**, keychain isolation and optional JIT entitlement settings. Entitlements alone do not guarantee JIT availability on a device.
- **IPA Explorer** for browsing app contents and editing `Info.plist`, files and images.
- **Clone Wizard** to create 1–20 numbered clones from a library app, rewriting identifiers and display names.
- **Clone icon badges** when a writable PNG icon is available; cloned apps still need compatible signing options and profiles.
- **File manager**, document browsing, QuickLook previews and file/compression settings.

### 📚 Sources, discovery & updates

- **AltStore-compatible repositories** through AltSourceKit, including the existing encrypted ESign parsing support.
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
- **App self-update checking** and controls for skipped source updates.

### 🛠️ Repository Builder & sharing

Available from **Settings → Ecosystem**.

- Create, edit, save and delete repository projects.
- Import repository JSON from files or HTTPS URLs.
- Export `source.json` and `apps.json`, with format selection and conversion for supported public JSON fields.
- Validate entries, probe links and apply supported URL/screenshot fixes.
- Generate and export **OTA manifests, installation links and QR codes**.

> OTA export does not upload your files or configure hosting. Installation requires a reachable HTTPS host and a correctly signed IPA. Repository conversion supports a common public JSON subset, not every provider-specific field.

### ⬇️ Downloads & file transfer

- **Background downloads** with progress, speed tracking, Live Activities and Dynamic Island support.
- **Wi-Fi-only and charging-only download conditions**.
- **HTTP and WebDAV file transfer** through the built-in web manager.
- **SHA-256 hashing** in download logs and file verification against a supplied hash.
- **Game Mode** to pause downloads and background work.

### 🔐 Certificates & security

- Import and manage signing certificates and provisioning profiles.
- **Certificate status monitoring**, batch checks and expiry reminders.
- **Certificate Dashboard** with profile payloads, entitlements, team information, expiry countdowns and device/bundle scope.
- **Local trust / OCSP checks**, status indicators and opt-in best-effort daily checks and alerts.
- **Local CA profile export** from the bundled certificate chain for configuring local HTTPS trust.
- **P12 password recovery tools** for your own password-protected certificates.
- **Face ID / passcode app lock** when the app leaves the foreground.
- **Keychain-backed secret storage and migration** for supported passwords and API credentials.
- **Anti-Revoke DNS profile tools** for verification-host filtering; these do not guarantee protection from certificate revocation.

### ⚡ Automation, cleanup & backup

- **Scheduled automation** for updates, cleanup and summaries, subject to iOS background execution limits.
- **Siri & Shortcuts**: eleven App Intents — sign a chosen app, install it, refresh one or all repositories, check certificates, download from a URL, open any section, set Game Mode, update all, clean now, sign the latest download and a pending-update count automations can branch on. See **Settings → Siri & Shortcuts**.
- **Widgets**: certificate/update status **and a configurable Repository Apps widget** (pick a repository, sort by name or updates-first, tap a row to open that app), plus **Live Activities** for supported signing/download workflows.
- **Automatic post-install cleanup**, cleanup history and storage management.
- **Encrypted `.vexbackup` backup and restore**.
- **Local analytics** with daily, weekly and monthly charts for recorded signing/install activity, certificate/source events and storage gauges.
- **Console and signing logs** for troubleshooting, plus diagnostic ZIP export with secret-redaction filters. Review diagnostics before sharing.

### 📺 Companion platforms

Apple TV, Apple Vision Pro and Apple Watch apps mirror what the phone is doing.
They cannot sign or install — no certificate, no IPA storage, no `installd` — so
they show certificate health, library and update state instead, and the watch can
trigger a refresh, a certificate check, Update All or a cleanup on the phone.

- **Apple TV** (tvOS 17+): focus-first status screen over the Web Manager API.
- **Apple Vision Pro** (visionOS 2+): spatial glass panels, same data.
- **Apple Watch** (watchOS 10+): certificate countdown, counts, four remote
  commands over WatchConnectivity, plus a complication widget.

See [companion platforms](docs/PLATFORMS.md) for pairing, build commands and the
limits.

### 🌐 Web tools

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

See [web tools](docs/WEBTOOLS.md) for endpoints and the privacy stance.

### 🎨 A native workspace

- SwiftUI navigation, search, material surfaces and availability-gated Liquid Glass styling.
- Appearance and app-icon settings.
- Configurable tab bar and library display preferences.
- Ecosystem tools grouped in a dedicated settings entry point.

<details>
<summary><strong>Developer components & implementation status</strong></summary>

This repository also contains services and tooling beyond the iOS app:

- **Python backend:** premium key validation, device binding, recovery, gated feeds, admin key management and IPA catalog endpoints. See [`server/`](server/).
- **Native cloud bridge:** endpoint/token configuration and connection testing, with client methods for remote signing jobs. Requires a compatible deployed backend.
- **Cloud-signing infrastructure:** a separate TypeScript/Fastify API with JWT authorization, PostgreSQL, Redis/BullMQ queues, private S3 storage, worker contracts, webhook retries and OTA endpoints. See [`cloud-signing/`](cloud-signing/).
- **OTA server pages:** manifest/download endpoints, installation links and QR codes, with optional app images, screenshots and changelogs.
- **Tests and CI:** the `VexSignTests` suite runs on every PR through the **Unit tests** workflow (or locally via `make test`), alongside backend and cloud-service tests, build checks and deployment tooling.

**Cloud signing is not a turnkey feature:** no signing engine/sandbox launcher is bundled. The native client bridge and settings do not by themselves provide a deployed signing service. It requires infrastructure, a signer integration and end-to-end validation. Discovery rankings are local, not global popularity statistics; background schedules are controlled by iOS.

For detailed feature boundaries, security caveats and remaining device/release testing, read the [ecosystem implementation status](docs/ECOSYSTEM.md).

</details>

---

<a id="install"></a>
## 📦 Download

Visit [releases](https://github.com/iamsmmh/VexSign/releases) and get the latest `.ipa`.

<a href="https://celloserenity.github.io/altdirect/?url=https://raw.githubusercontent.com/iamsmmh/VexSign/refs/heads/main/app-repo.json" target="_blank">
   <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" alt="Add AltSource" width="200">
</a>
<a href="https://github.com/iamsmmh/VexSign/releases/latest/download/VexSign.ipa" target="_blank">
   <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/Download_Blue.png?raw=true" alt="Download .ipa" width="200">
</a>

Prefer to add the source manually? Paste this URL into any AltStore-compatible signer such as SideStore, ESign, Scarlet or Feather:

```text
https://raw.githubusercontent.com/iamsmmh/VexSign/main/app-repo.json
```

### Start signing

1. Import your `.p12` certificate and `.mobileprovision` profile.
2. Import an IPA or download an app from a source you trust.
3. Choose signing options and any tweaks, then sign and install.

---

<a id="build"></a>
## 🧑‍💻 Build from source

Use macOS with Xcode and the iOS SDK. The project uses Swift 6 and targets iOS 16+; choose an Xcode version that supports the SDK APIs used by your checkout.

```bash
git clone --recursive https://github.com/iamsmmh/VexSign.git
cd VexSign
make deps
open VexSign.xcworkspace
```

`make deps` needs no network: it generates a self-signed **development** identity for the
local install server (certificate, key and hostname in `deps/`) with `openssl`, and keeps that
identity on later builds so a profile you trusted once keeps working. Devices must trust its
Root CA before HTTPS installs succeed — **Settings → Installation → Server & SSL → Export Root
CA Profile**, then enable full trust in *Settings → General → About → Certificate Trust
Settings*. Release builds do not use it:

```bash
make deps-pin       # once (and after a deliberate rotation): fetch the published identity,
                    # print its digest and rewrite Scripts/local-tls/pinned-pack.sha256
make deps-release   # fetch + verify that digest before packaging; fails loudly on a mismatch
```

Select the VexSign scheme and configure your development team in Xcode. To create the unsigned IPA using the repository’s build recipe:

```bash
make
```

The packaged IPA is written to `packages/VexSign.ipa` and requires signing before installation.

> Clone with `--recursive`: Zsign and IDeviceKitten are Git submodules. For an existing clone, run `git submodule update --init --recursive`.

### Project guide

- [`VexSign/`](VexSign/) — SwiftUI app, signing workflows and ecosystem tools.
- [`AltSourceKit/`](AltSourceKit/) · [`NimbleKit/`](NimbleKit/) — repository parsing and shared utilities.
- [`VexSignWidgetExtension/`](VexSignWidgetExtension/) — widgets and Live Activity UI.
- [`VexSignTV/`](VexSignTV/) · [`VexSignVision/`](VexSignVision/) · [`VexSignWatch/`](VexSignWatch/) — companion apps, with [`VexSign/Companion/`](VexSign/Companion/) shared between them.
- [`VexSignWatchWidgets/`](VexSignWatchWidgets/) — watch complication.
- [`server/`](server/) — Python premium and repository backend.
- [`cloud-signing/`](cloud-signing/) — separate cloud orchestration services.
- [`docs/PLATFORMS.md`](docs/PLATFORMS.md) — Apple TV / visionOS / watchOS companions.
- [`docs/WEBTOOLS.md`](docs/WEBTOOLS.md) — the browser tools and their endpoints.
- [`docs/ECOSYSTEM.md`](docs/ECOSYSTEM.md) — implementation scope and release considerations.
- [`docs/AUDIT_2026-10-31.md`](docs/AUDIT_2026-10-31.md) — source-code audit: verified findings, severities and evidence.
- [`docs/REFERENCE_COMPARISON.md`](docs/REFERENCE_COMPARISON.md) — reference projects verified against source, with adoption decisions and the licence boundary.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — prioritized engineering roadmap with acceptance criteria and tests.
- [`docs/RELEASING.md`](docs/RELEASING.md) — how releases are cut (tag push) and how to test a build without publishing.

Want to contribute? Read [Contributing](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md), or [open an issue](https://github.com/iamsmmh/VexSign/issues).

---

## 💜 Acknowledgments

**Built on [Feather](https://github.com/claration/Feather) by [claration](https://github.com/claration)** — the foundation for signing, storage, UI architecture, AltSourceKit and NimbleKit (GPL-3.0).

**Signing & installation** · [Zsign](https://github.com/zhlynn/zsign) by zhlynn (MIT) · [idevice](https://github.com/jkcoxson/idevice) by jkcoxson (MIT) · [ElleKit](https://github.com/everythingappletech/ElleKit) by tealbathingsuit (BSD-3).

**Networking & media** · [Vapor](https://github.com/vapor/vapor) by the Vapor team · [Nuke](https://github.com/kean/Nuke) by kean · [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) by weichsel · [SWCompression](https://github.com/tsolomko/SWCompression) by tsolomko (MIT).

**Service acknowledgment** · [backloop.dev](https://backloop.dev/) for public-CA-signed localhost SSL certificates.

## License

**GPL-3.0**, matching the Feather base. VexSign additions © 2026; Feather © 2024 Samara / claration. See [`LICENSE`](LICENSE) and [`LICENSE_ELLEKIT`](LICENSE_ELLEKIT) for the full notices.

---

<div align="center">

**Made for people who like control over their apps.**

[Releases](https://github.com/iamsmmh/VexSign/releases) · [Issues](https://github.com/iamsmmh/VexSign/issues) · [Contribute](CONTRIBUTING.md)

<sub>VexSign is not affiliated with Apple Inc. Sideloading may conflict with Apple Developer Program terms; use at your own risk.</sub>

</div>
