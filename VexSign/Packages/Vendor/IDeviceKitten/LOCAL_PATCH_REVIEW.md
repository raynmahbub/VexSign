# IDeviceKitten local foundation review

**2026-11-13 — source review only.** The wrapper remains pinned to
`claration/IDeviceKit` commit `837cf1e14d4875771dd5ee1b754a4c86215c5db3`.
`Package.swift` and the upstream MIT [LICENSE](LICENSE) are unchanged. The
[manifest](../manifest.json) lists SHA-256 values for six modified upstream Swift
files and nine local additions; the portable foundation checks enforce their
current bytes. Original hashes were compared with GitHub's contents API at the
immutable wrapper commit, not inferred from this checkout's older local patches.
`PairingFileStorage.swift` was already a local file, absent from that upstream tree.

No SideInstaller implementation, binary, asset or protocol patch was copied.
Only its public README, technical notes and restrictive license were read. It is
not a dependency. The local foundation is independently written around the
existing MIT wrapper and separately inspected `jkcoxson/idevice` source.

## Patch scope

- `Heartbeat*.swift`: one off-main executor, no cached/global native handles,
  no automatic launch/foreground handshake, consent/format/OS checks, protected
  record lifecycle and operation-scoped identity queries.
- `PairingRecordDocument` / `PairingPlistEnvelope`: at most 2 MiB, flat XML/binary
  structural preflight before Foundation/native parsing; classic/remote/combined
  inspection, normalized device identity, remote signing-key relation, preserved
  original bytes. Parsing is never device authorization.
- `PairingFileStorage`: retain the sole existing owner. Anchor the path to the
  POSIX-canonical home/container prefix, inspect existing private ancestors with
  no-follow `lstat` before creating missing descendants, reject links there,
  bounded no-follow descriptor reads, 0700 directories / 0600 files, physical-iOS
  Data Protection with no unsupported-protection fallback, backup exclusion,
  exclusive synchronized staging, no-clobber first import, digest-reviewed atomic
  replacement/deletion, protected exact-byte exports and bounded local recovery.

**2026-11-22 — migration race check.** `migrate` compared the source against its
pre-hook observation with `sameFile`, which includes `mtime` and `ctime` at
sub-second resolution. That made a *correct* migration fail intermittently whenever
the source was touched between the hook returning and the move — observed as a
flaky host test (`changedRecord`, with `ctime` false, on both `main` and the import
branch). It now compares device/inode/size through `sameIdentity`: enough to prove
the path was not swapped, without asserting the source was not written to. The
overwrite check on the target is unchanged, `FileManager`'s move still refuses to
clobber, and `sameFile` remains in use for read-time byte verification and for
`install`, where the bytes genuinely must not change.
- `DeviceOperationExecutor` / `DeviceServiceSession` / `DeviceTransportPolicy`:
  serialized native ownership; fresh service identity; conservative OS routing;
  sanitized errors; cancellation/timeout never free active native memory.
- `InstallationProxy`: bounded autoreleased 1 MiB streaming, no-follow regular
  archive read, transmitted SHA-256/file checks, positive staging-directory
  validation, expiry/OS recheck and atomic Stop/submission ordering. Mutations
  remain gated **before** staging/upload/commands. An uncertain native command
  response retains only that attempt's staged IPA; it is not deleted while iOS
  might still consume it. No private suspension or Completed acknowledgement.
- `InstallationAppProxy` / `DeviceServiceSession+Applications`: explicit-request,
  same-device positive CoreDevice App Service inventory with typed client/list
  cleanup. No legacy pointer-array deallocator or private inventory fallback.
- `DeviceApplicationInventory` / `DeviceInstallationSubmission`: bounded positive
  metadata, opaque device/record binding, exact archive/expiry/OS target, atomic
  Stop/command control and an acknowledgement distinct from an installed receipt.
- `SystemLogManager`: operation-scoped stream/client cleanup and cooperative stop.
  Do not log raw protocol dictionaries. A stop cannot interrupt a blocked FFI read.

The app continues to use its existing PairingBridge, account/session coordinator,
signing engine and installation queue. This is not a new competing installer.

## Native contract examined

The unchanged binary target is `IDevice` v0.1.57, SwiftPM checksum
`40cd5c769b60d1879a96c9caa27666037f9d5321844addec40ae99727b142d10`.
Its annotated tag resolves to source commit
[`99ea020acabd0579375a09fd690261ea6ca37f68`](https://github.com/jkcoxson/idevice/tree/99ea020acabd0579375a09fd690261ea6ca37f68).
This source reading **does not** prove the downloaded XCFramework's headers,
platform slices, ABI, linked dependency licenses, or runtime behaviour. Local
archive retrieval failed. The authorized full CI resolved the pinned binary and
compiled its actual C imports, exposing the `usize`/`libc::size_t` Swift signedness
differences now handled explicitly. That is not runtime/device acceptance; see
the exact candidate/run conclusions in the implementation status. No device
service call was run by these tests.

| Source file under `ffi/src/` | Source-level ownership finding / local handling |
| --- | --- |
| `pairing_file.rs` | `idevice_pairing_file_from_bytes` parses the reviewed byte snapshot; matching `idevice_pairing_file_free` for an unconsumed record. |
| `provider.rs` | TCP provider construction consumes pairing on success; the provider is released with `idevice_provider_free`. |
| `tunnel_provider.rs` | `tunnel_create_usb` borrows an `IdeviceProvider`, including a TCP provider despite the name; creates adapter + RSD handshake. Matching adapter/handshake destructors run after service cleanup. |
| `lockdown.rs` | RSD connection creates a scoped client; `lockdownd_get_value` returns a plist node. Local code checks plist-to-XML status, bounds values, frees nodes and XML buffers, and validates the actual returned device identity. |
| `afc.rs` | File close consumes its handle even on failure; never close the consumed pointer twice. Writes use `size_t`; local buffers stay inside `withUnsafeBytes`. |
| `core_device/app_service.rs` | Typed AppListEntryC list/free contract, exact identifier, optional version/build and path. Matching successful-list destructor is used. Intermediate CString conversion failure can leak; binary/partial-failure acceptance is outstanding. |
| `installation_proxy.rs` | Clients have a destructor. Browse/get-apps return an outer allocation with a separate ownership issue; see below. Native install callbacks are progress, not an installed receipt. |
| `os_trace_relay.rs` | Valid start-trace arguments consume the client on success **and** service error; free the receiver or the unconsumed client, not both. |
| `springboardservices.rs` | Icon result is a byte allocation, not a plist-pointer array; matching client and byte-buffer cleanup are scoped. This does not approve reusing the byte helper for inventory. |
| `plist.h` and utility helpers | Plist nodes use `plist_free`; XML buffers use `plist_mem_free`. The existing plist-array helper frees nodes, not the outer allocation. |

### Inventory implementation versus mutation acceptance

The old `installation_proxy_get_apps` / browse contract forgets a
`Box<[plist_t]>`; its existing helper frees only nodes. Arbitrary `free`, byte-Vec
or unrelated c_void-Vec destructors are not a repair. Those APIs stay unused.

The pinned source also has a distinct **typed CoreDevice App Service** list and
matching `app_service_free_app_list`. The new adapter queries on the existing
identity-checked tunnel, bounds results/UTF-8, excludes clips/extensions, retains
optional metadata and never infers absence. Successful native list cleanup is
source-reviewed; intermediate CString-construction failure can leak native
allocations that Swift never receives. This patch does not repair that defect.

Actual app wiring now verifies the copied payload and archive, submits an exact
bound target, and corroborates acknowledgement using the shared watcher and a
fresh same-device exact bundle/version/build observation. Library/task history
retain the actual observation with binding/freshness checks, not synthesized
expectations. These sources remain unverified by local native compilation.

`InstallationAppProxy.hasAcceptedInventoryBridge` remains computed `false`.
Do not enable it from a preference, read-only query or source review. Native
binary/header/symbol tests, failure ownership, exact installed-version device
acceptance and independent signing gates are still required. An experimental
read-only setup query is not installation/removal acceptance.

### Modern remote and host routes remain blocked

The pinned remote-record parser lacks the newer host-IRK contract, and its native
remote dictionary debug output can contain credentials. The listener-based
loopback client is not accepted for modern iOS. No reviewed on-device RPPairing
host/responder API, advertisement/PIN lifecycle, Developer Mode public detection
API or corresponding entitlement was established. Store/export recognized remote
bytes without calling that parser or claiming those transports work.

## Cancellation and filesystem limits

A query normally has a 30-second **waiter** budget; installation may use up to
300 seconds. Neither is a bound on an uninterruptible FFI call. The
worker and its single admission slot live until native cleanup actually retires.
A hung worker can require process restart. Never force-free or overlap it to make
the UI appear responsive. Protected local commits finish and return their actual
result when cancellation races an atomic commit.

The storage lock excludes all owned writers and recovery/export cleanup. Arbitrary
malicious same-process filesystem access is outside this boundary. Staging files
are synchronized before commit, but directory durability/power-loss behaviour is
not established. Host/simulator tests cannot establish iOS Data Protection,
backup behaviour on hardware or UIKit picker lifecycle correctness.

## License boundary and validation

The retained wrapper notice is MIT (copyright 2025 khcrysalis). The inspected
idevice Cargo metadata declares MIT (author Jackson Coxson), but complete binary
and transitive redistribution obligations are **not established** by that
metadata. No new VPN library or binary was added. LocalDevVPN is an optional,
user-installed/user-activated prerequisite, not bundled code; its source/license
closure was not accepted. Preserve existing SideSign AGPL and Zsign MIT/Apache
notices; this patch does not relicense them.

`make test-device-foundation` stages seven exact production sources and five
fixture/test sources into an isolated macOS SwiftPM graph without IDevice or
network dependencies. Portable preparation/security checks are not Swift tests.
Host compilation and CI outcomes are tracked separately from native ABI/runtime,
iOS Data Protection, real transport and device installation acceptance. See the [implementation status and manual gates](../../../Documentation/Architecture/on-device-foundation-status.md).
