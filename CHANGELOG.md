# Changelog

All notable changes to VexSign are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut from a tag whose name matches `MARKETING_VERSION` — see
[docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

### Fixed

- `tools/update-repo.sh` no longer word-splits its authorization header
  (curl used to receive `Bearer` as a URL and failed every authenticated
  run), and the stale workflow name in `docs/BUILD.md` was corrected.
- Tapping Reinstall (or Install) no longer ends in the dead end "The updater
  server isn't available in this build." with a Try Again button that repeated
  the same sentence. The update flow now evaluates a method plan before the tap
  (`SelfUpdateManager.plan`), names the actual blocker, offers the other install
  method when it is ready, and switches to it instead of failing when only the
  selected method is unconfigured. Settings → Updates gained an editable
  updater address (http(s) only, https assumed) so the server route can be set
  up in-app, plus a one-tap switch to IDevice when a pairing file exists. A
  stored address is validated before it is saved, a dismissed sheet no longer
  reopens on a stale failure, and the plan is covered by
  `VexSignTests/SelfUpdateReadinessTests.swift`.
- The Settings → Signing Methods screen no longer reports placeholder data:
  `SigningMethodAvailability` now exposes only real availability (paid
  mirrors imported certificates, TrollStore mirrors the device detector,
  free Apple ID stays selectable while live session state renders from
  `NativeSigningManager`), unavailable rows display why they cannot be
  selected, and the always-true availability tests were replaced with real
  assertions.

### Added

- A local notification the first time a newer VexSign release appears, controlled
  by **Settings → Updates → Release Notifications** (on by default; the
  permission is requested only when the switch is turned on). It fires once per
  version, never for a version marked as ignored, and never on top of the launch
  prompt that is already showing that release — if the prompt is dismissed, the
  next check announces it instead. Tapping the banner opens the update sheet.
  Because iOS schedules background work, the alert is posted by the update check
  at launch, in Update settings, or during a scheduled automation pass; it is not
  an instant server push. The scheduled automation pass now also checks for a new
  VexSign release before it looks at sources. The decision is pure and covered by
  `VexSignTests/SelfUpdateNotificationTests.swift`.
- Settings now opens with a compact identity header — the VexSign logo, app name
  and version — directly above the About section. It replaces the full-width
  "Star on GitHub" card that used to sit at the bottom of the list with a small
  star pill in the same header row, so the link stays reachable without a
  dedicated section. Debug and Nightly builds keep hiding the star, as before.
  `SettingsDonationCellView` is deleted.
- `docs/ARCHITECTURE.md` gained a **README feature coverage** table that maps
  every feature advertised in the README to the files that implement it, with an
  explicit statement of what that check does and does not prove.

### Changed

- All GitHub workflows were slimmed down and de-duplicated: the CI quick job
  runs its gates as three consolidated steps, failing-test diagnostics moved
  out of inline YAML into `.github/scripts/surface_test_failures.py`,
  unreachable release-mode branches and unneeded full-history checkouts were
  removed, and the unused `.github/scripts/git_identity.sh` was deleted.
- Repository-maintenance bot passes now run every 4 hours instead of hourly
  (75% fewer idle automation runs; weekly hygiene/audit unchanged).
- The cloud-signing `npm audit` gate runs only when `package.json` or
  `package-lock.json` actually changed (and on the weekly schedule), so
  source-only pull requests no longer fail on freshly published advisories.
- The standalone `native-signing-smoke` workflow was removed; its unique link
  diagnostics now live as the dispatch-only `link_smoke` job of the Combined
  native host workflow, which already ran the same gates and unit tests
  automatically. macOS job timeouts tightened (build 90→60, tests 60→45,
  platform legs 60→45 minutes).

## [1.1.0] - 2026-11-06

### Highlights

- Home is the middle of five tabs, with privacy-aware search across the workspace.
- Installation routes distinguish OTA, paired-device/IDevice and LiveContainer
  guest staging; a staged guest is never reported as an OS-installed app.
- Native account, anisette v3 and combined-host work is experimental. The public
  release artifact is the standalone app, not a device-accepted combined host.

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

- Installation confirmation no longer treats a negative lookup after the short
  version-settle window as immediate failure. New matching-app appearances can
  confirm installs when iOS exposes no progress counter, but unknown/pre-existing
  app states are not proof of a new install. Completed queue sheets dismiss.
- Shorter install recovery alerts separate technical details, omit empty waiting
  counts, and distinguish unconfirmed installation from a known rejection.
- About is first in Settings. Corrected English setup wording, removed promotional
  attribution phrasing (retaining licenses), and added contextual install/setup haptics.

- Signing now stops before library registration when post-sign structural
  verification fails. Known uncovered retained extensions are rejected before
  signing; users must choose a compatible profile or explicitly remove extensions.
- Post-sign identifier checks read current Info.plist bytes rather than cached
  Bundle metadata. TLS diagnostics distinguish device-local identities from
  actual bundled files; structural inspection is not called cryptographic verification.

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

### Build

- The simulator target now uses the same iOS 16 deployment target as the device
  target. The separate 18.5 override only produced deprecation warnings for APIs the
  app already guards at runtime.
- CI runs the unsigned build and simulator tests concurrently after the Linux checks,
  shares one SwiftPM cache across the companion-platform matrix, reuses the release
  package cache, and builds only the active simulator architecture. The known
  third-party `libunicorn.a` deployment-version lines are filtered from the live log
  while the full log stays in the failure artifact.

### Account and installation safety

- Added the pinned upstream anisette catalogue, explicit protocol selection and
  provider-bound, device-only ADI storage for the experimental v3 path. HTTP-only
  endpoints are blocked; catalogue inclusion does not imply verified health.
- Added owner-bound local identity/profile receipt inventory and a renewal review
  queue. Local history is not complete Apple portal inventory or installation quota.
- Removed simulated native signing/install success. Profile-only operations use
  actual registration results, separate explicit mutation approvals and an early
  CMS capability gate before quota-affecting work.
- Made native private-key export grants exact, single-use and revocable, with
  context/expiry checks before returning PKCS#12. Raw private-key DER stays inside
  the authoritative bridge.
- Preserved provider failures during authentication cleanup and rejected truncated,
  overflowing or trailing-data raw-DEFLATE streams with exact zlib consumption.
- Added architecture-bound physical-device acceptance reports. Native-primary
  builds require observations beyond standalone launch/install checks; reports
  start pending and are human attestations, not independent hardware proof.

### Experimental / not included as a stable combined artifact

- Added the native-primary VexSign/LiveContainer/SideStore bootstrap and packaging
  candidate, explicit session controls, separate OpenSSL namespaces, preserved
  runtime settings/legal panes and collision-checked localization merging.
- The combined host is not device-accepted and is not the standalone release IPA.
  Its packaging validation is separate; guest staging is not OS installation.
- Production native CMS verification remains gated. Full native-owned-key signing
  and verified installation, complete remote inventory and scoped unattended
  renewal are unfinished. Background discovery only prepares a review queue.
- Physical-iPhone/provider acceptance has not been performed. Simulator or
  synthetic native tests do not establish these properties.
