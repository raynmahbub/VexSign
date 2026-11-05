# Real-device installation acceptance

Simulator tests cannot establish certificate/profile compatibility, profile trust,
OTA installation, device Keychain persistence or locked-device behaviour. Use a
spare paired iPhone/iPad with non-production signing credentials. Do not reset
identities or install test profiles on a primary device without a backup.

## 1. Validate the exact source

Run **CI → full** on the candidate commit: both the unsigned macOS build and
simulator tests must pass. Run the Platform check workflow if companions changed.
Download the candidate IPA and retain its SHA-256. A locally re-signed IPA has a
new checksum: record the artifact actually used, not an earlier unsigned download.

## 2. Install and launch the signed app

On a Mac with Xcode, pair/trust/unlock the device. Build the VexSign scheme with
your team and valid provisioning in Xcode (or re-sign the candidate IPA with your
existing tool). Do not put signing material in Git or Actions artifacts.

```bash
xcrun devicectl list devices
DEVICE_ID='<selected-device-id>' SIGNED_APP='/absolute/path/VexSign.app' \
  CONFIRM_DEVICE_INSTALL=YES make device-smoke
```

This explicitly installs/replaces and launches the app. It does not silently
select a device or claim the in-app installer works. Keep device identifiers and
raw device logs private. The signed app must correspond to the recorded candidate.

## 3. Exercise the actual app workflow

Use a harmless test IPA and a compatible certificate/profile. Record observations:

| Report check | Required observation |
| --- | --- |
| `launch` | Fresh launch reaches Home without a crash. |
| `import_sign_verify` | Import identity/profile/test IPA, sign it, inspect verification output. |
| `trust_profile` | Export/install device root CA profile; explicitly enable Full Trust in Settings. |
| `offline_local_install` | With external networking disabled, Fully Local installation completes. Do not use Semi Local for this test. |
| `installed_version` | Launch the installed test app and verify its exact version, not only a success banner. |
| `relaunch_persistence` | Relaunch VexSign; identity and local CA remain available. |
| `update_persistence` | Update VexSign with the same signing/Keychain identity; CA trust persists. |
| `renewal_preserves_ca` | In a controlled test build, exercise near-expiry renewal; server cert changes but CA remains trusted. Never change the primary device clock to force this. |
| `explicit_rotation` | On the test device, confirm CA rotation; old trust is not silently reused, new profile is required. |
| `locked_device_failure` | Exercise unavailable/locked Keychain conditions; fail safely without silently replacing identity. |
| `cancel_and_timeout` | Cancel installation and simulate no confirmation; no false success. |
| `invalid_profile_rejected` | Incompatible/expired profile produces actionable failure, not success. |

If a scenario cannot be exercised, leave it pending; it is not a pass. Renewal,
locked storage and update tests may require instrumented builds or multiple
artifacts—describe those explicitly in notes and retain private evidence.

## 4. Record acceptance

From the exact, clean candidate checkout (Python 3.11+):

```bash
python3 tools/device-acceptance.py init --ipa /path/to/tested.ipa --report device-acceptance.local.json
# Fill tester, device model, OS version, UTC timestamp and every check's result/notes.
python3 tools/device-acceptance.py check --ipa /path/to/tested.ipa --report device-acceptance.local.json
```

Reports start pending and cannot overwrite an existing file. Validation rejects
missing checks, missing observations, non-pass results and mismatched commit/IPA.
This is human attestation, not hardware-backed proof. Keep the report and evidence
with the release review; redact credentials, UDIDs and personal information.
Changing source or the tested artifact requires a new acceptance run.

No self-hosted device runner is enabled: exposing a paired device/signing key to
untrusted PR code would cross a sensitive trust boundary. Hosted CI has no physical
iPhone. Stable publishing still needs maintainer review; no GitHub settings are
changed by these scripts.
