# On-device signing

## Supported path

VexSign already supports importing signing identities and signing IPA/app content locally through the existing certificate and Zsign pipeline. Reuse `VexSign/Utilities/Handlers/SigningHandler.swift`, `ZsignHandler.swift`, `VexSign/Utilities/Signing/ZsignEngine.swift`, `SignatureVerifier.swift`, `NestedBundleAudit.swift`, certificate import/inspection under `VexSign/Utilities/CertificateReader/`, protected certificate storage under `VexSign/Security/`, and `UnifiedTaskCenter`. Avoid a parallel signer or direct SwiftUI calls into the engine.

The user can import an IPA using Files/document providers and import an eligible `.p12` plus `.mobileprovision` through existing certificate/settings surfaces. Certificate/profile compatibility and signing completion must be verified by the existing signing pipeline; installing the resulting IPA still requires an eligible iOS handoff.

## Not all requests are supported

- A development certificate/profile is not interchangeable with Ad Hoc, Enterprise, or App Store distribution credentials.
- The native Apple-account experiment in `NativeSigning/` is not wired to signing. `SigningMethodCapabilities` deliberately reports native account signing as `notIntegrated`; documented CMS/profile gates remain closed.
- Network Extension, App Group, and other restricted entitlements may not be available to a Personal Team. Fail preflight rather than stripping or fabricating entitlements.
- Arbitrary apps cannot be installed by an ordinary app using unrestricted public iOS APIs.

## Transaction requirements for future workflow changes

Create a unique attempt ID and record input identity before work. Never mutate or replace the source IPA. Validate ZIP paths/layout and free space; inspect the profile and private-key match; check certificate/profile time bounds, bundle ID and entitlements; customize only in an isolated staging tree; sign the main app and every nested executable/bundle in correct order; verify all output signatures and provisioning; hash the final artifact; only then publish the output as successful. Route stages and cancellation/recovery through `UnifiedTaskCenter` and existing task history. A failed attempt must preserve the last known-good artifact and a provenance receipt.

Use Keychain and the existing protected-file mechanisms. Never put P12 passwords/private keys in `UserDefaults`, logs, task titles, crash reports, exported release bundles, or diagnostics. Do not send signing material to a remote service without a separately reviewed, explicit cloud-signing flow.

See [Personal Team limitations](apple-account-limitations.md) and [security boundaries](security.md).
