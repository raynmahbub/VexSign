# Proposed Git changes — 2026-11-13

Deliverable **G**. This document records the proposals as they stood while the work was an active
working tree. The user later explicitly requested a pull request; the commits below were applied,
`arena/4777f732-vexsign` was pushed, and PR #235 was opened. No merge, release, tag, visibility
change, secret change or deployment was executed; those actions remain user-controlled.

## Proposed pull request

**Title**

`fix(core): restore Swift 6 build and harden install, URL, and log boundaries`

**Base / head**

`main` ← `arena/4777f732-vexsign` (branched from
`c67fab28e3e66bdd90b6df0464eb774d5aa5b1d3`).

**Summary**

The current `main` HEAD fails the macOS CI build and simulator test jobs because of two Swift 6
diagnostics. This change fixes both compile issues, adds portable regression gates, and closes
four confirmed workflow/security defects found during source investigation: malformed public URL
ports, unverified OTA manifest fallback, incomplete shared-log redaction, and brittle deep-link
base64 staging. It keeps every native-account, bootstrap, cloud-signing, installation-state and
physical-device claim honest. No new dependency, signing engine, task system, singleton, secret
or upstream source copy is introduced.

**Major areas**

1. Swift 6 build repair: `AnisetteProviderUseCase`, `DeepLinkRouterUseCase`, new portable guard.
2. Server SSRF guard: deterministic port/IPv6 validation on both `resolve_dns` paths, 36 pytest
   cases including redirect hops.
3. OTA install honesty: network-free `ManifestService.select`, `AppInstaller` refusal on `nil`,
   XCTest + source contracts.
4. Log privacy: extended `LogRedaction` for certificate/session, pairing, hardware, device and
   account identifiers; domain-preserving email masking; idempotency and non-overfire tests.
5. Deep-link reliability: base64/base64url normalization, padding restoration, whitespace handling
   and decoded-size bound in `NimbleExtensions`.
6. Documentation: baseline, reference investigation, Definition-of-Done matrix, testing report,
   acceptance guide, blockers, and this proposal; `CHANGELOG.md` Unreleased entries.

**Suggested PR checklist**

- [ ] `make verify` green (already run locally, exit 0).
- [ ] `PYTHON=<venv>/bin/python make test-server` green (`215 passed, 1 skipped`).
- [ ] `make test-cloud` green (14/14, OpenAPI drift clean).
- [ ] Push branch and confirm a fresh `ci.yml` `build` + `tests` run is green.
- [ ] Attach Xcode build/test artifacts; record run URL in the testing report.
- [ ] Physical iPhone acceptance remains `Blocked (Device-verified)` until deliverable E is run.
- [ ] Do not change `nativeAppleAccountSigning: .notIntegrated` or any CMS/promotion gate.

## Suggested commit sequence

The sequence is Conventional Commits, smallest reviewable units first. Each commit is a
suggestion; the user may squash or reorder.

### 1. `docs(research): record implementation baseline before edits`

Files: `Documentation/Research/implementation-baseline-2026-11-13.md`.

Message body: capture HEAD/branch, portable baseline results, current-HEAD CI failure
`43513058621`, the two Swift 6 annotations, the reproducible URL-guard defect, environment limits
and the reference-investigation status before any source change.

### 2. `fix(build): resolve Swift 6 diagnostics in application use cases`

Files: `App/iOS/VexSign/Application/AnisetteProviderUseCase.swift`,
`App/iOS/VexSign/Application/DeepLinkRouterUseCase.swift`,
`Tools/CI/test_swift6_build_regressions.py`, `Makefile`, `.github/workflows/ci.yml`.

Message body: move the `@MainActor` singleton lookup out of a nonisolated default argument;
replace `Result<Void, String>` with a `LocalizedError`; add a portable guard against both
patterns and wire it into `make verify` and the CI quick job.

### 3. `fix(server): validate URL ports before every public fetch`

Files: `Services/API/server/url_guard.py`, `Services/API/server/tests/test_signer_decoder_installer.py`.

Message body: guard `urlparse` and `parsed.port`; reject port zero, out-of-range/non-numeric ports
and malformed IPv6 URLs on both DNS and fast paths; keep DNS/private-network blocking unchanged;
add unit and redirect-hop regressions for probe and decoder endpoints.

### 4. `fix(install): refuse unverified external OTA manifests`

Files: `App/iOS/VexSign/Backend/Server/ManifestService.swift`,
`App/iOS/VexSign/Backend/Observable/AppInstaller.swift`,
`App/Tests/VexSignTests/ManifestServiceResolutionTests.swift`,
`Tools/Development/test_integration_contracts.py`.

Message body: replace the `candidates.first` fallback with a cancellation-aware, network-free
selection rule that returns only a positively verified XML-plist endpoint; fail the install with
the existing user-visible error when no endpoint serves; add XCTest and source contracts.

### 5. `fix(privacy): redact account, pairing and device identifiers in shared logs`

Files: `App/iOS/VexSign/Utilities/Logging/LogRedaction.swift`,
`App/Tests/VexSignTests/LogRedactionTests.swift`, `Tools/Development/test_integration_contracts.py`.

Message body: add an escaped key alternation and rules for plist/JSON/header/Swift-line forms,
UDIDs and email local parts; keep domains, bare hashes and ordinary diagnostics readable; assert
idempotency, positive redaction and non-overfire cases.

### 6. `fix(deep-link): normalize and bound certificate base64 staging`

Files: `Packages/NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift`,
`App/Tests/VexSignTests/DeepLinkBase64StagingTests.swift`, `Tools/Development/test_integration_contracts.py`.

Message body: accept standard base64, base64url, missing padding and whitespace; reject empty,
invalid and oversized payloads before staging; keep the unique temporary-file write best-effort
and let the importer validate the result.

### 7. `docs: publish A–G engineering deliverables and changelog`

Files: `CHANGELOG.md`, `Documentation/Research/FEATURE_MATRIX.md`,
`Documentation/Research/reference-investigation-2026-11-13.md`,
`Documentation/Research/feature-completion-matrix-2026-11-13.md`,
`Documentation/Research/testing-report-2026-11-13.md`,
`Documentation/Research/device-acceptance-guide-2026-11-13.md`,
`Documentation/Research/remaining-blockers-2026-11-13.md`,
`Documentation/Research/proposed-git-changes-2026-11-13.md`,
`Documentation/Research/implementation-report-2026-11-13.md`.

Message body: record the implementation report, pinned upstream investigation, Definition-of-Done
matrix, exact test commands/results, physical-device acceptance procedure, remaining blockers and
this PR/commit proposal. State honestly that no release or device result was produced by the agent.
This is the forward-compatible wording used when the seven proposed commits were executed.

## Changelog entry (already applied to `CHANGELOG.md`)

Under `## [Unreleased]`:

```markdown
### Added
- Regression tests for Swift 6 build errors, manifest endpoint selection,
  server URL ports, extended log redaction, and deep-link base64 staging.

### Fixed
- The app target compiles under Swift 6 diagnostics again: the Anisette provider
  use case no longer evaluates a main-actor singleton in a default argument, and
  shared-file import failures now use a real `Error` type instead of `String`.
  Portable source guards cover both regressions; a fresh macOS CI build is
  required to confirm the compile on this branch.
- Public server URL probes reject malformed ports and malformed IPv6 URLs on
  both the DNS and fast paths, so a hostile redirect can no longer crash the
  probe/decode endpoints or skip port validation.
- External OTA installs no longer fall back to an unverified manifest endpoint.
  Every candidate must return an XML plist, and the install is refused with an
  error when none does.
- Shared diagnostic logs now redact imported certificate/session payloads,
  pairing secrets, hardware identifiers, device names, UDIDs and the local part
  of email addresses, while keeping ordinary errors and domains readable.
- Certificate/profile base64 deep links accept standard base64, base64url,
  missing padding and whitespace, and reject oversized payloads before staging.
```

## Explicitly not executed

- `git commit`, `git push`, `gh pr create`, `gh pr merge`, `gh pr close`.
- Release, tag, public visibility change, secret/credential change, deployment.
- Any change to `nativeAppleAccountSigning`, CMS promotion evidence, cloud-signing gate,
  bootstrap claims, or fabricated device results.
