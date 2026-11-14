# Testing report — 2026-11-13

Deliverable **D**. Every command below was run from `/home/user/VexSign` unless noted. Results are
for the working tree on `arena/4777f732-vexsign`; nothing was committed, pushed or released, so
there is **no new current-branch GitHub Actions run**.

## 1. Environment

| Item | Value |
| --- | --- |
| OS / toolchain | Linux sandbox; `swiftc`, Xcode, iOS simulator and physical iPhone unavailable |
| Git | `HEAD c67fab28e3e66bdd90b6df0464eb774d5aa5b1d3`, branch `arena/4777f732-vexsign`, working tree initially clean |
| Python | system `python3` for portable tools; `/tmp/vexvenv/bin/python` for server tests (created from `server/requirements.txt` + `pytest`) |
| Node | `cloud-signing` dependencies installed with `npm ci --no-audit --no-fund` (178 packages); `node_modules` is regenerated and excluded from snapshots |
| Swift parsing | `/tmp/vexvenv` `tree_sitter` 0.26.1 + `tree_sitter_swift`; **syntax only**, not type-check/build/link/device proof |
| Network | outbound allowlist only; GitHub Actions log/artifact blob hosts returned `EOF`, so failure evidence came from the Checks API annotations |

## 2. Baseline (before edits)

| Command | Result |
| --- | --- |
| `git status --short` | empty |
| `make verify` | exit 0; `swiftc not found - Swift syntax check skipped` advisory; NativeSigning 74 OK; EmbeddedContainer 31 OK |
| `python3 -m unittest discover -s tools -p 'test_*.py'` | 298 OK |
| `python3 -m unittest discover -s NativeSigning/PythonTests -v` | 74 OK |
| `python3 -m unittest discover -s EmbeddedContainer/tests -v` | 31 OK |
| `/tmp/vexvenv/bin/python -m pytest -q server/tests` | `179 passed, 1 skipped` |
| `cd cloud-signing && npm ci --no-audit --no-fund && npm test` | exit 0; 178 packages; `14 pass / 0 fail / 0 skipped` |
| `grep -rInE 'TODO\|FIXME\|XXX' --include='*.swift' VexSign \| wc -l` | 0 |

Full baseline is in [implementation-baseline-2026-11-13.md](implementation-baseline-2026-11-13.md).

## 3. CI evidence at baseline

`gh run list --workflow ci.yml --limit 8 --json databaseId,status,conclusion,headSha,createdAt,event`
showed the current-HEAD push run **`43513058621`** (`c67fab28`, `2026-11-13T21:42:22Z`) as
`completed / failure`. `gh run view 43513058621 --json jobs` reported:

| Job | Conclusion |
| --- | --- |
| `quick · syntax, resources, gates` | success |
| `build · VexSign Debug (unsigned)` | failure |
| `tests · VexSignTests (simulator)` | failure (`Testing cancelled because the build failed`) |
| `concurrency · first-party packages (report)` | success |

Checks API annotations (job check-runs `132189888675`, `132189888809`):

| Location | Level / title | Message |
| --- | --- | --- |
| `VexSign/Application/AnisetteProviderUseCase.swift:14` | failure / `New warning (treated as error)` | `main actor-isolated static property 'shared' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode` |
| `VexSign/Application/DeepLinkRouterUseCase.swift:233` | failure / `Compiler error` | `type 'String' does not conform to protocol 'Error'` |
| `.github/workflows/ci.yml:1` (test job) | log | `Testing cancelled because the build failed`, `result=unknown totalTestCount=0 passedTests=0 failedTests=0 skippedTests=0 expectedFailures=0` |

`gh api repos/raynmahbub/VexSign/actions/runs/43513058621/artifacts` listed build/test artifacts,
but `gh run view --log-failed`, job-log and artifact downloads returned `EOF` because the
`results-receiver.actions.githubusercontent.com` / `productionresultssa*.blob.core.windows.net`
hosts are outside the sandbox allowlist. The annotations above are the authoritative evidence.

`gh run list --branch main --limit 12` returned maintenance/repair/release runs
`43515514014`, `43515500625`, `43515500767`, `43515500693`, `43514977879`, `43514970651`,
`43514970682`, `43514970880`, `43514116415`, `43514104348`, `43514104325`, `43514104367`, all on
`c67fab28`; mostly skipped, with successes `43515500693`, `43514970651`, `43514104348`. These are
**not** current-branch build/test proof. Historical run `42602611745` in
`docs/research/remaining-roadmap-implementation.md` is an earlier commit's macOS evidence, also
not current-branch proof.

## 4. Final local verification (after implementation)

| # | Command | Result |
| --- | --- | --- |
| 1 | `python3 tools/test_swift6_build_regressions.py` | `Ran 5 tests … OK` |
| 2 | `python3 tools/test_integration_contracts.py` | `Ran 14 tests … OK` |
| 3 | `python3 -m unittest discover -s tools -p 'test_*.py'` | `Ran 309 tests … OK` (baseline 298; +11 new) |
| 4 | `make verify` | exit 0; docs links, policy suites, quick check, project/package graph, localisation, error/singleton/concurrency discipline, native handoff, CMS fixture, workflow policy, EmbeddedContainer 31 OK, NativeSigning 74 OK |
| 5 | `PYTHON=/tmp/vexvenv/bin/python make test-server` (equivalently `/tmp/vexvenv/bin/python -m pytest -q server/tests`) | `215 passed, 1 skipped, 1 warning` (baseline `179 passed, 1 skipped`; +36 new URL-guard cases) |
| 6 | `cd cloud-signing && npm test` | `14 pass / 0 fail / 0 skipped` |
| 7 | `make test-cloud` | exit 0; `npm run build`, `npm test` 14/14, `npm run contracts`, `git diff --exit-code -- cloud-signing/openapi.json` clean |
| 8 | `python3 -m unittest discover -s NativeSigning/PythonTests -v` | 74 OK |
| 9 | `python3 -m unittest discover -s EmbeddedContainer/tests -v` | 31 OK |
| 10 | `python3 tools/check-docs.py && python3 tools/test_docs.py` | documentation file links OK; README download/CI assertions OK |
| 11 | tree-sitter parse of every edited/new Swift file | 0 new syntax errors; two pre-existing parser limitations confirmed against `HEAD` in `DeepLinkRouterUseCase.swift` and `AppInstaller.swift` |

The single server skip is
`server/tests/test_web_tools.py:321: optional cryptography not installed`. The single warning is
`StarletteDeprecationWarning: Using httpx with starlette.testclient is deprecated; install httpx2 instead`.
Both are environment/dependency advisories, not failures introduced by this change.

### New regression coverage by area

| Area | New automated cases | Where |
| --- | --- | --- |
| Swift 6 build patterns | 5 portable | `tools/test_swift6_build_regressions.py` |
| Manifest resolution / installer refusal | 3 Swift XCTest + 2 portable contracts | `VexSignTests/ManifestServiceResolutionTests.swift`, `tools/test_integration_contracts.py` |
| Server URL guard | 36 pytest | `server/tests/test_signer_decoder_installer.py` |
| Log redaction | 5 Swift XCTest + 2 portable contracts | `VexSignTests/LogRedactionTests.swift`, `tools/test_integration_contracts.py` |
| Deep-link base64 staging | 6 Swift XCTest + 2 portable contracts | `VexSignTests/DeepLinkBase64StagingTests.swift`, `tools/test_integration_contracts.py` |

Swift XCTest cases are written but **not executed locally**; they require the macOS `tests` job.
The portable contracts, server pytest and Python simulations of the regex/base64 rules did run.

## 5. What was not verified

- `Build-verified`: no macOS/Xcode compile, generic unsigned iOS build or simulator XCTest on the
  current branch. The two compiler diagnostics are fixed and guarded, but a fresh green `ci.yml`
  run requires the user to commit/push.
- `Device-verified`: no physical iPhone, no real certificate/profile install, no launch
  confirmation, no force-quit fault injection, no device performance numbers. See deliverable E.
- CI workflow runs after the change: none, because no commit/push was made.
- Full upstream source audit: see deliverable B's limits.
- Production cloud signing, release trust key, TestFlight/Ad Hoc portal and native account
  promotion: intentionally gated, not tested as complete features.

## 6. Pass / fail / skip summary

| Suite | Passed | Failed | Skipped | Notes |
| --- | --- | --- | --- | --- |
| Portable `tools` unittest | 309 | 0 | 0 | local |
| `make verify` aggregate | exit 0 | 0 | 0 | includes 74 NativeSigning + 31 EmbeddedContainer |
| NativeSigning Python | 74 | 0 | 0 | local |
| EmbeddedContainer Python | 31 | 0 | 0 | local |
| Server pytest | 215 | 0 | 1 | `cryptography` optional skip |
| Cloud-signing Node | 14 | 0 | 0 | local |
| Swift XCTest (new + existing) | not run | not run | not run | requires macOS CI |
| Current-branch CI build/tests | not run | — | — | baseline run failed; no new run |
| Physical device acceptance | not run | — | — | no device |
