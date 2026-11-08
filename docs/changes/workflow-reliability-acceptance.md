# Workflow design and device test procedure

> Design and test instructions only. Current verdicts and release gates live in
> the sole [Validation and acceptance](feature-validation-status.md) record.

## Implemented

- One shared phase vocabulary for import, ready-to-sign, signing, signed,
  installation preparation, waiting for iOS, installing, verifying, completion,
  failure and cancellation. Terminal attempts cannot reopen. Signing cannot
  transition into installation; those operations have separate records.
- Timestamped, bounded stage histories survive relaunch, with backward-compatible
  decoding of old task history. Signing records identify the registered artifact,
  a hashed certificate reference and a deterministic options fingerprint. Raw
  options, identity material and passwords are not recorded. Import/sign/install
  records are linked locally by artifact and originating task references.
- One installation record per app/attempt, including batches. Retry keeps the
  original result instead of leaving an orphan queued record. Failed installation
  retries reuse the signed copy and do not invoke signing. A stale retry action
  cannot operate on a different current app.
- Task Details and installation failure UI expose View Report and Copy Redacted
  Report. Reports allowlist version/build, method, source revision, timestamps,
  elapsed times and typed outcome evidence. They omit raw errors, app names,
  bundle IDs, paths, URLs, file contents and credentials. Unknown metadata is
  reported as unavailable, not guessed. Raw local errors remain separately
  visible after redaction.
- About displays the source revision. Makefile IPA and CI builds stamp the actual
  checked-out Git revision into Info.plist without changing CFBundleVersion.
- Successful native installation-proxy command acknowledgement is authoritative
  device evidence; it is no longer vetoed by sandbox-filtered LaunchServices.
  OTA still requires installed-app evidence and cannot complete from progress
  alone. Confirmed outcomes update card and badge through the same finish path.
- Three Library partitions remain. Unsigned context actions include Sign and
  Sign & Install; signed actions retain Install, Re-sign and Export. Advanced
  network/pairing configuration remains in its existing Settings screens.

## Sensitive-material review

| Area | Result / boundary |
| --- | --- |
| Certificate passwords | Existing device-only, non-synchronizing Keychain storage and fail-closed migration retained. No secrets added to task context. |
| Managed P12/profile files | Migrated from shared Documents to protected, backup-excluded Application Support. UUID-directory collisions are preserved privately, never overwritten. Newly copied files receive protection and restricted permissions. User-selected original files are not deleted. |
| Pairing records | Shared path centralized; legacy Documents record moves to protected, backup-excluded Application Support. Existing newer credentials are never overwritten; older copies are preserved privately. Background use after first unlock remains supported. |
| Migration failures | Files are retained, not discarded. Locked/unwritable storage can defer migration and fall back to the existing location. This is not a promise that every legacy file has migrated before first unlock. |
| Logging/reporting | Added PEM, pairing-plist and cookie masking. Task receipts export allowlisted evidence rather than arbitrary error strings. Existing legacy logs may still exist until cleared. |
| Temporary IPAs | Existing archive leases, cancellation acknowledgement and cleanup-on-error retained. Installation failure never stages that app for delete-after-install cleanup. Auto-install signing consumers retain their signed copy; explicit user deletion/cleanup settings otherwise remain respected. |
| Security checks | Archive validation, certificate/profile checks, signatures, checksums and dependency verification were not disabled. |

This is a focused code review and hardening pass, not an independent security
certification. Protection after first unlock supports background operation; it
is not equivalent to requiring an unlocked device for every subsequent read.

## User device test procedure

Record results only in [Validation and acceptance](feature-validation-status.md),
with the exact source SHA, IPA hash and device/iOS version. The scenarios below
are instructions, not claims that tests have passed.

Use the unpublished IPA built from the final PR head. In Settings -> About,
verify Source commit matches the build's recorded source SHA. Keep the same IPA
for the whole matrix and attach a copied report for each unexpected result.

| Scenario | Expected result |
| --- | --- |
| Import -> Sign only | Ready to sign then Signed; retained signed artifact; no automatic iOS installation prompt. |
| Fresh Sign & Install | Signing result recorded independently; approve iOS prompt; Completed only on device evidence; card dismisses. |
| Same-version reinstall | New install activity/container evidence can complete; an unchanged pre-existing app alone cannot prove success. |
| Version update | Device reports target version; old-version evidence is not silently labeled the target version. |
| Invalid/rejected certificate | Signing failure never queues an install; a device rejection never becomes success from progress alone. |
| Declined prompt / Skip | No false completion; skip cancels this attempt without corrupting another entry or its report. |
| Large IPA / slow transfer | UI responsive; transfer does not consume install-start timeout; app resumes correctly after foregrounding. |
| Failed install -> Retry Install | Existing signed artifact reused, no new signing run; original failure report retained. |
| Batch with success and failure | Separate per-app results; earlier failure cannot relabel a later successful attempt. |
| Native pairing install | Native command success completes without a second sandbox lookup; command errors never count as success. |
| Legacy credentials after upgrade | Existing identities/pairing still usable after unlock; managed copies no longer remain in shared Documents on successful migration. |
| Copy report / relaunch | Stage history survives; report includes safe build/evidence fields, no passwords/keys/pairing contents. |

Record each observed outcome against the exact IPA source in the authoritative
acceptance record. Coding or CI alone cannot establish a device result.
