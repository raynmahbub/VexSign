# Validation and acceptance

This is the **authoritative acceptance record** for the workflow-reliability and
maintenance changes. Implementation notes and historical test counts elsewhere
are not evidence of acceptance. Updated 2026-11-08 for [PR #134](https://github.com/raynmahbub/VexSign/pull/134).

## Source and evidence

Evaluated runtime source: **`1eb8f74c652a4dce37583a7ce6ba11d4a6ad4d87`**.
The Step 6 documentation patch does not change runtime/test code. This table is
an explicitly pinned observation, not a live claim about later PR heads.

- **Implemented**: the production path is wired; not a build/test/device verdict.
- **Portable passed**: `make verify` and `git diff --check` passed at the evaluated
  source. The portable Python suite reported 74 tests. These are not iOS tests.
- **Grammar passed**: separate tree-sitter Swift parsing passed for changed Swift
  files. `make verify` on this Linux host does not compile Swift. Grammar parsing
  does not establish Apple SDK typechecking, linking or XCTest execution.
- **Apple pending**: at this observation, the evaluated source's Debug build and
  simulator-test jobs were in progress in [CI run 42527282445](https://github.com/raynmahbub/VexSign/actions/runs/42527282445).
  Its quick gate passed. [Documentation run 42527282442](https://github.com/raynmahbub/VexSign/actions/runs/42527282442)
  passed. Neither quick nor documentation success establishes an Apple build.
- **Device pending**: no physical-device acceptance or IPA hash is recorded here.
  The user performs device testing after a build is available.

Cancelled earlier runs do not validate later commits. No successful Apple result,
artifact or device result from an earlier revision is carried forward as a pass.

## Acceptance table

Every validation column below refers to the evaluated source above, not merely
the implementation checkpoint. `Baseline` means present in merged PR #133's
`b599320694fa3fb19797fb45a203cacf2c1d8d2a`; it is not a claim that all baseline
features originated in that commit. Native-test counts mean **added**, not run.

| Area / implementation checkpoint | Implementation and boundary | Portable / grammar | Apple compilation / native tests | Device acceptance required |
| --- | --- | --- | --- | --- |
| Baseline: signing, import and native execution | Wired; request-scoped ownership, native gate, archive/input checks and cooperative cancellation. Experimental account provisioning is not full production parity. | Passed / passed for changed Swift only | Pending | Pending: valid/invalid identities, tweaks, concurrent jobs, cancellation, large/malformed archives and Files providers. |
| Baseline: install evidence and queue | Wired; native command acknowledgement is evidence; OTA needs installed-app evidence. Unknown OTA lookup is bounded and does not imply success/failure. Stop Monitoring may not stop work accepted by iOS. | Passed / passed for changed Swift only | Pending | Pending: fresh install, reinstall/update, rejection, slow transfer, filtered lookup, stop/skip and mixed-result batch. |
| Baseline: resource ownership and disk preflight | Wired; process-local per-copy leases and conservative capacity estimates, not reservations or cross-process locks. | Passed / passed for changed Swift only | Pending | Pending: competing same-copy actions, independent copies, cancellation lifetime and low disk. |
| Baseline: reports, credentials and build provenance | Wired; allowlisted receipts, protected managed identities/pairing, embedded revision and artifact hashes. Required attribution remains in source/license notices. | Passed / passed for changed Swift only | Pending | Pending: report privacy, legacy migration after unlock, exact IPA revision and SHA256SUMS verification. |
| Baseline: backup/restore, exports and pairing transport | Wired; incremental restore, bounded streaming and scoped transport resources. Not a transactional whole-library snapshot or full parity. | Passed / passed for changed Swift only | Pending | Pending: restore/remapping, partial failure, repeated exports, real AFC transport and low storage. |
| Baseline: offline icons and OTA lookahead | Wired; thumbnails for successful new imports, one-app packaging lookahead, no concurrent OTA prompts. | Passed / passed for changed Swift only | Pending | Pending: offline/relaunch/history clearing; lookahead pause/skip/retry/settings changes and response cancellation. |
| Step 1: `5cca0b6` | Recoverable deletion; quarantine → isolated database commit → cleanup; unavailable/conflicting recovery evidence is retained. Seven native tests added. | Passed / passed | Pending / not confirmed executed | Pending: interruption before/after commit, failed save/purge, locked storage and unrelated unsaved edits. |
| Step 2: `e7326ed` | Explorer edit/rebuild leases; stale workspaces refused. Does not lock read-only previews or external writers. Four native tests added. | Passed / passed | Pending / not confirmed executed | Pending: each file action plus text/plist saves against signing/install/delete; successful retry and rebuild cancellation. |
| Step 3: `330d756` | Ordered background journal IO; malformed data preserved, access failures block replacement, live tasks merged after load. Queued writes can be lost on forced exit; atomic replacement is not power-loss certification. Seven native tests added. | Passed / passed | Pending / not confirmed executed | Pending: lock/unlock, low storage, unreadable history, clear during load, rapid transitions and forced exit/relaunch. |
| Step 4: `e0eedee` | Allowlisted migration warnings and safe password-cleanup ordering. Unmigrated originals retained; file permission errors are not proof of lock. Eight native tests added. | Passed / passed | Pending / not confirmed executed | Pending: Keychain access denial, file permissions, low storage, partial migration, retry and warning privacy/resolution. |
| Step 5: `1eb8f74` | First bounded extraction: stateless notification builder behind unchanged DownloadManager methods. Not a rewrite of every large manager. Eight native characterization tests added. | Passed / passed | Pending / not confirmed executed | Pending: fallback notification text/sound, paused/import-only state, completion, and Live Activity preference without duplicate notifications. |

Step 6 consolidates the status here and archives the previous integration log.
Steps 1–5 have implementation checkpoints; none is promoted to Apple/device
acceptance by completing this documentation step. The five checkpoints added
**34 native test methods** in total; this count is not an execution result.

## Updating evidence and release gate

1. Record the **full tested source SHA**, exact CI run/job URLs, conclusion and
   test result bundle. Check the run's `headSha`; do not infer success from a
   downloadable IPA or a different workflow/run. A later head needs new evidence.
2. Run `make verify` and `git diff --check`; record any separate grammar check as
   such. On macOS, require the intended source's Debug build and simulator XCTest
   job to pass. A skipped/cancelled test job is not a pass. Never merge based on
   this table's implementation column alone.
3. For device acceptance, record IPA filename, SHA-256, BUILD.json source revision,
   device/iOS version, scenario and observed outcome. Verify Source commit in
   About and the artifact's SHA256SUMS; unsigned CI IPAs require appropriate
   re-signing before installation. Do not guess an artifact revision from its name.
4. Run the scenarios in the table and the [workflow device procedure](workflow-reliability-acceptance.md#user-device-test-procedure).
   Attach redacted reports for unexpected results; never attach passwords,
   private keys, pairing records or credential-file contents.
5. Update this table's Apple/device cells only from that exact evidence. Preserve
   the old source/run as historical context if the head changes. PR #133 is
   already merged; the current review is PR #134. This document does not authorize
   merging or publishing either a build or a release.

## Implementation references (not parallel status records)

- [Historical integration notes at `e122b18`](https://github.com/raynmahbub/VexSign/blob/e122b18/docs/changes/feature-integration-history.md): previous feature scope and maintenance design details, retained in Git history.
- [Recovery and verification design](recovery-and-verification.md): ownership,
  disk estimates, restart recovery and install evidence semantics.
- [Workflow design and device procedure](workflow-reliability-acceptance.md):
  reporting/privacy boundaries and scenario instructions, not current verdicts.
- [Signing and installation lifecycle](signing-and-installation-lifecycle.md):
  later changes to signing-task state, install confirmation, re-signing with
  saved settings, install verification, and which library copies a sign and a
  cleanup pass leave. **Not evaluated in the table above.**
  Its own sections say what was run, what was not, and which device scenarios
  are outstanding; they are implementation notes, not acceptance.
- [Device testing](../../QA/DEVICE_TESTING.md), [build guide](../BUILD.md),
  [third-party adaptations](../../Security/THIRD_PARTY_ADAPTATIONS.md).
