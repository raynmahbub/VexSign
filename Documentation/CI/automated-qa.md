# Automated QA in GitHub Actions

The goal of these workflows is not “a green badge”. It is a defensible answer to
**did this commit actually build and run?** Each layer answers a different question
and the reports keep the layers separate.

## What runs on every relevant push or pull request

| Job | Runner | Question it answers |
|---|---|---|
| `quick` | Ubuntu | Are resources, project wiring, source policies and Python gates clean? |
| `build` | macOS | Do **Debug and Release** compile and link? Does the static analyzer find defects? |
| `tests` | iOS Simulator | Did XCTest cases actually execute, pass, fail or skip? |
| `ui-tests` | iOS Simulator | Did XCUITest actually drive the app's tabs, navigation, swipes and import/signing entry points? |
| `concurrency` | macOS | Are strict-concurrency diagnostics growing? |
| `device` | self-hosted iPhone | Did the app install and launch on real hardware? Optional, never a PR job. |

`build` produces an unsigned Debug IPA for inspection. It is a build artifact, not
proof that tests passed and not a release. `tests` and `ui-tests` each export their
own `xcresult`; the `quality-report.py` gate counts **leaf** test results and refuses
a green status when no test executed or any test failed. Skipped tests stay listed as
skipped. The UI job runs with one worker because each worker would launch its own app
and steal taps from the other.

## Native build and test commands

Locally, with Xcode installed:

```bash
make verify          # portable gates; no Xcode required
make typecheck       # xcodebuild Debug typecheck
make test            # simulator XCTest suite
make test-ui         # simulator XCUITest suite (taps, swipes, screenshots)
```

CI runs `xcodebuild` directly for Debug and Release, plus `VexSignTests` and the
separate `VexSignUITests` target, and calls `xcrun xcresulttool get test-results
tests` before writing each quality report. Coverage is reported from the unit-test
result bundle; a missing number is not a pass.

## Reports and evidence

Every native run uploads:

- `quality-report.json` / `quality-report.md`: passed, failed, skipped, blocked,
  crash signals and the exact executed-test count.
- `coverage.json` and the `xcresult` on failure.
- build logs for Debug, Release and the analyzer.
- `ui-tests` result bundle, log, test-results JSON and quality report on **every**
  attempt: XCUITest screenshots are attachments inside the `xcresult`, including
  the final frame captured when an assertion stops a test early.
- `feature-acceptance.json` from the device job, with one case per registered feature.

See [per-feature acceptance](../Deployment/feature-acceptance.md) for the rules that
prevent a pending or synthetic observation from becoming a pass.

## Physical-device runner setup

GitHub-hosted macOS runners cannot provide an iPhone. To enable the hardware job,
register a self-hosted macOS runner with labels `macos`, `arm64`, `ios-device`, connect
a device, and set:

- Variable `VEXSIGN_DEVICE_RUNNER=true`
- Variable `VEXSIGN_DEVICE_UDID=<device UDID>`
- Variable `VEXSIGN_DEVICE_IPA=<absolute path to a development-signed IPA on the runner>`
- Variable `VEXSIGN_DEVICE_RUN_TESTS=true` to run `VexSignTests` on the device
- Secret `VEXSIGN_DEVICE_SIGNING_IDENTITY=<development certificate>`

The CI Debug IPA is ad-hoc signed and is deliberately rejected by this job. The runner
script `Tools/Audit/run-device-acceptance.py` installs a development-signed build,
launches `com.vexsign.app`, optionally runs native tests on that device, and checks the
per-feature report. A device job that is skipped or lacks evidence never contributes to
a simulator result.

Pull requests never run the device job: a fork must not obtain runner credentials or
mutate a shared device.

## Release gate

`release.yml` calls `Tools/Release/verify_ci_gate.py` before compiling a release. It
queries check runs for the exact commit and requires:

- `quick`
- `build · VexSign Debug (unsigned)`
- `tests · VexSignTests (simulator)`
- `ui-tests · VexSignUITests (simulator)`

A publishing release also requires `device · iPhone (self-hosted, opt-in)`.
Missing, cancelled, failed or skipped checks block publication. Retries are resolved by
latest completed attempt, so an old failure does not poison a later green run and a
later failure cannot hide behind an old success.

## Honest limits

- The XCUITest target exists, but this Linux workspace has no Xcode or simulator.
  Its Swift sources have not been compiled or executed here; only a green macOS
  `ui-tests` job with executed leaf results counts as a UI pass.
- UI tests verify that entry points and navigation exist and that swipes do not
  break the app. They do **not** claim iOS accepted an install: signing,
  provisioning and installation outcomes stay device observations in the feature
  matrix.
- A simulator is not an iPhone. A unit test is not a UI tap. The report names the
  source of every result so neither is presented as the other.
- Apple Account provisioning, paired `installd` and computer-free bootstrap still
  require their dedicated device evidence; see
  [deployment docs](../Deployment/README.md).
