# ADR: Architecture-excellence ownership map and drift ratchet

**Status:** Proposed in the active working tree. No commit, push, PR, merge, release or deployment was executed for this architecture pass.

## Context

The shared architecture brief asks for six logical layers, one owner per core system, explicit composition, a single signing/application/task lifecycle, capability-driven installation and permanent enforcement. It also warns against a cosmetic folder rewrite or a second set of core engines.

The current repository already had:

- a pure `App/iOS/VexSign/Domain/` layer and `AppContainer.live()` composition root;
- `SigningService`, `SigningHandler`, `SigningPlan`, `NestedBundleAudit`, `ProfileCompatibility` and `SignatureVerifier`;
- `UnifiedTaskCenter`, `TaskHistoryJournal`, `DownloadManager`, `Storage`, `InstallQueue`, `AppInstaller` and `DeviceCapabilityResolver`;
- architecture boundary tests, but no complete machine-readable owner map and no ratchet for legacy Presentation coupling.

Concrete source inspection found real, historical violations:

- `App/iOS/VexSign/Application/WorkspaceSupportUseCase.swift` imported UIKit, presented `UIAlertController`, read `UIDevice`, `UserDefaults`, `SigningModeManager.shared`, `PairingBridge`, `MobileGestalt` and `FileManager.default`;
- `App/iOS/VexSign/Application/AnisetteProviderUseCase.swift` still imports `NativeSigning`;
- many `App/iOS/VexSign/Views/` files import CoreData, use `@FetchRequest`/`Storage.shared`, call `DirectInstaller`/`InstallQueue` directly, or call `URLSession.shared`;
- two `App/iOS/VexSign/Presentation/` coordinators still touch `Storage.shared` or `FileManager.default`.

Those legacy couplings are real but too broad to remove safely in one Linux-only pass without Xcode/simulator proof. Deleting or mass-moving them would violate the brief's incremental-migration rule.

## Decision

1. **Freeze the architecture, not the folder tree.** Add [`../architecture/dependency-rules.md`](../../Architecture/dependency-rules.md) and [`../architecture/component-map.json`](../../Architecture/component-map.json). The map uses the six requested layers and records responsibilities, dependencies, public interfaces, state ownership, concurrency, persistence, tests, failure modes and refactoring requirements for 24 major components plus the 14 named core systems.
2. **Fix one Application-layer violation end to end.** Introduce pure `WorkspaceSupportSnapshot` and `WorkspaceSupportEnvironmentProviding` in `App/iOS/VexSign/Domain/`, move UIKit/device/defaults/folder facts into `UIKitWorkspaceSupportEnvironmentAdapter`, inject that port through `AppContainer`, and make `WorkspaceSupportUseCase` depend only on Foundation, NimbleExtensions and explicit contracts.
3. **Ratchet the remaining legacy coupling.** Add [`../../Tools/Architecture/test_architecture_excellence.py`](../../../Tools/Architecture/test_architecture_excellence.py) and [`../../Tools/Architecture/architecture-drift-baseline.json`](../../../Tools/Architecture/architecture-drift-baseline.json). The guard fails when a new file joins a violation class; `--report` shows new/removed entries; `--write-baseline` is manual and reviewable.
4. **Wire the guard into both gates.** `make verify` and `.github/workflows/ci.yml` run the new unittest. The existing `Tools/Architecture/test_architecture_boundaries.py` additionally forbids UIKit/CoreData/IDeviceSwift/AltSourceKit imports in Application and asserts the WorkspaceSupport port boundary.
5. **Keep source-specific decisions licensed and honest.** [`../research/source-guided-architecture-decisions.md`](../../Research/source-guided-architecture-decisions.md) records pinned external sources for signing, download/sign progress, bootstrap, guest runtime, deep-link/log privacy and OCSP policy. No GPL/AGPL/custom-licence source was copied.

## Consequences

- New Presentation→Infrastructure shortcuts are now rejected by a deterministic portable gate.
- Existing legacy views remain functional and are explicitly documented as migration work, not hidden behind a false "clean architecture" claim.
- Domain stays Foundation-only; Application loses its UIKit import; the composition root gains one explicit dependency.
- Future refactors that remove a legacy violation must intentionally update the baseline and add a test, making architecture drift visible in review.
- The drift guard is a source-level ratchet. It cannot type-check Swift, prove actor isolation, build an IPA, run simulator XCTest or validate a physical iPhone.

## Migration phases completed here

| Phase | Result |
| --- | --- |
| 0 Source audit | Complete major-component map, 14 core-system owners, actual violations and source-specific feature evidence. |
| 1 Dependency boundaries | One Application UIKit violation removed; Domain/Application platform-import gate strengthened; legacy ratchet added. |
| 2 Contracts and composition | New pure support port, UIKit adapter and explicit `AppContainer` injection. |
| 3 Tests | XCTest for injected support snapshot/URL behavior; Python self-tests for synthetic drift and owner-map completeness; wired into local and CI gates. |
| 4 Documentation | Architecture doc, dependency rules/diagrams, ADR, source decisions, audit and changelog. |
| 5–10 | Not completed in one pass; signing/identity/lifecycle/device/task/security/performance work is mapped to existing owners and remaining gates, not blindly rewritten. |

## Gate discipline

Do not mark 10/10, `Build-verified` or `Device-verified` complete from this ADR. A green macOS CI run for the exact reviewed commit and a real-iPhone acceptance pass are still required. No commit/push was executed, so no fresh GitHub Actions run exists for this working tree.
