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

Changes to signing-task state, install confirmation, re-signing with saved
settings, install verification, and what a sign and a cleanup pass leave in the
library come with their own numbered scenarios:
[steps 1–20](../Engineering/Changes/signing-and-installation-lifecycle.md#required-on-device-acceptance),
[steps 21–39](../Engineering/Changes/signing-and-installation-lifecycle.md#required-on-device-acceptance-follow-up)
and [steps 40–55](../Engineering/Changes/signing-and-installation-lifecycle.md#required-on-device-acceptance-follow-up-2).
They are not report checks — `Tools/Development/device-acceptance.py` neither lists nor
validates them — so keep what you observe with the report, for example in the
notes of the closest check above (`import_sign_verify`, `installed_version`,
`cancel_and_timeout`). This repository records no result for any of them.

### Signing, installation and branding regression checks (pending)

- Test sign-only, modify-only and sign-and-install with valid, missing, expired
  and incompatible identities. Verify what was actually registered or installed.
- Stop during preparation, native signing and verification; check retry,
  same-app duplicate requests, unrelated concurrent work and cleanup. Native
  signing cancellation is cooperative, not a forced interruption.
- Exercise export, batch, background/foreground, low storage, first install,
  update, rejected install, cancellation and Skip/Retry races. Do not treat an
  unconfirmed install as success.
- Change the app icon and check the Home Screen and in-app branding after relaunch.
  The static launch artwork cannot follow a runtime icon preference.

No result has been recorded for these checks.

### Library swipe-to-delete (pending)

On a test device, try left and right swipes on signed and imported apps in compact
list, adaptive cards and icon-grid layouts. Confirm the Delete action opens the
existing confirmation, Cancel preserves the library copy, and Delete removes only
that copy—not an installed app. Check vertical scrolling, edit selection, VoiceOver,
and large text. With Reduce Motion and button animations disabled, confirm the
reveal is immediate. In Appearance, turn interface sounds on and off: check the
preview and Library grid reveal, including the device's silent setting. Inspect
the rounded launch mark in light and dark mode. Check Home actions at accessibility
text sizes and the app-icon picker after changing icons. No result has been
recorded for these checks.

### Home UX and accessibility (pending)

Test both Home presentations with VoiceOver, Bold Text and accessibility text
sizes. Check the updates summary offline and before a refresh, optional source
onboarding, and the URL field's label and touch target. Attempt a download with
Game Mode enabled, then with a valid URL; also try an existing paused or queued
row. Confirm rejected requests keep the entered URL and never claim a transfer
started. No result has been recorded for these checks.

## 4. Record acceptance

From the exact, clean candidate checkout (Python 3.11+):

```bash
python3 Tools/Development/device-acceptance.py init --ipa /path/to/tested.ipa --report device-acceptance.local.json
# Fill tester, device model, OS version, UTC timestamp and every check's result/notes.
python3 Tools/Development/device-acceptance.py check --ipa /path/to/tested.ipa --report device-acceptance.local.json
```

The report is bound to a source commit. The commit comes from `--commit <sha>`, then
`VEXSIGN_SOURCE_COMMIT` (or `GITHUB_SHA` in CI), then `git rev-parse HEAD`. A checkout is the
normal case; an unpacked source archive has no `.git`, so pass `--commit` or set
`VEXSIGN_SOURCE_COMMIT` there. With none of the three, the tool exits with a one-line diagnostic
instead of failing on git, and no report is written — the commit binding is the point of the
tool, not a step to skip.

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
(`Packages/NativeSigning/Identity/NativeProtectedSigningHandoff.swift`), and it refuses to
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

Until both are satisfied the guard in `Tools/Development/test_device_acceptance.py` keeps the
README's "experimental" wording tied to this section. Removing the caveat and
leaving the paths unexercised is the failure mode that guard exists to prevent.

## Free Apple ID handoff ladder (pending)

The native account → certificate-store handoff
([native signing handoff](../Security/NATIVE_SIGNING_HANDOFF.md)) has its own device ladder.
It is recorded inside the ordinary report rather than in a second file:

```bash
python3 Tools/Development/device-acceptance.py init --ipa /path/to/tested.ipa \
  --report device-acceptance.local.json --include-native-handoff
```

That private working copy is gitignored. Promotion evidence is reviewed from the
repository, so `Tools/Development/native-promotion-evidence.py` requires a **redacted,
committed** copy — by convention
`Documentation/QA/evidence/device-acceptance-native-handoff.json` — and rejects a record that
points at an ignored path. Redact device identifiers, portal details and account
information before committing it, and keep raw screenshots and logs local.

| Report check | Required observation |
| --- | --- |
| `native_sign_in_team_selection` | Sign in with the test Apple ID and select the free team; no account request happens before explicit consent. |
| `native_device_and_app_id_registration` | Register the device and the test bundle ID from the app, then confirm both in the developer portal. |
| `native_profile_creation_and_export` | Create the development profile and export it; the exported bytes match the recorded profile UUID, bundle ID and expiry. |
| `native_key_export_consent_import` | Grant the single-use key export with the in-app password and confirm the identity appears in the certificate store. Import is not signing and not installation. |
| `native_signed_output_verification` | Sign a small test app with that imported identity and inspect the verification output, not only a success banner. |
| `native_install_and_relaunch` | Install the signed app on the device and relaunch it. |
| `native_seven_day_expiry_observed` | Confirm the profile's seven-day expiry as reported on the device or portal. Never change the device clock to force it. |
| `native_identity_persistence_after_relaunch` | Relaunch VexSign; the imported identity and its profile remain available without a second key export. |

The flag is opt-in: a run that never touched the native flow records nothing and
stays valid. Declaring the ladder makes every case required, and recording some
of the cases without declaring it is rejected — neither shape reads as a pass.
Keep portal screenshots, device identifiers and logs out of Git.

Completing this report is necessary but not sufficient. Promoting
`SigningMethodCapabilities.nativeAppleAccountSigning` also requires the genuine
Apple CMS observations recorded by `Tools/Development/native-promotion-evidence.py`, which
binds itself to this report's digest, commit and tested IPA checksum, and refuses
a digest that matches a committed synthetic fixture. No result has been recorded
for any case above; the ladder has never been exercised on hardware.
