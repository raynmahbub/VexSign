# Computer-free bootstrap acceptance

This is a procedure for a **physical iPhone** and a named tester. The source-level
checks in `make verify` and the simulator tests do not satisfy any case below.
A passing report is a human attestation bound to one exact IPA SHA-256 and source
commit; it is not independent device verification.

## What this acceptance flow changes in VexSign

- `BootstrapJourney` is the single evidence ledger for the guided flow. It
  accepts a step only when the previous step produced a well-formed observation
  (pairing format/fingerprint, selected-device identity, team identifier, exact
  IPA digest, signer fingerprint, installation receipt). Navigation, stored
  files and accepted requests never complete a step by themselves.
- `BootstrapOrchestrator` drives only the two native steps VexSign owns: the
  iOS 27+ on-device RPPairing host through `PairingHostBridge`, and a fresh
  device identity query through `PairingBridge`. It re-reads the protected
  pairing record after enrollment and refuses a device that does not match the
  selected UDID.
- The guided section in **Installation → Tunnel & Pairing** shows the route,
  blockers, step states and cancellation/retry controls. Account authorization,
  signing and installation remain in their existing features. The guide's single
  integration point is `BootstrapOrchestrator.recordHandoff(_:)`: it accepts their
  evidence instead of re-implementing those flows. This acceptance flow records the
  handoff observations from the existing screens and the installation receipt;
  a navigation action never fills a step by itself.
- Route detection uses the existing `DevicePairingRoute` and
  `PairingHostBridge.isSupported`. iOS 27+ with an available host is the only
  computer-free route. Earlier supported releases require a compatible pairing
  file and are explicitly not a computer-free pass.

## Prerequisites that are not provided by this flow

1. VexSign is already installed and launched through a legitimate development
   build, an eligible external installer, or authorized distribution. VexSign
   cannot install its own first copy.
2. On supported devices the user enables Developer Mode and confirms the pairing
   prompt in **Settings → Privacy & Security → Developer Mode**, and grants
   Local Network access when iOS asks. VexSign cannot enable either.
3. A compatible VPN such as LocalDevVPN is installed and activated by the user
   in its own app. The usual peer is `10.7.0.1`; an interface address such as
   `10.7.1.1` is not the peer.
4. The device is unlocked and the tester has independently checked the UDID in
   Xcode, Finder or a trusted pairing tool.
5. Paired AFC/`installd` installation is still gated by the accepted native
   inventory bridge. A completed pairing does not unlock it. Use an eligible
   companion or the signed-IPA export path when the gate is unavailable.
6. Account provisioning, seven-day renewal and container guests remain separate
   stages. This pass does not validate the Free Apple Account lifecycle.

## Procedure

Build an unmodified IPA from the commit under test, then create a pending report:

```bash
make
python3 Tools/Audit/device-acceptance.py init \
  --ipa packages/VexSign-<version>.ipa \
  --report device-acceptance.local.json \
  --include-computer-free-bootstrap
```

`--include-computer-free-bootstrap` creates nine pending cases and an empty
`bootstrap` evidence object. A report without the flag cannot acquire those
cases; a report with the flag and missing observations fails validation.

On the physical iPhone:

1. Place the exact built IPA on the device with an eligible external installer
   and launch VexSign. Record `bootstrap_accepts_unmodified_ipa`: the app that
   launched is built from this commit and this IPA checksum, not a previously
   installed copy.
2. Open **Installation → Tunnel & Pairing → Guided computer-free bootstrap**.
   Confirm the route reads **On-device pairing (no computer)**. No pairing file
   was imported and no computer was connected for this pairing. Record
   `bootstrap_no_computer_or_existing_pairing_file`.
3. Enter the verified device UDID and start the flow. VexSign displays a PIN;
   enter it in the Settings pairing prompt. Record
   `bootstrap_host_advertised_with_pin_confirmation` only if the PIN was
   actually shown and accepted on that device.
4. Let VexSign run its fresh identity query. Record
   `bootstrap_device_identity_verified` only when the answered UDID matches the
   selected one. Copy the reviewed pairing fingerprint from the pairing record
   into the report; it must be the exact 64-character lowercase SHA-256.
5. Open **Authorize Apple Account or certificate** from the guide. Complete the
   account or certificate step in the existing Accounts/Certificates flow,
   including two-factor authentication when the account requires it. Record
   `bootstrap_account_authorization_confirmed` only for the identity that was
   actually used, and record its team identifier.
6. Open **Choose an IPA and continue in Library**, sign and verify the package
   with the existing signing flow, then submit it through the existing install
   queue. Record `bootstrap_install_request_confirmed_on_device` only when the
   installed bundle identifier, version and build match this exact artifact.
   An accepted request, a queue completion or a package export is not enough.
7. Launch the installed app and record `bootstrap_installed_app_launches`.
8. Repeat once with **Cancel bootstrap** while the host is advertising. It must
   return to the cancelled state, claim no device authorization and allow a
   fresh retry with the same selected UDID. Record `bootstrap_cancel_recovery`.
9. Repeat once with the VPN disconnected or a blocked local route. The flow must
   fail without reporting a paired device or an installation, and must recover
   after the tunnel is restored. Record `bootstrap_network_failure_recovery`.

Fill in the structured evidence from the observations above:

- `pairing_route`: `ondevice-host`
- `pairing_fingerprint_sha256`: exact reviewed record SHA-256
- `device_udid`: the selected device's UDID
- `installed_bundle_id`, `installed_version`: read from the installed app

Then validate the attestation:

```bash
python3 Tools/Audit/device-acceptance.py check \
  --ipa packages/VexSign-<version>.ipa \
  --report device-acceptance.local.json
```

## What a pass does and does not prove

A pass proves a named tester observed the guided route, pairing confirmation,
selected-device identity, account authorization, exact-artifact installation and
launch on a physical iPhone, plus cancellation and network-failure recovery. It
does **not** prove background installation, bypassed signing rules, Free Apple
Account seven-day renewal, paired installation without the inventory bridge,
guest-app launching, or that a GitHub-hosted simulator job installed anything.

`computer-free-bootstrap` stays `needsDevice` in `FeatureStatusRegistry.swift`
until such a report exists for the shipped artifact. The report is local and
gitignored; do not commit pairing records, PINs, account credentials or reports
containing device identifiers.
