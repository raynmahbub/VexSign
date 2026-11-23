# On-device signing

## Supported path

VexSign already supports importing signing identities and signing IPA/app content locally through the existing certificate and Zsign pipeline. Reuse `VexSign/App/iOS/Infrastructure/Signing/Execution/SigningHandler.swift`, `ZsignHandler.swift`, `VexSign/App/iOS/Infrastructure/Signing/Engines/Zsign/ZsignEngine.swift`, `SignatureVerifier.swift`, `NestedBundleAudit.swift`, certificate import/inspection under `VexSign/App/iOS/Infrastructure/Identity/Certificates/`, protected certificate storage under `VexSign/App/iOS/`, and `UnifiedTaskCenter`. Avoid a parallel signer or direct SwiftUI calls into the engine.

The user can import an IPA using Files/document providers and import an eligible `.p12` plus `.mobileprovision` through existing certificate/settings surfaces. Certificate/profile compatibility and signing completion must be verified by the existing signing pipeline; installing the resulting IPA still requires an eligible iOS handoff.

## Not all requests are supported

- A development certificate/profile is not interchangeable with Ad Hoc, Enterprise, or App Store distribution credentials.
- The native Apple-account experiment in `VexSign/Packages/NativeSigning/` is not wired to signing. `SigningMethodCapabilities` deliberately reports native account signing as `notIntegrated`; documented CMS/profile gates remain closed.
- Network Extension, App Group, and other restricted entitlements may not be available to a Personal Team. Fail preflight rather than stripping or fabricating entitlements.
- Arbitrary apps cannot be installed by an ordinary app using unrestricted public iOS APIs.

Free Apple ID profiles last seven days and every app expires with them. **Nothing in this build renews a profile for you.** `NativeSigningManager.refreshRenewalCandidates` only lists the profiles that are close to expiring, and the signed-app renewal path stays behind an explicit grant that is not implemented, so the app labels the method "Renew by hand each week" instead of advertising a refresh.

## Transaction requirements for future workflow changes

Create a unique attempt ID and record input identity before work. Never mutate or replace the source IPA. Validate ZIP paths/layout and free space; inspect the profile and private-key match; check certificate/profile time bounds, bundle ID and entitlements; customize only in an isolated staging tree; sign the main app and every nested executable/bundle in correct order; verify all output signatures and provisioning; hash the final artifact; only then publish the output as successful. Route stages and cancellation/recovery through `UnifiedTaskCenter` and existing task history. A failed attempt must preserve the last known-good artifact and a provenance receipt.

Use Keychain and the existing protected-file mechanisms. Never put P12 passwords/private keys in `UserDefaults`, logs, task titles, crash reports, exported release bundles, or diagnostics. Do not send signing material to a remote service without a separately reviewed, explicit cloud-signing flow.

## What a failed run says

A signing run can stop for a reason the user has to act on — no certificate, an expired or
revoked one, a tweak archive the app cannot unpack, a `.deb` whose envelope is unreadable, a
server body over a fetch cap. Each of those has to carry a sentence, because the sheet, the
task history and the diagnostics bundle all render `localizedDescription`: an error that is a
bare `Error` reads "The operation couldn't be completed. (VexSign.Rejection error 1.)".

The copy therefore lives with the error, not with the view:

| Where | What it says |
| --- | --- |
| `SigningRejectionMessages.swift` | the certificate refusals `SigningPipeline` returns before any work starts |
| `AppleAccountSessionErrorMessages.swift` | the session coordinator and durable-journal refusals |
| `TweakHandlerError`, `ARError`, `BoundedResponseFetch.Failure` | the type itself carries `LocalizedError` |

`test_error_message_policy.py` (in `make verify`) fails when an `enum ... : Error` under
`VexSign/App` has neither `LocalizedError` nor an `errorDescription`/`message`, and the five
types it records in `error-message-baseline.json` are the plumbing ones with a written reason
why they never reach a screen.

See [Personal Team limitations](apple-account-limitations.md) and [security boundaries](security.md).
