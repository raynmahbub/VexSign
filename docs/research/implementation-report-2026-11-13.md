# Repository implementation report — 2026-11-13

**Branch:** `arena/4777f732-vexsign` (base `c67fab28e3e66bdd90b6df0464eb774d5aa5b1d3`).
**Status:** active working tree; no commit, push, PR, merge, release, tag or deployment was made.
**Scope:** Phase 0 baseline, Phase 1 critical workflow repair, targeted Phase 4/6/8 reliability and
security work, and the A–G deliverables. Native Apple-account promotion, physical-device
acceptance and production bootstrap remain honestly gated (see
[remaining blockers](remaining-blockers-2026-11-13.md)).

## 1. What was wrong at baseline

The [baseline report](implementation-baseline-2026-11-13.md) recorded three reproducible
defects and one CI-wide failure:

1. Current-HEAD CI run `43513058621` failed both `build · VexSign Debug (unsigned)` and
   `tests · VexSignTests (simulator)` because of two Swift 6 diagnostics:
   - `AnisetteProviderUseCase.swift:14` evaluated the `@MainActor` singleton
     `AnisetteProviderFactory.shared` in a nonisolated default argument (a warning promoted to
     an error by the build gate).
   - `DeepLinkRouterUseCase.swift:233` used `Result<Void, String>`; `String` does not conform to
     `Error`, so the app target did not compile (`exit 65`, `totalTestCount=0`).
2. `server/url_guard.public_url_error` skipped port validation on the `resolve_dns=False` fast
   path and raised an uncaught `ValueError` on the DNS path for malformed ports. Malformed IPv6
   URLs also raised during `urlparse`. Public install-probe and repository-decode endpoints could
   therefore return HTTP 500 on a user-supplied or redirected URL.
3. `ManifestService.resolve` returned `candidates.first` when no manifest endpoint served an XML
   plist. `AppInstaller` would then hand iOS an `itms-services` link to an unverified endpoint.
4. Two feature gaps found during pinned upstream source comparison: VexSign's shared diagnostic
   log redactor did not cover imported certificate/session payloads, pairing secrets, hardware
   identifiers, device names or UDIDs; and deep-link base64 staging only replaced spaces, so
   base64url, missing padding, whitespace and oversized payloads were mishandled.

## 2. Implemented changes

### 2.1 Swift 6 build repair (Phase 1)

| File | Change |
| --- | --- |
| `VexSign/Application/AnisetteProviderUseCase.swift` | Default `factory` is now `nil`; the `@MainActor` singleton is resolved inside the isolated initializer. Injection seam preserved for tests/composition root. |
| `VexSign/Application/DeepLinkRouterUseCase.swift` | Added `CoordinatedFileCopyFailure: LocalizedError`; `copyCoordinatedFile` returns `Result<Void, CoordinatedFileCopyFailure>` and the failure text is presented through `localizedDescription`. |
| `tools/test_swift6_build_regressions.py` | New portable guard: no isolated `.shared` default arguments in `Application`, no `Result<..., String>` anywhere in `VexSign`, both repaired patterns present, and the guard is wired into `Makefile`/CI. |
| `Makefile`, `.github/workflows/ci.yml` | Run the new guard in `make verify` and the CI quick job. |

### 2.2 Public URL guard (Phase 1/6 security)

| File | Change |
| --- | --- |
| `server/url_guard.py` | `urlparse` and `parsed.port` are now guarded; port `0`, out-of-range/non-numeric ports and malformed IPv6 URLs return a deterministic refusal on **both** `resolve_dns` paths. Valid explicit/default ports are still passed to `_resolve_ips`. DNS/private-network blocking is unchanged. |
| `server/tests/test_signer_decoder_installer.py` | 36 new cases: malformed ports with/without DNS, port zero, malformed IPv6, valid ports and resolver ports, private-DNS regression, initial endpoint refusal, and redirect refusal for both probe and decoder. |

### 2.3 Honest OTA manifest handoff (Phase 1/4)

| File | Change |
| --- | --- |
| `VexSign/Backend/Server/ManifestService.swift` | Added network-free `select(candidates:serves:)`; only a positively verified XML-plist endpoint is returned. Cancellation stops the probe loop. `resolve(for:payload:)` delegates to it. |
| `VexSign/Backend/Observable/AppInstaller.swift` | `_serveForOTA` now refuses the install with the existing user-visible error when `resolve` returns `nil`, instead of starting the server with an unverified external manifest. |
| `VexSignTests/ManifestServiceResolutionTests.swift` | XCTest cases: no serving endpoint → `nil`, first verified endpoint wins, empty candidate list, no later probes after success. |
| `tools/test_integration_contracts.py` | Source contract: no `candidates.first` fallback, cancellation check present, installer guards `nil`. |

### 2.4 Shared-log privacy (Phase 8 security)

| File | Change |
| --- | --- |
| `VexSign/Utilities/Logging/LogRedaction.swift` | Added an escaped key alternation for certificate/session payloads, pairing secrets, serials, cellular/network identifiers, Apple account/anisette headers, device names and UDIDs. New rules cover plist `<key>` blocks, JSON/header `Key: value` / `Key=value`, Swift `Key = value` lines, keyed 40-hex UDIDs, modern 8-16 hex UDIDs, and email local parts (domain retained). All rules require a key/header/userinfo or a recognisable identifier shape; bare hashes and ordinary diagnostics stay readable. |
| `VexSignTests/LogRedactionTests.swift` | New XCTest cases for account/pairing JSON, anisette headers, device identifiers/names, email masking with domain, bare-hash non-redaction, and idempotency with an account value. |
| `tools/test_integration_contracts.py` | Source contract for the key list, escaped alternation, UDID rule and the new Swift tests. |

### 2.5 Deep-link base64 staging (Phase 6 reliability)

| File | Change |
| --- | --- |
| `NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift` | `decodeAndWrite` now removes whitespace, normalises base64url `-`/`_`, restores missing padding, bounds decoded size (default 16 MiB, injectable for tests), rejects empty/invalid data, and still stages to a unique temporary file. |
| `VexSignTests/DeepLinkBase64StagingTests.swift` | XCTest cases for standard base64, missing padding, whitespace, base64url alphabet, oversized payload and invalid/empty input. |
| `tools/test_integration_contracts.py` | Source contract for normalization, size bound and test coverage. |

### 2.6 Documentation and repository gates

- `docs/research/implementation-baseline-2026-11-13.md` — Phase 0 baseline.
- `CHANGELOG.md` — Unreleased Added/Fixed entries for all of the above.
- `docs/FEATURE_MATRIX.md` — pointer to the new Definition-of-Done matrix.
- `docs/research/reference-investigation-2026-11-13.md` — deliverable B.
- `docs/research/feature-completion-matrix-2026-11-13.md` — deliverable C.
- `docs/research/testing-report-2026-11-13.md` — deliverable D.
- `docs/research/device-acceptance-guide-2026-11-13.md` — deliverable E.
- `docs/research/remaining-blockers-2026-11-13.md` — deliverable F.
- `docs/research/proposed-git-changes-2026-11-13.md` — deliverable G.

## 3. Architecture and safety decisions

- The Clean Architecture direction (Presentation → Application → Domain ← Infrastructure/Platform)
  is unchanged. The new `CoordinatedFileCopyFailure` stays in the Application layer; the base64
  helper stays in the existing `NimbleExtensions` utility; `ManifestService.select` is a pure
  decision function with network injection through a closure.
- No new Swift package, dependency, singleton, signing engine, task system, concurrency escape or
  `try?` site was added. `tools/error-discipline.py`, `tools/singleton-freeze.py` and
  `tools/concurrency-discipline.py` remain green.
- Native signing gates are untouched: `nativeAppleAccountSigning: .notIntegrated`, production
  `.appleCMS()` verifier requirement, pinned Apple roots, strict CMS grammar, and the
  `native-promotion-evidence` device ladder all remain. No free-account, CMS, JIT, background,
  entitlement or installation claim was promoted.
- Installation state distinctions remain: transfer started/requested/accepted/confirmed/launch
  verified are not conflated. `ManifestService` now refuses rather than manufacturing a request.
- No upstream source code was copied. Two specific behaviours were independently reimplemented
  after pinned source comparison; see deliverable B for licence and adaptation notes.
- No secrets, private keys, tokens, production credentials, release tags, visibility changes or
  deployment actions were performed.

## 4. Verification summary

Full commands, counts and limits are in the [testing report](testing-report-2026-11-13.md).
Locally: `make verify` exit 0; `python3 -m unittest discover -s tools -p 'test_*.py'` 309 OK;
server pytest `215 passed, 1 skipped`; `make test-cloud` exit 0 with 14/14 Node tests and an
OpenAPI drift check; NativeSigning Python 74 OK; EmbeddedContainer Python 31 OK; tree-sitter
parsed every edited/new Swift file with zero new syntax errors (two pre-existing parser
limitations in `DeepLinkRouterUseCase.swift` and `AppInstaller.swift` were confirmed against the
baseline).

**Not verified here:** macOS/Xcode compile, simulator XCTest, generic unsigned iOS build, physical
iPhone acceptance, or a new current-branch GitHub Actions run. Those require a commit/push and a
real device, which the user controls. The baseline CI failure is diagnosed and its two compiler
diagnostics are fixed, but a fresh green CI run is still outstanding.

## 5. Files changed

Modified: `.github/workflows/ci.yml`, `Makefile`, `CHANGELOG.md`, `docs/FEATURE_MATRIX.md`,
`NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift`,
`VexSign/Application/AnisetteProviderUseCase.swift`,
`VexSign/Application/DeepLinkRouterUseCase.swift`,
`VexSign/Backend/Observable/AppInstaller.swift`,
`VexSign/Backend/Server/ManifestService.swift`,
`VexSign/Utilities/Logging/LogRedaction.swift`,
`VexSignTests/LogRedactionTests.swift`, `server/url_guard.py`,
`server/tests/test_signer_decoder_installer.py`, `tools/test_integration_contracts.py`.

Added: `tools/test_swift6_build_regressions.py`,
`VexSignTests/ManifestServiceResolutionTests.swift`,
`VexSignTests/DeepLinkBase64StagingTests.swift`, and the eight A–G/baseline research documents
under `docs/research/`.

See [proposed Git changes](proposed-git-changes-2026-11-13.md) for the professional PR title,
summary and suggested commit sequence. No commit was executed.
