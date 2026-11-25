# Per-feature acceptance matrix

This guide turns “are all features working?” into evidence instead of a feeling.

`Tools/Audit/feature-acceptance.py` reads the 41 entries in
`VexSign/Services/Diagnostics/FeatureStatusRegistry.swift` and creates one case per
feature, bound to an exact IPA SHA-256 and source commit. A report cannot pass with a
feature missing, with a pending case, or with notes such as “synthetic fixture”.

It does **not** simulate a device. It refuses to call a feature accepted until the
evidence is real:

- `implemented` entries accept an XCTest source file under `Tests/` as unit evidence.
- `needsDevice` entries require a named tester, device model, OS version, UTC timestamp
  and an observation made on that device.
- Every case is tied to the same IPA hash, so a rebuilt binary invalidates the report.

## 1. Run native tests (macOS/Xcode)

Simulator:

```bash
python3 Tools/Audit/run-native-tests.py \
  --destination "platform=iOS Simulator,name=iPhone 16"
```

Connected device (use the UDID shown by Xcode or `xcrun devicelist`):

```bash
python3 Tools/Audit/run-native-tests.py \
  --destination "id=<UDID>"
```

The wrapper requires `xcodebuild`. It fails loudly on Linux or without a destination;
no portable Python gate can execute iOS tests. It writes `.artifacts/VexSignTests.xcresult`.

## 2. Create the feature matrix

Use the exact unsigned build you installed:

```bash
python3 Tools/Audit/feature-acceptance.py init \
  --ipa packages/VexSign-<version>.ipa \
  --report feature-acceptance.local.json
```

The command refuses to overwrite an existing report. Edit `feature-acceptance.local.json`
and fill every case:

```json
{
  "forced-signing": {
    "result": "pass",
    "notes": "Signed and installed the marked IPA; profile and entitlements matched.",
    "evidence": "Tests/UnitTests/Signing/AutoSignIdentityPolicyTests.swift"
  },
  "extension-profiles": {
    "result": "pass",
    "notes": "Installed and launched an app with per-extension profiles on iPhone 16.",
    "tester": "Full Name",
    "device_model": "iPhone 16",
    "os_version": "iOS 26.0",
    "observed_at_utc": "2026-11-24T10:00:00Z"
  }
}
```

For a `needsDevice` case, `evidence` is not a substitute for the device fields. A
placeholder, a simulator-only result, or a note containing “synthetic” is rejected.

## 3. Check the report

```bash
python3 Tools/Audit/feature-acceptance.py check \
  --ipa packages/VexSign-<version>.ipa \
  --report feature-acceptance.local.json
```

A `PASS` line means the report has evidence for all registered features for that exact
artifact. It does not mean this repository has such a report checked in: the local file
is ignored because it contains device observations and must not be treated as source.

## What this does not cover

- It cannot make CI run without macOS/Xcode.
- It cannot make a simulator prove a physical-device result. The separate
  [`VexSignUITests` target](../../UITests/) drives simulator taps and screenshots,
  but its screenshots cannot fill a `needsDevice` case or prove an install was accepted.
- It cannot validate Apple Account provisioning, paired `installd`, or computer-free
  bootstrap without the separate observations in
  [`Tools/Audit/device-acceptance.py`](../../Tools/Audit/device-acceptance.py) and
  [`computer-free-installation.md`](computer-free-installation.md).

The harness is deliberately strict about that boundary: its job is to stop an
unvalidated change from being described as validated.
