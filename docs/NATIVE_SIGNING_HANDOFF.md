# Free Apple ID → signing handoff

**Status: not implemented.** This document specifies the missing seam between the
experimental `NativeSigning` package and the signing pipeline that actually
produces IPAs. It exists so the gap is written down instead of being
rediscovered, and so the work can be reviewed before it is attempted.

Read [native signing architecture](NATIVE_SIGNING_ARCHITECTURE.md) first for the
package's own boundaries. This document is only about the join.

## The gap in one sentence

A free Apple ID can authenticate, select a team, register a device and record a
provisioning profile — and then stop, because nothing converts that identity and
profile into the `CertificatePair` + `.mobileprovision` pair the signer consumes.

The UI says so (`ProvisioningFlowView.swift`: *"Only the provisioning profile was
recorded. No app has been signed or installed. Native signing handoff is not
enabled in this build."*), and `SigningMethodCapabilities` reports
`nativeAppleAccountSigning: .notIntegrated`.

## Three gates, all currently closed

None of these are oversights to "just wire up". Each one needs its own change and
its own validation.

### 1. Profile creation is gated on a CMS verifier that production never supplies

`NativeProvisioningProfileValidator` refuses to validate anything without a
verifier:

```swift
func requireCMSVerification() throws {
    guard verifier != nil else { throw NativeProfileValidationError.cmsVerificationUnavailable }
}
```

and the bridge derives profile availability from exactly that:

```swift
// SideSignAccountBridge.swift:103
func profileOperationsAvailable() -> Bool { !closed && profileValidator.isConfigured }
```

Every construction site that supplies a verifier lives under
`NativeSigning/Tests/`. `NativeAppleProfileCMSVerifier`'s own header says it is
*"written but NOT native-compiled or cryptographically validated yet; not
selected by default"*. So in a shipping build `profileOperationsAvailable()` is
false, and `NativeSigningManager.requireProfileOperations()` fails before any
quota-affecting request. That is the intended fail-closed behaviour.

**What has been validated so far** (`NativeSigning/Fixtures/` and the
`testOpenSSLBuilt…` cases):

| Question | Evidence |
| --- | --- |
| Does the parser accept a real CMS SignedData envelope? | Yes for the parsed subset. `Fixtures/make_cms_fixture.py` generates one with OpenSSL and checks the exact constraints `NativeProfileCMSEnvelope.parse` enforces: v1, definite lengths, one SHA-256 digest algorithm, attached `id-data`, issuerAndSerialNumber, DER-sorted signed attributes with matching `messageDigest`, 256–512-byte RSA signature. |
| Is the subset the same one OpenSSL produces by default? | Yes. OpenSSL adds `signingTime`, which the parser carries without trusting it — a good default, because it means the parser does not depend on Apple's attribute set matching ours exactly. |
| Does a structurally valid envelope still fail Apple trust? | Yes. The fixture is self-signed with an ephemeral RSA-2048 key and `verifyAppleProvisioningCMS` rejects it; structural parse is deliberately not trust. |
| Does tampering get caught at the right layer? | Yes. A flipped payload bit breaks the `messageDigest` comparison (parse rejects); a flipped signature bit still parses (the signature is opaque to the envelope) and fails at `verifySignature` — confirmed with `openssl cms -verify`. |

**What is still missing to promote the verifier:** an Apple-issued profile
fixture or a device-captured CMS whose chain actually reaches one of the pinned
roots, a real `SecKeyVerifySignature` pass against it, and native compilation.
The pin set in `apple-cms-policy-review.json` has not been re-checked against
Apple's current roots.

### 2. No profile bytes leave the package

The import path VexSign already has takes two **files**:

```swift
FR.handleCertificateFiles(p12URL:provisionURL:p12Password:certificateName:)
```

The native side never produces the second one. `NativeAuthenticatedProvisioningProfile`
holds `encodedCMS` but has a `fileprivate` initialiser, the durable journal stores
only `cmsSHA256`, and the public result of a profile operation is:

```swift
public struct NativeAccountProfileResult: Sendable {
    public let operationID: UUID?
    public let profileUUID: UUID
    public let expiresAt: Date
}
```

A digest and a UUID cannot be signed with. There is no export surface to call.

### 3. No native identity reaches the certificate store

`NativeAccountBackend.exportSigningIdentity(contextID:identityID:password:consent:)`
does exist and returns PKCS#12 `Data`, behind a single-use
`NativeKeyExportConsent`. But it has no caller outside the package, and
`NativeSigningManager` exposes no method for it — the app cannot export even if
the user consents.

## What the handoff must do

Six stages. Stages 1 and 5–6 already exist; the work is 2–4.

| # | Stage | Owner | Invariant |
| --- | --- | --- | --- |
| 1 | Sign in, pick team, register device, get profile | existing (`NativeSigningManager`) | separate consents per mutation, no automatic revocation |
| 2 | Export the device identity as PKCS#12 | `NativeSigningManager` → `exportSigningIdentity` | single-use grant, password generated in-app, bytes never written outside the import handler |
| 3 | Export the profile bytes | **new native API** | fresh CMS validation at export time; digest must equal the recorded receipt |
| 4 | Import both into the standard certificate store | **new app adapter** → `FR.handleCertificateFiles` | team/profile/bundle/device must match before import; no second signing path |
| 5 | Sign | existing `SigningService` / Zsign | unchanged |
| 6 | Install and verify | existing install routes | unchanged |

Stage 4 is the point of the whole exercise: once the pair is a normal
`CertificatePair`, the free-Apple-ID flow inherits preflight, verification,
batch, tweaks and install routes instead of growing a parallel signer.

## Changes required

**NativeSigning**

- Add a profile export that returns bytes, e.g.
  `exportProvisioningProfile(contextID:identityID:bundleIdentifier:deviceIdentifier:) async throws -> Data`,
  re-running `validator.validate` and cross-checking `cmsSHA256` against
  `NativeProfileReceipt` before returning.
- Provide a production validator factory once the CMS verifier has passed native
  build and cryptographic review. Until then `isConfigured` stays false and
  stage 1 still ends at "profile recorded".
- Tests: export refuses without a current receipt; refuses on digest mismatch;
  refuses after consent expiry; returns exactly the validated bytes.

**App**

- `NativeSigningManager.exportToCertificateStore(...)`: stages 2–4, reporting
  through `UnifiedTaskCenter` like every other long operation.
- Preflight before import: the profile's team/bundle/device must match the
  selected identity and target app; otherwise fail with actionable text.
- Flip `SigningMethodCapabilities.nativeAppleAccountSigning` to `.implemented`
  **only** in the change that also passes the device matrix below, and delete the
  "not enabled in this build" copy in the same commit. A capability flag that
  flips ahead of the wiring is how the old `.implemented` claims went wrong.
- Remove the Free Apple ID caveat from `docs/FREE_APPLE_ID_SETUP.md` when, and
  only when, the flow completes on a device.

## Acceptance ladder

Nothing here can be validated in a Linux workspace; there is no Apple SDK.

1. `swift test --package-path NativeSigning` — new export tests.
2. Native link smoke with the reviewed dependency graph.
3. Simulator: capability still `.notIntegrated` before the flip; the export path
   compiles and fails closed with no receipt.
4. Physical device, dedicated test Apple ID, explicit consent:
   sign in → team → register → profile → export → import → sign a small test app
   → verify output → install → relaunch → confirm the profile expires in 7 days
   and the identity survives a VexSign relaunch.
5. Record the run with `tools/device-acceptance.py` (see
   [device acceptance](DEVICE_TESTING.md)).

## Explicitly out of scope

Scoped unattended renewal, native-owned signing without export, and the
combined-host/primary-host path. Those stay experimental and unimplemented; this
document does not change their status.

## Why the seam is not simply written today

Stage 2 alone would produce a certificate the signer accepts, which is worse than
the current state: the failure would move from "nothing happened" to "an identity
that cannot be renewed or re-exported, with quota already spent". Writing stages
2–4 against a profile that cannot be exported (gate 1 and 2) would be untestable
code plus a capability flag that lies. The order above keeps every intermediate
state honest.
