# VexSign System Integration and Production Readiness Audit — 2026-11

Starting branch: `arena/d2c05cf4-vexsign`. Starting HEAD:
`2fad3a996bd8642779f7fede484be8c94ec54037`. The tree already contained 214
uncommitted entries from earlier work; this pass added its own changes on top
without discarding or committing any of them.

## How this audit was performed

The current worktree, `git log`, the Xcode project, all ten GitHub Actions
workflows, the shared schemes, entitlements, three `Package.resolved` files,
application source, test targets and release scripts were inspected directly.
No previous report was treated as evidence of the current implementation.
Source paths, protocol conformances, call sites and persisted fields were
followed across subsystem boundaries. Official Apple documentation and the
public GitHub metadata/source layout of the referenced sideloading projects
were consulted; no external code was copied into VexSign.

## Actual architecture and subsystem inventory

| Area | Actual entry point / implementation | Boundary and persistence | State of integration |
| --- | --- | --- | --- |
| App shell | `VexSignApp.swift` (`@main`), `AppDelegate.swift`, `AppLifecycleCoordinator` | `AppContainer.live()` is the composition root; `AppEnvironment` injects it once into the scene and install-queue window | Integrated. Startup recovery, notification configuration, background tasks, automation and diagnostics are called from the shell. |
| Navigation | `TabbarView`, `AppNavigationManager`, `WorkspaceNavigation`, deep-link router | Tab selection and hidden-tab preferences | Integrated. External URLs are buffered by `AppContainer` while App Lock covers the app. |
| Dependency composition | `AppContainer` initializer plus adapters in `VexSign/Shared/Protocols` | One production container; view models receive use cases; tests can construct adapters with fakes | Integrated, with some long-lived coordinators still using their existing `.shared` stores; those are deliberate owners rather than duplicated containers. |
| IPA import / archive inspection | `PackageImportService`, `AppFileHandler`, `IPAArchiveInspector`, `AppBundleInspector`, `ArchiveSafetyValidator` | Controlled work directories; Core Data library rows; task center records | Integrated. Path traversal, size and archive format checks live at the service boundary, not in UI. |
| Application metadata / bundle identity | `AppBundleInspection`, `VexSignBuildInfo`, `Storage` records | `Info.plist`, workspace snapshot | Integrated. App diagnostics and UI now read one app-level build-info source. |
| Certificate / private-key storage | `CertificateVault*`, `IdentityVault`, `CertificateManagementService`, Keychain adapters | Keychain references plus Core Data metadata; file-backed PKCS#12/profile material under controlled paths | Integrated; full Keychain and P12 behavior needs device validation. |
| Profiles and entitlements | `NativeProvisioningProfileValidator`, `EntitlementsManager`, `SigningIdentityPolicy`, `SigningResolutionSession` | Profile bytes, app group identifiers, bundle IDs, device UDIDs | Integrated into signing preflight; unavailable evidence is a refusal, not a default pass. |
| Apple account / anisette | `AppleAccountWorkspaceModel`, native authentication providers, `AnisetteProviderUseCase` | Account session and anisette headers; no account credentials committed | Implemented behind explicit user flows; not exercisable here. |
| Paid certificates | `VexSignAPI`, premium repository key providers | Optional reviewed API key supplied by the user | Implemented; external service behavior was not tested. |
| Signing | `PackageSigningCoordinator` → `SigningService` → `RunSigningUseCase` → `SigningPipeline` → `SigningHandler` → native/Zsign engine | One run lease per app, unified task record, signature verification before registration | Integrated. All UI, batch, update and automation callers pass through the coordinator. |
| Signature verification | `SignatureVerifier`, `SigningVerificationReportBuilder`, `BundleSignature`, `CertificateIdentity` | Per-component expectations; `report.requireVerified()` blocks registration | Integrated into the signing pipeline; device acceptance still needed. |
| Tweaks / dylib injection | `TweakManager`, `InjectionPlanner`, `MachOLoadCommandInjector`, authorization gates | Per-app options and controlled staging; authorized components only | Integrated into modification preflight; executable membership and compatibility are validated. |
| Devices / pairing | `PairingBridge`, `DeviceRegistryService`, `DeviceInventoryService`, `DeviceLifecycleCoordinator` | `EcosystemDatabase`, pairing file, companion/IDeviceSwift transports | Integrated, but real pairing records and devices remain external prerequisites. |
| Installation | `LibraryInstallationAdapter`, `InstallQueue`, `AppInstaller`, `DirectInstaller`, `PairedDeviceApplicationInstaller` | Verified library output is the input; queue owns lifecycle and evidence | Integrated. Hosted and paired paths do not claim computer-free installation. |
| Library / repository | `CoreDataWorkspaceRepository`, `SourceCatalogStore`, `CatalogRefreshService`, `CatalogUpdateDetector`, `RepositorySnapshotCache` | Last-known-good snapshot retained on refresh failure; integrity expectation travels with the selected release | Integrated with the fixes below; remote execution content is never trusted without validation. |
| Backup / restore | `BackupManager`, `BackupWorkspaceAdapter`, `ContainerArchiveService` | Encrypted archives, conflict previews, no silent overwrite | Integrated; real archive/device acceptance remains. |
| Notifications / automation | `VexSignNotificationService`, `PersistentAutomationEngine`, `ExpiryReminderScheduler`, background tasks | Local preferences and persisted jobs; notification actions navigate only | Integrated; scheduling depends on iOS and was not observed here. |
| Diagnostics / logging | `DiagnosticEventJournal`, `OperationOutcomeJournal`, `DiagnosticRecorder`, `LogRedaction`, `FeatureStatusRegistry` | Local journals exported through diagnostics; redaction at shared boundaries | Integrated. `FeatureStatusRegistry` itself marks device-dependent workflows as `needsDevice`. |
| Cloud / web management | `CloudSigningClient`, `WebManagerServer`, token/auth middleware | Keychain token; opt-in settings; no credentials in source | Implemented; live network/device paths not exercised here. |
| Release / artifact verification | Release scripts, `validate_release_config.py`, `artifact_manifest.py`, `verify_artifact.py` | `ARTIFACT.json` + `SHA256SUMS`; hosted artifacts are ad hoc and not device-installable | Wired into CI/release; synthetic verification only in this sandbox. |

## Important dependency flow

1. `VexSignApp.init()` prepares preferences; `AppContainer.live()` builds adapters, view
   models and the shared journal recorders. `AppEnvironment` injects the graph once.
2. Import: `PackageImportService` → structural validation → `AppFileHandler` → Core Data
   library row → import task outcome → signing hand-off.
3. Signing: one of the UI/batch/automation entry points → `PackageSigningCoordinator`
   (identity review, capability refusal, task/Live Activity lifecycle) → `SigningService`
   (lease, cancellation, ordered events) → `SigningPipeline` (identity re-check, copy,
   modify, sign, verify, register) → `LibraryAppReference`.
4. Installation: `LibraryInstallationProviding` → `InstallQueue` or `DirectInstaller` →
   signature verification → device/OTA/paired hand-off. Only verified output is accepted.
5. Repository: URL/source policy → bounded fetch → feed validation → persisted snapshot →
   update detection → catalog download request → `DownloadManager` → integrity check →
   import → signing.
6. Background and foreground transitions funnel through `AppLifecycleCoordinator` and
   `AppDelegate`; diagnostics and task records are the shared observability surfaces.

## Defects found and fixed

No critical defect (private-key exposure, false signature acceptance or destructive data
loss) was proven in the inspected production paths during this pass. The following
high/medium defects were confirmed from call sites and fixed.

### High — refused downloads were reported as started

`DownloadManager.startDownload` deliberately returns a `Download` object when a request is
refused by URL policy, Game Mode, Wi-Fi-only, charge-only or a missing session. That
object is never appended to `downloads`. Three callers treated the returned object or its
URL as success:

- `DownloadsTabViewModel`'s default handler always returned `true`, producing
  “Download started” for a refused request.
- `CatalogWorkspaceModel.download` always displayed “Downloading …” and swallowed the
  admission result.
- `PairedDeviceUpdateDownloader.start` compared `download.url == request.url`, which is
  true for the placeholder too. `DeviceLifecycleWorkspaceModel` then told the user the
  update had been handed to the download manager.

Fix:

- Added `VexSign/Services/Download/DownloadAdmission.swift`, which compares object identity,
  never URL/id/name equality.
- Added `DownloadManager.isTracked(_:)` with main-thread-safe lookup and made
  `VexHomeDownloadFeedback` delegate to the same rule.
- Updated all three callers. A refusal now produces an honest recovery message.
- Added `DownloadAdmissionIdentityTests` to the existing
  `VexSignTests/UnitTests/Application/DownloadAdmissionTests.swift` file, preserving all
  408 pre-existing lines of that test file.

### High — revoked identity was treated as available in device update planning

`CatalogWorkspaceModel` rejected revoked certificates when advertising updates, but the
paired-device `signingIdentityProvider` in `AppContainer` only checked expiration. A
revoked, unexpired identity could therefore advertise an update that signing would later
refuse. `certificateExpiryProvider` also returned a future expiry for revoked identities,
so installation authorization did not block them.

Fix:

- Added `VexSign/Services/Signing/Identity/SigningIdentityAvailability.swift` as the
  single rule: non-revoked and unexpired-or-unbounded. `installationExpiry` maps a revoked
  identity to an already-expired authorization so the existing coordinator guard blocks it.
- Updated `AppContainer` and `CatalogWorkspaceModel` to use the shared rule; the device
  coordinator message now says “expired or revoked”.
- Added `SigningIdentityAvailabilityTests` covering valid, expired, revoked, unbounded and
  mixed identity sets.

### Medium — cancelled device operations could publish stale state

`DeviceLifecycleWorkspaceModel.cancel()` cleared `operation` and `isWorking` immediately,
while the cancelled task was still unwinding. That allowed a second operation to begin and
let the old worker’s deferred cleanup or failure reporting overwrite the new state.
`CancellationError` was also displayed as an ordinary failure.

Fix:

- Added an operation generation token. `cancel()` cancels the task and retires the
  generation but leaves lifecycle cleanup to the worker’s `defer`.
- The worker now handles `CancellationError` explicitly and ignores stale completions and
  failures from retired generations.

## Workflows verified as integrated by code inspection

- Import → metadata → library row → signing hand-off: connected through
  `PackageImportService` and the signing coordinator.
- Signing → verification → registration → installation: connected; verification failures
  stop before registration, and installation verifies the stored bundle again.
- Certificate/profile → signing preflight → device update availability: now consistent for
  revocation and expiry in the two update surfaces.
- Repository → bounded download → integrity → import: connected, with admission now
  reported honestly.
- Operation lifecycle: signing uses one lease/run per app; device operations now use a
  generation token; download admission has one identity rule.
- Diagnostics: shared journal recorders are injected into signing, download and install
  singletons from the composition root.

## Workflows still incomplete or externally gated

- Native signature/profile validation, profile-device UDID membership, real Keychain
  access, P12 import and certificate replacement need macOS/Xcode and an eligible device.
- Installation completion, app-list synchronization, paired transport and interruption
  handling need a registered iPhone and a valid pairing record.
- TestFlight/App Store, enterprise/MDM and computer-free installation are not claimed as
  supported by this repository without their respective Apple credentials/services.
- Production artifact integrity and publication are implemented but have not run in
  GitHub Actions from this branch.
- The hosted IPA remains ad hoc / unsigned-for-installation. It is not a device-ready
  artifact until locally signed and verified with valid Apple material.

## Security findings and remediation

- Download admission was a trust-boundary reporting bug, not a URL-validation bypass: the
  policy still rejected unsafe URLs. The fix removes the false “started” signal.
- Revoked identity handling was inconsistent between two planners. The shared helper now
  makes revocation authoritative for update advertising and device authorization.
- Existing archive traversal limits, ZIP member validation, redirect policy, key redaction,
  Keychain boundaries, release-config gating and secret-like-key rejection were rechecked
  and left intact. No private key, profile secret, password or account credential was
  added or committed.
- `ReleaseManifestVerifier` and `ReleaseManifestTrustStore` exist and are exercised by
  tests and diagnostics, but no release-envelope key is provisioned in this repository.
  They must not be described as an active production update gate here.

## Persistence and concurrency findings

- Failed imports clean their work directories and do not complete the task; failed signing
  does not register a usable-looking signed artifact; download admission no longer lies
  about a queued row.
- Core Data workspace, catalog snapshots and preference migration retain last-known-good
  data on failure. No destructive migration was added.
- The signing service retains leases until the terminal event is consumed; the new device
  generation token applies the same principle to paired-device operations.
- `DownloadManager` remains main-queue owned for row mutation; the new `isTracked` query
  marshals to the main queue before reading the array.

## New integration and regression coverage

- `Tools/Audit/test_integration_contracts.py` gained `CrossSubsystemStateContractTests`
  (21 tests total in that module). It verifies download admission wiring, the single
  certificate-usability rule and cancellation generation semantics.
- Swift XCTest coverage added:
  - `DownloadAdmissionIdentityTests` — registered object, same-URL placeholder, empty
    manager list, reused id.
  - `SigningIdentityAvailabilityTests` — valid, expired, revoked, unbounded, mixed lists.
- These tests use fixtures and pure values; they require no Apple account, production
  certificate, network service or device.

## Exact commands executed in this sandbox

```
git branch --show-current && git rev-parse HEAD && git status --porcelain
make verify                                             # 88 gate(s) passed
make docs-check                                         # OK
python3 Tools/Audit/test_integration_contracts.py       # 21 tests OK
python3 Tools/Validation/repository-validation/sync-strings.py --check  # OK
python3 Tools/Validation/repository-validation/sync-strings.py --write  # 2 keys added
python3 Tools/Validation/repository-validation/check-pbxproj.py        # pbxproj structure OK
python3 Tools/Validation/repository-validation/check_project_wiring.py # wired OK
python3 Tools/Release/test_release_engineering.py       # 13 tests OK
python3 Tools/Release/test_release_assets.py            # 9 tests OK
python3 Tools/Audit/test_release_engineering_contracts.py # 9 tests OK
yaml.safe_load(.github/workflows/release.yml, ci.yml)   # parse OK
git diff --check                                        # clean
tree-sitter parse of 12 changed Swift files             # 0 parse errors
gh run list --branch arena/d2c05cf4-vexsign             # no runs found
```

`make verify` reports an advisory that `swiftc` is unavailable; tree-sitter parsing is
syntax-only and is not a compile or type-check. No `xcodebuild`, XCTest, XCUITest,
`codesign`, `security`, device or GitHub Actions run was performed here.

## GitHub Actions results

No Actions run exists on this branch at the time of writing. CI is configured to run
dependency resolution, project/config validation, the hosted macOS build, unit and
integration tests, simulator UI tests, static gates and release-artifact tests; this
audit added its contract checks to the already-wired integration-contract gate. The
configuration was validated locally, but no CI result can be reported until a real run.

## Features verified in CI

None from this sandbox. The statements above about CI describe workflow configuration
and local static validation only.

## Features requiring real iPhone validation

- Installation completion status, installed-app inventory and application launches.
- Pairing-file compatibility, companion transport, connection interruption and retry.
- Keychain access groups, P12 import, certificate replacement and revocation behavior.
- Signature/profile acceptance on iOS, JIT/container shortcuts and Live Activities.
- Backup restore, container restore, migration from an older installed build.
- Accessibility and UI tests on supported simulator runtimes plus a device pass.

## Features requiring external credentials or services

- Apple Developer account, distribution certificate/profile and registered device UDIDs.
- Paid certificate/premium repository key providers and their remote services.
- TestFlight/App StoreConnect processing, MDM or enterprise distribution.
- Release publication with a provisioned `ReleaseManifestKeys.plist` if signed manifests
  are to become an active update gate.

## Reference implementations and licensing

GitHub API inspection confirmed the following public projects and licenses without
copying their code: `altstoreio/AltStore` (AGPL-3.0), `SideStore/SideSign` and
`SideStore/*` documentation (AGPL-3.0), `claration/feather` (GPL-3.0),
`NexSideloading/NexStore` (GPL-3.0), `LiveContainer/LiveContainer` (AGPL-3.0),
`Nyasami/Ksign` (GPL-3.0), and `FrizzleM/SideInstaller` (NOASSERTION). VexSign keeps its
own independently implemented architecture and retains the licenses already vendored
under `Packages/`.

## Remaining blockers and recommended next actions

1. Run the full hosted CI matrix on this commit and read the real subsystem-level failures.
2. Build with the pinned Xcode and run the XCTest/XCUITest suites on supported simulators.
3. On a configured Mac, verify a real IPA with `codesign`/`security` and a valid profile.
4. On a registered iPhone, exercise import → sign → install → launch → upgrade with a
   valid pairing record and record the actual result.
5. Provision a reviewed `ReleaseManifestKeys.plist` before treating signed release
   manifests as a production trust gate.
6. Keep all changes uncommitted for manual review until the device and CI evidence exists.
