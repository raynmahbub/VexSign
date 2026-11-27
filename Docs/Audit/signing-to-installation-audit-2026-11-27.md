# Signing-to-installation pipeline audit — 2026-11-27

Scope: `main` at `8083ac4` (branch `arena/0443ad57-vexsign`, same commit). Follow-up to
GitHub issue #307 and the deep-audit brief dated 2026-11-27.

Evidence labels:

- **Verified (here)** — command executed in this Linux sandbox; result stated.
- **Verified (GitHub)** — read from the GitHub API for a specific run.
- **Source-verified** — the file and symbol were read; no compile or runtime result is implied.
- **Device required** — needs a physical iPhone, a real Apple-issued identity, or a real IPA.
- **Not verified** — could not be checked from this environment.

No application source was changed by this audit. This file is the only addition.

## 1. CI state of 8083ac4

| Claim | Evidence | Status |
| --- | --- | --- |
| 8083ac4 pins `@types/node` to the Node 22 line | `git diff be8120b 8083ac4` changes exactly `Services/Cloud/package.json` (`^26.6.6` → `^22.20.7`) and `package-lock.json`. `Services/Cloud/Dockerfile` uses `node:22-bookworm-slim`; `package.json` `engines.node` is `>=22`. | Verified (here) |
| `make verify` (the job that failed in run 45950476617) passes | Ran `make verify` on 8083ac4: exit 0, 90 gates passed. `test_runtime_policy.py`: 7 tests OK. | Verified (here). Swift syntax gate skipped: no `swiftc` in this sandbox. |
| Cloud service suite passes | `npm ci`, `npm run build`, `npm test`: 44 tests, 42 pass, 0 fail, **2 skipped** (`infrastructure.integration.test.ts`, gated on `TEST_DATABASE_URL` / `TEST_REDIS_URL`). | Verified (here) |
| Service checks on 8083ac4 are green on GitHub | Run `45951994330` (`Service checks`, push): `cloud`, `pytest · server`, `swift build · anisette mock` all `success`. | Verified (GitHub) |
| The two Postgres/Redis integration tests ran (not skipped) on GitHub | `services.yml` provides Postgres 17 and Redis 7 and sets both URLs. Run logs could not be downloaded (`gh run view --log` returned nothing), so the skip count on GitHub is unknown. | Not verified |
| The native-host check (`Combined native host · build only`, `embedded-container.yml`) passes on 8083ac4 | **No run exists for 8083ac4.** `embedded-container.yml` only triggers on paths that do not include `Services/Cloud/**`, and 8083ac4 only touches `Services/Cloud/`. The commit therefore shows no green native-host check; it is absent, not passing. | Verified (GitHub: no run) |
| The main `CI` workflow passes on 8083ac4 | No `CI` run exists for 8083ac4 for the same reason (`ci.yml` paths do not cover `Services/Cloud/**`). | Verified (GitHub: no run) |
| Issue #307 is closed | Still `OPEN`. Its body says to close only when `main` is green again. | Verified (GitHub) |

**Conclusion.** The Node type mismatch is fixed and the cloud job is green on GitHub.
The failing native-host check has not been re-run on the fixed code. Its absence on
8083ac4 looks like green, but the path filter means it never ran. Issue #307 should stay
open until the native-host check runs on a commit that includes this fix.

**Acceptance criterion A1.** Dispatch `embedded-container.yml` (`checks` job, `make verify`) against
8083ac4 or its successor and record a `success` conclusion before closing #307. This starts macOS
jobs, so it needs approval: `gh workflow run embedded-container.yml --ref arena/0443ad57-vexsign`.

## 2. Pipeline trace and findings

Stages: import → certificate/identity resolution → signing (Zsign) → post-sign verification →
installation (OTA `itms-services`; paired AFC/`installd` gated).

### 2.1 Import and identity resolution — source-verified

- `SigningPipeline.run` checks identity policy before signing (`VexSign/Services/Signing/Execution/SigningPipeline.swift:25`).
- `SigningIdentityPolicy.rejection(for:)` refuses a missing certificate. The test
  `FullSignPipelineIntegrationTests.testImportAndMissingIdentityRefusalPreserveTheSourceWithoutInstalling`
  asserts that the source bundle is unchanged after refusal. This is the only signing-path behaviour the
  full-pipeline test exercises (see F-3).

### 2.2 Signing engine — source-verified

- `ZsignEngine.sign(_:)` (`VexSign/Services/Signing/Engines/Zsign/ZsignEngine.swift:159`) is the
  single seam to the vendored Zsign package. Its cache directory is resolved from the process
  working directory (`./.zsign_cache`), not from the bundle, so two runs from different directories
  do not share cache entries (line 205–210). Refusal and identity checks run before the engine.

### 2.3 Post-sign verification — source-verified, strong

`SignatureVerifier.verify` (`VexSign/Security/CodeSigning/SignatureVerifier.swift:213`) for fresh
output does the following:

- Requires `_CodeSignature/CodeResources` to be a regular, readable, non-symlink file (`missingCodeResources`).
- Requires the main executable to carry a code signature (`unsignedExecutable`).
- Checks nested bundles, profile coverage, expiry, and entitlements (`_nestedIdentifierIssues`,
  `_entitlementIssues`).
- `SignatureVerifier+Seals.swift` verifies each image's CodeDirectory, special slots and page hashes
  (`verifyExecutable`, `verifyDirectory`), the resource seal (`verifyResources`, SHA1 and SHA256), and
  the CMS signature.
- The CMS chain is anchored to a pinned Apple root fingerprint in
  `Packages/Vendor/Zsign/src/openssl_tools.mm:132–169`. The code requires exactly three chain
  elements and a root whose SHA-256 is `b0b1730e…f024`. The CMS certificate list is explicitly not a
  trust anchor.

`SigningVerificationReportBuilder.make` (`…/Verification/SigningVerificationReportBuilder.swift`)
takes its verdict from the verifier, not from display metadata. Its signer fingerprints come only
from the main executable, and this is display-only.

Tests: `SignatureVerifierTests` (≈30 cases, including
`testFreshOutputRequiresVerifiedEvidenceWhileImportInspectionCanRemainIncomplete` and
`testFreshModeUsesIndependentCryptographicSealsNotImportStructure`), `SignatureSealTests` (uses
`CodeSignatureCMSFixture.json`), `SigningVerificationReportTests`.

**Not verified:** these tests are Swift and have not been compiled or run here (no Xcode).

**Device required:** a real Apple-issued Development or Free identity has not been run through this
verifier in any recorded test. The pinned root is verified against synthetic chains and one recorded
CMS fixture, not a live iPhone-signed IPA (see F-2).

### 2.4 Installation — source-verified, mostly gated

- `InstallationAppProxy.hasAcceptedInventoryBridge` is hard-coded to `false`
  (`Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift:12`).
  Every paired-install preflight (`InstallPreflight.swift:37`, `AppInstaller.swift:354`,
  `DeviceConnectivity.swift:382`, `PairingBridge.swift:88`) therefore reports paired installation
  unavailable. `README.md:342` documents this gate; the feature bullet at `README.md:53` does not.
- Install outcome is conservative: `InstallVerdictPolicy.outcome(for:)`
  (`VexSign/Services/Installation/Installation/InstallVerdictPolicy.swift`) maps
  `installedOtherVersion` to `.anotherVersion` rather than success, and `notInstalled`/timeouts to
  `.notConfirmed`.
- OTA installation is served over local HTTPS via `ServerInstaller` and `ManifestService`.
  **Device required:** nothing in this sandbox proves iOS accepts the served manifest.

### 2.5 Cloud signing — source-verified, infrastructure only

`Services/Cloud/Signing/Worker/processor.ts` (`runSigner` at line 259):

- Claims the job atomically (`queued → running`), creates a `0700` temp directory, deletes it in
  `finally`, and sets `input.password = ''` after the launcher returns (a JS string cannot be wiped).
- Checks the output: `lstat` (must be a regular file with one link, not a symlink, 4 B to 2 GiB), the
  ZIP magic `PK\x03\x04`, and a SHA-256 match with the launcher's `outputSha256`.
- `signer.ts` (`invokeSigner`) launches the administrator's executable with `shell: false`, a fixed
  environment, stdin-only secrets, a 10-minute timeout, and a 1 MiB stdout cap.

**Gap (F-1).** `signatureVerified: z.literal(true)` in `signer.ts:11` is validated but never checked by
the worker. The worker never inspects the signature. It accepts any IPA whose bytes match the hash the
launcher reports. A launcher that signs nothing and reports the hash of an unsigned ZIP produces a
`completed` artifact.

**Gap (F-4).** `Examples/mock-signer.mjs` is a non-signing fixture. `Services/Cloud/README.md:46–72`
says it must not be used for acceptance, but nothing prevents a deployment from pointing
`SIGNER_EXECUTABLE` at it.

## 3. Findings

Severity: High = can produce a false success or a false capability claim; Medium = missing evidence;
Low = documentation drift.

| ID | Sev | Finding | Where | Failure scenario | Regression test to add |
| --- | --- | --- | --- | --- | --- |
| F-1 | **High** | Cloud worker trusts the launcher's `signatureVerified` and never verifies the output signature. | `Services/Cloud/Signing/Worker/processor.ts` (~l.277–300); `Signing/CloudSigningCoordinator/signer.ts:11` | Launcher returns an unsigned, correctly hashed ZIP with `signatureVerified: true`. The job completes and the artifact is served to the user. | Fake launcher returns a valid ZIP whose hash matches but whose signature is absent. Expect `failed` / `INVALID_OUTPUT`. Requires an independent verifier (see A3). |
| F-2 | **High** | No automated test runs the real sign-then-verify path on fresh output. The pinned Apple root blocks a locally generated chain, so the verifier cannot be exercised end to end in CI. | `openssl_tools.mm:162–164` (hard-coded root); `FullSignPipelineIntegrationTests.swift` (no `ZsignEngine` call); `SigningRegressionFixture.swift` ("Generated, non-runnable code") | A regression in Zsign nested-bundle signing (for example, `.appex` not re-signed) passes every portable and unit test and is only caught on a device. | Add a Debug/test-only root-pin override (compiled out of Release) so a generated chain can run the real `SignatureVerifier.verify(.freshlySigned)`. Test: sign a bundle with an `.appex`, expect `verdict.isVerified`; then mutate one resource byte, expect `resourceSealInvalid`. |
| F-3 | Medium | The test named "full sign pipeline" does not sign. It covers refusal, task tracking, import and repacking. | `VexSignTests/IntegrationTests/SigningWorkflow/FullSignPipelineIntegrationTests.swift:18–168` | The suite stays green while signing is broken. | Rename to reflect scope, or add the signing case from F-2. |
| F-4 | Medium | Mock signer can be deployed as the production launcher, and nothing enforces the boundary. | `Services/Cloud/Examples/mock-signer.mjs`; `Configuration/config.ts:13` (`SIGNER_EXECUTABLE` only checks it starts with `/`) | A deployment with the example launcher reports `completed` for every job. | At startup, refuse a launcher whose path matches the example or whose protocol version mismatches. Test in `Services/Cloud/Tests/`. |
| F-5 | Medium | The two Postgres/Redis integration tests skip whenever their URLs are unset. | `Services/Cloud/Tests/infrastructure.integration.test.ts:13,64` | A skip is reported as passed locally and in any job without the services. | Make `services.yml` fail if the output contains `# SKIP` for these tests, or invert the default so CI always requires the URLs. |
| F-6 | Medium | Paired installation is unavailable in every build, but the feature list does not say so. | `README.md:53` vs `README.md:342`; `IDeviceKitten/…/InstallationAppProxy.swift:12` | A user reads the feature list and expects paired install. | Add the gate to the feature bullet; add a check that the bullet and `hasAcceptedInventoryBridge` agree. |
| F-7 | Medium | The native-host check is path-filtered and does not run for `Services/Cloud/**`, so a commit can look green without running it. | `.github/workflows/embedded-container.yml` `on.push.paths` | Issue #307 cannot be closed by any push that touches only the cloud package. | Add `Services/Cloud/**` to the path list, or require a manual dispatch before closing #307. |
| F-8 | Low | The Nov 26 audit (`Docs/Audit/complete-implementation-verification-2026-11.md`) describes an older branch. Its F-050 (invalid `for name where` in `InjectionTargetAuthorization.swift`) is **fixed on this tree** (line 37 now reads `for name in names where …`). | Verified in source. | Readers may treat F-050 as open. | Mark the older audit as historical in its header. |

Native Apple Account signing (not repeated above): `SigningMethodCapabilities.swift` keeps
`nativeAppleAccountSigning` and `vexSignPrimaryHost` at `.notIntegrated`, and the flag is correct. The
promotion gate `Tools/Validation/security-validation/check-native-handoff.py` requires committed
device evidence (`evidence/native-signing-promotion.json`, currently absent) before the flag may move.
`renewFreeAppleIDProfiles` is documented as non-renewing (`BackgroundAutomation.swift:385`). Both claims
match the source. Flipping the flag now would fail the gate.

## 4. Acceptance criteria for the next iteration

Each row needs evidence before the corresponding claim changes.

| # | Workstream | Evidence required | Current state |
| --- | --- | --- | --- |
| A1 | Native-host CI on current main | Successful `embedded-container.yml` run on the fixed commit; #307 closed only after it | Not run (F-7) |
| A2 | Full CI on current main | `ci.yml` `quick`, `build`, `tests`, `concurrency` green on a commit touching `VexSign/**` | Not run on 8083ac4 |
| A3 | Cloud output verification | Worker verifies the signature independently and rejects F-1 fixture | Missing |
| A4 | Cloud integration without skips | `services.yml` cloud job with Postgres and Redis, zero skips in the log | Unknown (F-5) |
| A5 | Fresh-output verification in CI | F-2 test passes on a macOS runner | Missing |
| A6 | Installation on device | OTA install, launch, in-place update, removal on an authorized iPhone | Device required; no result |
| A7 | Native Apple Account | `native-signing-promotion.json` complete and committed | Absent, as designed |

## 5. Verification run

- `make verify` on 8083ac4: exit 0, 90 gates.
- `Tools/Validation/repository-validation/test_runtime_policy.py`: 7 tests OK.
- `Services/Cloud`: `npm ci`, `npm run build`, `npm test` — 42 pass, 0 fail, 2 skipped (no database or Redis locally).
- Not run: `xcodebuild`, Swift unit or UI tests, `swiftc` syntax check, physical device tests.

## 6. Remediation applied on this branch

| Finding | Status | What changed | What remains |
| --- | --- | --- | --- |
| F-1 cloud trusts launcher signature claim | **Partly closed** | `Services/Cloud/Signing/Worker/ipaSeal.ts` (new) is called by `processor.ts` before upload. It validates the ZIP (no symlinks, traversal, encryption, zip64; CRC and size per entry), requires one app bundle, checks every file against `_CodeSignature/CodeResources` (SHA-1 and SHA-256), honours `rules2` omit entries, checks nested bundles that carry their own seal, and requires one root Mach-O. | The CMS signature and certificate chain are still not verified by the worker: Node has no Apple-root CMS verifier. The launcher must keep owning that, and the report must not say the worker verifies signatures. |
| F-2 no fresh-output sign-then-verify test | Open | Not changed. The Swift test seam needs a compiler to validate. | Needs a test-only root-pin override (Debug/test builds only) and a macOS run. |
| F-3 misleading "full pipeline" test | Documented | Scope comment added to `FullSignPipelineIntegrationTests.swift`. Class not renamed (project references not checked without Xcode). | Rename, or add the F-2 case. |
| F-4 mock signer deployable | **Closed** | `isProductionSigner` and `assertWorkerSigner` in `Configuration/config.ts`. `worker.ts` refuses to start with the mock, a missing file, or a non-executable launcher. The API still loads without a launcher. | None. Tests: `Tests/signer_config.test.ts`. |
| F-5 skipped integration tests pass silently | **Closed in CI** | `services.yml` cloud job now fails if any test reports `# SKIP` or `# skipped N`. | Not verified on GitHub. Postgres and Redis are not available in this sandbox, so the two tests were not run here. |
| F-6 paired install not gated in feature list | **Closed** | `README.md` feature bullet now states paired install is disabled in every build. | None. |
| F-7 native-host check skipped cloud changes | **Closed** | `embedded-container.yml` now triggers on `Services/Cloud/**` for push and pull request. | Cost: cloud-only changes now start the macOS build job too. Narrow it if that is too expensive. |
| F-8 stale audit read as current | **Closed** | Historical banner added to `Docs/Audit/complete-implementation-verification-2026-11.md`. | None. |
| A1 native-host run on current code | Open | Not dispatched: it starts macOS jobs and needs approval. | `gh workflow run embedded-container.yml --ref arena/0443ad57-vexsign`, then confirm #307 can close. |

### Verification run for this section

- `Services/Cloud`: `npm run build` ok; `npm test` 62 tests, 60 pass, 0 fail, 2 skipped (env-gated, no Postgres or Redis here); `npm run contracts` ok, `openapi.json` unchanged.
- `make verify`: 90 of 90 gates pass, including `docs-check`.
- `make docs-check`: pass after the README and audit header edits.
- `Services/WebManager/Tests` (Python, in a venv with `Configuration/requirements.txt`): 350 passed.
- Not run: `xcodebuild`, Swift tests, `swiftc`, Postgres/Redis integration, physical device. The workflow YAML was checked by `make verify`, not by a YAML parser, because PyYAML is not installed here.
