# Authorized real-device acceptance procedure

**This runbook is separate from structural tests.** Passing `.deb` inspection,
dependency resolution, XCTest fixtures, `make verify` or a local signature check
does **not** prove that a tweak works at runtime. No runtime compatibility claim
is made until the following procedure has been executed by the owner of the
device and the owner of the modified application.

## Preconditions

1. The tester owns the Apple Developer account/signing identity used and either
   owns the application or has written authorization to modify it.
2. The device is the tester's own and is enrolled for development signing. No
   enterprise, marketplace or guest runtime is used.
3. The imported `.ipa` and every `.deb` are recorded by name, version/provenance
   and SHA-256 in the test notes. No package script is executed on the host.
4. The modification plan is reviewed: selected bundle IDs, executable filters,
   package versions, dependency findings and nested targets are recorded.
5. The workspace is clean; the original import is preserved and its hash is
   recorded before the run.

## Execution

1. Build the plan in `TweaksView → Modify App with Tweaks`. Screenshot or export
   the preview and confirm every blocking finding is resolved.
2. Apply through the normal signing flow using the tester's own identity. Record
   the exact commit, signing identity type and the verifier verdict shown in the
   operation report. If verification fails, stop: do not install or relabel the
   output.
3. Install the verified output on the authorized device using VexSign's existing
   installation path. Record the device model, iOS version and build.
4. Launch the app. Record whether it launches, whether the expected UI change is
   observable, and whether any crash, safe-mode fallback or lost entitlement
   appears. Capture diagnostics with secrets and pairing data redacted.
5. Exercise the specific behavior the tweak claims to change. Repeat launch and
   the behavior at least three times. Record every run, including failures.
6. For nested targets, launch each app extension from its host app and record
   the result separately.
7. Verify that the untouched original import still has the hash from step 4 of
   the preconditions. Delete the signed test output from the device when the
   acceptance run is done; keep the original for the next reviewed run.

## Result labels

* **Accepted on this device/build** — only when all runs above succeeded and the
  verifier accepted the output. The statement must always name the device, iOS
  version, app version and tweak versions.
* **Rejected** — any launch failure, crash, missing behavior or verification
  failure. Record the operation report and rebuild the plan; do not generalize
  the result to other devices or app versions.
* **Not tested on device** — the default status for any structural build, CI run
  or simulator check. This is the only label available in this repository's
  automated checks.

No CI job, unit test or file in this repository substitutes for this procedure.
