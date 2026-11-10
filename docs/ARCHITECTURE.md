# Architecture

VexSign is one SwiftUI app with a small, explicit core. Feature views do not
talk to the signing engine or the device bridge directly; they go through the
task pipeline and services, which keeps progress, errors and persistence in one
place.

```text
VexSignApp
 └── VariedTabbarView / TabbarView
      ├── Home       → VexHomeDashboard
      ├── Discover   → AppStoreView + SourcesView
      ├── Library    → LibraryView, SigningView, IPA tools
      ├── Files      → FilesTabView
      └── Settings   → certificates, storage, automation, privacy
```

## Layers

| Layer | Location | Responsibility |
| --- | --- | --- |
| App shell | `VexSign/VexSignApp.swift`, `Views/TabView/Bars/` | Scene lifecycle, tabs, appearance, onboarding, app lock, download overlay. |
| Design system | `Extensions/Theme.swift`, `Extensions/WorkspaceStyle.swift`, `DesignSystem/` | Colour, type, spacing, surfaces, reusable controls. |
| Features | `Views/Library`, `Views/Sources`, `Views/Signing`, `Views/Settings`, `Views/Downloads`, `Views/Files`, `Views/Tweaks` | Screen-level composition and user intent. |
| Core services | `Backend/Services`, `Backend/Observable` | Import, signing, installation, downloads, updates, task state, storage cleanup. |
| Models and storage | `Backend/Storage`, `Utilities/Handlers` | Core Data entities, filesystem layout, import/export, archive handling. |
| Utilities | `Utilities/` | Mach-O, IPA inspection, OCSP, certificate reading, anti-revoke, logging, installing. |
| Local packages | `NimbleKit`, `AltSourceKit`, `NativeSigning`, `Vendor/` | Shared UI/utilities, repository parsing, experimental provisioning, signing and device bridge. |
| Companion targets | `VexSignTV/`, `VexSignVision/`, `VexSignWatch*/` | Shared companion UI and platform wrappers. |

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
| `Vendor/Zsign` | Pinned signing engine, vendored in-repo. |
| `Vendor/IDeviceKitten` | Pinned Swift device bridge; its `IDevice` binary target still resolves from upstream. |
| `SideSign` | Device-local identity and overlay support. |
| `EmbeddedContainer` | Experimental guest-host packaging, tested separately. |

`Vendor/` is ordinary source in this repository. See
[`Vendor/README.md`](../Vendor/README.md) for pins and update steps.

## Concurrency

- UI work and observable state are `@MainActor`.
- Downloads, archive inspection and signing run off the main actor and report
  back through the task center.
- `tools/concurrency-discipline.py` prevents new `@unchecked Sendable` and
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
- **New third-party code:** vendor it under `Vendor/` with its licence and pin;
  keep dependency source in `Vendor/` and update its manifest.

## README feature coverage

Every capability advertised in the [README feature list](../README.md#features) has
an implementation in this repository. This table is the mapping used to check
that, so a claim can be traced to code instead of a promise:

| Advertised area | Implementation |
| --- | --- |
| On-device signing | `Vendor/Zsign`, `VexSign/Utilities/Handlers/SigningHandler.swift` |
| Batch signing and install queues | `VexSign/Backend/Observable/BatchJobRunner.swift`, `InstallQueue.swift`, `VexSign/Views/Library/Batch/` |
| Signing profiles and presets | `VexSign/Backend/Observable/SigningProfileStore.swift`, `NamedSigningProfileStore.swift`, `VexSign/Views/Settings/Signing Options/SigningProfilesView.swift` |
| Signing options, preflight and signing logs | `VexSign/Views/Settings/Signing Options/ConfigurationView.swift`, `AdvancedSigningSettingsView.swift`, `VexSign/Backend/Observable/PreflightChecks.swift`, `SigningLog.swift` |
| Local HTTPS and AFC/`installd` installation | `VexSign/Backend/Server/LocalTLSIdentity.swift`, `Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift`, `VexSign/Utilities/Installing/` |
| Signing Live Activities | `VexSign/Backend/Observable/SigningLiveActivityManager.swift`, `VexSignWidgetExtension/SigningLiveActivity.swift` |
| Auto-sign and Update All | `VexSign/Backend/Observable/AutoSignManager.swift`, `AppUpdateChecker.swift` |
| Tweak injection and ElleKit | `VexSign/Views/Tweaks/TweakInjectConfigView.swift`, `TweakRepositoryView.swift`, `VexSign/Utilities/Handlers/TweakHandler.swift`, `OneShotTweakFiles.swift` (files added for one sign are copied per run and never saved by path), `Vendor/` ElleKit resources |
| Mach-O thinning | `VexSign/Utilities/Handlers/SigningHandler.swift` (`.thinning` stage), `VexSign/Utilities/Signing/SigningService.swift` |
| IPA Explorer | `VexSign/Views/IPAExplorer/`, `VexSign/Utilities/IPAExplorer/` |
| Clone Wizard and icon badges | `VexSign/Utilities/Handlers/AppCloner.swift` (badge is drawn onto a writable PNG icon), `VexSign/CloneWizard/CloneWizardView.swift` |
| File manager and QuickLook | `VexSign/Views/FileManager/FileManagerView.swift`, `VexSign/Views/Settings/Files & Compression/` |
| AltStore-compatible sources and ESign parsing | `AltSourceKit/`, `VexSign/Utilities/SourceFeedLoader.swift` |
| Public GitHub release IPA sources (single IPA asset; no bundle-ID matching guarantee) | `VexSign/Utilities/GitHubReleaseSource.swift`, `FR.swift`, `SourceFeedLoader.swift` |
| Repository sync, ETag revalidation and offline catalog | `VexSign/RepositorySync/RepositorySyncEngine.swift`, `VexSign/Views/Sources/SourcesViewModel.swift` |
| Source health dashboard | `VexSign/Views/Sources/SourceHealthDashboardView.swift` |
| Discover, ranking and bundle grouping | `VexSign/Views/TabView/AppStoreView.swift` (state, catalog, body), `AppStoreView+Discover.swift`, `AppStoreView+Repositories.swift`, `AppStoreRepositoryRows.swift`, `VexSign/Views/Sources/Apps/` |
| Per-app update rules and skipped updates | `VexSign/Backend/Observable/PerAppUpdateRules.swift`, `SkippedUpdatesManager.swift` |
| Premium activation and catalog filters | `VexSign/Backend/Observable/PremiumManager.swift`, `VexSign/Views/Sources/PremiumSettingsView.swift`, `server/` |
| Self-update checks, release notification and install methods | `VexSign/Backend/Observable/SelfUpdateManager.swift`, `SelfUpdateNotifier.swift`, `VexSign/Views/Updates/` |
| Background downloads, conditions and Game Mode | `DownloadManager.swift`, `DownloadManager+Delegates.swift`, `DownloadManager+LiveActivity.swift`, `DownloadManager+PackageImport.swift`, `DownloadPreferences.swift`, `GameMode.swift` |
| Web manager with HTTP/WebDAV | `VexSign/Views/Settings/Web Manager/WebManagerView.swift`, `server/web_tools.py` |
| Storage report and cleanup | `VexSign/Backend/Observable/StorageManager.swift` (`LibrarySnapshot` decides what is an orphan; a failed certificate fetch protects everything, and a copy that is being signed or imported is never an orphan) |
| Download integrity and hashing | `VexSign/Utilities/DownloadIntegrity.swift`, `FileIntegrity.swift` |
| Certificate monitoring, dashboard and OCSP | `CertificateStatusManager.swift`, `BatchCertChecker.swift`, `VexSign/CertificateDashboard/`, `VexSign/Utilities/OCSP/` |
| Local trust setup with a device TLS identity | `VexSign/Backend/Server/LocalTLSIdentity.swift`, `LocalCAProfile.swift`, `VexSign/Utilities/IdentityVault.swift` |
| P12 password recovery | `VexSign/Utilities/P12Cracker.swift`, `VexSign/Views/Settings/Certificates/P12CrackerView.swift` |
| App lock and secret storage | `VexSign/Security/AppLockManager.swift`, `SecureSecretStore.swift`, `CertificateSecrets.swift` |
| Profile compatibility, nested bundles and output verification | `VexSign/Utilities/Signing/ProfileCompatibility.swift`, `NestedBundleAudit.swift`, `SignatureVerifier.swift` |
| Signed source metadata | `VexSign/Utilities/SourceProvenance.swift`, `docs/SOURCE_SIGNING.md` |
| Anti-revoke DNS profiles | `VexSign/Utilities/AntiRevoke/`, `VexSign/Views/Settings/Security/AntiRevokeSettingsView.swift` |
| Background automation, App Intents and widgets | `VexSign/Backend/Observable/BackgroundAutomation.swift`, `VexSign/Backend/AppIntents/`, `VexSignWidgetExtension/` |
| Cleanup, backup and analytics | `CleanupManager.swift` (every pass, Clean Now included, leaves the temporary directory and leftovers alone while a sign or install is running), `VexSign/Backend/Services/PostSignArtifacts.swift` (which copies a finished sign leaves), `VexSign/Backend/Services/CleanupPolicy.swift` (what a pass defers; which duplicate signed copy is kept), `InstallCleanup.swift`, `BackupManager.swift` (archive creation, validation and restore orchestration), `BackupRestorePlan.swift` (restore admission), `LibraryBackupSupport.swift` (library entry and tree validation), `BackupCrypto.swift` (backup encryption), `VexSign/Analytics/` |
| Logs and diagnostic export | `VexSign/Utilities/FileLogger.swift`, `DiagnosticBundleExporter.swift`, `VexSign/Views/Logs/`, `VexSign/Views/Settings/About/DiagnosticsCenterView.swift` |
| Companion apps | `VexSignTV/`, `VexSignVision/`, `VexSignWatch/`, `VexSignWatchWidgets/`, `docs/PLATFORMS.md` |
| Web tools | `server/web_signer.py`, `server/repo_creator.py`, `server/repo_decoder.py`, `server/app_installer.py`, `server/cert_inspector.py`, `server/udid_grabber.py`, `VexSign/Ecosystem/WebToolsView.swift` |
| Repository builder, OTA export and QR | `VexSign/OTA/OTAExporter.swift`, `VexSign/OTA/OTAView.swift`, `VexSign/Ecosystem/EcosystemView.swift` |
| Appearance, tint, icon and tab preferences | `VexSign/Extensions/AppStyle.swift`, `VexSign/Backend/Observable/AppearanceStore.swift`, `VexSign/Views/Settings/App Icon/AppIconView.swift`, `TabBarSettingsView.swift` |
| Native account provisioning and cloud bridge | `NativeSigning/`, `VexSign/Backend/CloudSigning/`, `VexSign/Views/Settings/CloudSigning/`, `cloud-signing/` |
| Experimental guest-host packaging | `EmbeddedContainer/` |
| Automated tests and CI | `VexSignTests/`, `server/tests/`, `cloud-signing/test/`, `.github/workflows/` |

**What this check does and does not prove.** The mapping was verified by reading
the named files and confirming each area has a real implementation (not a stub or
a settings row without a consumer); `Settings → About → Feature Status` exposes
the same wiring for the signing, install and update pipeline. It does *not* prove
that a feature works on a physical device. Signing, installation, background
execution and companion pairing still need the device pass described in
[`DEVICE_TESTING.md`](DEVICE_TESTING.md); the README's own caveats (experimental
provisioning, opt-in services, iOS scheduling limits) stand.
