# Architecture

VexSign is one SwiftUI app with a small, explicit core. Feature views do not
talk to the signing engine or the device bridge directly; they go through the
task pipeline and services, which keeps progress, errors and persistence in one
place.

```text
VexSignApp
 └── TabbarView
      ├── Home       → VexHomeDashboard
      ├── Discover   → AppStoreView + SourcesView
      ├── Library    → LibraryView, SigningView, IPA tools
      ├── Files      → FilesTabView
      └── Settings   → certificates, storage, automation, privacy
```

## Layers

| Layer | Location | Responsibility |
| --- | --- | --- |
| App shell & Composition Root | `App/iOS/VexSign/VexSignApp.swift`, `Application/AppContainer.swift`, `Presentation/AppContainerEnvironment.swift` | Scene lifecycle, explicit dependency graph (`AppContainer.live()`), `@Environment(\.appContainer)` injection, deep-link dispatch. |
| Domain | `App/iOS/VexSign/Domain/` (`Foundation`-only) | Framework-free contracts, subsystem boundary protocols, value snapshots, errors, and `DeepLinkCommand` parsing. |
| Application | `App/iOS/VexSign/Application/` | Orchestration use cases (`DirectPackageInstallUseCase`, `FirmwareDownloadUseCase`, `WorkspaceResetUseCase`, `DeepLinkRouterUseCase`, `AnisetteProviderUseCase`, `WorkspaceSupportUseCase`). |
| Presentation | `App/iOS/VexSign/Presentation/`, `Views/` | `@MainActor` ViewModels/coordinators and pure SwiftUI views decoupled from Core Data, `URLSession`, and `FileManager` internals. |
| Security & Shared | `App/iOS/VexSign/Security/`, `App/iOS/VexSign/Shared/` | `SecurityPolicyGateway`, `TransferSecuritySession` (HTTP `2xx`, redirect policy, byte cap), `AppLockManager`, `ErrorBoundary`, redacted `SubsystemDiagnosticsLog`. |
| Platform & Infrastructure | `App/iOS/VexSign/Platform/`, `App/iOS/VexSign/Infrastructure/` | Concrete UIKit/Nuke/filesystem/Core Data/network adapters implementing `Domain` boundary protocols. |
| Design system | `Extensions/Theme.swift`, `Extensions/WorkspaceStyle.swift`, `DesignSystem/` | Colour, type, spacing, surfaces, reusable controls. |
| Core services | `Backend/Services`, `Backend/Observable` | Import, signing, installation, downloads, updates, task state, storage cleanup. |
| Models and storage | `Backend/Storage`, `Utilities/Handlers` | Core Data entities, filesystem layout, import/export, archive handling. |
| Utilities | `Utilities/` | Mach-O, IPA inspection, OCSP, certificate reading, anti-revoke, logging, installing. |
| Local packages | `NimbleKit`, `AltSourceKit`, `NativeSigning`, `Packages/Vendor/` | Shared UI/utilities, repository parsing, experimental provisioning, signing and device bridge. |
| Companion targets | `App/TV/VexSignTV/`, `App/Vision/VexSignVision/`, `VexSignWatch*/` | Shared companion UI and platform wrappers. |

Architectural boundaries (pure `Domain`, zero `URLSession.shared` or `CoreData` leaks in Presentation/Application or refactored views, and `AppContainer` composition-root wiring) are enforced continuously by [`Tools/Architecture/test_architecture_boundaries.py`](../../Tools/Architecture/test_architecture_boundaries.py) and [Clean Architecture Boundaries](../Engineering/Changes/clean-architecture-boundaries.md).

## The task pipeline

`UnifiedTaskCenter` is the single source of truth for long-running work. A task
moves through:

```text
queued → downloading → extracting → signing → installing → completed
                         ↘ failed / cancelled (from any stage)
```

`DownloadManager` mirrors downloads into the same task model, and signing and
installation flows call `begin`/`transition` at their natural boundaries. The
Home dashboard, Task Center, Downloads tab, widgets and Dynamic Island all read
that state instead of maintaining separate progress values.

A signing task names two library copies, and they are different records: its
`subjectID` is the copy the run was **started from**, and `context.artifactID`
is the copy it **produced**, set only when it completes. A screen that describes
a copy asks `UnifiedTaskCenter.signingRecords(forCopy:)`, which keeps the two
apart (`SigningRecordIdentity`); `latestSigningTask(subjectID:)` answers only
"what was last started from this copy". A failed run never changes the copy it
started from, so its record must not be shown as that copy's result.

A signing request roughly follows:

```text
DocumentPicker / repository URL
  → import + archive validation
  → certificate/profile compatibility checks
  → Zsign (vendored C++/Objective-C++ through SwiftPM)
  → output verification
  → install queue (local HTTPS, idevice or companion)
  → Library entry + task history
```

## What the install card may claim

An installation is described by two independent clocks, and the screen has to
combine them rather than pick one:

- the **transport** — `InstallerStatusViewModel.InstallerStatus`: packaging,
  manifest, payload transfer, `installd`'s counter. It describes what VexSign's
  own server and connection are doing.
- the **lifecycle** — `InstallConfirmation.Phase`: waiting for iOS's prompt,
  downloading, verifying against device evidence, then a verdict.

They disagree for a real stretch of every OTA install. The server reports
`ready` the moment it can serve, iOS then shows its own confirmation prompt, and
the transport has nothing more to say until the user answers. `InstallStatusPresentation`
is the single pure resolver for that pair: a terminal transport answer wins, the
lifecycle outranks a transport status that has not caught up, and the transport
is the fallback only for the stretches the lifecycle cannot describe (packaging
and payload transfer, before any progress exists). The card's line, its icon,
its percentage and the progress ring's VoiceOver label all come from that one
resolution, so they cannot drift apart. A completion published through
`publishConfirmedCompletion` means the device proved the install; nothing else
does.

## State and storage

- **Core Data** stores certificate pairs, imported/signed apps and repository
  sources (`Backend/Storage/VexSign.xcdatamodeld`).
- **Files** under the app sandbox hold imported archives, signed outputs,
  exports and logs. `StorageManager` owns the layout and cleanup rules.
- **A signing run has two library copies**, the one it was started from and the
  one it produced, and `PostSignArtifacts` is the only rule for what happens to
  them. The produced copy is never deleted when a sign finishes; the other goes
  only when a flow or a setting asks, and only after the produced copy is
  confirmed to be in the library. Every flow that signs a library app ends in
  `CleanupManager.finishSign`; the self-update, which signs a scratch copy of
  VexSign and removes it again, is the one exception.
- **A copy's bundle is in the library before its row is.** Signing and importing
  announce the copy to `AppOperationRegistry` (`claimProduction`,
  `confirmProduction`) so that a cleanup pass in between does not take its
  folder for a leftover.
- **The temporary directory** is shared working space: signing work directories,
  the archive an install hands to iOS, and tweak files staged for one sign. It
  is emptied at every launch (download staging aside), and cleanup may empty it
  after a sign or an install, or on Clean Now — though not while
  `AppOperationRegistry` holds any lease (`CleanupPassPolicy`; leftovers wait
  the same way). Nothing that has to outlive one operation may be saved as a
  path into it; saved signing settings keep the *names* of one-time tweak files
  for that reason (`OneShotTweakFiles`, `SigningProfile.replayable()`).
- **Keychain** holds credentials and secrets; `CertificateSecrets` and the
  security utilities wrap access.
- **UserDefaults** holds preferences and migration keys. Legacy Feather/Ryuk
  keys are migrated once at launch.
- **Task history** stores the last 200 finished tasks as metadata only — never
  credentials or file contents.

## Local packages

| Package | Why it is local |
| --- | --- |
| `NimbleKit` | Shared SwiftUI helpers, logging, extensions and policy-friendly utilities. |
| `AltSourceKit` | AltStore-compatible source parsing, isolated from the app target. |
| `NativeSigning` | Experimental account/provisioning backend with its own tests. |
| `Packages/Vendor/Zsign` | Pinned signing engine, vendored in-repo. |
| `Packages/Vendor/IDeviceKitten` | Pinned Swift device bridge; its `IDevice` binary target still resolves from upstream. |
| `SideSign` | Device-local identity and overlay support. |
| `EmbeddedContainer` | Experimental guest-host packaging, tested separately. |

`Packages/Vendor/` is ordinary source in this repository. See
[`Packages/Vendor/README.md`](../../Packages/Vendor/README.md) for pins and update steps.

## Concurrency

- UI work and observable state are `@MainActor`.
- Downloads, archive inspection and signing run off the main actor and report
  back through the task center.
- `Tools/Development/concurrency-discipline.py` prevents new `@unchecked Sendable` and
  `nonisolated(unsafe)` escapes outside the reviewed baseline.
- `make strict-concurrency` reports the remaining Swift 6 warnings in the local
  packages.

## Security boundaries

1. **Archive boundary** — imported ZIPs are validated before extraction;
   traversal, links and unsupported entries are rejected.
2. **Identity boundary** — certificates and passwords are read from protected
   storage only for the signing operation and are redacted from logs.
3. **Network boundary** — repository content is treated as untrusted data; the
   local install server generates a per-device TLS identity.
4. **Device bridge** — idevice operations require a valid pairing file and an
   active connection; success is verified rather than inferred from a request.

## Where to add a feature

- **New screen:** put it under the matching `Views/` folder, use
  `Theme`/`VexHomeSurface` tokens, and add it to the relevant navigation root.
- **New background work:** create a `UnifiedTask`, report phase transitions, and
  surface failures through the task center rather than a one-off alert.
- **New persisted model:** update the Core Data model, add a migration-safe
  default, and cover import/export paths.
- **New repository field:** extend `AltSourceKit` with decoding tests before
  wiring it into Discover.
- **New third-party code:** vendor it under `Packages/Vendor/` with its licence and pin;
  keep dependency source in `Packages/Vendor/` and update its manifest.

## README feature coverage

Every capability advertised in the [README feature list](../../README.md#features) has
an implementation in this repository. This table is the mapping used to check
that, so a claim can be traced to code instead of a promise:

| Advertised area | Implementation |
| --- | --- |
| On-device signing | `Packages/Vendor/Zsign`, `App/iOS/VexSign/Utilities/Handlers/SigningHandler.swift` |
| Batch signing and install queues | `App/iOS/VexSign/Backend/Observable/BatchJobRunner.swift`, `InstallQueue.swift`, `App/iOS/VexSign/Views/Library/Batch/` |
| Signing profiles and presets | `App/iOS/VexSign/Backend/Observable/SigningProfileStore.swift`, `NamedSigningProfileStore.swift`, `App/iOS/VexSign/Views/Settings/Signing Options/SigningProfilesView.swift` |
| Signing options, preflight and signing logs | `App/iOS/VexSign/Views/Settings/Signing Options/ConfigurationView.swift`, `AdvancedSigningSettingsView.swift`, `App/iOS/VexSign/Backend/Observable/PreflightChecks.swift`, `SigningLog.swift` |
| Local HTTPS and AFC/`installd` installation | `App/iOS/VexSign/Backend/Server/LocalTLSIdentity.swift`, `Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift`, `App/iOS/VexSign/Utilities/Installing/` |
| Signing Live Activities | `App/iOS/VexSign/Backend/Observable/SigningLiveActivityManager.swift`, `Extensions/Widgets/VexSignWidgetExtension/SigningLiveActivity.swift` |
| Auto-sign and Update All | `App/iOS/VexSign/Backend/Observable/AutoSignManager.swift`, `AppUpdateChecker.swift` |
| Tweak injection and ElleKit | `App/iOS/VexSign/Views/Tweaks/TweakInjectConfigView.swift`, `TweakRepositoryView.swift`, `App/iOS/VexSign/Utilities/Handlers/TweakHandler.swift`, `OneShotTweakFiles.swift` (files added for one sign are copied per run and never saved by path), `Packages/Vendor/` ElleKit resources |
| Mach-O thinning | `App/iOS/VexSign/Utilities/Handlers/SigningHandler.swift` (`.thinning` stage), `App/iOS/VexSign/Utilities/Signing/SigningService.swift` |
| IPA Explorer | `App/iOS/VexSign/Views/IPAExplorer/`, `App/iOS/VexSign/Utilities/IPAExplorer/` |
| Clone Wizard and icon badges | `App/iOS/VexSign/Utilities/Handlers/AppCloner.swift` (badge is drawn onto a writable PNG icon), `App/iOS/VexSign/CloneWizard/CloneWizardView.swift` |
| File manager and QuickLook | `App/iOS/VexSign/Views/FileManager/FileManagerView.swift`, `App/iOS/VexSign/Views/Settings/Files & Compression/` |
| AltStore-compatible sources and ESign parsing | `Packages/AltSourceKit/`, `App/iOS/VexSign/Utilities/SourceFeedLoader.swift` |
| Public GitHub release IPA sources (single IPA asset; no bundle-ID matching guarantee) | `App/iOS/VexSign/Utilities/GitHubReleaseSource.swift`, `Utilities/Services/RepositoryCatalogService.swift`, `SourceFeedLoader.swift` |
| Repository sync, ETag revalidation and offline catalog | `App/iOS/VexSign/RepositorySync/RepositorySyncEngine.swift`, `App/iOS/VexSign/Views/Sources/SourcesViewModel.swift` |
| Source health dashboard | `App/iOS/VexSign/Views/Sources/SourceHealthDashboardView.swift` |
| Discover, ranking and bundle grouping | `App/iOS/VexSign/Views/TabView/AppStoreView.swift` (state, catalog, body), `AppStoreView+Discover.swift`, `AppStoreView+Repositories.swift`, `AppStoreRepositoryRows.swift`, `App/iOS/VexSign/Views/Sources/Apps/` |
| Per-app update rules and skipped updates | `App/iOS/VexSign/Backend/Observable/PerAppUpdateRules.swift`, `SkippedUpdatesManager.swift` |
| Premium activation and catalog filters | `App/iOS/VexSign/Backend/Observable/PremiumManager.swift`, `App/iOS/VexSign/Views/Sources/PremiumSettingsView.swift`, `Services/API/server/` |
| Self-update checks, release notification and install methods | `App/iOS/VexSign/Backend/Observable/SelfUpdateManager.swift`, `SelfUpdateNotifier.swift`, `App/iOS/VexSign/Views/Updates/` |
| Background downloads, conditions and Game Mode | `DownloadManager.swift`, `DownloadManager+Delegates.swift`, `DownloadManager+LiveActivity.swift`, `DownloadManager+PackageImport.swift`, `DownloadPreferences.swift`, `GameMode.swift` |
| Web manager with device-local HTTPS and WebDAV | `App/iOS/VexSign/Views/Settings/Web Manager/WebManagerView.swift`, `App/iOS/VexSign/Backend/Server/WebManagerServer.swift` |
| Storage report and cleanup | `App/iOS/VexSign/Backend/Observable/StorageManager.swift` (`LibrarySnapshot` decides what is an orphan; a failed certificate fetch protects everything, and a copy that is being signed or imported is never an orphan) |
| Download integrity and hashing | `App/iOS/VexSign/Utilities/DownloadIntegrity.swift`, `FileIntegrity.swift` |
| Certificate monitoring, dashboard and OCSP | `CertificateStatusManager.swift`, `BatchCertChecker.swift`, `App/iOS/VexSign/CertificateDashboard/`, `App/iOS/VexSign/Utilities/OCSP/` |
| Local trust setup with a device TLS identity | `App/iOS/VexSign/Backend/Server/LocalTLSIdentity.swift`, `LocalCAProfile.swift`, `App/iOS/VexSign/Utilities/IdentityVault.swift` |
| P12 password recovery | `App/iOS/VexSign/Utilities/P12Cracker.swift`, `App/iOS/VexSign/Views/Settings/Certificates/P12CrackerView.swift` |
| App lock and secret storage | `App/iOS/VexSign/Security/AppLockManager.swift`, `SecureSecretStore.swift`, `CertificateSecrets.swift` |
| Profile compatibility, nested bundles and output verification | `App/iOS/VexSign/Utilities/Signing/ProfileCompatibility.swift`, `NestedBundleAudit.swift`, `SignatureVerifier.swift` |
| Signed source metadata | `App/iOS/VexSign/Utilities/SourceProvenance.swift`, `Documentation/Architecture/SOURCE_SIGNING.md` |
| Anti-revoke DNS profiles | `App/iOS/VexSign/Utilities/AntiRevoke/`, `App/iOS/VexSign/Views/Settings/Security/AntiRevokeSettingsView.swift` |
| Background automation, App Intents and widgets | `App/iOS/VexSign/Backend/Observable/BackgroundAutomation.swift`, `App/iOS/VexSign/Backend/AppIntents/`, `Extensions/Widgets/VexSignWidgetExtension/` |
| Cleanup, backup and analytics | `CleanupManager.swift` (every pass, Clean Now included, leaves the temporary directory and leftovers alone while a sign or install is running), `App/iOS/VexSign/Backend/Services/PostSignArtifacts.swift` (which copies a finished sign leaves), `App/iOS/VexSign/Backend/Services/CleanupPolicy.swift` (what a pass defers; which duplicate signed copy is kept), `InstallCleanup.swift`, `BackupManager.swift` (archive creation, validation and restore orchestration), `BackupRestorePlan.swift` (restore admission), `LibraryBackupSupport.swift` (library entry and tree validation), `BackupCrypto.swift` (backup encryption), `App/iOS/VexSign/Analytics/` |
| Logs and diagnostic export | `App/iOS/VexSign/Utilities/FileLogger.swift`, `DiagnosticBundleExporter.swift`, `App/iOS/VexSign/Views/Logs/`, `App/iOS/VexSign/Views/Settings/About/DiagnosticsCenterView.swift` |
| Companion apps | `App/TV/VexSignTV/`, `App/Vision/VexSignVision/`, `Extensions/Watch/VexSignWatch/`, `Extensions/Watch/VexSignWatchWidgets/`, `Documentation/Engineering/PLATFORMS.md` |
| Web tools | `Services/API/server/web_signer.py`, `Services/API/server/repo_creator.py`, `Services/API/server/repo_decoder.py`, `Services/API/server/app_installer.py`, `Services/API/server/cert_inspector.py`, `Services/API/server/udid_grabber.py`, `App/iOS/VexSign/Ecosystem/WebToolsView.swift` |
| Repository builder, OTA export and QR | `App/iOS/VexSign/OTA/OTAExporter.swift`, `App/iOS/VexSign/OTA/OTAView.swift`, `App/iOS/VexSign/Ecosystem/EcosystemView.swift` |
| Appearance, tint, icon and tab preferences | `App/iOS/VexSign/Extensions/AppStyle.swift`, `App/iOS/VexSign/Backend/Observable/AppearanceStore.swift`, `App/iOS/VexSign/Views/Settings/App Icon/AppIconView.swift`, `TabBarSettingsView.swift` |
| Native account provisioning and cloud bridge | `Packages/NativeSigning/`, `App/iOS/VexSign/Backend/CloudSigning/`, `App/iOS/VexSign/Views/Settings/CloudSigning/`, `Services/CloudSigning/cloud-signing/` |
| Experimental guest-host packaging | `Integrations/EmbeddedContainer/` |
| Automated tests and CI | `App/Tests/VexSignTests/`, `Services/API/server/tests/`, `Services/CloudSigning/cloud-signing/test/`, `.github/workflows/` |

**What this check does and does not prove.** The mapping was verified by reading
the named files and confirming each area has a real implementation (not a stub or
a settings row without a consumer); `Settings → About → Feature Status` exposes
the same wiring for the signing, install and update pipeline. It does *not* prove
that a feature works on a physical device. Signing, installation, background
execution and companion pairing still need the device pass described in
[`DEVICE_TESTING.md`](../QA/DEVICE_TESTING.md); the README's own caveats (experimental
provisioning, opt-in services, iOS scheduling limits) stand.

## Architecture-excellence transformation

This pass freezes the high-level architecture without moving the existing
folder tree. The six logical layers, dependency direction, owner diagrams and
enforcement rules are in [dependency rules and diagrams](dependency-rules.md).
The complete machine-readable map of 24 major components, 14 core-system owners,
dependencies, state, concurrency, persistence, tests, failure modes and
refactoring requirements is [component-map.json](component-map.json).
The [architecture excellence audit](../Research/architecture-excellence-audit.md)
records the initial audit, migration phases, validation results, security and
performance findings, remaining limitations and final assessment.
[Source-guided decisions](../Research/source-guided-architecture-decisions.md)
records pinned upstream evidence for specific features and licence boundaries.

### Architecture drift ratchet

The repository still contains historical SwiftUI views that import Core Data or
call `Storage.shared`, `DirectInstaller`, `InstallQueue` or `URLSession.shared`
directly. They are not hidden by a new abstraction layer: every reviewed file is
recorded in [architecture-drift-baseline.json](../../Tools/Architecture/architecture-drift-baseline.json)
and [Tools/Architecture/test_architecture_excellence.py](../../Tools/Architecture/test_architecture_excellence.py)
fails when a new file joins a violation class. `--report` prints new/removed
entries, and `--write-baseline` is a manual, reviewable operation used only after
an intentional migration. The gate runs in `make verify` and CI's `Docs and
regressions` step. The accepted decision and consequences are in the
[architecture drift ADR](../Engineering/Changes/architecture-excellence-drift-guard.md).

The first completed migration removes UIKit and platform-global coupling from
`WorkspaceSupportUseCase`: `WorkspaceSupportEnvironmentProviding` is a pure
Domain port, `UIKitWorkspaceSupportEnvironmentAdapter` owns platform facts, and
`AppContainer.live()` injects the adapter explicitly. An `AnisetteProviderUseCase`
`NativeSigning` import remains a documented external-integration seam; the
remaining legacy Presentation coupling is baseline-tracked for incremental
removal. This is a stronger boundary, not a claim that every screen is already
clean, and not a `Build-verified` or `Device-verified` claim.
