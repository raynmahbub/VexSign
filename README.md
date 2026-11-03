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

### 🎨 A polished native workspace

- **Vex Glass design:** quiet, opaque content surfaces with restrained accents; native Liquid Glass is reserved for supported navigation and actions, with Reduce Transparency and Increased Contrast fallbacks.
- **Consistent themes:** System, Midnight Violet, Graphite, Paper and OLED, with existing Luna/Flare preferences preserved.
- **Actionable Home:** Import IPA and Sign an app shortcuts, certificate/setup health, active tasks, relevant updates, Needs Attention and privacy-filtered recently added apps—without empty charts or decorative counters.
- **Appearance controls:** live preview, custom accent colors, theme-accent reset, confirmed workspace reset and app-icon preferences.
- **Accessible layout:** system typography by default, Dynamic Type, monospaced technical text and counts, adaptive action groups, shared spacing and Reduce Motion support.
- **Organized Settings:** Setup Health first, followed by signing, sources, automation, appearance, security, storage, companions and advanced tools; About and support stay at the bottom. Search preserves access to existing destinations.
- **Five organized tabs:** Library (Apps + Files), Home, App Store (catalog + sources), Activity (Downloads + Tasks + Logs) and Settings. Native SwiftUI tabs provide iOS 26 Liquid Glass and an iPad sidebar. Optional standalone destinations and launch-tab preferences remain available.

### 📚 Library & app management

- **Compact list by default**, with adaptive row cards and a separate icon-grid option.
- **All · Imported · Signed · Needs Attention** filters, search, sorting, selection and manual reordering in list mode.
- **Evidence-based status:** stored/imported copies, signed copies and device installation are separate facts. Unknown installation status is not presented as failure—or success.
- **App details:** installation evidence, bundle-signature expiry, certificate identity and the latest signing task associated with that exact Library entry when available.
- **Bulk actions:** sign/install, export and confirmed deletion, with an adaptive selection bar and keyboard shortcuts.
- **Manual duplicate-import review:** Keep Both or Use Existing for accessible imported copies with matching bundle ID and version. Matching metadata does not prove identical contents; existing copies are never silently replaced.
- **Privacy controls:** hidden/locked app handling and authenticated detail entry, with hidden or currently locked app names excluded from Home recents and attention summaries.

### ✍️ Signing & installation

- **On-device IPA signing** powered by Zsign.
- **Batch signing and install queues** for processing multiple apps with per-app settings.
- **Reusable signing profiles** and named presets for repeat workflows.
- **Ready to Sign review:** effective bundle identifier, certificate, extension removal, injection count and actual preflight issues before the pipeline starts. Changed reviewed options, identity or issues require another review; overriding a blocking issue requires explicit confirmation.
- **Signing options and entitlement management**, with real **Prepare → Customize → Sign → Verify** stage reporting; installation remains a separate step, and milestone estimates are not presented as measured percentages.
- **Recoverable signing flow:** stop/cancel, selectable redacted errors, optional logs and manual-signing result actions for Install, Share IPA or View in Library. Signing success never means installation is confirmed.
- **Repeat signing from app details:** review saved settings, certificate expiry, unavailable-certificate fallback and preflight warnings before running. Source contents are not fingerprinted; other repeat-sign shortcuts retain their existing behavior.
- **Local HTTPS installation** using `itms-services://`, plus paired installation through the AFC / `installd` backend.
- **Installation-method preflight** for local HTTPS, idevice, export and TrollStore. Device-state checks distinguish confirmed installation from a handoff or completed progress; TrollStore is detected, not installed by VexSign.
- **Signing Live Activities** to follow progress on supported devices.
- **Auto-sign workflows** and **Update All** for re-signing source updates.

### 🧩 Customization & IPA tools

- **Tweak injection** for `.dylib`, `.deb`, `.framework`, `.bundle` and `.appex` inputs, with ElleKit support.
- **Tweak management** to organize injection components, with dependency-aware ElleKit injection, legacy Substrate replacement and a searchable bulk **Inject by Default** screen.
- **Mach-O thinning** to remove non-target architectures from supported universal binaries.
- **Document picker fixes**, keychain isolation and optional JIT entitlement settings. Entitlements alone do not guarantee JIT availability on a device.
- **IPA Explorer** for browsing app contents and editing `Info.plist`, files and images.
- **Clone Wizard** to create 1–20 numbered clones from a library app, rewriting identifiers and display names.
- **Clone icon badges** when a writable PNG icon is available; cloned apps still need compatible signing options and profiles.
- **File manager**, document browsing, QuickLook previews and file/compression settings.

### 📚 Sources, discovery & updates

- **AltStore-compatible repositories** through AltSourceKit, including the existing encrypted ESign parsing support.
- **Source management and preferences**, repository refresh and app update tracking.
- **Signed repository feeds:** optional Ed25519 signatures with verification badges. Invalid claimed signatures reject the refresh and retain the previous catalog; unsigned feeds remain supported. See [source signing](docs/SOURCE_SIGNING.md).
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
- **HTTP and WebDAV file transfer** through the built-in web manager, with authentication enabled by default and separate controls for sensitive certificate exports.
- **SHA-256 hashing** in download logs and pre-import integrity checks against repository-provided sizes and hashes. Mismatches require an explicit, logged Import Anyway override or Delete.
- **Safer IPA imports:** archive containment checks, isolated staging and step-specific errors for unreadable files, extraction, storage and Library registration.
- **Task Center:** active work and persistent history, filter/search/sort controls, failure-stage guidance and retry/cancel where supported. Copy Redacted Report exports task outcomes and recovery guidance while omitting app names, identifiers, URLs, paths and raw errors.
- **Game Mode** to pause downloads and background work.

### 🔐 Certificates & security

- Import and manage signing certificates and provisioning profiles.
- **Certificate status monitoring**, batch checks and expiry reminders.
- **Certificate Dashboard** with profile payloads, entitlements, team information, expiry countdowns and device/bundle scope.
- **System-trust certificate inspection**, status indicators and opt-in best-effort checks and alerts. The unsafe legacy native OCSP path is bypassed; offline or unreadable results do not count as positive revocation evidence.
- **Bounded certificate/profile input reads** to reject oversized files before parsing, plus in-place bundled-certificate refresh with file/password rollback on update errors.
- **Local CA profile export** from the bundled certificate chain for configuring local HTTPS trust.
- **P12 password recovery tools** for your own password-protected certificates.
- **Face ID / passcode app lock** when the app leaves the foreground.
- **Keychain-backed secret storage and migration** for supported passwords and API credentials.
- **Anti-Revoke DNS profile tools** for verification-host filtering, with a visible, configurable HTTPS rule endpoint and opt-in activation; these do not guarantee protection from certificate revocation.

### ⚡ Automation, cleanup & backup

- **Scheduled automation** for updates, cleanup and summaries, subject to iOS background execution limits.
- **Automation preview and history:** inspect pending candidates from the current repository snapshot, review the active policy and edit per-app rules without starting downloads, signing or installation.
- **Siri & Shortcuts**: eleven App Intents — sign a chosen app, install it, refresh one or all repositories, check certificates, download from a URL, open any section, set Game Mode, update all, clean now, sign the latest download and a pending-update count automations can branch on. See **Settings → Siri & Shortcuts**.
- **Widgets**: certificate/update status **and a configurable Repository Apps widget** (pick a repository, sort by name or updates-first, tap a row to open that app), plus **Live Activities** for supported signing/download workflows.
- **Automatic post-install cleanup**, cleanup history and storage management.
- **Encrypted `.vexbackup` backup and restore**.
- **Local analytics** with daily, weekly and monthly charts for recorded signing/install activity, certificate/source events and storage gauges.
- **Console and signing logs** for troubleshooting, plus diagnostic ZIP export with secret-redaction filters. Review diagnostics before sharing.

### 🤝 SideStore & LiveContainer

A single **Settings → Companion Apps & Devices → SideStore & LiveContainer** destination explains each app's role:

**Prepare/share in VexSign → install/manage in SideStore → import compatible guests in LiveContainer.**

- **SideStore:** Apple-account login, two-factor authentication, provisioning and renewal remain inside SideStore. VexSign can hand off a validated hosted HTTPS IPA URL using SideStore's supported install link.
- **LiveContainer:** prepare a Library IPA or choose a local IPA, then use system sharing/Files for guest import. LiveContainer decides compatibility and provides guest execution; VexSign does not embed its runtime.
- **Guided diagnostics:** distinguish detected URL handlers, accepted open requests and results that must be checked in the companion app. Detection or handoff never confirms login, renewal, import or installation.
- **Local handoff checks:** staged file preparation, cancellable file copying, SHA-256 fingerprints and optional expected-hash comparison. A matching local hash is not publisher authentication.
- **No shared credentials or silent synchronization:** accounts, libraries and completion state remain separate. See [the companion workflow guide](docs/COMPANION_SIGNING.md).

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

<details>
<summary><strong>Developer components & implementation status</strong></summary>

This repository also contains services and tooling beyond the iOS app:

- **Python backend:** premium key validation, device binding, recovery, gated feeds, admin key management and IPA catalog endpoints. See [`server/`](server/).
- **Native cloud bridge:** endpoint/token configuration and connection testing, with client methods for remote signing jobs. Requires a compatible deployed backend.
- **Cloud-signing infrastructure:** a separate TypeScript/Fastify API with JWT authorization, PostgreSQL, Redis/BullMQ queues, private S3 storage, worker contracts, webhook retries and OTA endpoints. See [`cloud-signing/`](cloud-signing/).
- **OTA server pages:** manifest/download endpoints, installation links and QR codes, with optional app images, screenshots and changelogs.
- **Tests and CI:** no automatic pull-request validation. Relevant pushes to `main` run Linux gates → unsigned iOS build → simulator `VexSignTests`. Manually dispatch **CI** on a branch with `quick` (Linux only) or `full` validation before merging; component checks are path-filtered and manually runnable too. Cloud dependencies retain a weekly audit. `make test` requires macOS/Xcode. Configured checks are not proof that a commit or device workflow has passed; see the [automation policy and required-check migration](docs/AUTOMATION.md).

**Cloud signing is not a turnkey feature:** no signing engine/sandbox launcher is bundled. The native client bridge and settings do not by themselves provide a deployed signing service. It requires infrastructure, a signer integration and end-to-end validation. Discovery rankings are local, not global popularity statistics; background schedules are controlled by iOS.

**Implementation boundaries:** the standalone OCSP request/parser/signature-verification foundation is not wired into the UI and does not yet chain responder certificates to an issuer. Source-content fingerprinting and uniform review across every repeat-sign entry point remain open. Simulator and physical-device validation are still required for hardware-dependent workflows.

For detailed scope and validation status, see [feature status](docs/FEATURE_STATUS.md), [UI implementation](docs/UI_POLISH.md), [build readiness](docs/BUILD_READINESS.md), the [test plan](docs/TEST_PLAN.md) and [ecosystem implementation status](docs/ECOSYSTEM.md). Release history belongs in the [changelog](CHANGELOG.md).

</details>

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

Prefer to add the source manually? Paste this URL into any AltStore-compatible signer such as SideStore, ESign, Scarlet or Feather:

```text
https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json
```

### Start signing

1. Import your `.p12` certificate and `.mobileprovision` profile.
2. Import an IPA or download an app from a source you trust.
3. Choose signing options and tweaks, review the preflight summary, then sign.
4. Install, share the IPA or view the result in Library; check installation separately.

---

<a id="build"></a>
## 🧑‍💻 Build from source

Use macOS with **Xcode 26 or later** and the iOS SDK. The app targets iOS 16+ using runtime availability checks for newer UI. The checkout requires a Swift 6-capable toolchain; individual targets and packages may use different Swift language modes.

```bash
git clone --recursive https://github.com/raynmahbub/VexSign.git
cd VexSign
open VexSign.xcworkspace
```

The local install server creates its own device-specific identity on first use,
without fetching a certificate pack or shipping shared private keys. Export and
trust its Root CA profile under **Settings → Installation → Server & SSL**, then
turn on Full Trust in system Settings. The CA persists in the device-only Keychain
across app updates; routine server-certificate renewal keeps that CA unchanged.
Users migrating from an older shared identity must trust the new CA once.

> **Release:** run the Release workflow to publish; check `build_only` for testing.
> No TLS endpoint or pin setup is required. See the [release guide](docs/RELEASING.md)
> for environment protections and device-testing requirements. Semi Local still
> uses a remote manifest service.

Select the VexSign scheme and configure your development team in Xcode. To create the unsigned IPA using the repository’s build recipe:

```bash
make
```

The packaged IPA is written to `packages/VexSign.ipa` and requires signing before installation.

> Clone with `--recursive`: Zsign and IDeviceKitten are Git submodules. For an existing clone, run `git submodule update --init --recursive`.

### Verify and test

```bash
make verify                # Toolchain-free repository, localization and architecture gates
make test                  # Unit tests on an automatically selected iPhone simulator (macOS/Xcode)
make strict-concurrency    # Package concurrency diagnostics (Swift toolchain)
```

`make verify` runs six gates corresponding to CI’s quick job (without Swift syntax parsing): repository checks, localization coverage, error discipline, singleton freeze, concurrency discipline and workflow-trigger policy. For simulator selection, device-only checks and release validation, follow the [test plan](docs/TEST_PLAN.md) and [release guide](docs/RELEASING.md). CI configuration is not a substitute for a completed device test pass.

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
- [`CHANGELOG.md`](CHANGELOG.md) — release changes and known limitations.
- [`docs/FEATURE_STATUS.md`](docs/FEATURE_STATUS.md) — feature pipelines and device-validation boundaries.
- [`docs/SOURCE_SIGNING.md`](docs/SOURCE_SIGNING.md) — signed feed format and publisher instructions.
- [`docs/UI_POLISH.md`](docs/UI_POLISH.md) — workspace design, accessibility and implementation checklist.
- [`docs/COMPANION_SIGNING.md`](docs/COMPANION_SIGNING.md) — SideStore/LiveContainer handoff, privacy and lifecycle boundaries.
- [`docs/BUILD_READINESS.md`](docs/BUILD_READINESS.md) — build audit, recorded checks and remaining device acceptance gates.
- [`docs/TEST_PLAN.md`](docs/TEST_PLAN.md) — verification gates, simulator tests and physical-device checks.
- [`docs/ECOSYSTEM.md`](docs/ECOSYSTEM.md) — implementation scope and release considerations.
- [`docs/AUDIT_2026-10-31.md`](docs/AUDIT_2026-10-31.md) — source-code audit: verified findings, severities and evidence.
- [`docs/REFERENCE_COMPARISON.md`](docs/REFERENCE_COMPARISON.md) — reference projects verified against source, with adoption decisions and the licence boundary.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — prioritized engineering roadmap with acceptance criteria and tests.
- [`docs/RELEASING.md`](docs/RELEASING.md) — how releases are cut (tag push) and how to test a build without publishing.

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

A separate upstream-derived host build now includes the real LiveContainer runtime,
SideStore support/framework conversion and a bundled VexSign guest. It is not an
external-app URL launcher. Native archive/device validation is still pending; it
keeps the official host bundle identity and therefore conflicts with stock
LiveContainer. The normal VexSign IPA/release path remains separate. See
[build instructions, limits and source obligations](EmbeddedContainer/README.md).
This prototype is not the final one-app architecture. The implementation target
is [VexSign as the primary host with native account and certificate services](docs/NATIVE_SIGNING_ARCHITECTURE.md).
