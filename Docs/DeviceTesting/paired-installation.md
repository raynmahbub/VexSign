# Paired installation acceptance

This is the acceptance procedure for installing an exact signed IPA over an
admitted pairing route. Source checks, simulator runs and a command
acknowledgement cannot satisfy a case. A report is a named tester's attestation
bound to one exact IPA SHA-256 and source commit; it is not independent device
verification.

## What this acceptance flow changes

It does **not** turn on the installation bridge. The vendored
`InstallationAppProxy.hasAcceptedInventoryBridge` stays `false`, so a normal
build refuses the paired route before packaging. That refusal is deliberate:
pairing, a readable record, an active VPN or a successful device query does not
authorize an installation mutation.

What is new:

- `PairedInstallationJourney` is a pure evidence ledger over the existing
  owners (`PairingBridge`, `InstallPreflight`, `PairedInstallationValidation`,
  `InstallQueue`, `InstallConfirmation`, installed-app inventory). It is not a
  second installation coordinator. In this build it is a tested policy seam; it
  is not an active runtime recorder, because the bridge gate below is closed.
- It keeps four outcomes separate: route/pairing admission, exact artifact
  validation, installation-request acknowledgement, and exact installed-app
  confirmation followed by a user-observed launch. A navigation callback, a
  private negative, a different version or a reused receipt cannot fill a later
  step.
- `device-acceptance.py --include-paired-installation` records eight explicit
  cases plus structured evidence. It validates that the package digest is the
  exact IPA in the report, that the confirmation receipt differs from the
  submission acknowledgement, and that confirmation is not before submission or
  after the report timestamp.
- The opt-in ladder is independent of the computer-free bootstrap and Apple
  Account ladders. A report cannot inherit a pass from either.

## Gate policy

| Route | Local admission |
|---|---|
| Below iOS 17.4 | Unsupported |
| iOS 17.4–26.3 with a classic record | Candidate only: VPN, consent, device trust and the accepted bridge are still required |
| iOS 26.4–26.7 | Remote Pairing record required; the pinned bridge has no accepted modern loopback route |
| iOS 26.8–26.x | Unknown OS; no route is enabled |
| iOS 27+ with an on-device RPPairing host | Candidate only: explicit pairing/PIN, VPN, consent, device trust and the accepted bridge are still required |

A candidate route is not an installation pass. The bridge gate may be enabled
only in a reviewed candidate build whose commit and IPA are the ones the report
attests. The shipping gate stays closed until that evidence exists.

## Procedure

Create a pending report bound to the candidate commit and unmodified IPA:

```bash
python3 Tools/Audit/device-acceptance.py init \
  --ipa packages/VexSign-<version>.ipa \
  --report paired-installation.local.json \
  --include-paired-installation
```

On a physical iPhone:

1. Confirm the OS route and that the candidate build's accepted inventory bridge
   is the one under test. Record `paired_route_and_bridge_admitted`.
2. Pair or import a record for that route. Verify the stored record's SHA-256,
   start the pairing VPN, grant device-service consent and run a fresh device
   query. Its UDID and pairing fingerprint must match the selected device.
   Record `paired_record_fingerprint_matches_device_query`.
3. Sign a complete IPA and let `PairedInstallationValidation` verify the exact
   bundle identifier, version, build, nested-code manifest, signer, profile and
   device-family slices. Record `paired_signed_artifact_validated`.
4. Submit through the existing install queue. Record
   `paired_install_request_accepted` only for a real, bounded submission receipt.
   A command acknowledgement is not an installation.
5. Wait for `InstallConfirmation` to obtain a positive, same-device,
   exact-version installed-app reading made after the submission. Record
   `paired_exact_version_confirmed`.
6. Open the app on the Home Screen and record `paired_app_launch_observed`. This
   is a separate human observation; a device inventory record cannot fill it.
7. Repeat with an unanswered prompt or lost command response. The UI must end
   as unconfirmed with a check-device-first retry, never as installed. Record
   `paired_timeout_leaves_outcome_unknown`.
8. Cancel one attempt and retry after the session is free. Record
   `paired_cancel_and_retry_recovers`.

Fill `paired_installation_evidence` from those observations:

- `pairing_route`: `imported-classic` or `ondevice-host`
- `pairing_fingerprint_sha256`, `device_udid`, `package_sha256`
- `install_receipt`, `confirmation_receipt` (must differ)
- `installed_bundle_id`, `installed_version`
- `submitted_at_utc`, `confirmed_at_utc`

Then validate:

```bash
python3 Tools/Audit/device-acceptance.py check \
  --ipa packages/VexSign-<version>.ipa \
  --report paired-installation.local.json
```

## What a pass does and does not prove

A pass proves a named tester observed an admitted route, matching pairing and
device identity, exact artifact validation, a bounded submission, an exact
installed-app reading and a separate launch, plus timeout and cancellation
recovery.

It does **not** prove universal pairing-file compatibility, a bypass of Apple's
signing/provisioning rules, automatic retry after an unknown outcome, or an
installation by any build that still reports the bridge as unaccepted. Do not
commit pairing records, private keys, account tokens, PINs or raw device
reports.
