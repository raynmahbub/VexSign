# Device inventory acceptance

This document describes the read-only, library-app-scoped inventory surface added to
Installation → Tunnel & Pairing → Read library-app inventory. Source tests and simulator runs
do not establish a real device response. A report from a named tester is an attestation, not
independent verification.

## What VexSign actually queries

The inventory model asks the **selected** device, over the reviewed pairing session, about each
valid bundle identifier in the VexSign library, one at a time and at most 64 apps. It consumes
`DeviceInstalledApplication` readings from `PairingBridge`, which already checks the frozen
device/record binding, peer address, consent and selection generation.

This is not a full SpringBoard application list. iOS sandboxing does not give an ordinary app a
supported general-purpose inventory API, and the vendored service does not expose arbitrary
private containers. Bundle paths and pairing secrets are not retained in inventory rows.

## Reading a row

- **Matches library version** — the device returned the same bundle identifier, version and
  build under the same frozen session binding.
- **Different version on device** — the device returned this identifier, but at another version.
  This is not confirmation that the library artifact is installed.
- **No comparable device report** — the service returned nothing usable, a different binding, or
  incomplete version/build metadata. This is *not* an absence claim. The shared inventory policy
  deliberately has no shipping probe that can assert "not installed".

A successful refresh timestamp means the read loop completed. It does not mean every app was
found, that VexSign installed anything, or that the app was launched.

## Manual hardware procedure

1. Use a physical iPhone with a legitimate VexSign installation, Developer Mode where required,
   Local Network permission, an active compatible VPN, and a reviewed pairing record for that
   exact device.
2. Open Installation → Tunnel & Pairing. Import or confirm the record, enter the expected device
   identifier, grant device-service consent, and tap **Verify selected device**. Wait for the
   fresh product/version/build summary.
3. Open **Read library-app inventory**. Confirm the button is enabled only after the above.
4. Tap **Read installed apps from selected device**. A task record must appear in the task center
   with progress advancing per app; **Cancel inventory read** must stop between app queries.
5. For an app already known to be installed at the library version, expect a "Matches library
   version" row with the device's exact version and build.
6. For an app updated outside VexSign, expect "Different version on device" with the device's
   actual version. Do not expect "Not installed".
7. For an app known to be absent, expect "No comparable device report". A missing result is not
   evidence of absence.
8. Lock the device, revoke trust or replace the pairing record, then retry. The read must be
   refused or return only unreported rows; stale rows must not survive a record change.
9. Attach the commit, iOS version, device model, redacted record fingerprint suffix, task
   outcome and the observed rows to the acceptance report. Never attach the pairing file or raw
   device identifier.

## Known limits

- GitHub-hosted macOS runners and iOS simulators cannot perform steps 1–9 against a physical
  iPhone. CI only runs deterministic parsing/comparison tests and workflow checks.
- The paired installation bridge remains gated until a separate paired-installation hardware
  pass accepts device-side version/build confirmation. A successful inventory read does not
  unlock installation or removal.
- A live task's rows are published only after the whole loop completes; a cancelled loop does not
  publish partial readings. Library badges may refresh when an individual positive reading is
  validated, but only for the currently selected device/record binding.
