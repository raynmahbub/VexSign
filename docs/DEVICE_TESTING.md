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

## Native-primary combined-host acceptance

The acceptance tool classifies the root IPA metadata and binds the report to
that architecture, commit and tested (re-signed) IPA checksum. Metadata is not
execution evidence. A standalone report cannot satisfy native-primary acceptance.
For combined hosts the installed identity is `com.kdt.livecontainer`; installation
may replace stock LiveContainer. Back up existing guest/container data first.

In addition to the checks above, native-primary reports require:

| Report check | Required observation |
| --- | --- |
| `native_primary_bootstrap` | Cold launch opens native VexSign without installing/staging it as a guest. |
| `host_session_switches` | Explicitly switch VexSign → LC UI → VexSign and embedded SideStore → VexSign; account state is not silently shared. |
| `single_guest_boundary` | One guest runs at a time; unsupported overlaps fail clearly. |
| `primary_keychain_guard` | Supported guest mode cannot invoke native account/key export APIs; locked storage fails without replacement. This is not malicious-code isolation. |
| `installed_inventory_evidence` | Verify actual OS-installed apps separately from imported/staged guests, including exact version/device association. |
| `v3_provider_explicit_consent` | Exercise a real supported provider with explicit consent; no legacy fallback or account request before approval. Keep provider/device/account evidence private. |
| `cms_quota_gate` | With the default unavailable CMS verifier, profile UI stops before certificate/registration mutations or quota consumption. |
| `native_owned_sign_install` | Once production CMS verification is accepted, use an owned native identity, fresh profile/status checks, explicit signing approval and verify the resulting app on the intended device. |
| `scoped_unattended_renewal` | Exercise an explicit scoped grant, expiry/revocation/cancellation and verified installation; a review queue or success banner is insufficient. |

The final two paths are still incomplete. Leave those observations **pending**;
a bootstrap/build-only test must not be recorded as full product acceptance.
The agent/hosted runner cannot perform these physical-device checks.

### What each pending path is actually waiting on

Both are blocked on evidence, not on a missing screen. The prerequisites below
are what a maintainer with hardware has to produce; none of them can be inferred
from a green CI run.

**`native_owned_sign_install`** — the code path exists
(`NativeSigning/Identity/NativeProtectedSigningHandoff.swift`), and it refuses to
run without CMS verification:

1. `NativeAppleProfileCMSVerifier` is written against public `Security` APIs and
   pins Apple roots, but it has **never been compiled on macOS or checked against
   a real Apple-issued profile**. That is why `NativeProvisioningProfileValidator`
   defaults to *unavailable* and `appleCMS()` is an explicit internal opt-in.
2. Promote it only after verifying, on macOS, that it accepts genuine profiles
   from the current Apple generation and rejects tampered ones. A verifier that
   merely parses a plist is not evidence of trust — do not enable it to make a
   report pass.
3. Then, on the intended device: owned native identity, fresh profile/status
   checks, explicit signing approval, and confirm the installed app launches.

**`scoped_unattended_renewal`** — there is no scoped-grant model in the codebase
yet. `BackgroundAutomation` has an enabled flag and a policy, but nothing that
issues a *grant* with an expiry, a revocation and a cancellation, which is what
this check exercises. Implementing that is new security-sensitive behaviour, so
it needs its own design and review, not an acceptance run:

1. An explicit grant recording scope, expiry and the approving user action.
2. Expiry, revocation and cancellation that actually stop unattended work.
3. A renewal that ends in a **verified installation** on the device. The check
   says so deliberately: a review queue entry or a success banner is not a pass.

Until both are satisfied the guard in `tools/test_device_acceptance.py` keeps the
README's "experimental" wording tied to this section. Removing the caveat and
leaving the paths unexercised is the failure mode that guard exists to prevent.
