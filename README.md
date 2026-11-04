<div align="center">

<img src="icon.png" alt="VexSign app icon" width="140">

# VexSign

### Your apps. Your tweaks. Your device.

Sign, customize and install IPAs on your iPhone or iPad.<br>
A native signing workspace built with SwiftUI, powered by open source.

[![Release](https://img.shields.io/github/v/release/raynmahbub/VexSign?style=for-the-badge&color=c96fad)](https://github.com/raynmahbub/VexSign/releases)
[![Downloads](https://img.shields.io/github/downloads/raynmahbub/VexSign/total?style=for-the-badge&color=6366f1)](https://github.com/raynmahbub/VexSign/releases)
![iOS](https://img.shields.io/badge/iOS-16%2B-18181b?style=for-the-badge&logo=apple&logoColor=white)
![tvOS](https://img.shields.io/badge/tvOS-17%2B-0f0f14?style=for-the-badge&logo=appletv&logoColor=white)
![visionOS](https://img.shields.io/badge/visionOS-2%2B-1e1b4b?style=for-the-badge&logo=applevisionpro&logoColor=white)
![watchOS](https://img.shields.io/badge/watchOS-10%2B-111827?style=for-the-badge&logo=applewatch&logoColor=white)
[![License](https://img.shields.io/badge/License-GPL--3.0-22c55e?style=for-the-badge)](LICENSE)

**[Download IPA](https://github.com/raynmahbub/VexSign/releases) · [Add source](#install) · [Explore features](#features) · [Build it yourself](#build)**

<sub>Built on <a href="https://github.com/claration/Feather">Feather</a> · No jailbreak required · iPhone & iPad</sub>

</div>

---

## At a glance

**SIGN** with your certificate → **CUSTOMIZE** apps and tweaks → **INSTALL** on device → **MANAGE** updates, sources and backups.

VexSign brings signing, IPA editing, repository discovery and device utilities into one native app. Use `.p12` certificates and `.mobileprovision` profiles with Zsign, organize your library, and automate repeat tasks without a desktop in the everyday signing workflow.

> **Requirements:** iOS 16 or later, a valid signing certificate and a compatible provisioning profile. Installation and entitlement support depend on your device and signing setup. Newer system UI and Live Activity features require supported iOS versions and hardware.

<a id="features"></a>
## ✨ Features

### 🔐 Free Apple ID Signing (3 apps / 7 days)

Sign apps **without a paid Apple Developer Program** membership:

- **Full Apple ID flow**: Apple ID + password → 2FA → Team selection
- **5-step provisioning wizard**: Select App → Select Device → Review → Provision → Complete
- **3-app limit** with live counter in settings
- **Anisette Provider** configuration with endpoint testing
- **Certificate Status** checking (OCSP/CRL) with explicit consent
- **Auto-renewal** via BackgroundAutomation (daily check for expiring profiles)
- **TrollStore integration** for permanent installation on iOS 14.0–16.6.1

### 💎 Paid Certificate Signing (unlimited)

Traditional signing with your own `.p12` / `.mobileprovision`:

- Import and manage multiple certificates and profiles
- Certificate Dashboard with expiry countdowns, entitlements, team info
- System-trust inspection and opt-in revocation checks
- Local CA profile export for HTTPS trust configuration

### 🎨 A polished native workspace

- **Vex Glass design**: opaque content surfaces with restrained accents; Liquid Glass on supported navigation
- **Consistent themes**: System, Midnight Violet, Graphite, Paper, OLED
- **Actionable Home**: Import IPA / Sign shortcuts, certificate health, active tasks, relevant updates
- **Appearance controls**: live preview, custom accent colors, theme-accent reset, app-icon preferences
- **Accessible layout**: Dynamic Type, monospaced technical text, adaptive action groups, Reduce Motion
- **Organized Settings**: Setup Health, signing, sources, automation, appearance, security, storage, companions
- **Five organized tabs**: Library, Home, App Store, Activity, Settings

### 📚 Library & app management

- **Compact list + icon grid** views with filters (All / Imported / Signed / Needs Attention)
- **Evidence-based status**: stored copies, signed copies, device installation are separate facts
- **App details**: installation evidence, bundle-signature expiry, certificate identity, latest signing task
- **Bulk actions**: sign/install, export, confirmed deletion with adaptive selection bar
- **Duplicate-import review**: Keep Both or Use Existing for matching bundle ID + version
- **Privacy controls**: hidden/locked app handling, authenticated detail entry

### ✍️ Signing & installation

- **On-device IPA signing** powered by Zsign
- **Batch signing and install queues** with per-app settings
- **Reusable signing profiles** and named presets
- **Ready to Sign review**: effective bundle ID, certificate, extension removal, injection count, preflight issues
- **Signing options & entitlement management**: Prepare → Customize → Sign → Verify stage reporting
- **Recoverable signing flow**: stop/cancel, redacted error selection, optional logs, manual result actions
- **Local HTTPS** (`itms-services://`) + paired AFC/`installd` installation
- **Installation-method preflight**: HTTPS, idevice, export, TrollStore
- **Signing Live Activities** for progress tracking
- **Auto-sign workflows** and **Update All** for source updates

### 🧩 Customization & IPA tools

- **Tweak injection**: `.dylib`, `.deb`, `.framework`, `.bundle`, `.appex` with ElleKit support
- **Tweak management**: dependency-aware ElleKit injection, legacy Substrate replacement
- **Mach-O thinning** to remove non-target architectures
- **IPA Explorer** for browsing and editing `Info.plist`, files, images
- **Clone Wizard**: create 1–20 numbered clones, rewriting identifiers and display names
- **Clone icon badges** when writable PNG icon is available
- **File manager**, document browsing, QuickLook, compression settings

### 📚 Sources, discovery & updates

- **AltStore-compatible repositories** via AltSourceKit (including encrypted ESign parsing)
- **Source management**: refresh, update tracking, health dashboard
- **Signed repository feeds**: optional Ed25519 signatures with verification badges
- **HTTPS-only transport** with opt-in for local HTTP
- **Discovery**: multi-term search, suggestions, favorites, categories, collections
- **Featured, trending, recently updated** views with app cards
- **Bundle-ID grouping** and multi-source version selection
- **Offline repository catalog** — last successful snapshot kept on disk
- **Conditional sync** using ETag/Last-Modified, coalesced refreshes
- **Per-app update rules**: ignore version/source, pin certificate, disable auto-updates

### 🛠️ Repository Builder & sharing

Available from **Settings → Ecosystem**:

- Create, edit, save, delete repository projects
- Import/export `source.json` and `apps.json` with format conversion
- Validate entries, probe links, apply URL/screenshot fixes
- Generate OTA manifests, installation links, QR codes

### ⬇️ Downloads & file transfer

- **Background downloads** with progress, speed, Live Activities, Dynamic Island
- **Wi-Fi-only / charging-only** conditions
- **HTTP & WebDAV** file transfer via built-in web manager
- **SHA-256 hashing** in logs, pre-import integrity checks
- **Safer IPA imports**: containment checks, isolated staging, step-specific errors
- **Task Center**: active work + persistent history, filter/search/sort, failure-stage guidance
- **Game Mode** to pause downloads and background work

### 🔐 Certificates & security

- Import/manage signing certificates and provisioning profiles
- **Certificate status monitoring**, batch checks, expiry reminders
- **Certificate Dashboard**: profile payloads, entitlements, team info, expiry countdowns
- **System-trust inspection**, opt-in best-effort checks and alerts
- **Bounded input reads** reject oversized files before parsing
- **Local CA profile export** from bundled certificate chain
- **P12 password recovery** tools
- **Face ID / passcode** app lock on background
- **Keychain-backed secret storage** and migration
- **Anti-Revoke DNS** profile tools with configurable HTTPS rule endpoint

### ⚡ Automation, cleanup & backup

- **Scheduled automation** for updates, cleanup, summaries (iOS background limits apply)
- **Automation preview & history**: inspect pending candidates, review policy, edit per-app rules
- **Siri & Shortcuts**: 11 App Intents (sign, install, refresh, check certs, download, open section, Game Mode, update all, clean, sign latest, pending-update count)
- **Widgets**: certificate/update status + configurable Repository Apps widget + Live Activities
- **Automatic post-install cleanup**, cleanup history, storage management
- **Encrypted `.vexbackup`** backup and restore
- **Local analytics** with daily/weekly/monthly charts
- **Console & signing logs** for troubleshooting, diagnostic ZIP export with secret redaction

### 🤝 SideStore & LiveContainer

Single **Settings → Companion Apps & Devices → SideStore & LiveContainer** destination:

- **SideStore**: Apple-account login, 2FA, provisioning, renewal inside SideStore. VexSign hands off validated HTTPS IPA URL.
- **LiveContainer**: prepare Library IPA or local IPA, system sharing/Files for guest import.
- **Guided diagnostics**: distinguish URL handlers, accepted requests, results checked in companion app.
- **Local handoff checks**: staged file prep, cancellable copying, SHA-256 fingerprints, optional expected-hash comparison.
- **No shared credentials or silent sync**: accounts, libraries, completion state remain separate.

### 📺 Companion platforms

Apple TV, Apple Vision Pro, Apple Watch apps mirror phone state (no cert, no IPA storage, no `installd`):

- **Apple TV** (tvOS 17+): focus-first status screen over Web Manager API
- **Apple Vision Pro** (visionOS 2+): spatial glass panels, same data
- **Apple Watch** (watchOS 10+): certificate countdown, counts, 4 remote commands via WatchConnectivity, complication widget

### 🌐 Web tools

Served by backend under `/tools`, linked from **Settings → Ecosystem → Web Tools**:

- **Signer Console** — queue IPAs in browser, get signed ones back (relays to phone's Web Manager)
- **Repository Creator** — build, validate, export source feed + OTA manifests
- **Repository Decoder** — read any feed (AltStore, SideStore, flat schema, `apps.json`, legacy XML), export in another dialect
- **App Installer** — turn hosted IPA into `itms-services://` link, probe URL
- **Certificate Status Checker** — expiry, team, entitlements, device scope from `.mobileprovision`
- **UDID Grabber** — one-time enrolment profile, in-memory session, no storage

---

<a id="install"></a>
## 📦 Download

Visit [releases](https://github.com/raynmahbub/VexSign/releases) and get the latest `.ipa`.

<a href="https://celloserenity.github.io/altdirect/?url=https://raw.githubusercontent.com/raynmahbub/VexSign/refs/heads/main/app-repo.json" target="_blank">
   <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" alt="Add AltSource" width="200">
</a>
<a href="https://github.com/raynmahbub/VexSign/releases/latest/download/VexSign.ipa" target="_blank">
   <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/Download_Blue.png?raw=true" alt="Download .ipa" width="200">
</a>

Prefer manual source? Paste into any AltStore-compatible signer (SideStore, ESign, Scarlet, Feather):

```text
https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json
```

### Start signing (Paid Certificate)

1. Import your `.p12` certificate and `.mobileprovision` profile
2. Import an IPA or download an app from a trusted source
3. Choose signing options and tweaks, review preflight summary, then sign
4. Install, share the IPA or view result in Library; check installation separately

### Start signing (Free Apple ID)

1. **Deploy Anisette Provider** (HTTPS endpoint returning 10 Apple headers as JSON)
   ```bash
   cd AnisetteServer && swift build -c release && ./.build/release/AnisetteServer
   ```
2. **Configure in VexSign**: Settings → Signing Methods → Free Apple ID → Anisette Provider
3. **Sign in**: Enter Apple ID + password → Complete 2FA → Select Team (Free)
4. **Provision**: Settings → Signing Methods → Free Apple ID → Provision App
   - 5-step wizard: Select App → Select Device → Review → Provision → Complete
5. **Install**: Signed app appears in Library → Install via HTTPS or TrollStore
6. **Auto-renewal**: Enable BackgroundAutomation (Settings → Automation) for daily profile renewal

---

<a id="build"></a>
## 🧑‍💻 Build from source

Use macOS with **Xcode 26 or later** and the iOS SDK. The app targets iOS 16+ using runtime availability checks for newer UI.

```bash
git clone --recursive https://github.com/raynmahbub/VexSign.git
cd VexSign
open VexSign.xcworkspace
```

The local install server creates its own device-specific identity on first use, without fetching a certificate pack or shipping shared private keys. Export and trust its Root CA profile under **Settings → Installation → Server & SSL**, then turn on Full Trust in system Settings. The CA persists in the device-only Keychain across app updates; routine server-certificate renewal keeps that CA unchanged. Users migrating from an older shared identity must trust the new CA once.

> **Release:** run the Release workflow to publish; check `build_only` for testing.
> No TLS endpoint or pin setup is required. See the [release guide](docs/RELEASING.md) for environment protections and device-testing requirements. Semi Local still uses a remote manifest service.

Select the VexSign scheme and configure your development team in Xcode. To create the unsigned IPA using the repository's build recipe:

```bash
make
```

The packaged IPA is written to `packages/VexSign.ipa` and requires signing before installation.

> Clone with `--recursive`: Zsign and IDeviceKitten are Git submodules. For an existing clone, run `git submodule update --init --recursive`.

### Verify and test

```bash
make verify                # Toolchain-free gates (localisation, error discipline, singleton freeze, concurrency)
make test                  # Unit tests on automatically selected iPhone simulator (macOS/Xcode)
make strict-concurrency    # Package concurrency diagnostics (Swift toolchain)
```

`make verify` runs gates corresponding to CI's quick job (without Swift syntax parsing): repository checks, localisation coverage, error discipline, singleton freeze, concurrency discipline, workflow-trigger policy. For simulator selection, device-only checks and release validation, follow the [test plan](docs/TEST_PLAN.md) and [release guide](docs/RELEASING.md). CI configuration is not a substitute for a completed device test pass.

### Project guide

| Path | Description |
|------|-------------|
| [`VexSign/`](VexSign/) | SwiftUI app, signing workflows, ecosystem tools |
| [`AltSourceKit/`](AltSourceKit/) · [`NimbleKit/`](NimbleKit/) | Repository parsing, shared utilities |
| [`VexSignWidgetExtension/`](VexSignWidgetExtension/) | Widgets, Live Activity UI |
| [`VexSignTV/`](VexSignTV/) · [`VexSignVision/`](VexSignVision/) · [`VexSignWatch/`](VexSignWatch/) | Companion apps |
| [`server/`](server/) | Python premium & repository backend |
| [`cloud-signing/`](cloud-signing/) | Cloud orchestration services (TypeScript/Fastify) |
| [`NativeSigning/`](NativeSigning/) | Native Free Apple ID signing module |
| [`AnisetteServer/`](AnisetteServer/) | Reference Anisette provider implementation |
| [`docs/FREE_APPLE_ID_SETUP.md`](docs/FREE_APPLE_ID_SETUP.md) | Complete Free Apple ID setup guide |
| [`docs/PLATFORMS.md`](docs/PLATFORMS.md) | Apple TV / visionOS / watchOS companions |
| [`docs/WEBTOOLS.md`](docs/WEBTOOLS.md) | Browser tools and endpoints |
| [`docs/COMPANION_SIGNING.md`](docs/COMPANION_SIGNING.md) | SideStore/LiveContainer handoff guide |
| [`docs/NATIVE_SIGNING_ARCHITECTURE.md`](docs/NATIVE_SIGNING_ARCHITECTURE.md) | Native signing architecture |
| [`CHANGELOG.md`](CHANGELOG.md) | Release changes and known limitations |
| [`docs/FEATURE_STATUS.md`](docs/FEATURE_STATUS.md) | Feature pipelines and device-validation boundaries |
| [`docs/UI_POLISH.md`](docs/UI_POLISH.md) | Workspace design, accessibility, implementation checklist |
| [`docs/BUILD_READINESS.md`](docs/BUILD_READINESS.md) | Build audit, recorded checks, remaining device gates |
| [`docs/TEST_PLAN.md`](docs/TEST_PLAN.md) | Verification gates, simulator tests, physical-device checks |
| [`docs/ECOSYSTEM.md`](docs/ECOSYSTEM.md) | Implementation scope and release considerations |
| [`docs/AUTOMATION.md`](docs/AUTOMATION.md) | Automation policy and required-check migration |
| [`docs/RELEASING.md`](docs/RELEASING.md) | How releases are cut (tag push) and test without publishing |

Want to contribute? Read [Contributing](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md), or [open an issue](https://github.com/raynmahbub/VexSign/issues).

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

[Releases](https://github.com/raynmahbub/VexSign/releases) · [Issues](https://github.com/raynmahbub/VexSign/issues) · [Contribute](CONTRIBUTING.md)

<sub>VexSign is not affiliated with Apple Inc. Sideloading may conflict with Apple Developer Program terms; use at your own risk.</sub>

</div>

### Experimental guest-host prototype

A separate upstream-derived host build now includes the real LiveContainer runtime, SideStore support/framework conversion and a bundled VexSign guest. It is not an external-app URL launcher. Native archive/device validation is still pending; it keeps the official host bundle identity and therefore conflicts with stock LiveContainer. The normal VexSign IPA/release path remains separate. See [build instructions, limits and source obligations](EmbeddedContainer/README.md). This prototype is not the final one-app architecture. The implementation target is [VexSign as the primary host with native account and certificate services](docs/NATIVE_SIGNING_ARCHITECTURE.md).