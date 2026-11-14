# ADR: Clean Architecture Layering & Composition Root

## Status

Accepted — applied incrementally alongside existing `Backend/` services and verified by `Tools/Architecture/test_architecture_boundaries.py` and `App/Tests/VexSignTests/CleanArchitectureLayerTests.swift`.

## Context

VexSign grew feature screens rapidly across `App/iOS/VexSign/Views/` and `App/iOS/VexSign/VexSignApp.swift`. Several SwiftUI views directly instantiated `URLSession.shared.download(from:)`, bypassed URL/SSRF and HTTP status/size policies, queried Core Data (`@FetchRequest` / `Storage.shared`) during struct initialization, or contained static reset/persistence/network helpers mixed with UI layout.

At the same time, core signing and telemetry contracts (`SigningService`, `CleanupManager.finishSign`, `UnifiedTaskCenter`, `InstallStatusPresentation`, and `VexSign.xcodeproj`'s `PBXFileSystemSynchronizedRootGroup`) are covered by strict behavioral tests and workflow trace gates.

## Decisions

1. **Pure Domain & Dependency Inversion (`App/iOS/VexSign/Domain/`)**
   - `DomainContracts.swift` and `SubsystemBoundaries.swift` depend exclusively on `Foundation` and never touch `SwiftUI`, `UIKit`, `CoreData`, `Nuke`, `.shared` singletons, or `FileManager.default`.
   - All cross-boundary interactions (security policy validation, validated transfers, workspace resets, staged downloads, diagnostics, privacy vault, certificate catalog, and platform UI hooks) are modeled via narrow protocols.

2. **Explicit Composition Root (`App/iOS/VexSign/Application/AppContainer.swift`)**
   - `VexSignApp` owns `@StateObject private var appContainer = AppContainer.live()` and propagates it via `.environmentObject(appContainer)` and `.environment(\.appContainer, appContainer)` without adding a new `static shared` singleton.
   - Use cases (`DirectPackageInstallUseCase`, `FirmwareDownloadUseCase`, `WorkspaceResetUseCase`, `DeepLinkRouterUseCase`, `AnisetteProviderUseCase`, `WorkspaceSupportUseCase`) compose domain ports cleanly and are directly testable with mock implementations.

3. **Security & Error Boundaries (`App/iOS/VexSign/Security/`, `App/iOS/VexSign/Shared/`)**
   - `DirectInstallSheet`, `IPSWBrowserView`, and `DownloadsTabView` no longer invoke raw `URLSession.shared` directly. All direct package and firmware downloads pass through `SecurityPolicyGateway` (`PackageDownloadURLPolicy` + HTTPS enforcement for firmware) and `TransferSecuritySession` (ephemeral session, `PackageDownloadRedirectDelegate` hop validation, HTTP `200..<300` status verification, bounded timeouts, and byte caps).
   - `ErrorBoundary` maps technical errors into user-safe `VexSignError` messages while `SubsystemDiagnosticsLog` redacts URLs and paths via `FileLogger` / `LogRedaction`.

4. **Incremental View Extraction (`App/iOS/VexSign/Presentation/`)**
   - Coupled views (`DirectInstallSheet`, `IPSWBrowserView`, `ResetView`, `DiagnosticsCenterView`, `HiddenAppsSettingsView`, `SpecificAppLockSettingsView`, `FavoritesAndAutoUpdatesSettingsView`, `DownloadsTabView`, `HomeView+Actions`, `CertificatesView`, `AnisetteProviderConfigView`, `SettingsView`) delegate logic to Presentation ViewModels/Coordinators and Application Use Cases while preserving existing UX, accessibility identifiers, and localization keys.

5. **Independent VexSign Subsystem Consolidation (`Utilities/Services/`, `Views/Common/Vex*`)**
   - Consolidated legacy `FR*` static facades into single-responsibility VexSign services (`PackageImportService`, `PackageSigningCoordinator`, `CertificateManagementService`, `RepositoryCatalogService`) and renamed shared views to `VexAppIconView`, `VexExpirationPillView`, and `VexIconCellView`.
   - Removed unused legacy tab wrappers (`ExtendedTabbarView`, `VariedTabbarView`) so `VexSignApp` renders `TabbarView` directly.

## Consequences

- `Tools/Architecture/test_architecture_boundaries.py` runs as part of `make verify` and `.github/workflows/ci.yml`, preventing regressions across layers.
- `App/Tests/VexSignTests/CleanArchitectureLayerTests.swift` exercises deep-link parsing/routing, SSRF/HTTPS validation, reset scoping, direct install confirmation flows, firmware downloads, and presentation ViewModels in memory without network or Core Data side effects.
