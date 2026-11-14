# End-to-end integration matrix

This document records what the subsystems of VexSign actually exchange, which user
journeys have been traced through that seam, and what evidence exists for each. It is
the integration half of release qualification; [DEVICE_TESTING.md](DEVICE_TESTING.md)
is the hardware half and is unchanged by it.

Status vocabulary — used strictly:

| Status | Means |
| --- | --- |
| **traced** | The path was read end to end in this repository and the seams named below exist as described. Reading is not executing. |
| **unverified** | Code exists and is wired, but nothing in this pass ran it. |
| **blocked** | Requires hardware, credentials or a service this pass did not have. |
| **defect** | A seam was read and found to report something untrue; the entry names the fix or the open gap. |

Nothing in this file is a claim that a workflow ran successfully. No build, no test
run and no device interaction happened while it was written — see
[What this document does not establish](#4-what-this-document-does-not-establish).

## 1. Subsystem integration map

`Produces` / `Consumes` are the data that actually crosses the boundary, not a
restatement of the module name.

| Subsystem | Authoritative implementation | Produces | Consumes | Persistence | Error surface | Cancellation | Existing tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Apple account | `Services/AppleAccountSessionCoordinator.swift`, `AppleAccountSessionRepository.swift`, `AnisetteProvider.swift` | Session state, provisioning artefacts | Credentials from `AppleAccountCredentialStore`, Anisette data | Keychain (`…ThisDeviceOnly`) plus a resume journal | `AppleAccountAuthenticationState` | Coordinator-owned task; resume journal survives relaunch | `AppleAccount*Tests.swift`, `AnisetteProviderTests.swift` |
| Certificates and keys | `Utilities/Handlers/CertificateFileHandler.swift`, `Security/IdentityVault.swift` | Imported `CertificatePair`, key material in Keychain | `.p12` + password, profile | Core Data metadata; secrets in Keychain only | Typed `CertificateFileHandlerError` | Import is atomic per file | `CertificateRemovalDurabilityTests`, `CredentialMigrationDiagnosticsTests` |
| Provisioning profiles | `Utilities/CertificateReader`, `Utilities/Signing/ProfileCompatibility.swift` | Decoded profile, permitted entitlements, expiry | Profile bytes | Profile file beside the certificate | Decode failures are explicit, never coerced | n/a | `ProfileCompatibilityTests`, `RenewalReadinessTests` |
| Signing orchestration | `Utilities/FR+Signing.swift` → `Utilities/Signing/SigningService.swift`, `SigningExecutionGate.swift`, `ZsignEngine.swift` | Signed `Signed` record, verification outcome | Identity, profile, entitlements, tweaks, `Options` | `Storage+Signed`; provenance in `TaskContext` | `SigningErrorMapper`, structured stages | Cooperative (`SigningExecutionGate`); `BackgroundTaskManager` keeps the window open | `SigningServiceTests`, `SigningExecutionGateTests`, `FullSignPipelineIntegrationTests` |
| Entitlements | `Utilities/MachOEntitlements.swift`, `Utilities/Signing/BundleSignature.swift` | Parsed and rewritten entitlement plists | Mach-O, profile | Inside the signed bundle | Parse errors abort the app, never the batch | n/a | `SignatureVerifierTests`, `NestedBundleAuditTests` |
| IPA import and archives | `Utilities/FR+Import.swift` → `Handlers/AppFileHandler.swift`, `ArchiveSafetyValidator.swift` | `Imported` record, extracted bundle on disk | IPA from Files, share sheet or a download | Core Data row after the filesystem copy commits | `VexSignError` with a stage; `ImportControl` checkpoints | `Task.checkCancellation` at the commit boundary | `IPAExtractorTests`, `ArchiveLimitsTests`, `ImportAndInstallationTests` |
| Mach-O inspection | `Utilities/MachO/`, `MachOReader.swift`, `MachOInspectorTests` vector | Architecture list, encryption status, linked dylibs | Bundle executables | Not persisted | Bounds-checked reader; malformed input throws | n/a | `MachOReaderTests`, `MachOInspectorTests`, `ExecutablePreflightTests` |
| Customisation | `Utilities/PlistDiff.swift`, `TweakModels.swift`, `NameChanger`-style options in `OptionsManager` | Per-app `Options`, tweak injections | Bundled tweak `.dylib`s, user input | `Options` per app | Invalid option values rejected before signing | n/a | `OptionsCompatibilityTests`, `TweakInjectionDefaultsTests` |
| Repositories | `AltSourceKit` (package), `Utilities/SourceFeedLoader.swift`, `FR+Repository.swift` | Normalised `StoreApps` with source provenance | Remote JSON, `repos.json` | Core Data sources + cached payloads | Per-source failure, never fatal to the list | Fetch tasks cancel with the screen | `SourceFeedLoaderTests`, `GitHubIPAReleasesTests`, `SourceProvenanceTests` |
| Discovery | `Views/Sources`, `Discovery/DiscoveryViewModel.swift` | Search/filtered listings | Repository payloads | Preference stores only | Empty states distinguish "no result" from "source unavailable" | n/a | `DiscoveryViewModelTests`, `PremiumFilterPreferences` coverage |
| Downloads | `Observable/DownloadManager*.swift` | Staged IPA, integrity verdict, recovery journal record | Source URL, `DownloadIntegrity.Expectation` | Journal file; staged file in `DownloadStagingPath` | UI alert + `retainedPackageURL` on integrity failure | `ImportControl`, `PackageVerificationOwner`, per-task cancel | `DownloadIntegrityTests`, `DownloadRecoveryJournalTests`, `DownloadAdmissionTests` |
| Application library | `Backend/Storage/*` (Core Data), `Observable/LibraryStatusStore.swift` | The authoritative app inventory | Imported/signed rows, artifact availability, install status | Core Data with migrations | Storage errors surfaced, no silent row loss | n/a | `LibrarySnapshotTests`, `CatalogIdentityTests`, `StorageLibrarySnapshotTests` |
| Device discovery and pairing | `Utilities/IDevice/`, `IDeviceSwift` (vendored), `DeviceTLSIdentity.swift` | Paired device list, transport readiness | Pairing file, VPN state, local CA | Pairing file + Keychain TLS identity | Connectivity failures are distinct from authorisation failures | Transport tasks cancel with the sheet | `DeviceConnectivityTests`, `DevicePickerTests`, `DeviceTLSIdentityTests` |
| Installation | `Observable/AppInstaller.swift`, `Installing/InstallVerificationPolicy.swift`, `InstallQueue*.swift`, `TrollStoreHandoff.swift` | Transfer outcome, verification evidence, inventory sync | Signed bundle, device transport | Library status via `LibraryStatusStore` | Phases separate transfer from installation; `unconfirmed` is not success | `InstallDeadlineBudget`, monitoring stop is recorded explicitly | `InstallEvidenceReportingTests`, `InstallVerificationTests`, `InstallerStatus` tests |
| Task orchestration | `Observable/UnifiedTaskCenter.swift` + `UnifiedTask*`, `Services/TaskHistoryJournal.swift`, `TaskReceipt.swift` | One task record per operation; persisted history | Downloads (mirrored), signing stages, install stages | `UnifiedTaskHistory.json` (200 entries, icons separate) | Terminal phases only through `move(to:)`; `TaskMirrorPolicy` for mirrors | `TaskRetryPolicy`; retry handlers are released on finalize | `UnifiedTaskPolicyTests`, `TaskHistoryJournalTests`, `TaskReceiptOutcomeTests` |
| Backup and restoration | `Observable/BackupManager.swift`, `Services/BackupRestorePlan.swift`, `Handlers/BackupVerification.swift` | Encrypted archive + manifest | Library metadata, repository config, non-secret signing metadata | Streamed to file; restore is planned before it writes | Verification before restore; plan refuses partial states | Bounded streaming, cancellable | `BackupRestorePolicyTests`, `BackupVerificationTests`, `BackupStreamingTests` |
| Persistence and caching | `Backend/Storage/Storage.swift`, `StorageConcurrency.swift`, `Utilities/StoragePreflight.swift` | Single Core Data store | Every feature above | `NSPersistentContainer` with write-context boundary | Errors propagate to the caller that asked | Writes are not left half-applied by cancellation | `StorageConcurrencyTests`, `ProtectedFileAttributesTests` |
| Diagnostics and logging | `Utilities/Logging/`, `FileLogger.swift`, `LogRedaction.swift`, `DiagnosticBundleExporter.swift`, `Services/TaskTrace.swift` | Redacted exportable bundle | Log records, task traces | Rotating local log files | Export reports what it could not include | n/a | `LogRedactionTests`, `TaskIconArchiveTests`, `WorkflowTraceTests` |
| Companion and cloud services | `Backend/Companion/CompanionBridge.swift`, `Backend/CloudSigning`, `Backend/Server/WebManagerServer.swift`, `Services/CloudSigning/cloud-signing/`, `Services/API/server/`, `Services/Anisette/AnisetteServer/` | Handoff links, remote signing jobs, LAN UI | Device pairing, tokens, uploaded IPA | Companion secrets in Keychain | Auth middleware rejects when unconfigured | Requests cancel with the sheet | `CompanionAndWidgetTests`, `WebManagerAccessTests`, `CloudUploadBodyTests` |

Known duplicate-of-truth risks, recorded rather than refactored:

- **`BatchJobRunner`** keeps its own per-item state (`queued/working/signed/…`) for
  batch screens while the individual sign and install steps also report into
  `UnifiedTaskCenter`. The batch list is screen state; the durable record is the task
  center. Two vocabularies exist for the same outcome, and they are mapped by hand.
- **`Download.phase`** has no failure case. A failed or stopped transfer is expressed
  by *removing* the row, which is what made the mirroring defect below possible.
- The Apple-ID certificate handoff records its work as `UnifiedTaskKind.export`
  (`Services/NativeSigningManager.swift`), so history groups an import under
  "Export". The title is correct; the kind is not. Fixing it means a new persisted
  kind value, so it is recorded here instead of changed quietly.

## 2. Workflow matrix

Success and failure conditions are the states the code actually produces. "Traced"
means the seam was read; it does not mean a run was observed.

| Workflow | Entry point | Dependencies | Success condition | Failure conditions | Recovery | Tests | Platform restrictions | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| IPA import → library | Files/share sheet → `FR.handlePackageFile`; download import → `DownloadManager+PackageImport` | Archive safety, extractor, storage, library | `Imported` row exists, artifact directory resolves, task reaches `.completed` with `import-registered` | Unsafe paths, unsupported archive, no `Payload/*.app`, storage commit failure, cancellation at commit | `handler.clean()` on failure; interrupted import detected on next launch; duplicate copy offered "keep both / discard this one" | `IPAExtractorTests`, `ImportAndInstallationTests`, `ImportControlTests` (`ImportDuplicateReview` has no dedicated test) | Very large archives are bounded (8 GiB) | traced |
| Identity → signed IPA | Sign sheet or automated flow → `FR.signPackage` → `SigningService` | Certificate + key, profile compatibility, entitlements, nested bundles, tweaks | `Signed` record registered after signature verification; task `.completed` | Invalid identity, expired/incompatible profile, keychain denial, verification failure, cancellation | Structured stage + `SigningErrorMapper` message; retry re-registers settings; no partial `Signed` row | `SigningServiceTests`, `FullSignPipelineIntegrationTests`, `PostSignArtifactsTests`, `SigningIdentityResolutionTests` | Signing does not imply installable or launchable; that is stated in the UI and in `TaskContext` | traced |
| Repository → downloaded app | Sources tab → source JSON → download → import | Repository parsing, download admission, integrity, library import | Listing normalised, artifact staged, integrity verdict matches expectation, import completes | Malformed source JSON, unavailable host, redirect to unsupported scheme, size limit, integrity mismatch, duplicate release | Per-source error isolation; staged file retained for explicit override; `DownloadRecoveryJournal` for interrupted transfers | `SourceFeedLoaderTests`, `DownloadIntegrityTests`, `WebDAVTransferPolicyTests`, `GitHubIPAReleasesTests` | Background transfer limits are iOS-defined and are not claimed here | traced |
| Signing → device installation | Install sheet / queue → `AppInstaller` → transport | Validated identity, signed bundle, paired device, VPN or local CA | Transfer completes **and** verification finds the installed app | Disconnect, rejection, timeout, deadline budget expiry, monitoring stop, iOS withholding evidence | Distinct phases; `unconfirmed` instead of failure when iOS will not confirm; cancellation recorded as monitoring-stopped | `InstallEvidenceReportingTests`, `InstallDeadlineBudgetTests`, `InstallVerificationTests`, `InstallQueue*Tests` | Transfer ≠ installation; private LaunchServices lookups are filtered on modern iOS | traced |
| Task orchestration | `UnifiedTaskCenter.begin` from imports, signing, install queue and download mirroring | Journal, redaction, retry registry | One record per operation; monotonic progress; one terminal phase | Duplicate submission, late progress callback, persistence failure, process exit mid-work | Journal merges live tasks after load; `recoverAfterRestart` marks unfinished work `interrupted`/`unconfirmed` | `UnifiedTaskPolicyTests`, `TaskHistoryJournalTests`, `TaskReceiptOutcomeTests` | Background execution time is granted by iOS, not by the app | **defect fixed**, see D1 |
| Backup → restore | Settings → Backup → `BackupManager` | Manifest, encryption, verification, storage | Verified archive restores into a consistent library; identities revalidated before use | Corruption, truncation, wrong password, insufficient space, partial restore | Verify-before-write; plan refuses ambiguous states; interrupted restore leaves the original data in place | `BackupRestorePolicyTests`, `BackupVerificationTests`, `BackupStreamingTests`, `LibraryBackupSupportTests` | Keychain secrets are not exported; restored identities must re-derive their secrets | traced |

## 3. Integration defects

### D1 — A download that vanished was recorded as completed (fixed)

`Observable/UnifiedTaskDownloadMirroring.swift` dropped a mirrored task when its
`Download` row disappeared, and set it to `.completed` first:

```swift
if !task.phase.isTerminal {
    task.phase = .completed   // no transition, no evidence
    _finalize(task)
}
```

`DownloadManager` removes the row on every path that did **not** finish: a
non-recoverable transfer error, a package over the 8 GiB safety limit, and the user
stopping the transfer (`DownloadManager+Delegates.swift:157`, `:236`, `:269`;
`DownloadManager+TransferControl.swift:137`). So the Task Center and the Dynamic
Island showed a green "Completed" for a download that had just failed, and
`_finalize` released the retry handler on the way out. The alert and the task list
disagreed about the same operation.

`TaskMirrorPolicy.vanished(_:)` in `UnifiedTaskPolicies.swift` now owns the verdict:
a non-terminal mirror becomes `.interrupted`, a terminal one is left alone, and the
transition goes through `transition(_:to:)` so the record is finalized and persisted
the same way as every other phase. `.interrupted` is the claim this side of the seam
can defend — the transfer did not finish, and which of the three paths ended it is
not recoverable from an absent row. Failure is not invented for a download the user
stopped themselves.

Covered by five tests in `App/Tests/VexSignTests/UnifiedTaskPolicyTests.swift`; the manual
reasoning above is why the fourth asserts `.download` and `.importIPA` both accept
the verdict through the real transition authority.

### D2 — A merge to main cancelled the previous merge's only validation (fixed)

`ci.yml`, `platform-check.yml`, `services.yml`, `embedded-container.yml` and
`docs.yml` all used:

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

On a push to `main`, `github.ref` is `refs/heads/main` for every commit, so each
merge cancelled the run before it. The run list is the evidence, not the file: of
main runs 370–388, every completed CI run was `cancelled` and none succeeded. The
branch a release is cut from therefore had no completed CI at all, and a later
`gh run list` cannot tell "not validated" from "validated quietly".

The group is now keyed per commit on push and `cancel-in-progress` applies only to
pull requests, where superseding is what you want. `Tools/CI/test_workflow_policy.py`
asserts the rule for all five workflows, so a revert fails a check instead of
silently removing the evidence again.

### Open gaps (not fixed)

- **R1 — `begin` can leave an orphaned queued record.** `UnifiedTaskCenter.begin`
  adopts a `.queued` duplicate only when the caller also asks for `.queued`; a caller
  asking for a running phase with the same kind and subject creates a second record
  and abandons the queued one, which is never finalized. No current caller reaches
  this (imports and the download mirror start `.queued`, signing and installation
  start further along), and a fix has to decide what adopting means for a caller
  that expects to begin mid-pipeline, so it is recorded rather than guessed at.
- **R2 — the mirror cannot tell "failed", "stopped" and "removed" apart.** D1 makes
  the recorded outcome honest; distinguishing the three needs an outcome on
  `Download` and a signal to the center before removal.
- **R3 — no Release archive has ever been produced or inspected in this repository.**
  Entitlements, privacy manifests and the export path are unvalidated. No
  distribution build was attempted: the credentials are not available here, and an
  unproven archive must not be described as one.
- **R4 — `Platform check` is failing on main** (run `43305902567`, and the previous
  main run `43283590947`). Its logs were not retrievable from this environment, so
  the failure is recorded, not diagnosed. Multi-platform support remains unproven.
- **R5 — the backend services are unaudited.** `Services/API/server/`, `Services/CloudSigning/cloud-signing/` and
  `Services/Anisette/AnisetteServer/` accept uploads and issue jobs; nothing in this or any earlier
  pass established their request handling.

## 4. What this document does not establish

- No Swift was compiled and no test was executed. Every "traced" row above is a
  source read; the tests named are files that exist, not tests that passed.
- No voice, dynamic-type, contrast, performance or battery observation exists.
- No device, simulator, transport or installation was exercised.
- No CI run on this branch was observed to completion.
- Nothing here certifies the application as secure or release-ready.
