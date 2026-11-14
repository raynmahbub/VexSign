# Free Apple ID → signing handoff

**Status: code handoff implemented; production CMS promotion and device acceptance remain pending.**
`SigningMethodCapabilities.nativeAppleAccountSigning` therefore remains
`.notIntegrated`. Imported-certificate signing is still the supported path.
Flipping that claim is evidence-gated, not a source edit: see
[Promotion evidence gate](#promotion-evidence-gate).

Read [native signing architecture](../Architecture/NATIVE_SIGNING_ARCHITECTURE.md) for the package
boundaries. This document tracks the join between native provisioning and the
ordinary certificate-based signing pipeline.

## Implemented seam

The native account flow can authenticate, select a team, register a device/App
ID, create an identity and record a provisioning profile. The following handoff
code now connects that result to the existing certificate store:

| Stage | Implementation | Invariant |
| --- | --- | --- |
| Export profile | `NativeAccountBackend.exportProvisioningProfile` → `SideSignAccountBridge.exportProvisioningProfile` | Fresh portal download and CMS validation; exact owner, identity, profile UUID, bundle, device, certificate, expiry and CMS receipt-digest match |
| Export identity | `NativeSigningManager.exportToCertificateStore` → `exportSigningIdentity` | Separate short-lived, single-use `NativeKeyExportConsent`; cryptographically random password generated in the app |
| App preflight | `NativeSigningHandoffPreflight` | Rechecks team, identity phase, bundle, device, profile UUID, expiry, development certificate presence and restricted entitlements before consuming the key grant |
| Import pair | `FR.handleCertificateFiles` | Uses the existing `CertificatePair` + `.mobileprovision` pipeline rather than a parallel signer |
| Scratch cleanup | `NativeSigningManager.exportToCertificateStore` | Device-protected `0700` directory, `0600` files and `defer` removal |
| Progress | `UnifiedTaskCenter` | Completion means certificate import only, never signed or installed |

`ProvisioningFlowView` exposes the import only after an explicit private-key
export consent. Once imported, the user selects that certificate in the existing
signing flow. Provisioning does not automatically sign, install or renew an app.

Package regressions cover exact-byte export, missing receipts, CMS digest
substitution and expired consent. App regressions cover target, identity,
certificate, expiry and entitlement mismatches. Coordinator regressions exercise
exact-byte staging, `0700`/`0600` permissions, cleanup, pre-export and post-export
cancellation, import failure, and task-center terminal states using injected
synthetic operations; the production adapter still calls the same backend and
`FR.handleCertificateFiles` route. Synthetic CMS verification and injected import
operations are not evidence of Apple production trust or a real certificate import.

## Production gate still closed

`NativeProvisioningProfileValidator` refuses validation without a verifier, and
the production `NativeAccountBackend` still uses that default:

```swift
func requireCMSVerification() throws {
    guard verifier != nil else { throw NativeProfileValidationError.cmsVerificationUnavailable }
}
```

Consequently `profileOperationsAvailable()` is false in the shipping factory and
`NativeSigningManager.requireProfileOperations()` fails before quota-affecting
profile work. `NativeProvisioningProfileValidator.appleCMS()` is not selected by
production. The export and app handoff therefore compile and can be tested, but
do not turn an unaccepted CMS implementation into a supported account flow.

The existing OpenSSL-generated fixtures establish parser behavior and rejection
of self-signed/tampered input. They do **not** establish that an Apple-issued
profile reaches the pinned production roots or that the profile/device flow is
accepted by Apple. An Apple-issued profile fixture or device-captured CMS, a real
`SecKeyVerifySignature`/chain pass, current Apple root review and native test
execution are still required before selecting `.appleCMS()` in the production
factory.

Selecting `.appleCMS()` in production is a deliberate source change, and it is
not sufficient on its own: the capability claim is additionally gated on recorded
evidence (below), so a wiring edit cannot quietly promote the flow.

## Promotion evidence gate

Every check this repository can run itself — portable verification, native unit
regressions, simulator suites, link smoke, combined builds — passes without the
two missing observations. Promotion is therefore gated on an artifact rather than
on a code edit:

```bash
python3 Tools/Development/native-promotion-evidence.py init   # writes a pending record
python3 Tools/Development/native-promotion-evidence.py check  # refuses until it is genuine
```

The canonical record is `Documentation/QA/evidence/native-signing-promotion.json`, committed
with the change that flips the flag. It holds digests and observations only:
profile bytes, PKCS#12 material, passwords, private keys, UDIDs and device logs
never belong in Git, and blob-like values are rejected. A record is complete only
when all of the following hold:

| Requirement | Why |
| --- | --- |
| Apple-issued profile UUID, team ID, bundle ID, envelope and payload SHA-256 | Binds the observation to one real profile |
| `profile_source: apple_developer_portal_download` | Rules out generated or community-supplied material |
| `verifier: Security.framework_chain_and_SecKeyVerifySignature` | Names the production verification path, not the DER parser |
| Observed Apple roots plus verification and expiry timestamps | A plist parse is not a chain check |
| `synthetic_or_openssl_input_used: false`, with notes free of synthetic wording | Self-admitted fixtures cannot be relabelled as evidence |
| Digests differ from every committed `Packages/NativeSigning/Fixtures` digest | The OpenSSL fixture proves parser behavior only |
| `SideSignAccountBridge` defaults the validator to `.appleCMS()` | Evidence cannot promote an unwired verifier |
| Device report created with `--include-native-handoff`, digest-bound, all eight `native_*` ladder cases explicitly passed | The device matrix is part of the same claim |
| Report committed as a redacted copy under `Documentation/QA/evidence/` | `device-acceptance.local.json` is gitignored, and a record must be reviewable; private originals, screenshots and logs stay local |
| Evidence commit is the checkout or an ancestor of it | Promotion belongs to a revision |

`Tools/Development/check-native-handoff.py` (Makefile `verify` and the CI repository gates)
enforces the coupling in both directions: `.implemented` without complete
evidence, or without the production verifier, fails, and complete evidence while
the flag is still `.notIntegrated` also fails, so the flag, the UI caveat and
this document move in one change. A complete record is a human attestation bound
to a revision and an artifact digest. It is not independent verification of Apple
trust, and it does not make the flow supported on any device other than the one
recorded.

## Remaining acceptance ladder

1. Run the complete portable repository verification (`make verify`).
2. Run `swift test --package-path NativeSigning`, including the new export tests.
3. Run native link smoke and the combined-host build with the reviewed dependency graph.
4. Run the simulator suite, including app-preflight and fail-closed no-receipt coverage.

Steps 1–4 are reproducible in hosted CI and pass for the current handoff code.
They exercise synthetic CMS bytes and injected import operations, so they are not
promotion evidence and they do not narrow the gates above.

5. With a dedicated physical device and test Apple ID, explicitly exercise:
   sign in → team → register → profile → export → import → sign a small test app
   → verify output → install → relaunch → confirm seven-day expiry and identity
   persistence across a VexSign relaunch.
6. Record that run with `Tools/Development/device-acceptance.py init --include-native-handoff`,
   which adds the eight `native_*` ladder cases to the ordinary report (see
   [device acceptance](../QA/DEVICE_TESTING.md#free-apple-id-handoff-ladder-pending)).
7. Record the Apple CMS observations and bind them to that report with
   `Tools/Development/native-promotion-evidence.py`, then re-run `Tools/Development/check-native-handoff.py`.

Only after production CMS promotion and the device matrix should the capability
flip to `.implemented`, the pending-integration UI copy be removed, and the Free
Apple ID setup guide describe the flow as supported.

## Explicitly still out of scope

Scoped unattended renewal, native-owned signing without certificate-store
export, automatic sign/install after import, and the combined-host/primary-host
path. Their experimental status is unchanged. Real provider, Apple-account,
certificate, profile, code-signature and physical-device outcomes must not be
inferred from portable checks, synthetic fixtures or successful compilation.
