# On-device foundation physical acceptance

**2026-11-13 — procedure only. All F01–F20 and I01–I06 are PENDING.**

No physical phone, Apple Account, real signing identity, paired session, signed
IPA installation or installed-version read-back was used in this implementation
workspace. Nothing below is a recorded pass. Synthetic unit fixtures, policy
checks, a successful build and refusal of an unsupported feature do not establish
positive end-to-end acceptance.

This checklist supplements, not replaces, [DEVICE_TESTING.md](DEVICE_TESTING.md),
[SIGNING_LIBRARY_ACCEPTANCE.md](SIGNING_LIBRARY_ACCEPTANCE.md), and the older
numbered signing/installation scenarios linked there. F-numbers below are manual
foundation checks; `device-acceptance.py` does not automatically validate them.
See [exact-source build/test instructions](../Architecture/on-device-foundation-status.md#manual-build-and-test-instructions).

## Safe preparation and evidence

Use a spare iPhone/iPad, dedicated test account/identity and a harmless IPA you are
authorized to sign/install. Back up first. Do not rotate/revoke unrelated
certificates, consume quotas without explicit approval, change the primary device
clock, bypass Developer Mode/trust/signing rules, or upload a pairing record/key
to a VexSign backend. Do not put paired phones or private identities on runners
accessible to untrusted pull requests.

For **each** scenario, retain locally:

- Date/time and scenario ID; result PENDING / observed pass / observed fail with
  reason. A dependency-blocked positive path remains PENDING, not inferred pass.
- Exact reviewed candidate commit and whether the source tree was clean. The
  starting `e68423687674cbddd75052db19fb6e0f70dd7173` is the base, not this
  candidate's final source identity. For a dirty experiment also record a
  private patch/source hash; do not claim clean-commit acceptance.
- Actual signed IPA SHA-256 (after any re-sign), bundle ID, short version/build,
  signing class, actual profile expiry and compatible device scope. A nominal
  free-account lifetime is not proof of the issued profile's expiry.
- Device model, iOS version/build, private device alias, actual intended/queried
  identity match, pairing **format**, selected peer/transport and service results.
  Keep the full UDID, device name, record/host UUID and network identity private.
- Redacted task report and relevant screenshots/device installation evidence,
  exact observed version/build after launch and again after relaunch; real CI run
  URL, head SHA and individual job conclusions if available.

Keep raw pairing plists, P12/private keys, Apple credentials, session tokens,
cookies, anisette material and unredacted device logs **out of Git, issues, chat,
PR artifacts and public CI**. Never fabricate an empty/generic receipt to fill a
missing observation. Hash public/redacted evidence files only after inspecting
for secrets. Full device identity can be compared privately without including it
in exported diagnostics.

## F01–F20

| ID | Scenario and required observation | Current result |
| --- | --- | --- |
| F01 | **Legitimate first install / cold launch.** Install the exact eligible development or authorized-distribution build using the existing trusted route. Confirm no unsigned-download/self-bootstrap claim; guide separates initial installation from pairing, signing and subsequent installation. Record model/OS/build/source/IPA hash. | PENDING |
| F02 | **Invalid and oversized imports.** Try empty, malformed, duplicate/nested XML/binary, wrong-type, unknown-version, mismatched remote-key and over-2-MiB inputs. No native session; no crash; existing reviewed bytes survive; original document-provider scope closes. Synthetic fixtures test rejection only, not trust. | PENDING |
| F03 | **Real record formats / identity.** With authorized exports, inspect classic, remote and combined records without conversion. Missing device UDID requires explicit target selection; remote host UUID never becomes device UDID; conflicting aliases are refused. Preserve original bytes privately; do not attach them as evidence. | PENDING |
| F04 | **Reviewed replacement / changed review.** Cancel replacement, then change/delete the stored record between review and commit through a controlled local test. Re-review required; no silent overwrite. First import refuses a newly appeared destination. Exercise malformed-but-bounded old-record review separately from unreadable/oversized refusal. | PENDING |
| F05 | **Explicit export / picker lifecycle.** Choose a trusted destination, cancel, swipe-dismiss, attempt while another presentation is busy, and terminate/relaunch after preparing an export. Original bytes remain protected; temporary cleanup occurs or protected bounded recovery retains ownership. No companion receipt/compatibility claim; no automatic sharing. Inspect protection/backup attributes on hardware with authorized local tooling, never by exporting credentials to CI. | PENDING |
| F06 | **Reviewed deletion.** Explicitly delete the unchanged reviewed local record; cancel another attempt. Local deletion is not device trust revocation and does not delete external exported copies. Stale review is refused; no unrelated identity or certificate is removed. | PENDING |
| F07 | **Eligible classic route / fresh device query.** On a genuinely eligible 17.4–26.3 device, activate compatible transport yourself, grant protocol consent, select the intended UDID, and query. Actual returned UniqueDeviceID/OS/build and required services must match; session closes after the query. A success label describes only that query, not a live session, Developer Mode proof or installation capability. | PENDING |
| F08 | **Wrong-device authorization.** Select a different known device ID and use a record with a missing/mismatched UDID. No mutation is possible; actual query identity mismatch fails authorization without printing either full identifier. Do not test with an unauthorized device. | PENDING |
| F09 | **VPN / local permission / peer failures.** VPN off, wrong peer, own interface, localhost/public address, refused connection, Local Network denied and unreachable peer produce distinct safe recovery. Opening LocalDevVPN does not activate it. An open socket never grants trust; EPERM never diagnoses pairing revocation by itself. | PENDING |
| F10 | **26.4–26.7 import route.** Classic-only input never becomes compatible remote pairing. A recognized remote record can be preserved/exported, but the unaccepted native loopback bridge remains unavailable and no pairing/PIN generation is attempted. Computer/companion prerequisite is explicit. Positive modern transport acceptance remains pending until a reviewed bridge exists. | PENDING |
| F11 | **27+ host and unknown OS gates.** No on-device host, PIN or advertisement is fabricated. Imported remote bytes do not bypass the host/bridge gate. 26.8–26.x outside the reviewed matrix remains unknown/unavailable. Test the actual OS available; unowned/unavailable OS versions stay pending rather than using a simulator as physical proof. | PENDING |
| F12 | **Developer Mode / trust / locked device.** Disabled/unknown Developer Mode, locked/protected storage, revoked pairing and trust refusal do not silently regenerate keys, enable settings or claim authorization. Follow contextual user recovery; keep genuine device error evidence redacted. No guaranteed public detection API is assumed. | PENDING |
| F13 | **Native cancellation / timeout / single admission.** Cancel at each real query stage, induce transport failure and, with an instrumented build if necessary, a blocked native call. Waiter ends within its budget; actual native memory/slot is retained until retirement; new work is refused busy; no force-free, duplicate continuation or stale success. Record native-vs-fixture distinction and observed latency. | PENDING |
| F14 | **Foreground/background / VPN loss / changing input.** Background during query, disconnect transport, revoke consent and change target/peer before retry. No automatic handshake, stale verified summary or cached native handles survive. Relaunch shows an interrupted setup task and requires a new explicit query. | PENDING |
| F15 | **Storage recovery / low storage / migration.** Exercise interruption around staging/commit, low space, locked Data Protection, Documents migration with an existing private record, substituted ancestor links and export-recovery limits on controlled test data. Previous usable bytes or completed new bytes remain honest; colliding legacy bytes are private; no Documents fallback. Record any power-loss limitations, not an assumed durability guarantee. | PENDING |
| F16 | **Imported paid identity / local signing.** Without Apple Account login, import an authorized P12/profile and harmless IPA through existing owners. Verify profile/device/expiry, entitlements, nested signing, DER/CMS/output checks, failure cleanup and tamper refusal. A registered signed artifact is not installed success. No new signer or backend key upload. | PENDING |
| F17 | **Existing account / provisioning security gates.** With a dedicated account only after explicit authorization, exercise existing sign-in/2FA/session/team/registration/key/profile recovery and quota-affecting approvals. Genuine Apple CMS trust must pass its independent gate before promotion. Production stays closed when evidence is absent; synthetic CMS/quota fixtures and a gate-refusal test are not native-account signing acceptance. Do not revoke unrelated identities. | PENDING |
| F18 | **OTA / external handoff honesty.** Use an otherwise eligible signed IPA and current supported external/OTA route. Prompt/transfer/accepted/unconfirmed/cancel states remain separate; no private progress or silent paired retry. With no supported exact device response, task/library stay unknown/unconfirmed. Verify manually on the Home Screen and record actual version/build without relabelling that as automated VexSign read-back. | PENDING |
| F19 | **Future paired install / inventory / library receipt.** Currently blocked before staging/upload/command. Positive acceptance requires reviewed typed native ownership, fresh same-device bundle + nonempty expected version/build read-back, cancellation/timeout, exact library propagation and a versioned persisted receipt that survives relaunch. Another/missing version/build must not succeed; removal needs authoritative same-device absence. Leave positive workflow pending while any prerequisite is missing. | PENDING |
| F20 | **Persistence / retry / diagnostics / self-update boundaries.** Relaunch after record/task operations and an actual eligible install/update. Unsupported historical success downgrades to unconfirmed; missing handoff is not recorded, not proof nothing was sent. Check-device-first retry avoids duplicate installs; only read-only setup retry is automatic. Exported diagnostics omit keys/full identifiers and retain failure stage. Self-update blocks before reading/uploading signing material, private suspension or route switching. Record actual profile expiry/version/relaunch, not a banner. | PENDING |

## Completion criteria

For every observed result identify exact evidence and SHA-256, distinguish a
successful safety refusal from an accepted positive workflow, and leave remaining
paths PENDING. Do not enable inventory, modern pairing or native CMS/account
capability merely to run the table. A future accepted dependency must undergo its
own source/binary/header/license/deadline review first.

Overall implementation completion requires genuine supported workflows, exact
source/build provenance, real candidate Actions conclusions and all applicable
physical acceptance. **None of those missing observations is supplied by this
procedure. No physical result is recorded here.**

## I01–I06 · integrated inventory/submission evidence

These extend F01–F20. All are **PENDING**. Source integration and CI do not prove
a real phone accepted these operations. Do not bypass the native mutation gate
merely to collect a green screenshot; complete dependency/ownership review and
use a separately reviewed authorized test candidate.

| ID | Scenario and required observation | Current result |
| --- | --- | --- |
| I01 | **Read-only positive CoreDevice metadata.** Query a harmless known installed app on the explicitly selected classic-route device. Compare actual short version/build independently. Query a missing/filtered app, an App Clip and a malformed result in an instrumented build; omission is Unknown, never Not installed. Inspect cleanup with the pinned native binary, including zero results and native conversion failures. | PENDING |
| I02 | **Exact signed payload admission and transmitted bytes.** Use a legitimately signed harmless IPA. Confirm copied main/nested signatures, authenticated profiles, device scope and minimum OS are verified before zipping. Tamper version/build, signature, nested code, archive bytes, inode/size and staging links in controlled test inputs. No rejected target reaches installd. Expiry or an OS change during a slow upload requires new preparation. | PENDING |
| I03 | **Stop versus command boundary.** Stop during copy, zip, AFC upload and immediately around the instrumented native command boundary. Stop first must prevent the command even before waiter cancellation arrives; Stop after boundary records an uncertain handoff, not cancelled iOS installation. Do not force-free the worker or overlap the next command. | PENDING |
| I04 | **Acknowledgement versus fresh exact read-back.** After the actual command returns, compare bundle/version/build on the same device and frozen record. A wrong build, stale pre-ack observation, replaced record, device switch, filtered inventory or lost response cannot complete the task, increment installed analytics or delete the signed Library copy. Retain actual positive metadata, not expected values. | PENDING |
| I05 | **Library and receipt isolation.** Verify visible and later-mounted rows use exact build and selected-device binding. Change target/peer, revoke consent and replace/delete the record while reads retire; a late result cannot reselect the target. Round-trip a real dated receipt through restart; retain its dated observation but never use history to seed current installed badges. Legacy reason-only history stays unconfirmed. Export no raw device/record/app identifiers. | PENDING |
| I06 | **Ambiguous command failure / remote staging.** With a controlled dedicated device, interrupt the command response after submission. Report Unknown/check-device-first and do not retry automatically. Preserve only the attempt's staged IPA while installd may consume it; clean normal pre-submission failures and known completed commands. Record retained remote space and the lack of automatic orphan reclamation, not an assumed cleanup pass. | PENDING |
