# ZeeSigner comparison: implementation backlog

Reference: https://zeejb.com/zeesigner/. Track user outcomes, not vendor guarantees.

| Workstream | Starting point | Acceptance before calling it shipped |
|---|---|---|
| Profile expiry timeline | Certificate details show the final seven days | Check expired, under 24 hours, 1–6 whole days and 7+ days on device; verify VoiceOver and large text. |
| Personal account renewal | Experimental NativeSigning and SideSign | Sign, install and renew the same app on a real device without losing its data; test expired login, team mismatch and account removal. |
| Account and slot management | Library plus separate guest-host prototype | Isolate credentials per account, show actual team quotas, and demonstrate a user-approved deactivate/restore cycle with verified data recovery. Never uninstall the only copy of user data. |
| Cellular refresh | Existing App Intents and paired installation | With Wi-Fi disabled, verify connectivity, renew a profile, install, then verify the new expiry. Report each failure; fetching a source is not renewal. |
| First install | OTA manifests, pairing-record support, phone-backed web console | Validate clean-device onboarding separately for desktop and no-PC routes. Test absent trust, disconnected device and invalid identity. |
| Library and customization | Local signing, tweak import, clones, catalogs and file inspection | Exercise import through install with an authorized test IPA, extension and compatible profile; evaluate licensed optional tweak packs separately. |
| Update and progress | Update checks and Live Activities | Verify cancellation, cleanup and rollback at each supported stage. |
| Compatibility and speed | iOS 17 minimum; local Zsign | Record device, OS, IPA size, cold/warm timing, peak memory and install outcome. Older OS support requires a separate availability audit. |

Commercial certificate fulfillment, warranties, checkout and support are service commitments, not signer features. Do not claim privileged filesystem access, Apple quota exceptions, or immunity from revocation. Optional cosmetics and beginner onboarding can ship independently of provisioning.

### First personal-account renewal: physical-device check

Use an expendable test app you control that displays its own bundle ID, embedded profile team and UTC expiry, and can save/read a random marker in its local Documents directory. Disable cloud restore for the fixture. Do not use personal app data.

1. Create the existing device acceptance report with `python3 VexSign/Tools/Development/device-acceptance.py init --ipa VexSign.ipa --report acceptance.json --include-native-handoff --renewal` (supply the actual VexSign build path).
2. Install the fixture with your personal team. Save a new marker, relaunch, and record the installed app's identifiers, expiry and SHA-256 of the marker in `renewal.before`.
3. Obtain a later-expiring profile for the same team and bundle. Re-sign and install **over** the fixture. Do not uninstall, restore a backup, or recreate the marker. A new signed library entry alone is not a pass.
4. Relaunch the installed fixture, read the original marker from disk and record the independently observed values in `renewal.after`. Leave the report incomplete if any step is blocked. Never include passwords, private keys, pairing records or raw profiles.
5. Complete the rest of the measured checks and run `python3 VexSign/Tools/Development/device-acceptance.py check --ipa VexSign.ipa --report acceptance.json --renewal`. This checks the tester's observations for consistency; it cannot attest the phone remotely or enable unattended renewal.

### Manual repeat install (not profile renewal)

In Shortcuts, add **VexSign → Re-sign and Queue Install**, then select a signed library copy. The action opens VexSign and uses its normal serialized signing and install queue. It requires a saved certificate still present in the library, does not substitute the current selection, and refuses a bundle-ID override that changes the ID. The final installation prompt and result belong to the installer. Signing with the same profile does not advance its expiry.

On device, check a successful queue submission, then repeat with a missing saved identity, a changed identifier, and a locked library app. No failed attempt should enqueue a new install. This action does not deactivate or uninstall an existing app.

For the personal-account test, select the signed fixture in **Provision & Sign**. At **Review & Provision**, enable **Require a later expiry than this signed library copy**. The baseline is the authenticated development profile embedded in the library artifact, not an inventory estimate or a measurement from the installed app. Normal Apple quota approvals still apply. An unchanged expiry stops the handoff, without deleting the old profile or retrying portal mutations. A later expiry makes the result eligible for the existing consent-based import and signing review; verify the installation and marker separately on the device.

### Desktop USB first install (already-signed IPA)

With Python 3, `idevice_id` (libimobiledevice) and the current `ideviceinstaller` CLI on PATH, connect and trust your phone. Windows also needs working Apple USB drivers. From the repository root:

1. `python3 VexSign/Tools/Desktop/install.py` lists attached USB devices. On Windows use `py -3` instead of `python3`.
2. `python3 VexSign/Tools/Desktop/install.py --ipa VexSign.ipa --device YOUR_DEVICE_ID` previews the bundle and selected device.
3. Repeat with `--confirm-install` to install. Open the app on the phone to verify launch.

Use an IPA signed for this device. The helper checks archive structure, not signature validity; the device enforces signing. It does not sign the release IPA, handle Apple credentials, uninstall an app, or install a trust/DNS profile. Replacement can affect existing app data.

### Safari first install without VexSign already installed

A distributor with a legitimately OTA-distributable, signed IPA can prepare a static install site. With the following example, upload the **contents** of `install-site` to `https://downloads.example.org/vexsign/` on a trusted HTTPS host. Replace the example URL with your own before generating the site.

```sh
python3 VexSign/Tools/Desktop/safari_install.py --ipa VexSign-signed.ipa --output install-site --base-url https://downloads.example.org/vexsign/
```

The recipient opens that URL on the iPhone in Safari and taps **Install**; no existing phone signer, USB pairing, or desktop is required on the recipient's side. The host must serve the manifest and IPA directly to iOS, not a login or HTML download interstitial. Only distribute to authorized recipients: the IPA contains its embedded profile and may contain device identifiers. The generator publishes nothing, does not sign an unsigned IPA and does not make a development profile eligible for OTA distribution. Test install and launch on authorized hardware before sharing.

The internal renewal worker prepares a review from one authenticated portal profile matching the baseline CMS digest. Confirmation rechecks the live target, consumes the review, journals a device-only intent, and sends one regeneration request. It re-downloads and authenticates the profile before returning a result, requiring the same portal record and a later expiry. Missing, stale or ambiguous inventory is not permission to retry. To opt in, enable **Request one regeneration of this app’s existing Apple profile** under the later-expiry check in Review & Provision. Leaving it off does not regenerate anything. This experimental route requires a still-valid profile matching a native receipt for the same account, identity and target. It is not recovery for an expired or unrelated IPA. Separate key-export and signing review remain mandatory; the actual device result is unverified.

### Running the physical renewal fixture

On a Mac with Xcode and Python 3, build a disposable test IPA (substitute a bundle ID you control):

```sh
VexSign/Tools/Development/RenewalFixture/build.sh /tmp/fixture.ipa com.example.myrenewalfixture
```

1. Import the unsigned fixture into VexSign, provision with your personal team, sign and install. Retain the **signed** output IPA as `before.ipa`. On the phone create the initial marker once. Relaunch the fixture, tap **Read installed copy**, and save the shared JSON text to `before.json`.
2. Use the same signed library copy for the renewal flow. Install over the original, without deleting the fixture. Export this exact signed output as `after.ipa`. Relaunch and save a fresh observation as `after.json`. If the marker is missing, stop: do not create another.
3. For each stage run `python3 VexSign/Tools/Development/RenewalFixture/observation.py before.json before.ipa` (then substitute `after`). Copy each result into the matching `renewal.before` or `renewal.after` field of the device acceptance report. The converter checks the installed profile digest against the exported IPA before decoding expiry and team metadata locally. It does not prove an Apple account operation or signed-app validity by itself.
4. Run the `check --renewal` command above. Keep the IPAs private; the shared observations contain no marker contents or raw provisioning profiles.

### Foreground renewal on mobile data

Open **Settings → Signing & Installation → Review Renewal over Cellular** or add the Shortcuts action of the same name. The action opens the review; it does not grant account permissions. Sign in first in Signing Methods. With Wi-Fi off and mobile data enabled, select a signed library app, supply the device ID, and review the regeneration request. The screen disables submission without a satisfied cellular default path and rechecks it when starting. An unavailable or ambiguous path (including some VPN configurations) is not treated as cellular.

This is not per-request routing, a background scheduler, or a tunnel reset. A route can change mid-operation. Install transport and device trust still have their own requirements. A successful account response does not establish that installation worked over mobile data; use the before/after fixture observations with Wi-Fi disabled to check that separately.

### Preserve an app-provided export before considering slot changes

On a trusted development iPhone where Xcode allows app data-container access, use the app's own export function to create a file in its Documents directory. On the paired Mac:

```sh
python3 VexSign/Tools/Desktop/slot_export.py backup --device DEVICE_ID --bundle com.example.test --name export.zip --snapshot ./my-snapshot
python3 VexSign/Tools/Desktop/slot_export.py restore --device DEVICE_ID --bundle com.example.test --snapshot ./my-snapshot --confirm-restore
```

The backup compares two independent reads. Restore writes to a new, uniquely named document and reads it back; use the app’s importer and confirm the actual records afterward. The snapshot may contain sensitive personal data: keep it private. An export is not a sandbox backup or a guarantee that Keychain items, shared groups, settings or saves are recoverable. Some apps have no usable export or import. Neither operation uninstalls the app or authorizes automatic eviction.

### Manual slot rehearsal for the disposable fixture

Build the updated renewal fixture (it declares `VexSignMarkerFixture`), sign it, install it and create its initial marker. Open its **Export fixture backup**, then paste the JSON into **Library → signed fixture → Fixture slot manager**. Return the rehearsal request to the fixture and paste its reply back into VexSign. Only a matching rehearsal unlocks **Plan manual deactivation**. This is a cooperating test app protocol, not cryptographic proof for arbitrary third-party apps.

Confirm the plan before manually removing the **fixture only** on the phone. Keep VexSign and its signed library copy. Open the same record to queue reinstall; after launch, give the fixture the restore packet and return its reply. A different marker is never overwritten. VexSign records the fixture’s acknowledgment, not independent proof of uninstall or slot availability. The journal is local, file-protected, excluded from backup and tied to the library copy and verified profile digest. There is no automatic eviction or uninstall replay.

To return from the Home Screen, create a shortcut with **Open Fixture Slot Manager**, select its **saved fixture backup**, then use Shortcuts’ **Add to Home Screen**. Tapping the icon opens its recovery review, not the fixture itself. The shortcut uses the backup ID even if its original library row is deleted. A missing backup is reported, never substituted by bundle ID. If an older shortcut asks for its former library-app parameter, edit the action and select the saved backup once. The shortcut never queues installation, confirms recovery or removes an app.

The recovery screen journals the reinstall attempt **before** calling the installer. After reopening, it distinguishes an uncertain submission from an accepted standalone install waiting for the fixture reply. Neither state resubmits. If the device and install queue show that no installation is pending, **Review manual retry** enables a fresh request without submitting it; use the new restore packet because the previous reply is no longer valid.

**Expired fixture profile:** Keep the original signed library entry as the recovery record’s anchor. Open its slot manager and unlock the library app if required. An expired profile blocks install and restore actions but does not erase the local marker. In the read-only view, explicitly select a valid re-signed fixture with the same bundle identifier and signing team. VexSign verifies the replacement and changes the recovery challenge, without installing or removing anything. Use only the new packet. Rebinding does not clear an uncertain install attempt. Older records without a stored team require the original authenticated profile to establish the team; marker access does not require this migration to succeed.

**Library entry deleted:** For newly saved records, go to **Settings → Signing & Installation → Recover fixture backup**. Unlock any protected copies, open the saved record, and explicitly rebind to a valid same-team signed fixture. This list does not install anything or choose a replacement by bundle ID. The original and rebound library lock identifiers are kept in the protected record so deleting a library row is not an unlock. Older records missing these identifiers must be opened from their retained, valid library copy to migrate before cleanup; the orphan list does not guess their lock identity. Deleting VexSign itself still deletes its local recovery files.

### Saved-account storage

The native backend can open one of five numbered local session slots. The default uses the original Keychain services; additional slots have separate session and resume-journal services. Slot numbers are not Apple identities, team IDs, or extra quota. The single-backend lease still applies across slots. In Signing Methods → Free Apple ID Signing, choose a slot, then sign in or explicitly resume it. Switching closes the old backend without signing out or contacting Apple. Resume contacts the configured Anisette provider and Apple and may require verification and team selection. On relaunch the picker starts at slot 1; other saved sessions remain in their slots. Test on-device by alternating two accounts, checking each team and inventory, then signing out of one and resuming the other.
