# Apple Account signing — reference-source investigation

Date: 2026-11-26. This is a source-reading record, **not** a claim that any
listed application was executed, nor permission to copy its code. No source
from these projects was copied into VexSign. Where a project's code is AGPL-3.0
or GPL-3.0, only architectural observations were used; VexSign's own owners
(NativeSigning, SideSign as an isolated pinned package, the certificate vault
and Zsign) remain the implementation.

## Why this was done

Before changing the Apple Account flow we checked how existing on-device
signers handle: Apple authentication and 2FA, team discovery, certificate
creation and replacement, App ID/device registration, profile generation and
expiry, and the limits a free Personal Team actually has. Apple's own
[Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/)
is the controlling source for the Personal Team numbers now encoded in
`AppleAccountLifecyclePolicy`: 10 App IDs and 3 devices (each for 7 days), 3
apps per device, and profiles expiring 7 days after issue.

## Projects and observations

| Project / default branch / last push observed | Licence | Source actually inspected | Relevant observation |
|---|---|---|---|
| [SideStore/SideStore](https://github.com/SideStore/SideStore) `develop`, 2026-11-07 | AGPL-3.0 | `Core/Auth/AuthManager.swift`, `Core/Auth/DeveloperPortalProxy.swift`, `Core/Auth/Flows/CertificateProvisioningFlow.swift`, `Core/Auth/Flows/DeviceRegistrationFlow.swift`, `Core/Profiles/ProfileManager.swift`, `AltStore/Authentication/SelectTeamViewController.swift` | Stores Apple ID/password/xcode token in Keychain; explicit team list; reuses a portal certificate with a locally held private key when it matches the active serial; asks the user before revoking certificates; reads the device list and registers only a fetched real UDID. Its retry loop is user-decision driven, not unbounded. |
| [altstoreio/AltStore](https://github.com/altstoreio/AltStore) `marketplace`, 2026-11-25; original AltStore tree through the SideStore fork | AGPL-3.0 | `AltStore/Authentication/*`, `AltStore/Core/Model/Team.swift`, host-server layout from the AltStore/AltForge source tree | UI + `AltStoreCore`; Apple API/signing work in `AltSign`; original installation preparation runs in a macOS/Windows companion (`AltServer`) using libimobiledevice. No host-server mechanism was assumed to be available inside an iPhone app. |
| [FrizzleM/SideInstaller](https://github.com/FrizzleM/SideInstaller) `main`, 2026-11-24 | NOASSERTION (read only) | `NOTES.md` (several chunks) | iOS 27 on-device siboot pairing; 26.4+ requires a computer-produced remote pairing file; RPPairing pair-verify → LocalDevVPN loopback → TLS-PSK/CDTunnel → RSD → AFC/installation_proxy. A tunnel handle is not liveness; pairing records can stop working after an OS update. No code copied. |
| [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer) `main`, 2026-11-20 | AGPL-3.0 | repository tree, guest hooks, vendored ZSign headers | A guest/host container with its own filesystem hooks and an embedded zsign; it is explicitly outside VexSign's supported scope. Nothing here was used to claim in-app guest execution or in-process CMS signing. |
| [claration/feather](https://github.com/claration/feather) `main`, 2026-11-23 | GPL-3.0 | repository tree, `Utilities/MachO/MachOUtils.m`, certificate import/store files, entitlements merge history | Imports `.p12` + `mobileprovision` into a local store and signs with zsign; Mach-O helpers carry LiveContainer-derived patches with their own notices. Its entitlement merging is a separate concern from Apple-issued entitlement policy and was not copied. |
| FeatherPlus | not found as a public canonical repository under that exact name | derived Feather-family trees and published FeatherPlus/KSign wiki notes | Only the Feather-derived `.p12`/profile signing pattern and wiki statements about the advanced `idevice` pairing route (pairing file + LocalDevVPN) were used as orientation. No FeatherPlus internals were copied. |
| [Nyasami/Ksign](https://github.com/Nyasami/Ksign) `main`, 2026-10-22 | GPL-3.0 | `Ksign/Views/Settings/Certificates/CertificatesView.swift`, certificate reader/handler files, signing options tree | Feather-derived certificate grid and local `.p12` import; no Apple Account portal or certificate-issuance implementation was found. Confirms that certificate import alone is not account provisioning. |
| [NexSideloading/NexStore](https://github.com/NexSideloading/NexStore) `main`, 2026-10-31 | GPL-3.0 | `Backend/Observable/CertificateStatusManager.swift`, certificate store/reader files, official-certificates view | certificate status is partly from a third-party HTTPS checker and cached in `UserDefaults`, with `unknown` as a case. VexSign deliberately does **not** cache certificate status in `UserDefaults` or rely on an unauthenticated third-party checker; its status check requires explicit consent and an authenticated local verifier. |
| [raynmahbub/Odysseus](https://github.com/raynmahbub/Odysseus) `master`, 2026-10-31 | GPL-3.0 | `Feather/Backend/AppleID/ODAppleIDManager.swift`, `ODKeychain.swift`, certificate OCSP/export files, bundled SideSign portal tree | Uses SideSign for Apple ID + password + 2FA, anisette servers, a device-generated key, certificate creation, explicit UDID (pairing file or manual), App ID registration and a limited-development profile, then zsign. Its own source comment states the free-account numbers and that they still need device testing — we did not treat that comment as proof of a live run. |
| [murk-sus/SayoSign](https://github.com/murk-sus/SayoSign) `main`, 2026-11-25 | GPL-3.0 | `app/Sources/AppleID.swift`, `AppleIDViews.swift`, `CertificatesView.swift` | Independent anisette v3/v1 client and direct Apple plist requests, with a documented need for Mac-based anisette and matching client metadata; certificate/PKCS#12 handling is separate from portal provisioning. Its direct protocol is not reused: VexSign keeps anisette behind `AnisetteProviderDescriptor` and the pinned SideSign boundary with a consent gate. |

## Decisions carried into VexSign

1. **Keep the replaceable boundary.** Authentication, 2FA, team discovery and
   portal mutations stay in `NativeAccountBackend` / SideSign behind
   `AnisetteProviderDescriptor`. A remote anisette provider is an external
   service with documented compatibility limits, never a trusted identity.
2. **No copied auth or entitlement bypass.** There is no password-by-email
   shortcut, no TLS bypass, no cookie/session logging and no host-side
   libimobiledevice dependency. VexSign requires an explicitly supplied device
   identifier and explicit per-mutation approvals.
3. **Paid teams are not guessed.** SideSign's `Team.type == .individual` or
   `.organization` is a label, not proof of an active paid program membership
   in this build. `SideSignAccountBridge` therefore reports those teams as
   `.developerProgramUnverified`, provisioning refuses them before mutation,
   and `.paidVerified` remains a state for a future verified signal. No paid
   certificate, profile or capability is claimed from a team label alone.
4. **Free limits are source-labelled.** Apple's documented Personal Team
   limits live in one policy with a source and validity string. A count that
   was not read from Apple's portal is `unknown` and blocks a new registration.
   A local profile journal is never described as portal quota.
5. **Certificate status is not a signing grant.** Status checks require their
   own consent, and only an authenticated, exact team/app/device/identity
   profile handoff can reach the ordinary certificate store. Zsign remains the
   single native signing seam; `nativeAppleAccountSigning` stays `.notIntegrated`.
6. **Renewal stays attended.** No reference project's automatic refresh loop
   was adapted. VexSign only discovers candidates and offers an approved flow.

## Open evidence limits

No real Apple Account sign-in, certificate issuance, profile issuance, device
registration or physical installation was performed in this repository while
writing this document. Source observations are orientation only; see
`Docs/DeviceTesting/apple-account.md` for the separate manual acceptance
procedure and the evidence that would be required to claim a live pass.
