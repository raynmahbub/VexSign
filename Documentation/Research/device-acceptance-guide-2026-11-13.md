# Physical iPhone acceptance guide — 2026-11-13

Deliverable **E**. This is a **procedure only**: no step below has been run, no device result is
claimed, and no screenshot/log/UDID is fabricated. It extends the existing
[real-device acceptance procedure](../QA/QA_DEVICE_ACCEPTANCE.md) and
[device testing notes](../QA/DEVICE_TESTING.md) with the specific checks introduced by the
2026-11-13 implementation pass.

Record for every step: build (`CFBundleShortVersionString` + `CFBundleVersion`), commit SHA,
iPhone model, iOS version, date/time, pairing/transport used, exact error text, and the evidence
file name. A step passes only when its stated **observable** result is seen — not when a spinner
stops, not when a request is handed to iOS, and not when a test says "requested".

## 0. Preconditions and evidence hygiene

| # | Action | Observable prerequisite |
| --- | --- | --- |
| 0.1 | Commit/push this branch and obtain a green `ci.yml` `build` + `tests` run. | Save the run URL, job conclusions, Xcode version and test count. This is the `Build-verified` gate; it has not run yet. |
| 0.2 | Build a signed installable VexSign IPA through a legitimate route (TestFlight, Ad Hoc, Enterprise, MDM or eligible marketplace). An unsigned release IPA is not installable by Safari/Files. | Save the export method, signing identity/team, provisioning profile, device UDID eligibility and `codesign -dv --verbose=4` output with secrets redacted. |
| 0.3 | Prepare one small IPA you own, one paid `.p12` + password, one matching `.mobileprovision`, and a local HTTPS-capable test source. | Confirm the profile includes this device UDID and the certificate is in date; record expiry. |
| 0.4 | Prepare a pairing file + loopback VPN only if you will exercise the idevice transport. | Settings → Setup Health shows a complete pairing record and reachable heartbeat socket. |
| 0.5 | Enable diagnostic log export; decide where evidence is stored. | Logs must be exported **after** `LogRedaction` runs; never attach raw private keys, passwords, tokens or unredacted pairing files. |

**Evidence to collect:** `00-environment.txt`, `00-ci-run.txt`, `00-signing-identity.txt`,
`00-profile.txt` (redacted), `00-device.txt`. Redact UDID/serial/Apple ID; keep only the last four
characters where correlation is needed.

## 1. Clean install and first launch

| # | Step | Pass criteria | Evidence |
| --- | --- | --- | --- |
| 1.1 | Delete any prior VexSign, install the signed build, launch. | First launch reaches the library without crash; no certificate/network permission is requested before needed. | `01-launch.png`, `01-launch.log` |
| 1.2 | Complete onboarding (or skip each page) and revisit Settings. | Every optional step points to a real working screen; no claim of unrestricted computer-free install is shown. | `01-onboarding.png` |
| 1.3 | Open Settings → Setup Health / Installation Engine. | Pairing, TLS and capability states match the actual device configuration; gated features are labelled gated. | `01-setup-health.png` |

## 2. Import → inspect → select identity → configure signing

| # | Step | Pass criteria | Evidence |
| --- | --- | --- | --- |
| 2.1 | Import the test IPA from Files and from a `vexsign://` deep link. | Both copies appear in Library with distinct identities; no duplicate silent merge; archive extraction rejects a deliberately path-traversal ZIP. | `02-import.png`, `02-archive-rejection.log` |
| 2.2 | Inspect Info.plist, nested bundles, entitlements and Mach-O slices. | Bundle ID, version, executable, nested extensions and encrypted/arm64 status match the known test IPA; unknown evidence stays unknown. | `02-inspection.txt` |
| 2.3 | Import the paid P12 + profile with its password. | Certificate appears with correct team/expiry; wrong password is refused; no secret appears in exported logs. | `02-identity.png`, `02-redacted-log.txt` |
| 2.4 | Exercise certificate/profile deep links with standard base64, base64url, missing padding and whitespace. | Valid variants stage and import; an oversized payload and invalid base64 are refused without a crash or a staged file. | `02-base64-cases.txt` |
| 2.5 | Select the identity and configure signing options (bundle ID, display name, icon, dylib, entitlements). | Preflight shows real profile/entitlement/device compatibility; blocked issues require an explicit reviewed override; no ungranted entitlement is promised. | `02-preflight.png` |

## 3. Sign → verify → install → confirm

| # | Step | Pass criteria | Evidence |
| --- | --- | --- | --- |
| 3.1 | Sign the test IPA. | All ten signing steps report from recorded evidence; stages not needed are skipped; failure cleans unregistered output. | `03-signing-trace.txt` |
| 3.2 | Inspect the post-sign verification receipt. | `SignatureVerifier` confirms a freshly signed bundle before library registration; a tampered output is rejected. | `03-signature-receipt.txt` |
| 3.3 | Install over local OTA (`itms-services`). | If every external manifest endpoint fails its XML-plist probe, VexSign shows the install-link error and **does not open** `itms-services`. A successful install link points only to a positively verified endpoint. | `03-manifest-fallback.png`, `03-ota-link.txt` |
| 3.4 | Distinguish transfer states. | UI shows transfer started / requested / accepted / unconfirmed separately; OTA handoff never says "Installed" by itself. | `03-state-transitions.png` |
| 3.5 | Confirm installation. | Only a positively observed installed app (or installed other version) counts as confirmed; placeholder/new-install evidence is handled; filtered negative lookup stays unknown. | `03-confirmation.png`, `03-evidence-report.txt` |
| 3.6 | Launch the installed app by bundle ID. | App launches; record the Home Screen icon and launch timestamp. | `03-launch.png`, `03-launch.log` |
| 3.7 | Repeat with the pairing/idevice transport if configured. | Device's own result is reported; removal is reported "Removed" only after read-back shows absence. | `03-pairing-install.txt`, `03-removal.txt` |

## 4. Manage → update / re-sign → backup / restore

| # | Step | Pass criteria | Evidence |
| --- | --- | --- | --- |
| 4.1 | Rename, hide, clone, export and delete a library copy. | Installed app is untouched unless an explicit uninstall is confirmed; cloned bundle IDs are unique. | `04-library.png` |
| 4.2 | Add a source, download an update, check version matching. | Exact identity wins; ambiguous names/sources are not auto-selected; ETag/304 and cancellation behave; checksum verified. | `04-update.txt` |
| 4.3 | Re-sign with saved settings and with a reviewed override. | Original options replay; pinned certificate is honoured; background grant is certificate-bound and revocable. | `04-resign.txt` |
| 4.4 | Force-quit at each task phase, relaunch, inspect Task Center. | No blind resume, no duplicate import, no silent user-data deletion; corrupt journal is preserved. | `04-recovery.txt`, `04-journal-backup.json` (redacted) |
| 4.5 | Back up, reset, restore. | Schema/components validated; secrets excluded; collision skipped; rollback on failure; no data silently deleted. | `04-backup.txt`, `04-restore.txt` |

## 5. Security and privacy checks added in this pass

| # | Step | Pass criteria | Evidence |
| --- | --- | --- | --- |
| 5.1 | Generate a diagnostic log containing a fake `certificateP12`, `certificatePassword`, `SerialNumber`, `DeviceName`, UDID, Apple ID email and anisette header. | Exported log contains `<redacted>` markers; the email domain may remain but the local part does not; ordinary signing failure text and a bare 40-hex commit hash remain readable. | `05-redacted-log.txt` |
| 5.2 | Send a `vexsign://` certificate link with an oversized base64 payload. | No file is staged, no crash, the import is refused; memory does not spike. | `05-oversize-link.txt` |
| 5.3 | From a machine that can reach the optional server, probe a URL that redirects to `https://example.com:99999/app.ipa` and to a malformed IPv6 URL. | Endpoints return a clean `422` refusal, not HTTP 500; no request is sent to the malformed hop. | `05-server-guard.txt` |
| 5.4 | Inspect Settings for capability disclosure. | `nativeAppleAccountSigning` remains `.notIntegrated`; no free-account, JIT, unlimited background, wireless transport or ungranted-entitlement claim is presented as complete. | `05-capabilities.png` |

## 6. Real-device performance and fault injection (device only)

Follow the portable corpus instructions in
[remaining-roadmap-implementation.md](remaining-roadmap-implementation.md) but record **device**
numbers only: device model, iOS, build commit, scenario, file/entry count, input size, phase
start/end, elapsed, p95 over repeated runs, peak memory, physical bytes read, cancellation
latency, foreground/background survival, Wi-Fi → cellular → Wi-Fi, low storage, and observed
outcome. Leave unmeasured fields blank/null. Do not copy portable-host timings into device
results.

## 7. Evidence manifest

Create `acceptance-evidence/INDEX.md` listing every file above with SHA-256, device, iOS, build
commit, date and pass/fail/blocked. Include:

- CI run URL and job conclusions (`Build-verified`).
- Signed IPA provenance and profile/device eligibility.
- Redacted exported logs (never raw secrets).
- Screenshots of each install state and final Home Screen.
- Exact error texts for every refusal.
- A statement that `Device-verified` is achieved only for steps with an observable result; leave
  all other steps `Blocked (Device-verified)`.

No acceptance result is recorded in this repository yet. The matrix in
[feature-completion-matrix-2026-11-13.md](feature-completion-matrix-2026-11-13.md) remains
honest until this guide is executed with a real iPhone.
