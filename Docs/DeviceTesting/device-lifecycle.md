# Device and application lifecycle acceptance

This document describes the device/app lifecycle layer implemented in
`VexSign/Services/Devices/Device*.swift` and exposed from **Installation → Tunnel & Pairing →
Open device and app lifecycle**.

Compilation checks, repository gates and simulator tests do **not** satisfy any case below.
A passing report is a named tester's attestation against one exact IPA SHA-256 and source
commit; it is not independent evidence that iOS behaved as recorded.

## What the implementation actually does

- `DeviceLifecycleStore` persists device rows, positive-only inventory snapshots and sync
  markers in the existing `EcosystemDatabase` (WAL SQLite). It does not create a second
  database or a second device transport.
- `DeviceRegistryService` separates a readable pairing record (`.paired`) from a fresh,
  identity-bound device answer (`.connected`). Remembered, unavailable, pairing-required and
  untrusted states are stored separately. A pairing file never raises trust by itself.
- `DeviceInventoryService` asks the consented pairing session for the CoreDevice installation
  service's app list. Only positive records with the frozen device/record binding are saved.
  An empty or unreadable response is not converted into "no apps installed".
- `DeviceLifecycleCoordinator` submits the selected signed library artifact through the
  existing `LibraryInstallationProviding`/`InstallQueue` path and reads the device back. A
  command acknowledgement is reported as "submitted, not confirmed" unless a fresh, exact
  same-device observation follows it. Removal goes through the existing `DeviceAppRemoval`
  sequence and requires typed bundle-id confirmation and a supported transport.
- `DeviceUpdatePlanner` combines the existing catalog detector with device OS, route
  capability, authorization expiry, declared SHA-256 and measurable free space. It refuses
  downgrades, unknown versions, bad digests and incompatible releases. The download itself is
  handed to the existing `DownloadManager`, which owns verification, import and signing.
- `DeviceBackupCoordinator` backs up VexSign library data with the existing `BackupManager`
  and exports selected VexSign-owned containers with the existing container archive service.
  It cannot read another app's sandbox, keychain or complete iOS backup.

## Transports and APIs used

1. `PairingBridge.reviewRecord()` and `PairingBridge.canQuery(...)` for pairing format and
   route admission.
2. `PairingBridge.queryDevice(...)` / `HeartbeatManager.queryDevice(...)` for a fresh identity
   snapshot. There is no public iOS API for general device discovery or pairing from a third
   party app; the pairing record and local VPN transport are user-supplied prerequisites.
3. `HeartbeatManager.queryApplicationInventory(request:)` for a positive CoreDevice app list.
   This is an experimental community protocol bridge, not a public App Store API. It remains
   gated by explicit user consent and may return filtered data.
4. `InstallationAppProxy.deleteApp(...)` through `DeviceAppRemoval`, gated by the pinned
   library's `hasAcceptedRemovalBridge`. When the gate is false, the UI hides removal.
5. `BackupManager` / `BackupCrypto` and `ContainerArchiveService` for VexSign-owned data.
6. `UnifiedTaskCenter` through `DeviceLifecycleTaskReporter`. Device protocol stages map to
   ordered task phases with indeterminate progress; no percentages are invented.

## Physical-device cases still required

Perform these on a physical iPhone with a compatible pairing record, Developer Mode and local
network permission. Record the OS version, pairing format, IPA SHA-256 and commit.

1. **Record separation:** import a pairing record, open the lifecycle screen and confirm the
   row says paired/not connected, not connected. Verify; confirm it changes to connected only
   after a fresh device answer. Force-close VexSign, relaunch and confirm the row returns to
   remembered/paired rather than retaining a live connection badge.
2. **Reconnection and failure:** with the VPN off, attempt verify and confirm a transport
   error with actionable guidance, not a fabricated connection. Turn the VPN on and verify
   again; confirm the same stable device row is reused.
3. **Trust refusal:** reset pairing on the device, attempt verification and confirm the row is
   untrusted/pairing required and that no install action is offered.
4. **Inventory:** refresh a known library app set; confirm reported apps carry device version
   and build, unknown apps remain explicitly unreported, and a second refresh with a filtered
   or empty response does not erase prior metadata or produce a mass "removed" list.
5. **Install:** select a signed, eligible library app. Confirm submission, then confirm the
   device report matches the exact bundle/version/build. If the device cannot be read, the
   result must remain "submitted, not confirmed".
6. **Reinstall/update:** confirm an update refuses a different bundle id, a downgrade and an
   expired certificate. Verify that a compatible update downloads through VexSign's existing
   download manager and that post-install inventory is refreshed.
7. **Removal:** only when the removal bridge is accepted in the pinned binary. Confirm the
   typed bundle-id dialog, observe the device readback and confirm `.removed` is shown only
   after device-side absence evidence. With the bridge rejected, confirm no removal action
   is offered.
8. **Backup/restore:** create a backup with library metadata and one VexSign container; verify
   the archive opens, that a restore preview lists existing records as conflicts, and that
   restore does not overwrite them. Confirm an IPA is never presented as app data.
9. **Concurrency:** start an inventory refresh and attempt a second one; confirm the second is
   rejected or queued by `TaskSubmissionPolicy` and no device state is corrupted.
10. **Cancellation:** cancel an inventory read mid-query and confirm sync state is marked
    interrupted, not successful, and partial readings are not published.

## Reference implementations reviewed

No AGPL/GPL source was copied. Repositories were inspected for architecture and licensing only:

| Project | Ref / licence | Relevant observation |
| --- | --- | --- |
| SideStore/SideStore | `develop`, AGPL-3.0 | Backup/install orchestration patterns; no code reused. |
| altstoreio/AltStore | `marketplace`, AGPL-3.0 | Backup component model and its explicit boundaries. |
| LiveContainer/LiveContainer | `main`, AGPL-3.0 | Named data containers and a URL hand-off; its launcher is a separate runtime, not a VexSign capability. |
| claration/feather | `main`, GPL-3.0 | App records/archives stored locally, not a general device inventory. |
| Nyasami/Ksign, NexSideloading/NexStore | `main`, GPL-3.0 | Signing/catalog structures only. |
| FrizzleM/SideInstaller | `main`, custom licence | On-device bootstrap companion; custom licence prohibits redistribution. No code reused. |

A repository search did not identify an authoritative iOS `Odysseus` or `FeatherPlus`
implementation to rely on; none was assumed. LiveContainer's private LaunchServices and JIT
behaviour is third-party runtime behaviour and is not implemented here.
