# Signing workspace build-readiness audit

Date: 2026-11-01. Branch: `arena/a2198363-vexsign`.

## Status

Local static audit completed; **not compiler-validated or release-ready**.
This sandbox has no `swift`, `swiftc` or `xcodebuild`. No unit/UI tests were
executed and no device behavior is claimed as verified.

## Findings addressed

### Duplicate-import modal sequencing

Previously, alert actions invoked their import completion before UIKit finished
alert dismissal. Quick Sign could then attempt a cover, or the next queued import
could attempt another alert, during the transition. The queue also lacked explicit
processing state to guard a reentrant completion that enqueues another import.

- Replaced the fixed 350 ms queue delay with dismissal transition completion.
- Nonanimated paths use UIKit's dismissal completion callback.
- Only a transition originating from the alert counts as its dismissal.
- Weak alert captures avoid action/alert retain cycles.
- Keep processing state through callbacks; advance the queue on the next run-loop
  turn. Reentrant callers enqueue rather than starting a second presenter.
- Resolve and recheck the existing Library object, hidden status and lock state
  after dismissal, before discarding the new copy.

UIKit presentation failure, backgrounding and simultaneous manual imports still
need a physical-device check. When no safe presenter exists, the implementation
retains the new copy rather than deleting anything implicitly.

### Preflight review can become stale

The selected certificate index can refer to a different row if the certificate
collection changes while review is visible. Options or preflight issues could
also change before acceptance.

- Capture reviewed options, certificate UUID and issues in a value snapshot.
- Re-run preflight after review dismissal, before starting the pipeline.
- Require all three to match. Otherwise do not start; ask for another review.
- Added unit cases for unchanged review, changed options, changed/missing identity,
  changed issues and certificate-free modes.

This is not a source-file fingerprint or certificate-byte digest. Mutation of
files without changed preflight results is not detected.

### Deferred automatic-install action ordering

The log-sheet dismissal handler previously executed its deferred completion before
clearing the stored closure. It now takes and clears the action first, matching
the manual result completion path and reducing reentrant duplicate execution risk.

## Structural/tooling checks

- `make verify`: passed; 402 Swift files scanned, 2,769 localization keys.
- `git diff --check`: passed.
- Supplementary tree-sitter parse: 51 changed/new Swift files, zero syntax errors.
- Project uses filesystem-synchronized app/test groups, so these new source files
  do not require hand-added PBXBuildFile entries for the iOS app/test group.
- Existing CI supports unsigned app compilation and simulator tests. Its workflow
  is `.github/workflows/ci.yml`, not the stale `build.yml` reference in the syntax
  helper's introductory comment.
- Native glass APIs require an Xcode 26 SDK despite their runtime availability
  checks. Xcode 16 cannot compile references to unavailable SDK symbols.

These checks do not establish SwiftUI type inference, actor-isolation correctness,
SDK availability correctness or successful linking.

## Next macOS checks

Use Xcode 26 (or the compatible version selected by existing CI).

```sh
xcodebuild -workspace VexSign.xcworkspace -scheme VexSign \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

xcodebuild -workspace VexSign.xcworkspace -scheme VexSignTests -showdestinations
```

Then select an available simulator destination from that output and run the
`VexSignTests` scheme. CI already resolves a simulator at runtime; do not hardcode
a device name or UDID that may not exist on another machine.

## Device acceptance gates

1. Open/close preflight; confirm, cancel, override and return to options. Change or
   remove a certificate while review is open: signing must require another review.
2. Sign with logs closed/open; stop at several stages; retry after failure.
3. Manual Done/Install/Share/View in Library under each cleanup preference; automatic
   install with logs closed/open. No duplicate completion or premature deletion.
4. Import multiple matching/nonmatching IPAs; choose both outcomes; try reentrant
   Quick Sign, backgrounding, removed existing entries and locked/hidden entries.
5. Repeat-sign expiry and missing-certificate review. Existing alternate repeat-sign
   shortcuts still do not all use the new review; source fingerprinting remains open.
6. iOS 16 opaque fallbacks and iOS 26 native glass; Dynamic Type, RTL, VoiceOver,
   Escape/Command-A and small-screen/iPad action layouts.

Release TLS pin review and dependency review remain separate existing release gates.

## Executed testing — 2026-11-01

| Scope | Command | Result |
|---|---|---|
| Python server | isolated venv, pinned server requirements + pytest + cryptography; `python -m pytest tests/ -q` from server | **85 passed**, no skips, 1 deprecation warning |
| Cloud signer types | `npm run check` | Passed |
| Cloud signer tests | `npm test` | **12 passed**, 0 failed, 0 skipped |
| Cloud signer compilation | `npm run build` | Passed |
| OpenAPI contract | `npm run contracts`, compare generated bytes with original working-tree contract | Identical; passed |
| Production npm dependency audit | `npm audit --omit=dev --audit-level=high` | 0 reported vulnerabilities |
| Repository gates | `make verify` | Passed; Swift compiler syntax stage unavailable |
| Supplementary Swift syntax | tree-sitter parse of changed/new Swift files | 51 files, zero syntax errors |
| Whitespace | `git diff --check` | Passed |
| iOS XCTest | `make test` | **Blocked before test execution**: no iPhone simulator; no Swift/Xcode toolchain installed |

Python ran under 3.11 in an isolated environment (CI uses 3.12); Node was 22.22.3.
The temporary Python environment was removed after testing. Dependency/build outputs
were not added to Git. Server tests use mocked outbound HTTP, not real services.

Warnings: Starlette's TestClient warns that its httpx adapter is deprecated; npm
installation reports deprecated cron-parser 4.9.0. Neither caused a test failure.
No dependency versions were changed for these warnings.

**Scope boundary:** these executed server/cloud suites do not test the native signing
workspace. All Swift XCTest cases (including the newly added regression cases),
SwiftUI type checking, native signing and device accessibility flows remain untested.
No remote CI run was started: the current uncommitted working tree has not been
published to GitHub by this testing pass. Remote CI needs this exact tree committed
and pushed on the session branch before its results would validate these changes.
