# Apple Account signing lifecycle acceptance

This is a physical-device procedure for the Free/Paid Apple Account path. Source
checks and simulator tests cannot satisfy a case. A passing report is a named
tester's attestation bound to one exact IPA SHA-256 and source commit; it is not
independent device verification.

## Scope

The existing owners are unchanged and remain authoritative:

- `NativeAccountBackend` owns authentication, anisette consent, two-factor
  challenges, team selection, certificate creation, App ID/device registration,
  profile creation and the CMS-authenticated profile verifier.
- `AppleAccountWorkspaceAdapter` owns the receipt-bound profile/key handoff into
  the ordinary certificate store and the attended refresh pipeline.
- `ManualAccountRefreshCoordinator`, `AccountRefreshPipeline`,
  `RenewalScheduleCoordinator` and the existing signing/install queue own the
  refresh, signing, installation and deadline stages.

What is new:

- `AppleAccountLifecyclePolicy` is a pure policy evaluated **after the Apple
  portal preflight and before any portal mutation**. It uses Apple's documented
  [Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account/):
  10 App IDs and 3 registered devices (each for 7 days), 3 apps per device, and
  provisioning profiles that expire 7 days after issue. Renewing an app already
  in Apple's inventory does not consume another App ID slot. Each limit carries
  its source and validity; a portal count that was not observed is `unknown`
  and a new registration is refused rather than guessed. The local profile
  journal is explicitly not used as portal quota. A team whose
  developer-program enrollment is unverified cannot provision at all.
- The policy also classifies the Apple-issued profile expiry against the
  expected free-account ceiling as an advisory, and states the renewal mode:
  attended and manual. Nothing in this build renews a profile in the background.
- `device-acceptance.py --include-apple-account-lifecycle` records eight explicit
  lifecycle cases plus structured evidence. Free reports must show no more than
  10 App IDs, 3 registered devices and a roughly seven-day profile lifetime; a
  partial, undeclared or forged report fails validation.
- `SigningMethodCapabilities.nativeAppleAccountSigning` stays `.notIntegrated`.
  The account flow exports an Apple-issued certificate and profile into the
  ordinary certificate store and the imported-certificate engine signs with
  them. This flow does **not** claim an in-process CMS signer, and it does not
  change the promotion evidence gate.

## Account matrix

| Team | Local provisioning admission | Profile expectation | Renewal |
|---|---|---|---|
| Free | At most 10 Apple-observed App IDs and 3 devices; portal count required for a new registration | About seven days | Attended manual refresh only |
| Paid, verified (requires a verified signal; not produced from a team label alone) | No local free-account ceiling is imposed | Issuer-defined | Attended manual refresh; imported-certificate lifecycle remains separate |
| Individual/organization label without verified enrollment | Classified unverified and refused before any portal mutation | None | None |

These numbers are a local, source-labelled transcription of Apple's published
Personal Team rules, not a live portal response. Apple remains the authority for
issuance, quotas and revocation, and may change the published limits.

## Procedure

Create a pending report bound to the commit and the exact unmodified IPA:

```bash
python3 Tools/Audit/device-acceptance.py init \
  --ipa packages/VexSign-<version>.ipa \
  --report device-acceptance.local.json \
  --include-native-handoff \
  --include-apple-account-lifecycle
```

The lifecycle ladder requires `native_handoff: true`; it cannot be declared on
its own. On a physical iPhone:

1. Sign in with a free Apple Account in **Settings → Signing Methods**. Complete
   the two-factor challenge when Apple asks and select the team explicitly.
   Repeat with a paid developer account when one is available. In this build an
   individual/organization team without a verified membership signal is shown
   as **unverified** and cannot provision; record that honestly rather than
   treating the label as paid enrollment. Record
   `account_free_and_paid_teams_observed` and
   `account_two_factor_challenge_confirmed` only for the teams actually used.
2. In **Provision & Sign**, choose an imported app, its target UDID and the three
   portal mutations (certificate, registration, profile). Verify that the
   authenticated profile is scoped to that team, app, device and identity.
   Record `account_certificate_and_profile_created`.
3. With the free team and 10 active App IDs already in Apple's portal, attempt
   an 11th, different bundle ID. VexSign must refuse locally **before** requesting
   any certificate, device or App ID mutation. Then renew one of the existing
   apps and confirm that path is still admitted. Separately, with three devices
   already registered, attempt to register a fourth and confirm it is refused.
   Record `account_free_quota_observed` only for the cases actually exercised.
4. Approve the key export, confirm the exact identity import, sign the retained
   IPA with the imported-certificate engine and submit it through the existing
   install queue. Record `account_signed_artifact_installed` only when the
   installed bundle and version match this artifact and the install receipt is
   real. A queued request is not an installation.
5. Observe the profile expiring after about seven days and confirm the app stops
   launching when it lapses. Record `account_seven_day_expiry_observed`.
6. Open the attended refresh with the same app, approve each stage again and
   confirm the installed profile expiry advances. Record
   `account_manual_renewal_advances_expiry`. No background or unattended pass
   may fill this case.
7. Cancel a sign-in or provisioning attempt once and retry it after the session
   is free. Record `account_cancel_and_retry_recovers`.

Fill the structured evidence from those observations:

- `account_kind`: `free` or `paid` (the ladder's seven-day check applies to `free`)
- `team_identifier`, `profile_uuid`, `profile_expires_utc`
- `signed_ipa_sha256`, `installed_bundle_id`, `install_receipt`
- `active_app_id_count`: the free account's Apple-observed active App ID count
- `registered_device_count`: the free account's Apple-observed device count

Then validate:

```bash
python3 Tools/Audit/device-acceptance.py check \
  --ipa packages/VexSign-<version>.ipa \
  --report device-acceptance.local.json
```

## What a pass does and does not prove

A pass proves a named tester observed both team kinds, 2FA, certificate and
profile creation, the free-account ceiling before portal mutation, an exact
artifact signed and installed, seven-day expiry, an attended renewal that
advanced the expiry, and cancellation recovery.

It does **not** prove an in-process Apple Account CMS signer, automatic or
background renewal, unrestricted portal quotas, a bypass of revocation, or a
guest/container launch. The in-process signer remains gated by
`Tools/Validation/security-validation/native-promotion-evidence.py`. Do not
commit pairing records, private keys, passwords, account tokens or raw device
reports.
