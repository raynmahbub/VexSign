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

### Build

- The simulator target now uses the same iOS 16 deployment target as the device
  target. The separate 18.5 override only produced deprecation warnings for APIs the
  app already guards at runtime.
- CI runs the unsigned build and simulator tests concurrently after the Linux checks,
  shares one SwiftPM cache across the companion-platform matrix, reuses the release
  package cache, and builds only the active simulator architecture. The known
  third-party `libunicorn.a` deployment-version lines are filtered from the live log
  while the full log stays in the failure artifact.
