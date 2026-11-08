# Third-party code adaptations

This register supplements—not replaces—the project's existing copyright notices,
licenses and dependency acknowledgements. See [LICENSE](../LICENSE),
[LICENSE_ELLEKIT](../LICENSE_ELLEKIT) and [vendored dependencies](../Vendor/README.md).

## IPA export naming and collision handling

- **Upstream:** [korboybeats/KorSign](https://github.com/korboybeats/KorSign).
- **Reviewed revision:** `f20892f43177476ef769b2ac76fc038f87d963ec`.
- **Source:** [`KorSign/Utilities/Handlers/ArchiveHandler.swift`](https://github.com/korboybeats/KorSign/blob/f20892f43177476ef769b2ac76fc038f87d963ec/KorSign/Utilities/Handlers/ArchiveHandler.swift), `exportStem` and the collision-handling portion of `moveToArchive`.
- **Original file notice:** Created by samara on 22.04.2025; subsequent work by KorSign contributors.
- **License:** GNU General Public License version 3; license text is preserved in the repository's [LICENSE](../LICENSE).
- **VexSign location:** `VexSign/Utilities/Handlers/IPAExportNaming.swift`.
- **Adapted:** 2026-11-08.

### Modifications and integration

Extracted the naming method into `IPAExportNaming.stem`. Adapted the numbered,
non-overwriting move loop into a reusable `movePackage` function with explicit
source/destination parameters and cooperative cancellation checks. Native UI and
browser exports share the naming helper. Opening the Files app remains the
responsibility of `ArchiveHandler` after a successful move.

VexSign now propagates failed archive saves instead of silently returning an
unwritten path. An additional VexSign change bounds the persisted compression
index before packaging. Six regression tests cover fallback names, unsafe
characters, Unicode budgets, collisions and failure preservation.

No third-party certificates, private keys, signing binaries or new package
dependencies are included in this adaptation. KSign/RyukSign signing comparisons
are recorded in the [comparison notes](research/public-signer-comparison.md);
existing shared functionality was not duplicated simply to claim another port.

## Pairing-transfer compression policy

- **Upstream:** KorSign, same revision and original file notice as above.
- **Source:** `ArchiveHandler.archive(compressForTransfer:)` selects `.BestSpeed`
  for pairing transfers when the selected level is `.NoCompression`.
- **License:** GNU GPL version 3; see [LICENSE](../LICENSE).
- **VexSign location:** `VexSign/Utilities/Handlers/ArchiveTransferPolicy.swift`.
- **Adapted:** 2026-11-08.

The policy is extracted into a testable helper with bounds checking for invalid
stored values. `AppInstaller` enables it only for non-export pairing installs.
User export, OTA and companion packaging defaults are unchanged, and the saved
preference is not rewritten. Four XCTest cases cover transfer selection,
preserved preferences and out-of-range indices. Smaller payloads may reduce
transfer costs, but no device performance improvement is claimed without measurement.

## Signed / unsigned Library workflow actions

- **Upstream:** [Nyasami/Ksign](https://github.com/Nyasami/Ksign), confirmed by the user.
- **Reviewed revision:** `c14dedc0c9dadb669021cce83435b14f781b8412`.
- **Source:** [`Ksign/Views/Library/LibraryCellView.swift`](https://github.com/Nyasami/Ksign/blob/c14dedc0c9dadb669021cce83435b14f781b8412/Ksign/Views/Library/LibraryCellView.swift), signed Install/Re-sign and unsigned Sign & Install actions.
- **Original file notice:** LibraryAppIconView.swift, Feather; created by samara on 11.04.2025; subsequent KSign contributors.
- **License:** GPL-3.0; repository [LICENSE](../LICENSE) retained.
- **VexSign locations:** `Utilities/LibraryAppWorkflowAction.swift`, LibraryCellView leading swipe actions, AnyApp request metadata, SigningView initialization.

Adapted the action/intent split into a testable policy and explicit per-request
install-after-signing intent. Signed rows offer Install and Re-sign; imported rows
offer Sign & Install while retaining their normal Sign button. The new leading
swipes require authentication for locked apps and disable accidental full-swipe
execution. VexSign's signing preflight, checked native results, certificate handling,
confirmed-install watcher, queue dismissal and Installed badge handoff are kept.
Global signing defaults are not changed by the quick action.

Also reviewed KSign ArchiveHandler, SigningHandler and InstallPreviewView at that
revision. Their packaging/signing/pairing/OTA capabilities already have counterparts
in VexSign; they are not duplicated wholesale. In particular, upstream forced
installer/identifier unwraps, progress-based assumptions and late/shadowed signing
error checks are not imported. No third-party certificates or binaries were added.
