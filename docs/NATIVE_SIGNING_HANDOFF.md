# Free Apple ID → signing handoff

**Status: code handoff implemented; production CMS promotion and device acceptance remain pending.**
`SigningMethodCapabilities.nativeAppleAccountSigning` therefore remains
`.notIntegrated`. Imported-certificate signing is still the supported path.

Read [native signing architecture](NATIVE_SIGNING_ARCHITECTURE.md) for the package
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

## Remaining acceptance ladder

1. Run the complete portable repository verification.
2. Run `swift test --package-path NativeSigning`, including the new export tests.
3. Run native link smoke and the combined-host build with the reviewed dependency graph.
4. Run the simulator suite, including app-preflight and fail-closed no-receipt coverage.
5. With a dedicated physical device and test Apple ID, explicitly exercise:
   sign in → team → register → profile → export → import → sign a small test app
   → verify output → install → relaunch → confirm seven-day expiry and identity
   persistence across a VexSign relaunch.
6. Record genuine results with `tools/device-acceptance.py` (see
   [device acceptance](DEVICE_TESTING.md)).

Only after production CMS promotion and the device matrix should the capability
flip to `.implemented`, the pending-integration UI copy be removed, and the Free
Apple ID setup guide describe the flow as supported.

## Explicitly still out of scope

Scoped unattended renewal, native-owned signing without certificate-store
export, automatic sign/install after import, and the combined-host/primary-host
path. Their experimental status is unchanged. Real provider, Apple-account,
certificate, profile, code-signature and physical-device outcomes must not be
inferred from portable checks, synthetic fixtures or successful compilation.
