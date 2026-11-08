# VexSign native signing and import reliability

## Native execution ownership

The pipeline owns and injects `SigningExecutionGate` into its handlers; there is
no additional global singleton. The gate serializes native signing, stdout capture and cache
cleanup, and the gated dylib-removal call. Bundle preparation may overlap, but
only one gated operation runs at a time. Waiters are FIFO; cancellation removes
queued work. Errors release ownership, and cancellation is checked again after
handoff before entering native code.

The synchronous signer is not forcibly interrupted after it starts. Cancellation
remains cooperative before execution and after return. This gate does not cover
every C-library call made during tweak preparation.

## Input validation

`SigningInputValidation` requires custom entitlements to be a readable plist
dictionary. An empty path uses the provisioning profile defaults. The file is
checked again after waiting for the signer. Format validity does not mean that
the provisioning profile grants every requested entitlement.

Before dylib removal, the declared executable must be a readable regular file
inside the bundle. Missing files, directory paths, traversal names and symlinks
escaping the bundle are rejected.

The existing typed engine request, provisioning-flag translation, native failure
checks and verification-before-registration order remain unchanged. The internal
ad-hoc helper does not imply that identity-free signatures can install on stock iOS.

## IPA import

`IPAExtractor` uses 256 KiB decode buffers, verifies CRC and expanded entry sizes,
and preserves executable permissions. Progress is monotonic and throttled to
one-percent increments; completion is reported only after checks finish.

The existing archive safety limits remain: at most 50,000 entries and 8 GiB of
expanded data, with unsafe paths and symlinks rejected. Containment is rechecked
before each write. Existing output files are not overwritten, and storage
headroom is checked using expanded bytes.

Cancellation and deadlines are checked by the decoder itself, avoiding cleanup
races with a separate dispatch writer. The deadline is cooperative, not a hard
interruption of a blocked filesystem call. Import owns security-scoped access
until completion and resolves the saved library row by its permanent database ID.

## Regression coverage

| Test suite | Coverage |
| --- | --- |
| `SigningExecutionGateTests` | FIFO handoff, queued cancellation, error release and pre-cancelled operations. |
| `SigningInputValidationTests` | Entitlements format, executable existence/type, traversal and external symlinks. |
| `IPAExtractorTests` | Bytes, executable mode, progress, cancellation, CRC corruption, overwrite protection and deadlines. |

## Release acceptance

Static project, diff, concurrency-discipline and error-discipline checks passed
in the development workspace. These XCTest suites and native device flows have
not run there because Xcode and Apple SDKs are unavailable.

Before release:

1. Run the iOS test target in Xcode.
2. Sign two different apps concurrently; cancel a waiting run and retry after failure.
3. Test custom entitlements, tweak removal and bundle ID/name/version changes.
4. Import small and large IPAs, damaged archives and Files-provider documents.
5. Test low storage, cancellation, automatic cleanup, export and installation.
6. Confirm installation independently of signing; retain signed output on unconfirmed failure.

For public implementation context, see the [comparison notes](../research/public-signer-comparison.md).

## Import controls and pairing upload follow-up

- Download cards and download-list actions expose import Pause/Resume and Cancel.
  Bulk controls route to the same worker controller. Pausing preserves extraction
  progress and does not consume the cooperative extraction deadline.
- Stop wakes a paused worker. The row remains until cleanup completes; cancellation
  is not shown as an import failure. The atomic database commit boundary rejects
  late pause/cancel requests so a saved import is not misreported as cancelled.
- Copy/move operations are not forcibly interrupted; controls take effect at the
  next checkpoint. Auto-sign is a separate owner and is not hidden by download
  cancellation. Paused work is in-memory and is not resumable across app termination.
- `ImportControlTests` adds six cases for pause, resume, stop, commit protection,
  paused progress and auto-sign control availability.
- The local IDeviceKitten patch streams payloads in 1 MiB chunks and keeps native
  pointers inside the owning buffer scope. Installer Stop cancels its tracked
  main/fallback tasks; parent cancellation forwards to the upload worker.
  In-progress native calls remain cooperative, not forcibly interruptible.
- The dependency pin, license and before/after patch hashes are documented in
  `Vendor/manifest.json` and the [vendor notes](../../Vendor/README.md).

`make verify` passes after this follow-up. XCTest and real pairing/import controls
still require Xcode and an iPhone; no throughput benchmark is claimed.

## Bounded library backup and offline task thumbnails

The App Library backup component includes imported/signed bundles and their value
metadata in manifest version 3. Versions 1–2 remain readable. UUID/basename and
no-symlink tree validation precede restore; the staged container is limited to
8 GiB by the safe extraction policy. The new VEXBK3 file container encrypts and
decrypts in independently authenticated 1 MiB records rather than one Data buffer.
Oversized libraries must still use smaller backups or individual IPA exports. No installed-app
sandbox data is included. Restore skips existing UUIDs/directories and removes a
newly copied app directory if that app's database commit fails. Earlier successful
entries remain on later failure; this is not a whole-library transaction. Idle
checks are cooperative guards, not an exclusive mutation lock.

New successful imports save 64×64 local task-history PNGs independent of remote
repositories. Receipt retention/clear-history prunes icons, keeping active tasks;
missing/old/failed-download thumbnails fall back to the existing glyph. Thumbnail
errors do not undo a successful app import. Helper XCTest cases were added but
require Xcode; portable verification does not execute UIKit or Core Data flows.
OTA lookahead and archive lifetime ownership are now implemented as described below; device validation remains outstanding.

## OTA packaging lookahead

After packaging the current OTA app, InstallQueue may package exactly one next
OTA entry during the current transfer/verification. Prompts, server activation,
installed-app confirmation and cleanup decisions remain serial and unchanged.
Preparation is not installation success. Settings changes invalidate a prepared
installer before consumption; exports, pairing and guest imports remain outside
this path. Pause keeps the prepared package parked; failure/stop/clear cancel it.

Each install package has a private reference-owned workspace. Native consumers
and Vapor response completions retain that ownership independently of the queue;
Skip cannot unlink an IPA while its response body still needs it. The final owner
cleans its workspace, including partial copies/ZIPs on failure. Extra Payload
copies are removed after successful zipping. Exported files remain outside that
workspace and are not deleted when the installer retires. Cancellation is bridged
into detached packaging tasks; non-interruptible copy/ZIP operations still finish
before their next checkpoint. Stale status callbacks are ignored after Stop.

Helper XCTest coverage is added; actual parallel-transfer timing, server shutdown,
low-storage handling and iOS background execution still require Apple testing.
