# Native IPA signing and signature verification

This document describes the signing path that is actually compiled into VexSign. It is a code
map and an evidence boundary, not a claim that a physical device accepted the output.

## One pipeline

All signing entry points — the signing sheet, Update All, batch jobs and automation — converge on
`PackageSigningCoordinator.signPackage`. That coordinator resolves and re-checks the reviewed
identity, opens a unified task, and starts `SigningService`. `SigningService` owns cancellation,
per-app admission and the event stream; `RunSigningUseCase` forwards progress and emits exactly
one terminal event. `SigningPipeline` is the worker: it copies the source bundle into a unique
temporary work directory, applies modifications, signs, verifies, and registers the output.

The native signer is the pinned vendored `Zsign` package (pin and licence recorded in
`Packages/Vendor/manifest.json`). `ZsignEngine` is the only seam to it; `ZsignHandler` acquires a
process-wide permit, resolves the exact leased identity from `SigningIdentityStore`, builds a
component plan with `SigningResolutionSession`, writes only the authenticated proto/entitlement
bytes into a protected workspace, and hands a single request to `ZsignAdapter`. Nested
frameworks, dylibs, extensions, Watch and plug-in bundles are discovered and assigned their own
profile and identity expectations by that plan — they are not guessed from a path suffix at
verification time.

## Checks that can stop a run

- The identity is selected by opaque reference; private-key access is proved before signing and
  re-checked against the reviewed inputs immediately before the native call. No alternate
  certificate is substituted.
- Provisioning profiles are parsed and checked for team, App ID, certificate fingerprint, device
  authorization, expiry and capability grants. Requested entitlements are resolved per component
  and rejected when they would expand what the profile grants; a custom plist cannot silently
  remove a required capability.
- Mach-O images are inspected for valid headers, load commands, slices and signature bounds.
  Malformed or unsupported structures throw typed errors; imported code is never executed.
- Source IPA files are copied, never rewritten in place. Extraction and signing use bounded,
  unique work directories, with cleanup on success, failure and cancellation.
- After the engine returns, `SignatureVerifier` independently checks every architecture's
  SuperBlob layout, CodeDirectory header and page hashes, CMS signer fingerprint and validity,
  agreement between slices, embedded profiles, entitlement slots and resource-envelope hashes.
  `requireVerified()` must accept before the output is registered; an incomplete or import-only
  inspection is never described as a fresh device signature.

## Result reporting

The accepted verifier report is converted by `SigningVerificationReportBuilder` into a bounded,
redacted `SigningVerificationReport`: verdict, counts, issue codes, accepted signer fingerprints,
architecture count, component count and duration. It travels as `.verificationReport` alongside
`.signatureVerified`, is stored on the task's `TaskSigningTrace`, and is displayed in the signing
workflow panel. Nothing in the UI derives a report from a stage or a successful registration.

## What this does not establish

- Verification is performed on the iOS sandbox/app process and its own file reads. It does not
  replace Apple's installation checks on a physical device, device-pair trust, or an actual
  launch.
- `NativeSigningManager` and the Free Apple ID handoff remain capability-gated: they record
  material for review and do not mint or renew Apple certificates. Physical-device acceptance
  evidence is still tracked separately.
- The pinned engine emits its specific CodeDirectory layout; verifier checks fail closed on
  layouts it does not understand rather than accepting unknown signatures.
- Hosted CI and simulator runs exercise source policy and deterministic fixtures. Only the
  explicitly selected physical-device flows can establish installation and launch behavior.
