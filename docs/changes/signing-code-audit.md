# Signing code-side audit and device handoff

Updated 2026-11-08. This records source inspection and portable checks, **not** a
successful Xcode build, native-engine execution or device installation.

## Inspected path

`SigningService` → `SigningPipeline` → `SigningHandler` → `ZsignHandler` →
`ZsignEngine` → pinned Zsign Swift/C++ wrapper → `SignatureVerifier` → storage.

- The pinned C++ entry returns zero on success and -1 on failure. Its Swift
  wrapper converts nonzero into false. Asset initialization failure is therefore
  rejected even when there is no callback error message.
- Outcome acceptance is centralized in `Outcome.requireSuccess`: either a false
  result or any non-nil error message rejects the run. Contradictory success plus
  an error is still failure. ZsignHandler records and rethrows rejection.
- Input executable containment is checked before native execution and rechecked
  after acquiring the execution gate. Entitlements are likewise rechecked.
- Signature inspection precedes moving/registration. Cancellation is checked
  after native execution and before registration. Existing commit-point cleanup
  preserves a committed row rather than deleting its bundle after commit.
- Registration requires an actual bundle, a nonempty current on-disk identifier
  and a contained readable regular executable. It does not rely on a previously
  cached Bundle identifier.
- Post-sign executable checks use the same containment validator as native input.
  CodeResources must be a readable regular file, not a directory or symlink.
- Sign Anyway no longer bypasses every verification failure. Only profile expiry,
  profile/app identifier incompatibility, uncovered nested identifiers and
  entitlement incompatibility may be explicitly accepted. Missing structural
  evidence and a requested identifier that was not applied remain blocking.
  Compatibility risks remain in the report; accepting them does not prove that
  iOS will accept the app.

## Regression coverage added

Ten new XCTest methods cover native outcome combinations, the override allowlist,
mixed structural/compatibility failures, ignored requested identifiers, external
executable symlinks, empty identifiers, and directory/symlink CodeResources.
The earlier profile-override test now uses an actual profile mismatch instead of
an ignored requested identifier. Existing lifecycle, cancellation, gate and input
validation XCTest cases are retained.

Portable `make verify` and `git diff --check` passed after these changes. An
independent tree-sitter Swift grammar parsed ten signing-related production/test
files without syntax errors. This parser does **not** resolve types, actors,
imports, linking or Apple APIs. Xcode/Swift are unavailable here, and the XCTest
cases above have not executed. The 74-test native-preparation suite reported by
portable verification is not an end-to-end signing suite.

## Device handoff

First build the current working tree in Xcode and run `make test` on macOS/Xcode.
Do not treat an older IPA or a build of the unchanged base commit as evidence for
these edits.

1. Use a test app you control with a known-valid certificate/profile. Start with
   default signing, no tweaks and experimental modifications disabled. Confirm
   the log reaches sign → verify → register, then export, install and launch it.
2. Repeat with a changed bundle identifier covered by the selected profile.
3. Use a wrong P12 password and an unrelated profile. Expect a visible failure,
   no newly registered successful app, and no orphan working bundle.
4. Test a covered extension/framework app. Check logs for compatibility removals
   and warnings; confirm the retained extensions work after installation.
5. Cancel during copy, while queued for native execution, and after native signing
   but before registration; retry. Ensure the original remains intact, no duplicate
   rows appear and later jobs do not get stuck waiting for the gate.
6. Test Sign Anyway separately. Structural failures must still reject output;
   accepted profile risks must remain visible and can still fail installation.
7. Relaunch VexSign and verify the resulting library record, identifier, certificate
   association and exported IPA remain consistent.

The verifier is structural/profile inspection, not a CMS or full CodeDirectory
hash re-verification. Unknown evidence and some unsigned nested bundles are still
warnings. Native signing, Core Data concurrency, Apple certificate acceptance,
entitlement enforcement and actual launch remain Apple-toolchain/device checks.
A source audit cannot establish that signing works perfectly for every IPA.
