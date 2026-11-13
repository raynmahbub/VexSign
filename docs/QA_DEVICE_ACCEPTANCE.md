# Real-device acceptance procedure

A reproducible manual pass over the workflows that cannot be proven by unit tests. Written for an
iPhone with a developer provisioning context; nothing here has been run as part of this change.
Where a step's only evidence can be a device, it is marked **device only** rather than claimed.

Record for every step: build (`CFBundleShortVersionString` + `CFBundleVersion`), iOS version,
device model, date, and the exact error text if it fails. A step passes only when the stated
*observable* result is seen — not when the app stops showing a spinner.

## 0. Preconditions

- Build from the branch under review; note the commit (`git rev-parse --short HEAD`).
- One test IPA (a small, already-signed app you own), one `.p12` + its password, one
  `.mobileprovision` that matches it.
- A test repository JSON (a small local file served over HTTP on the LAN is enough).
- Airplane mode available; at least 2 GB free storage; a second device for the multi-device step if
  possible.

## 1. Application behaviour

| # | Step | Pass criteria |
|---|---|---|
| 1.1 | Delete the app, reinstall from a clean build, launch | First launch reaches the library without a crash; no signing or network permission is requested before it is needed |
| 1.2 | Navigate every top-level tab twice, background and foreground | State is preserved; no blank list where data exists; no duplicate rows after returning |
| 1.3 | Deny Local Network / Photos prompts when shown | The affected screen explains what it needs and stays usable for other work |
| 1.4 | Import 200+ apps (script the import if possible), then scroll the library | Scrolling stays responsive; icons load lazily; memory does not grow without bound (record the Xcode memory gauge if attached) |
| 1.5 | Rotate, switch apps during a running task, return | Task progress continues from where it was; no task resets to 0% or jumps to 100% |

## 2. Signing (device only for the final verification)

| # | Step | Pass criteria |
|---|---|---|
| 2.1 | Import the test IPA | Appears in the library with the correct name, version and bundle identifier |
| 2.2 | Import the `.p12` with its password | Certificate appears; a wrong password is refused with a message and adds nothing |
| 2.3 | Import the `.mobileprovision` | Profile shows its expiry; a mismatched bundle identifier is reported before signing |
| 2.4 | Sign the IPA with the matching identity/profile | Every stage reports; the run ends at "Verifying the signature", and the result is only shown as signed when verification passed — check that the toast/detail does **not** say signed when verification stage failed |
| 2.5 | Export the signed IPA, then re-import it | The re-imported copy reports the signing identity and is accepted by the library |
| 2.6 | Change a customization option after signing (e.g. rename the app) | The signed copy is re-signed or explicitly marked as no longer matching — it must not silently keep the old signature while showing the new name |
| 2.7 | Cancel mid-signing | Cancel is honoured, the stage stops at the stage it reached, temporary files are gone from Storage → temp, and the library is unchanged |
| 2.8 | Sign with an expired certificate | Refused with a message naming expiry, before any bundle is modified |

## 3. Repositories and downloads

| # | Step | Pass criteria |
|---|---|---|
| 3.1 | Add the test repository | Source appears with its name and icon |
| 3.2 | Refresh it | Catalog lists the expected apps; pull-to-refresh completes without a duplicate list |
| 3.3 | Turn off Wi-Fi, refresh again | An error is shown and **the previously loaded catalog is still there** |
| 3.4 | Restore Wi-Fi, refresh | Catalog updates; no duplicate entries appear |
| 3.5 | Download an app, interrupt by backgrounding, return | Download resumes or fails with an actionable message; no partially-imported app in the library |
| 3.6 | Download the same app twice | The second attempt is recognised (duplicate review or replace prompt), not silently duplicated |
| 3.7 | Update an installed app from the source | Available vs installed versions differ before, match after |

## 4. Device operations (device only)

| # | Step | Pass criteria |
|---|---|---|
| 4.1 | Connect a device, open the device screen | Device is discovered with model/iOS version; unauthorised state is named |
| 4.2 | Install a signed app | Progress is monotonic; "installed" appears only after the device reports it — verify by unlocking the device and looking at the home screen |
| 4.3 | Cancel an install mid-transfer | Cancelled state is shown; the app does not appear as installed; the library record is not marked installed |
| 4.4 | Install while offline / device unplugged | Failure is classified (transfer vs install), with a message that distinguishes them |
| 4.5 | Install to a second device | Inventory for each device stays separate |
| 4.6 | Refresh installed-app inventory | Matches what the device actually has, including an app installed outside VexSign |

## 5. Task centre and recovery

| # | Step | Pass criteria |
|---|---|---|
| 5.1 | Start a long download, force-quit the app, relaunch | Task history shows the interrupted task as interrupted — not completed, not missing |
| 5.2 | Repeat with a signing run | Same, plus the stage it reached is visible |
| 5.3 | Clear history in Settings → Diagnostics | History empties and stays empty after relaunch |
| 5.4 | With history present, run a signing task to completion and relaunch | History is intact; no duplicate rows appear |

## 6. Backup and restore

| # | Step | Pass criteria |
|---|---|---|
| 6.1 | Create a backup with certificates, sources, settings and library | A file is produced; the summary counts match what is in the app |
| 6.2 | Wipe the app (delete + reinstall), restore the backup | Certificates, sources, settings and library return; signed apps remain signed; no duplicates |
| 6.3 | Restore the same backup twice | Second run reports everything as skipped, adds nothing |
| 6.4 | Restore a backup with a wrong password | Refused, nothing changed |
| 6.5 | Restore while a download is running | Refused with a busy message rather than a partial restore |
| 6.6 | After restore, sign with a restored certificate | Signing works, or the app says exactly why the restored identity cannot be used |

## 7. Resilience

| # | Step | Pass criteria |
|---|---|---|
| 7.1 | Airplane mode: open library, inspect an app, sign locally | All local work proceeds; only network-dependent surfaces report offline |
| 7.2 | Set an invalid cloud/service URL in settings, run the connection test | Failure names the layer (unreachable vs rejected) and does not disable local signing |
| 7.3 | Import a corrupt IPA (truncated), a non-IPA file, and a ZIP with `../` entries | Each is refused with a message; nothing is extracted outside the app container; the library is unchanged |
| 7.4 | Fill the device to <100 MB free, then import | Import fails with a storage message; existing data is intact |
| 7.5 | With an expired/revoked certificate configured | Signing refuses and points at the identity, not at the IPA |

## 8. What this plan does not cover

- Performance numbers: record them, but this change makes no performance claims.
- Cloud signing end-to-end: remote signing is disabled by policy in this build
  (`CloudSigningClient.signRemotely` refuses), so there is nothing to accept.
- Any Apple capability the app does not implement (background install, automatic re-signing of an
  installed app, etc.).
