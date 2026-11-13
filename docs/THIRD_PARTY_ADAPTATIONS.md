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

## GitHub release IPA chooser

- **Feature reference:** [NuzProjects/Feather](https://github.com/NuzProjects/Feather).
- **Reviewed revision:** `1436e8609053d836f7c69e771b56b06dca52dcda`.
- **Sources:** `Feather/Core/ReleaseRules.swift` and `Feather/Features/Library/GitHubImportView.swift`.
- **License:** GPL-3.0; see upstream notices and the repository [LICENSE](../LICENSE).
- **VexSign locations:** `Utilities/GitHubIPAReleases.swift`, `Views/Library/GitHubIPAImportView.swift` and Library import menu.

Adapted the repository-to-release-to-IPA selection workflow with VexSign-specific
models, stricter URL boundaries, bounded streaming metadata retrieval, declared
integrity handoff and existing download/import ownership. Upstream automatic
tracking, notifications, source persistence and replacement identity logic are not
included. No upstream binaries, credentials or additional dependencies are imported.
Apple build/test and device acceptance remain pending; see the
[integration assessment](research/public-signer-integration-assessment.md).

## Tweak load-time compatibility gate

- **Feature references:** [faroukbmiled/RyukSign](https://github.com/faroukbmiled/RyukSign)
  at `46c6d15` (`RyukSign/Utilities/Handlers/TweakAnalyzer.swift`, `TweakHandler.swift`) and
  [Mesutcydev/ForgeSign-iOS](https://github.com/Mesutcydev/ForgeSign-iOS) at `a08e679`
  (`App/Services/DylibInjectionService.swift`, `IPAPreflight.swift`).
- **License:** RyukSign is GPL-3.0. ForgeSign-iOS publishes no license, so nothing from it
  may be copied; it was read for the idea of a preflight step only.
- **VexSign locations:** `Utilities/Handlers/TweakCompatibility.swift`, and its callers in
  `TweakHandler.swift` and `TweakAnalyzer.swift`.

Concept only: inspect, check compatibility, then inject, as separate steps. The rules, the
layout resolution and the Mach-O reading are VexSign's own, built on the existing
`MachOInspector`. No source text from either project is included.

## Typed certificate status

- **Feature references:** [NexSideloading/NexStore](https://github.com/NexSideloading/NexStore)
  at `d4c7fc1` (`NexStore/Backend/Observable/CertificateStatusManager.swift`) and
  [raynmahbub/Odysseus](https://github.com/raynmahbub/Odysseus) at `ab74059`
  (`Feather/Backend/Certificates/ODOCSPCore.swift`, `ODCertificateStatusStore.swift`), read as
  an on-device comparison; its responder status is also good/revoked/unknown.
- **License:** GPL-3.0 for both.
- **VexSign locations:** `Utilities/Signing/CertificateStatusAssessment.swift`,
  `Backend/Observable/CertificateStatusManager.swift`, `CertificateDashboard/CertificateInspector.swift`.

Concept only. NexStore's manager has the same three states VexSign already had
(signed/revoked/unknown) and obtains them by uploading the `.p12` and its password to a
third-party checker (`certchecker.novadev.vip`). That mechanism is rejected: VexSign keeps
its on-device trust evaluation and sends no key material anywhere. The additional states
(expired, check unavailable, check unsupported) and the evidence-age rule are VexSign's own.
