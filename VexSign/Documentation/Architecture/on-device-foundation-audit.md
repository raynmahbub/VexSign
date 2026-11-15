# On-device bootstrap and transport: source audit

> This is the initial pre-integration audit. The later
> [implementation and acceptance status](on-device-foundation-status.md) records
> the now-written CoreDevice inventory and exact-evidence installation wiring,
> without claiming native/physical acceptance or modern-host implementation.


Audit date: **2026-11-13**. Starting branch: `arena/53ca8fed-vexsign`.
Starting commit: `e68423687674cbddd75052db19fb6e0f70dd7173`.
The starting working tree was clean. This is a new feature task, not another layout migration.
No commit, push, publication, release, deployment or physical-device operation is authorized here.
See the [current implementation status](on-device-foundation-status.md) for the
saved changes, current validation, remaining gates and manual test instructions.
This audit's implementation map describes the **starting** code, not a claim
that all mapped defects or requested phases are complete.

## Evidence and scope

The implementations below were read before implementation changes. `make verify`
passed at the starting revision (512 portable tests across 33 suites). This Linux
workspace has Python, Node and `gh`, but no Swift compiler, Xcode, iOS simulator,
Rust compiler or attached iPhone. Portable checks cannot establish Apple trust,
Developer Mode, pairing authorization, device installation or hardware acceptance.

Public reference material was limited to SideInstaller's README, technical notes
and license at revision
[`82452dfd2a575b5a031145de2b22b98d4b7b3a76`](https://github.com/FrizzleM/SideInstaller/tree/82452dfd2a575b5a031145de2b22b98d4b7b3a76).
No SideInstaller implementation source, binary, artwork or protocol patch was
copied. Its custom non-commercial/source-only distribution restrictions are **not**
compatible with treating it as a reusable GPL dependency. It is research only.

- [Technical notes](https://github.com/FrizzleM/SideInstaller/blob/82452dfd2a575b5a031145de2b22b98d4b7b3a76/NOTES.md)
- [README / compatibility claims](https://github.com/FrizzleM/SideInstaller/blob/82452dfd2a575b5a031145de2b22b98d4b7b3a76/README.md)
- [License](https://github.com/FrizzleM/SideInstaller/blob/82452dfd2a575b5a031145de2b22b98d4b7b3a76/LICENSE.md)

The separately licensed `jkcoxson/idevice` **v0.1.57** FFI and parser source was
inspected directly, not taken from SideInstaller. Reference claims about iOS
cutoffs are conservatively enforced as restrictions, **not** converted into
VexSign device-acceptance claims. In particular, iOS 27 alone does not establish
that an app can host RPPairing using a public Apple API.

## Implementation map at the starting revision

Paths below are relative to `VexSign/` unless prefixed otherwise.

| Area | Actual existing owner / implementation | Finding and integration point |
| --- | --- | --- |
| Device state | `App/iOS/Infrastructure/Devices/Transport/DeviceConnectivity.swift` | Presence, pairing validity and trust are separate types. Preserve them; strengthen the capability resolver, which currently calls a file plus an open TCP socket sufficient for paired operations. |
| Pairing file location | `Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/Heartbeat/PairingFileStorage.swift` | Existing owner migrates Documents credentials to protected, backup-excluded Application Support. Extend this owner, not a second pairing vault. |
| Pairing import | `App/iOS/Infrastructure/Identity/CertificateManagementService.swift` | Only checks a nonempty `HostID`. Rejects genuine RPPairing-only files and accepts incomplete classic records. File size check and read are separate. Reuse the importer but share one bounded format-aware parser. |
| Pairing inspection | `DeviceConnectivity.swift` → `PairingRecordInspector` | Classic-only; accepts unexpected field types; reads a file before enforcing the size limit. Never treat parsing as authentication. |
| Transport bridge | `App/iOS/Infrastructure/Devices/Transport/PairingBridge.swift` | Existing app boundary for `HeartbeatManager`. Keep UI and app adapters behind it. |
| Device information | `App/iOS/Infrastructure/Devices/Transport/LockdownClient.swift` | `connect()` only reads a file, sets a Boolean and logs the full identifier. Queries mix that file's UDID with the running device's metadata. Replace this pseudo-session with actual device-service evidence, never infer a remote device's details from `UIDevice`. |
| Device session | `Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat*.swift` | Chooses RPPairing solely by OS >=17.4, not record format. `ensureRSDTunnel()` returns true if initialization is busy, leaves its busy flag set on failures, shares static native handles and leaks failure-path objects. Blocking callers use multiple detached tasks without one native-operation owner. |
| RSD / service APIs | `IDeviceKitten` binary target `IDevice` v0.1.57 | Has TCP provider, CoreDeviceProxy (`tunnel_create_usb`, despite its name it takes a provider), RPPairing client tunnel, RSD, lockdown, AFC, Installation Proxy, House Arrest, Misagent and installation-coordination FFI. Presence of symbols is not proof each service is available on a particular device. |
| On-device RPPairing host | Pinned binary / Swift wrapper | No exposed host/responder API, persisted host IRK contract, host advertisement lifecycle or cancellable PIN-host API. The pinned remote record model also lacks `alt_irk`. Do not advertise a host or mint a fake PIN. |
| Remote loopback tunnel | `idevice` v0.1.57 `ffi/src/tunnel_provider.rs` | `tunnel_create_rppairing` calls `create_tcp_listener`, then dials that listener on the original address. The public research documents on-device listener reachability failures and later, separate multihost/route changes. Do not label the old pinned path a validated modern-iOS transport. |
| Installation | `App/iOS/Infrastructure/Devices/Installation/AppInstaller.swift`, `InstallQueue*.swift`, `InstallationArchive.swift` | Existing authoritative queue, per-app leases, protected working archive, cancellation, OTA fallback and task integration. Extend these; do not create another installer. |
| Paired upload | `IDeviceSwift/InstallationProxy/InstallationProxy.swift` | Existing 1 MiB AFC upload and `installation_proxy_install_with_callback`. Keep bounded streaming and pointer scopes. Native completion must still be corroborated, not surfaced as installed. Legacy self-update invokes an undocumented suspend selector; do not carry that into the new supported route. |
| App inventory | `IDeviceSwift/InstallationProxy/InstallationAppProxy.swift` | Real device inventory FFI exists but array/native cleanup and connection ownership need repair. App's `InstalledAppProbe.swift` instead uses dynamically decoded private LaunchServices selectors. Do not silently make those the new workflow's authority. |
| Install confirmation | `InstallConfirmation.swift`, `InstallEvidenceSummary.swift`, `InstalledAppProbe.swift`, `Domain/Policies/InstallVerificationPolicy.swift` | Existing pure version/build/baseline evidence engine and unconfirmed verdicts are reusable. Supply exact device-service readings; never turn an accepted upload, missing metadata or inaccessible inventory into success. |
| Removal | `DeviceAppRemoval.swift` → `InstallationAppProxy.deleteApp` | Existing confirmation and read-back sequence. Keep refusal rules and same-device evidence; missing lookup must remain unknown. |
| Apple authentication | `Infrastructure/Accounts/NativeSigningManager.swift`, `AppleAccountSessionCoordinator.swift`, `AppleAccountAuthenticationState.swift`; `Packages/NativeSigning/Authentication/NativeAccountBackend.swift`, `SideSignAccountBridge.swift` | Already implements explicit operations, 2FA, team selection, session revalidation/cancellation and public sanitized facade. Do not build another account manager. |
| Session persistence | `AppleAccountSessionRepository.swift`, NativeSigning `Security/AppleAccountCredentialStore.swift`, `AppleAccountResumeJournalStore.swift` | Device-only Keychain, reservation journal, orphan cleanup, explicit sign-out and revalidation. Passwords are not persisted. Keep existing ownership/guest restrictions. |
| Anisette | `Infrastructure/Accounts/AnisetteProvider.swift`, `NativeAnisetteConfigurationAdapter.swift`; NativeSigning consented HTTPS/header and v3 providers | Explicit configured provider and consent; no automatic endpoint or legacy fallback. This is not permission to send credentials/private keys to VexSign's backend. |
| Certificate / registration / profiles | NativeSigning `Identity/NativeSigningIdentity*.swift`, `Authentication/SideSignProvisioningAdapter.swift`, `Provisioning/NativeRegistrationExecutor.swift`, `NativeProfileCreationExecutor.swift`, `SideSignBound*Portal.swift` | Owned local keys, quota-affecting approvals, journaled submissions and receipts already exist. Never revoke unrelated certificates. Local profile counts are not complete device-wide free-account quota evidence. |
| Native CMS gate | NativeSigning `Provisioning/NativeProvisioningProfileValidator.swift`, `NativeAppleProfileCMSVerifier.swift`, `Authentication/SideSignAccountBridge.swift` | Production still defaults to an unavailable verifier. Preserve it and the evidence gate; parser/OpenSSL fixtures do not establish genuine Apple CMS trust. |
| Native signing handoff | `Infrastructure/Accounts/NativeSigningManager.swift` → `NativeSigningHandoffCoordinator`; NativeSigning `Identity/NativeProtectedSigningHandoff.swift` | Receipt-bound export into the ordinary certificate store already exists; direct protected execution remains gated. Keep random export passwords, single-use approval, owner/team/device/profile binding and protected cleanup. |
| IPA signing | `Infrastructure/Signing/Execution/{SigningService,SigningPipeline,SigningHandler,ZsignHandler}.swift`; `Planning/SigningResolutionSession.swift`; `Engines/Zsign/ZsignEngine.swift` | Existing execution gate, profile/key/entitlement/nested-bundle resolution, isolated mutation and verification. Reuse it unchanged unless a narrowly demonstrated integration defect requires a repair. |
| Native engine | `Packages/Vendor/Zsign/` | Existing pinned MIT/Apache-noticed C++/Swift bridge; no replacement engine is necessary. |
| Signing/account SDK | `Packages/SideSign/` | Existing AGPL-3.0-derived code and pinned SDK graph. No new SDK is necessary. Preserve notices; distribution obligations require maintainer review. |
| Secret/log ownership | App `Security/Secrets/`, NativeSigning Keychain stores, `Infrastructure/Diagnostics/LogRedaction.swift` | Existing redaction knows classic keys and some remote keys. Add format-specific keys/host identifiers where needed; never print raw native protocol dictionaries. |
| UI | `Presentation/Features/Installation/Views/InstallationView.swift`, `Tunnel & Pairing/TunnelView.swift`, Settings/Setup Health, DevicePicker | Reuse existing navigation; present version/format/transport/trust separately. A URL handler cannot silently start another app's VPN or establish its identity. |
| Tasks | `Infrastructure/Tasks/UnifiedTaskCenter.swift` and existing installation/signing adapters | Reuse task stages and terminal states. A prerequisite check is not a sign/install task or product completion. |
| Build / CI | Root `Makefile`, `.github/workflows/ci.yml`, `embedded-container.yml`, synchronized Xcode source groups, package manifests/resolved files | Portable checks and macOS unsigned build/simulator jobs already exist. New app/test sources enter synchronized groups. No signing secrets or self-hosted device runner should be introduced. |

## Bootstrap compatibility policy

| OS family | Conservative pairing prerequisite | What this checkout can honestly claim before hardware acceptance |
| --- | --- | --- |
| <17.4 | No new paired-device route | Unsupported by this foundation; use an eligible external installer or the separately configured OTA/export flow. |
| 17.4–26.3 | Complete compatible classic lockdown record; remote formats must never be misread as classic | Existing imported-record route can be repaired around the pinned provider/CoreDeviceProxy/RSD APIs; device validation still pending. |
| 26.4–26.7 | Remote pairing record required for the researched loopback route | Validate/store imports, but classic-only records must be rejected for this transport. Current binary's modern local RPPairing connection is not accepted. Companion/dependency work required. |
| 26.8–26.x (not specified by researched matrix) | Unknown | Explicitly unsupported/unvalidated, not rounded into 26.7 or 27. |
| >=27 | A reviewed host implementation or compatible imported remote record, Developer Mode and explicit transport setup | Host API absent in pinned dependency; no public Apple RPPairing-host or Developer Mode detection API established. Do not claim on-device host support from the OS number. |

These are **restrictions and prerequisites**, not promises that every combination
works. Simulator, future/unknown versions, unknown permissions and untested
hardware remain unverified. First installation is independent: a valid signed
development build, eligible existing tool, or authorized distribution channel is
required. No CI job or unsigned IPA installs VexSign on a user's device.

## Planned incremental boundary

1. Shared bounded format-aware import/storage, conservative bootstrap policy,
   serialized native ownership, typed errors and actual identity query.
2. Guided existing-UI integration with explicit protocol/VPN consent and honest
   progress; existing signing/CMS owners remain gated.
3. Feed genuine paired inventory into the existing installation confirmation
   path and persist only redacted exact-version receipts; keep OTA unconfirmed
   without supported evidence.
4. Native compile, genuine Apple CMS review, modern tunnel/host dependency review
   and physical-device matrix are mandatory follow-ups. They cannot be fabricated
   or replaced by deterministic fixtures.

The implementation report will record what actually landed and what remains
blocked. This audit alone is not completion of any runtime/device gate.
