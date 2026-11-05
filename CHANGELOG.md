# Changelog

All notable changes to VexSign are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut from a tag whose name matches `MARKETING_VERSION` — see
[docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

### Added

- A rebuilt Home dashboard with a certificate-aware hero, one-tap import and
  quick-sign actions, a three-step getting-started checklist, live task and
  update status, recent apps and a compact workspace-tools card. It uses the
  shared design tokens and collapses empty sections instead of showing dead
  cards.
- A documented design system (`docs/DESIGN.md`) and reusable Home components
  under `VexSign/DesignSystem/`, including contrast-aware surfaces, responsive
  action tiles and accessible setup/status rows.
- A professional repository front page, architecture/build/design guides,
  documentation index and security policy.

### Automation

- The Release workflow now has two channels: stable tags/manual publishes and a
  daily **nightly pre-release** at 03:00 UTC. Nightly tags are unique
  (`v<version>-nightly.<date>.<run>.<attempt>`), immutable and never update the
  installation listing; stable releases still sync `app-repo.json`.
- Added Dependabot coverage for GitHub Actions, server Python, cloud npm,
  SwiftPM packages and Docker images, plus a weekly read-only audit for the
  root Xcode SwiftPM requirements that Dependabot cannot parse.
- Added deterministic repository maintenance (localisation sync → `make verify`
  → review PR) and automatic CI failure triage into issues. Neither bot guesses
  at behavioural fixes or pushes to `main`.
- Added the release/maintenance documentation and environment guidance.

### Changed

- Zsign and IDeviceKit are vendored under `Vendor/` with pinned commits and
  licences; cloning and CI no longer require Git submodules or `--recursive`.
- `make bootstrap` validates the toolchain and package graph before the first
  Xcode build.

### Fixed

- Certificate import no longer starts Zsign's legacy native OCSP checker, which
  has unsafe response-pointer initialization and asynchronous certificate lifetime
  handling in the pinned dependency. Import, refresh and legacy certificate-check
  entry points now use the system-trust inspector. Only positive revocation
  evidence marks a stored certificate revoked; offline or unreadable results do not.
- Certificate and provisioning-profile reads are bounded to 10 MiB before parsing
  to avoid excessive allocation from oversized selections. Pending status results
  are discarded when their certificate row has been deleted.
- Provisioning failures now map certificate-limit, profile-limit, device and App ID
  conflicts before the generic quota message, and free-account expiry rounds up so a
  profile with 2 days and 20 hours left is reported as 3 days, not 2.
- Archive extraction rejects a path whose existing prefix is a symbolic link, closing
  an escape where `escape/outside` resolved outside the workspace because the final
  component did not exist yet.

### Changed

- The simulator target now uses the same iOS 16 deployment target as the device
  target. The separate 18.5 override only produced deprecation warnings for APIs the
  app already guards at runtime.
- CI runs the unsigned build and simulator tests concurrently after the Linux checks,
  shares one SwiftPM cache across the companion-platform matrix, reuses the release
  package cache, and builds only the active simulator architecture. The known
  third-party `libunicorn.a` deployment-version lines are filtered from the live log
  while the full log stays in the failure artifact.

## [1.1.0] — 2026-11-01

A hardening release. Most of it is not new surface: it is the app telling the truth about what it is
doing, and refusing to do the wrong thing quietly.

### Added

- **Download integrity.** When a repository publishes a size for an app (and, when one exists, a
  hash), the download is checked against it **before** the importer opens it. A mismatch is reported
  with both byte counts and the file is never imported by accident: the alert offers *Import Anyway*
  — one deliberate, logged bypass for that file — or *Delete*, which removes it unconditionally.
  Previously a truncated download failed three steps later, inside the unarchiver, with a message
  that said nothing about the download.
- **Signed repositories.** A repository may now carry an Ed25519 signature over its catalogue. When
  it verifies, the source is badged *Signed by …* and the badge is evidence rather than a switch.
  When a source claims a signature that does not verify, the refresh is refused and the previous
  catalogue stays. Unsigned sources keep working exactly as before. Format, canonicalisation rule
  and an OpenSSL recipe: [docs/SOURCE_SIGNING.md](docs/SOURCE_SIGNING.md).
- **Install-method preflight.** Settings → Installation now lists every way an app can reach the
  device — local HTTPS, idevice, export, TrollStore — and names what each one is missing before the
  install starts, instead of failing later with a socket error. TrollStore is detected, never
  installed, and reimplementing CoreTrust is explicitly out of scope.
- **One "Inject by Default" screen.** Every tweak's auto-injection flag in one list, with search,
  bulk toggles and the exception count per row. It writes the same flag the tweak's own screen does.
- **OCSP revocation evidence (foundation).** A self-contained ASN.1 reader/writer, OCSP request
  builder, response parser, responder-signature verification and a revocation policy that never acts
  on an unverified or stale answer. Not yet wired to any screen or setting; chaining the responder to
  an issuer is the documented next step.
- **Repository tooling for contributors:** `make verify` (the repository gates the Quick check runs),
  `make strict-concurrency`, and four CI gates with baselines — localisation catalogue, unjustified
  `try?`, global singletons, and concurrency escapes (`@unchecked Sendable`, `nonisolated(unsafe)`,
  `@preconcurrency`).
- **Docs:** [CONTRIBUTING.md](CONTRIBUTING.md) — what to run, and the device checks no test can
  stand in for.

### Changed

- **The anti-revoke endpoint is configurable and visible.** The NovaDNS service host was hard-coded
  to a third-party domain with no way to see or change it. It is now a default: the rule endpoint is
  shown, replaceable (https only), resettable, and the feature stays **off** by default. Every
  install that rewrites resolution logs it once, with the endpoint that is actually used, and the
  settings screen says plainly what the feature cannot do.
- **Feeds decode off the main thread**, with signposts around fetch, decode and publish so a slow
  refresh can be attributed to a phase.
- **Library writes leave the main queue**, and installs are confirmed by the device rather than
  inferred from a progress bar ending.
- **Logs are redacted at the sink.** Passwords, p12 passwords, tokens, bearer credentials, API keys
  and URL userinfo never reach the log file a user can export.
- **`AppStoreView` was split** (1,567 → 1,386 lines) and a view model can now be built with an
  injected download seam, so it is testable without a live session.
- The third-party certificate catalogue is **contained, not removed** — renamed to
  `CommunityCertificatesView`, clearly marked as unverified community content.

### Fixed

- A download that failed its integrity check could never be imported deliberately, and its file was
  left on disk. The choice now lives in the alert that reports the mismatch, and refusing it deletes
  the file.
- Four silent `try?` boundaries at user-visible points — the entitlements plist write, the IPA change
  journal, tweak member writes and the backup encryption check — now log typed failures instead of
  doing nothing.
- The web manager no longer exports LAN certificates and is authenticated by default.
- The remote certificate checker is gone; local OCSP helpers remain.
- Source decoding no longer blocks the interface on large feeds.

### Security

- No new third-party dependencies behind any security toggle. The signature check uses CryptoKit, the
  OCSP signature check uses Security.framework, and the endpoint validation is Foundation.

### Known limitations

- The OCSP evidence is a tested library, not a feature: nothing builds a request yet.
- The responder certificate is not yet chained to an issuer or Apple's WWDR root.
- `make deps-pin` has not been run in this tree, so Release CI needs it before the first tag.

## [1.0] — 2026-09-19

Previous release: signing, install queues, sources, backups and the tweak library.
