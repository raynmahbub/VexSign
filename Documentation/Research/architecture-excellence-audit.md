# VexSign architecture excellence audit — 2026-11-13

**Branch:** `arena/562440f7-vexsign`, branched from `main` at `7aafec17a898667fad4765f5a8647ceada2b2d48`.
**Status:** uncommitted working tree. No commit, push, PR, merge, release, tag, secret change or deployment was executed.
**Objective:** evolve the existing app toward the shared six-layer architecture using source evidence, without a rewrite, duplicate engines, cosmetic package extraction or fabricated device/CI claims.

This document is the consolidated record for the requested final deliverables. The machine-readable dependency map is [`../architecture/component-map.json`](../Architecture/component-map.json); the normative rules and diagrams are [`../architecture/dependency-rules.md`](../Architecture/dependency-rules.md); the accepted decision is [`../changes/architecture-excellence-drift-guard.md`](../Engineering/Changes/architecture-excellence-drift-guard.md).

## 1. Initial architecture audit

### Verified repository facts

| Item | Source-level finding |
| --- | --- |
| Tracked files | 1,355 files, no `.gitmodules`; local packages are vendored/pinned in the checkout. |
| Swift source | 556 app Swift files, 145 `VexSignTests` Swift files, 110 `NativeSigning` Swift files, 50 `NimbleKit`, 46 `SideSign`, 8 `AltSourceKit`, plus widget/watch/TV/Vision Swift files. |
| Xcode targets | `VexSign`, `VexSignTests`, `VexSignWidgetExtensionExtension`, `VexSignWatch`, `VexSignWatchWidgets`, `VexSignTV`, `VexSignVision`; Debug/Release and `Debug-distribution`/`Release-distribution` configurations. |
| Build settings | iOS deployment target 17.0; project `SWIFT_VERSION = 5.0`; CI uses a Swift 6 toolchain and Swift 6 diagnostics; file-system-synchronized groups mean new files in existing groups need no `project.pbxproj` edit. |
| SwiftPM pins | Workspace and project `Package.resolved` each have 42 pins; `Packages/SideSign/Package.resolved` has 6. No new package was introduced. |
| Architecture docs | `Documentation/Architecture/ARCHITECTURE.md`, `Documentation/Engineering/Changes/clean-architecture-boundaries.md`, `Documentation/VexSign.docc/Architecture.md`, distribution/threat/device docs and the 2026-11-13 research set already existed. |
| CI | Nine workflows; `ci.yml` has quick, build, tests and concurrency jobs; `platform-check.yml`, `services.yml`, `docs.yml`, release and maintenance workflows are separate. |
| Baseline portable gates | `make verify` exit 0; `python3 -m unittest discover -s tools -p 'test_*.py'` 309 OK before this pass. |

### Verified strengths, not documentation claims

- `App/iOS/VexSign/Domain/` is Foundation-only and contains narrow boundary protocols.
- `AppContainer.live()` is an explicit composition root with `@Environment` injection.
- One signing pipeline exists: `SigningService` → `SigningHandler`/`ZsignEngine`, with `SigningPlan`, `NestedBundleAudit`, `ProfileCompatibility` and `SignatureVerifier`.
- One task model exists: `UnifiedTaskCenter`, `UnifiedTaskModels/Policies/Artifacts`, `TaskHistoryJournal`, `TaskReceipt` and `TaskTrace`.
- `DeviceConnectivity.swift` already separates presence, pairing record readability, trust and capability status.
- Installation evidence is distinct from transport status (`InstallConfirmation`, `InstallerStatusViewModel`, `AppInstaller`).
- Existing security gates cover URL policy, redirects/HTTP status/size, archive extraction, log redaction, Keychain tiers, Web Manager authorization, cloud signing contract and native CMS fail-closed behavior.

### Actual architectural violations found

| Violation | Evidence | Disposition |
| --- | --- | --- |
| Application imported UIKit and platform globals | `WorkspaceSupportUseCase.swift` used `UIAlertController`, `UIDevice`, `UserDefaults`, `SigningModeManager.shared`, `PairingBridge`, `MobileGestalt`, `FileManager.default`. | Fixed in this pass with a pure Domain port and Platform adapter. |
| Application still imports an external integration | `AnisetteProviderUseCase.swift` imports `NativeSigning`. | Baseline-tracked; migrate behind a domain provider port in a later phase. |
| Presentation directly touches storage/filesystem | `CertificatesCoordinator.swift`, `HomeActionCoordinator.swift`. | Baseline-tracked; no risky mass refactor without Xcode proof. |
| Legacy SwiftUI views import CoreData or call `Storage.shared`/`@FetchRequest` | 17 CoreData imports, 44 direct-storage files in the drift report. | Baseline-tracked; new files are blocked. |
| Legacy views directly start installs/signing/imports | 3 direct-install files, 2 direct-signing files. | Baseline-tracked; use cases/coordinators are the migration target. |
| One legacy view still calls `URLSession.shared` | `SourcesAddView+Repositories.swift`. | Baseline-tracked; must route through `SecurityPolicyGateway`/`TransferSecuritySession`. |

The exact reviewed file lists are in [`../../Tools/Architecture/architecture-drift-baseline.json`](../../Tools/Architecture/architecture-drift-baseline.json). The guard is source-level; it does not replace compilation.

## 2. Existing-to-target component mapping

The full 24-component map with all nine required fields is [`../architecture/component-map.json`](../Architecture/component-map.json). The 14 named core systems map to existing owners rather than new duplicate types:

| Target name | Existing owner | Layer | Refactor requirement |
| --- | --- | --- | --- |
| SigningOrchestrator | `SigningService`, `SigningHandler`, `SigningPlan` | Infrastructure | Preserve one pipeline; provider differences belong in identity/plan inputs. |
| IdentityManager | `IdentityVault`, `CertificateSecrets`, `CertificateStatusManager`, `NativeSigning` identity stores | Platform | Keep secrets in Keychain; no automatic unsupported renewal. |
| ProvisioningValidator | `ProfileCompatibility`, `NestedBundleAudit`, `NativeProvisioningProfileValidator` | Domain | Keep pure policies and strict CMS gate separate. |
| ApplicationRegistry | `Storage`, `ImportDuplicateReview`, `LibraryIntegrityAudit` | Infrastructure | One canonical lifecycle store; schema migration needs simulator/device rehearsal. |
| InstallationCoordinator | `AppInstaller`, `InstallQueue`, `InstallConfirmation` | Platform | Capability-based adapters; no success claim without verification. |
| DeviceCapabilityResolver | `DeviceConnectivity.swift` | Platform | Preserve capability/trust/presence separation. |
| UnifiedTaskCenter | `UnifiedTaskCenter.swift` and related models/policies | Infrastructure | No independent progress engine. |
| PersistentTaskJournal | `TaskHistoryJournal`, `TaskHistoryQuery`, `TaskTrace` | Infrastructure | Operation-specific recovery only. |
| RepositoryManager | `RepositorySyncEngine`, `RepositoryCatalogService`, `AltSourceKit` | Infrastructure | Keep ETag/offline catalog policy in one owner. |
| DownloadManager | `DownloadManager.swift` and extensions | Infrastructure | Keep validated transfer lifecycle and recovery. |
| ArtifactStorage | `Utilities/Handlers`, `PostSignArtifacts`, integrity utilities | Infrastructure | Atomic bounded staging; no second storage system. |
| BackupRestoreCoordinator | `BackupManager`, `BackupRestorePlan`, `BackupCrypto`, `LibraryBackupSupport` | Infrastructure | Encryption/integrity/restore admission remain together. |
| AutomationCoordinator | `BackgroundAutomation`, `AppIntents`, Live Activity managers | External integrations | Read-only task snapshots and explicit grants. |
| DiagnosticService | `DiagnosticBundleExporter`, `SubsystemDiagnosticsLog`, `LogRedaction`, `FileLogger` | Infrastructure | Redact before display/copy/export/stdout. |

## 3. Updated architecture documentation

- [`../ARCHITECTURE.md`](../Architecture/ARCHITECTURE.md) now links the six-layer rules, owner map, drift ratchet and honest assessment.
- [`../architecture/dependency-rules.md`](../Architecture/dependency-rules.md) is the normative dependency-direction document.
- [`../architecture/component-map.json`](../Architecture/component-map.json) is the machine-readable dependency/owner map.
- [`../changes/architecture-excellence-drift-guard.md`](../Engineering/Changes/architecture-excellence-drift-guard.md) is the ADR.
- [`source-guided-architecture-decisions.md`](source-guided-architecture-decisions.md) records pinned sources for specific features.
- [`../README.md`](../README.md) indexes the new architecture documents.
- [`../../CHANGELOG.md`](../../CHANGELOG.md) has Unreleased Added/Fixed entries.

## 4. Dependency rules and diagrams

The six layers are Presentation, Application, Domain, Infrastructure, Platform and External integrations. Dependencies point inward toward Domain. Mermaid diagrams for layer direction, core-system ownership and the signing pipeline are in [`../architecture/dependency-rules.md`](../Architecture/dependency-rules.md).

Permanent rules enforced by `Tools/Architecture/test_architecture_excellence.py`:

1. Domain has no forbidden imports.
2. Application has no UIKit/SwiftUI/CoreData/Nuke/IDeviceSwift/AltSourceKit imports and no `URLSession.shared`.
3. `AppContainer.live()` remains the explicit composition root.
4. New files may not join the legacy Presentation coupling baseline.
5. The 14 core systems and 24 major components must stay documented with all required fields.
6. Guard wiring must remain in `Makefile` and CI.
7. Build-verified and Device-verified claims remain separate gates.

## 5. Refactored source implementation

| File | Change |
| --- | --- |
| `App/iOS/VexSign/Domain/WorkspaceSupportContracts.swift` | New Foundation-only `WorkspaceSupportSnapshot` and `WorkspaceSupportEnvironmentProviding` port. |
| `App/iOS/VexSign/Application/WorkspaceSupportUseCase.swift` | Removed `import UIKit`, `UIAlertController`, `UIDevice`, `UserDefaults`, `SigningModeManager.shared`, `PairingBridge`, `MobileGestalt`, `FileManager.default`; now formats an injected non-secret snapshot and delegates presentation/folder URLs through ports. |
| `App/iOS/VexSign/Platform/UIKitWorkspaceSupportEnvironmentAdapter.swift` | New UIKit adapter that owns device/defaults/pairing/signing-mode facts and alert presentation. |
| `App/iOS/VexSign/Application/AppContainer.swift` | Injects the new adapter explicitly into the composition root and the support use-case factory. |
| `Tools/Architecture/test_architecture_boundaries.py` | Forbids additional Application platform imports and asserts the support-port boundary. |
| `Tools/Architecture/test_architecture_excellence.py`, `Tools/Architecture/architecture-drift-baseline.json` | New ownership-map/drift guard and reviewed legacy baseline. |
| `Makefile`, `.github/workflows/ci.yml` | Run the new guard locally and in CI's quick/docs regressions step. |

No folder was mass-moved, no existing feature was removed and no new Swift package/dependency was introduced.

## 6. New and updated tests

- `App/Tests/VexSignTests/WorkspaceSupportArchitectureTests.swift`: injected snapshot URL content, no credential/device-secret leakage, feedback choice URL routing, and shared-folder URL injection.
- `Tools/Architecture/test_architecture_boundaries.py`: Application platform-import ban and WorkspaceSupport port assertions.
- `Tools/Architecture/test_architecture_excellence.py`: baseline equality, clean Domain/Application platform imports, non-empty legacy baseline, synthetic violation detection, component-map completeness, source-evidence path existence, CI/Makefile wiring and documentation links.
- `Tools/Development/test_docs.py` / `Tools/Development/check-docs.py`: existing offline link and documentation checks remain.

The Swift XCTest file is written but **not executed locally**: the Linux sandbox has no Xcode/simulator. Tree-sitter parsing is syntax-only and is not a build or type-check.

## 7. GitHub Actions validation results

### Local portable gates

| Command | Result before this pass | Final result after this pass |
| --- | --- | --- |
| `make verify` | exit 0 | exit 0 |
| `python3 -m unittest discover -s tools -p 'test_*.py'` | 309 OK | 318 OK (8 new architecture-excellence tests and 1 new boundary test) |
| `python3 Tools/Development/test_docs.py` | 3 OK | 3 OK |
| `PYTHON=<venv>/bin/python make test-server` | 215 passed, 1 skipped | 215 passed, 1 skipped |
| `make test-cloud` | exit 0; 14/14 Node tests, OpenAPI drift clean | exit 0; 14/14 Node tests, OpenAPI drift clean |
| `python3 Tools/Development/check-docs.py` | OK | OK |
| `python3 .github/scripts/quick_check.py --no-swiftc` | exit 0 | exit 0 |
| `git diff --check` | clean | clean |
| tree-sitter parse of 5 new/modified Swift files | n/a | 0 parse errors; syntax only, not type-check/build |

The single server skip is `optional cryptography not installed`. The warning is a Starlette/httpx deprecation advisory. No local `swiftc` or Xcode was available.

### GitHub Actions

At the time of final verification, the current `main` push commit `7aafec17` had these workflow results:

| Run | Workflow | Result |
| --- | --- | --- |
| `43562550583` | Documentation | success |
| `43562550659` | Service checks | success |
| `43562550638` | Platform check | success |
| `43562550643` | CI | in progress |
| `43562550619` | Combined native host · build only | in progress |
| Repository maintenance runs | Repository maintenance | skipped |

The `CI` and `Combined native host · build only` runs were rechecked after the final portable verification and were still in progress. These are **current-main** results, not validation of this uncommitted architecture diff. The user explicitly prohibited automatic commits/pushes, so no fresh GitHub Actions run was triggered for this working tree. A future PR/commit must run `ci.yml` quick, build, tests and concurrency on the exact reviewed SHA before any `Build-verified` claim.

## 8. Security and performance findings

### Security

- The new support snapshot contains only device model, iOS version, app version, routing preference and non-secret installation lines; no private key, password, token, UDID, certificate payload or pairing record crosses the Application boundary.
- Existing redaction-before-export, URL/SSRF guards, HTTP status/redirect/byte caps, archive path-traversal/decompression limits, Keychain ThisDeviceOnly storage, Web Manager authorization, explicit cloud authorization and native CMS fail-closed gates were preserved.
- The drift baseline makes legacy direct persistence/network calls visible instead of hiding them; it does not grant them a security exception.
- Source-guided decisions preserve licence boundaries: no GPL/AGPL/custom-licence implementation source was copied.

### Performance

- No speculative optimization was performed. There is no profiler, simulator or device trace in this sandbox.
- Known future work: large SwiftUI views with `@FetchRequest`, repeated `AppContainer.live()` fallback in `SettingsView`, main-thread filesystem calls in legacy views, repository refresh duplication and unbounded legacy view-side work.
- The new guard discourages regression by blocking new direct-infrastructure shortcuts; it does not claim measured p95, memory or energy improvements.
- Long-running work remains owned by `UnifiedTaskCenter`, `DownloadManager` and `InstallQueue`; no second progress engine was added.

## 9. Remaining limitations

1. No local Swift compiler/Xcode/simulator: no compile, type-check, link, generic unsigned iOS build or XCTest execution for the new Swift files.
2. No physical iPhone: no `Device-verified`, install confirmation, launch evidence, force-quit fault injection or performance numbers.
3. No fresh GitHub Actions run for this uncommitted diff; no commit/push was executed.
4. `AnisetteProviderUseCase` still imports `NativeSigning`; the baseline records it as an external-integration seam.
5. Legacy Presentation coupling remains: 17 CoreData imports, 44 direct-storage files, 3 direct-install files, 2 direct-signing files and 1 `URLSession.shared` file.
6. Native Apple-account signing remains `.notIntegrated`; genuine Apple CMS, full device ladder, production trust key, unattended profile renewal and multi-device pairing remain gated.
7. Bootstrap/TestFlight/Ad Hoc/Enterprise/MDM/marketplace portal, operational cloud-signing backend, unrestricted computer-free install and release deployment are not implemented or verified.
8. Full upstream repository source audit was not performed; only pinned source-specific evidence was used.
9. The architecture is not claimed 10/10 complete. The requested completion criteria are partially met and explicitly mapped.

## 10. Final architecture assessment

| Criterion | Honest status |
| --- | --- |
| Dependency direction | Enforced for Domain/Application and ratcheted for Presentation; legacy exceptions documented. |
| Separation of responsibilities | Strong core ownership; incremental view migration remains. |
| Signing correctness | One pipeline with preflight/output verification; no duplicate engine. |
| Application lifecycle consistency | One Storage/registry owner; schema uniqueness migration deferred safely. |
| Device abstraction | Capability resolver and evidence gates exist; no universal install promise. |
| Security architecture | Existing gates preserved, new snapshot is non-secret, drift is visible. |
| Error handling and recovery | Existing task/journal/trace systems retained; no blind resume claim. |
| Testability | New port and XCTest doubles; portable guard self-tests. Swift tests not locally executed. |
| Performance design | No speculative changes; known risks documented. |
| Maintainability | Machine-readable owner map, ADR, diagrams and enforced guard. |
| CI builds and relevant tests pass | Local portable gates pass; fresh CI for this diff is not available without push. |
| Device acceptance | Not performed. |

This pass is a measured architecture improvement, not a cosmetic tree shuffle and not a completion certificate. VexSign now has an enforceable ownership map, a smaller Application/Platform boundary, and a ratchet that prevents new architectural drift while preserving existing features.

## Professional PR title

`refactor(architecture): add ownership map, drift ratchet, and support port boundary`

## Commit message proposal

```text
refactor(architecture): freeze ownership and enforce dependency drift

Add a machine-readable six-layer component map, dependency rules/diagrams,
source-guided feature decisions and an ADR. Remove UIKit and platform-global
coupling from WorkspaceSupportUseCase through a pure Domain port and a UIKit
adapter injected by AppContainer. Add XCTest coverage, a legacy architecture
drift ratchet, and wire the new guards into make verify and CI quick.

Preserve existing signing, installation, task, storage, native/CMS, bootstrap,
cloud and device gates. No commits, pushes, merges, releases or device claims
were executed.
```

Optional incremental sequence: `docs(architecture): record baseline and owner map`; `refactor(application): inject workspace support environment`; `test(architecture): add drift ratchet and support contracts`; `docs: publish architecture decisions, assessment and changelog`.

## Changelog entry

Already applied to `CHANGELOG.md` under Unreleased:

```markdown
### Added
- A machine-readable architecture owner map, six-layer dependency rules and
  diagrams, source-guided feature decisions, and a permanent architecture drift
  ratchet that fails when new Presentation→Infrastructure shortcuts appear.
- A pure support-environment port and UIKit adapter so feedback/diagnostic
  actions no longer couple the Application layer to UIKit or platform globals.

### Fixed
- The workspace support use case no longer imports UIKit, presents alerts
  directly, or reads device/user-default/pairing globals; those facts are
  injected through a Domain port and a Platform adapter, with XCTest coverage.
```
