# Architecture

VexSign has one main source tree, `VexSign/`, with a feature-oriented iOS app and
separate package, service, test, resource, documentation, tool and configuration
owners. This implements the repository layout in the
[requested architecture](https://chatgpt.com/s/t_6af8130278148191bc92dd1663a4f27b).
The [migration record](feature-layout-migration.md) explains the inventory,
compatibility safeguards, implemented boundaries and remaining acceptance work.

**Layout alone is not decoupling.** Domain and Application are Foundation-only;
the consumed feature workflows now use injected ports and immutable/opaque values.
The guarded whole-Presentation storage, Core Data, I/O and engine-owner matches
are zero; historical review provenance is retained rather than erased. Other UI
and platform implementation details are not an exhaustive architecture proof.
Nothing here is a claim of Xcode-build or physical-device acceptance.

## Repository layout

```text
repository/
├── .github/                         GitHub-required automation
├── VexSign.xcodeproj/               existing targets and package requirements
├── VexSign.xcworkspace/             existing workspace and resolved pins
├── Makefile, README.md, legal/community files
├── app-repo.json, repos.json, icon.png, license_plist.yml, render.yaml
└── VexSign/
    ├── App/
    │   ├── iOS/VexSign/
    │   │   ├── App/
    │   │   ├── Presentation/
    │   │   ├── Application/
    │   │   ├── Domain/
    │   │   ├── Infrastructure/
    │   │   ├── Platform/
    │   │   ├── Security/
    │   │   └── Resources/
    │   ├── Extensions/WidgetExtension/
    │   ├── TV/VexSignTV/
    │   ├── Vision/VexSignVision/
    │   ├── Watch/{VexSignWatch,VexSignWatchWidgets}/
    │   └── SharedPlatformInfo/
    ├── Packages/                    genuine existing compilation boundaries
    ├── Services/{WebManager,Cloud}/ optional services; anisette mock under Cloud
    ├── Tests/                       unit, workflow, security, performance
    ├── Resources/                   repository branding and published templates
    ├── Documentation/
    ├── Tools/{Scripts,Validation,Development,Release}/
    ├── Configuration/{Build,Signing,Entitlements}/
    └── Integrations/EmbeddedContainer/ existing experimental host build
```

The five root compatibility files remain byte-identical to their canonical
owners under `VexSign/`; published feed URLs and commit-pinned URLs are not
rewritten. Root project/workspace locations, target identities, product names,
package identities, licenses and companion apps are preserved.

## Layers

Paths below are relative to `VexSign/App/iOS/VexSign/`.

| Owner | Actual contents and responsibility |
| --- | --- |
| **App** | `VexSignApp.swift` declares scenes and injects `AppContainer.live()`. `Bootstrap/AppPreferencesBootstrap` registers/migrates nonsecret preferences. `Lifecycle/AppDelegate` and `AppLifecycleCoordinator` own startup/foreground/background hooks. `Composition/` wires concrete adapters; `Navigation/` owns workspace routing. |
| **Presentation** | `DesignSystem/`, `Shared/{Components,Models,ViewModels,Navigation}/`, and `Features/<Feature>/{Views,ViewModels,Models}` where real code exists. Includes Home, Library, Import, Signing, Certificates, Accounts, Devices, Repositories, Downloads, Updates, Tasks, Backups, Diagnostics, Settings, Customization, Onboarding and About, plus the existing Files and Installation features. No empty role folders are manufactured. |
| **Application** | Focused `Accounts`, `Backups`, `Builder`, `Downloads`, `Files`, `Installation`, `Library`, `Repositories`, `Signing`, `Tasks` and `Shared` use cases. They depend on Domain ports and Foundation, not UIKit, Core Data, NativeSigning, concrete singletons, filesystem APIs or network sessions. |
| **Domain** | `Entities`, `ValueObjects`, `Enums`, `Protocols`, `Services`, `Results`: pure models, deterministic validation/parsing, `SigningEngine`, generic `SigningWork`, transfer/configuration/installation/workspace ports. No SDK, database, UI, bundle-loading or HTTP implementation. |
| **Infrastructure** | Existing implementations grouped by Signing (Engines/Planning/Verification/Transformation/Execution), Archives, Identity, Accounts, Devices, Repositories, Downloads, Updates, Persistence, Backups, Networking, Diagnostics and Tasks. Adapters reuse the authoritative implementations. |
| **Platform** | Apple device/files/background/notification/localization adapters, iOS document/share/URL/haptic/intent hooks, and Compatibility for the experimental host. Security-scoped file coordination belongs here, not in Application. |
| **Security** | Secrets, Certificates, Archives, Network, Storage, Logging and Validation policies. Keychain/protected-file credentials, validated/bounded transfers, archive safety and diagnostic privacy remain explicit responsibilities. |
| **Resources** | App asset catalogs, localization, sound, signing-tool resources, bundled anisette reference data/license and web assets. Build plists, entitlements, the bridge header and FilePickerFix source are Configuration inputs, not loose app resources. |

Only existing package boundaries are retained: NimbleKit, AltSourceKit,
NativeSigning, SideSign, and the vendored engine/device packages. The illustrative
`VexSignCore`/`VexSignDevices` packages from the proposal are not empty new modules.
Services, External integrations and Tooling are separate owners, not additional
layers that Domain can depend on.

See [dependency rules and diagrams](dependency-rules.md) and the machine-readable
[component map](component-map.json) for dependencies, state ownership, concurrency,
persistence, failure modes and source evidence.

## Implemented inward boundaries

```text
feature view / view model
  → Application use case
    → Domain protocol + value types
      ← concrete Infrastructure / Platform adapter

App/Composition/AppContainer.live() chooses the adapters.
```

- `AnisetteProviderUseCase` accepts `AnisetteConfigurationProviding`. The NativeSigning
  descriptor conversion, provider probes, catalogue bundle I/O and persistence
  are in `NativeAnisetteConfigurationAdapter`. Saving checks cancellation after
  a probe and before changing the persisted provider.
- `DirectPackageInstallUseCase` accepts `DirectInstallationProviding` with an
  opaque `ImportedPackageHandle`. The adapter alone resolves legacy library
  objects and calls the existing importer/installer. Unknown routing fails
  closed; confirmation retains a handle only until accepted/replaced.
- Firmware existence checks and destination directories are injected;
  `SecureTransferProviding` owns network operations.
- `DeepLinkRouterUseCase` coordinates commands. `IncomingFilesProviding` owns
  temporary directories, security-scoped access and coordinated copies;
  `RoutingDiagnosticsProviding` owns concrete logging/error presentation text.
- `WorkspaceSupportUseCase` and reset/download/diagnostic/privacy view models
  use the existing Domain boundaries rather than introducing another manager.
- `RunSigningUseCase` consumes the generic `SigningWork` port and owns the
  progress/terminal-event contract. `SigningService` retains run admission,
  cancellation handles and the existing `AppOperationRegistry` leases.
- `ZsignHandler` calls the Domain `SigningEngine` contract. `ZsignAdapter` is its
  production implementation; the pinned wrapper, flag polarity and error
  translation remain in Infrastructure. Signing request/outcome values are
  Domain types, while the legacy UIKit/Core Data workflow request stays outside
  Domain.
- The pure repository validator no longer performs HTTP probes;
  `RepositoryDownloadProbe` owns those network checks in Infrastructure.

### Consumed feature workspaces

- `WorkspaceCatalogProviding`/`LibraryRepository` project store-bound values;
  `LibraryUseCase` and `CoreDataWorkspaceRepository` resolve mutation identities
  and retain last-good snapshots. Onboarding uses the same import engine behind
  this boundary. `SourceCatalogStore` is still the refresh/cache/coalescing owner.
- Signing, preferences, certificate, installation queue/session and batch models
  consume Application use cases over existing managers. Invocation/generation
  checks reject stale callbacks. Signing completion is bound to reviewed inputs
  and the registered output, with at-most-once completion side effects.
- Task/history/recovery, account, backup, cloud configuration, archive/files,
  clone, tweak/entitlement, repository builder and companion views use consumed
  ports. Their adapters keep the authoritative task/journal/native/crypto/file
  engines and secret-bearing objects outside the presentation snapshots.
- Observation termination cancels subscriptions, cancellation waits for workers
  before scope/lease release, and temporary outputs stay owned while a share
  extension or embedded staging reader uses them.
- Certificate delete/undo uses isolated saves and the existing durable staging
  journal. Failed saves do not erase a surviving row's files/credential or save
  unrelated view edits. Partial holding moves refuse deletion; interrupted undo
  and failed re-stage retain journal ownership of the restored original. Cleanup
  checks persisted/pending replacement UUID owners and defers on unreadable stores.
  The six-second operation-owned offer clears captures independently of UI lifetime;
  late status results remain row/generation-bound.

The [migration record](feature-layout-migration.md) lists the behavioral changes,
portable evidence and still-required native/device cases. New source regressions
run in `test_feature_workspace_boundaries.py`; fake-provider/Core Data XCTest
sources have been added but cannot execute without Xcode.

## The task pipeline

The existing `UnifiedTaskCenter` remains the single source of truth for long
running work, mirrored by downloads, signing, installation, widgets and Live
Activities. `TaskHistoryJournal` persists bounded history and salvages individual
readable records. `Storage` remains the canonical imported/signed-app registry;
no second task center, signing pipeline, device coordinator or registry is added.

```text
import → archive validation → inspect → identity / SigningPlan
       → execute through SigningEngine → verify → register artifact
       → optional installation submission → separate device confirmation
```

`SigningPipeline` still delegates to `SigningHandler` in the same order and uses
the same execution gate, identity checks, cancellation checkpoints and cleanup.
The `SigningStage` raw values are unchanged because task history persists them.
Only a verifier acceptance emits `.signatureVerified`; work implementations
cannot emit an extra terminal event through `RunSigningUseCase`.

A task's `subjectID` identifies its source copy; `context.artifactID` identifies
its output copy. `SigningRecordIdentity` keeps those distinct.
`PostSignArtifacts`/`CleanupManager.finishSign` retain the registered output and
apply existing source-deletion policy only after successful registration.

## What the install card may claim

A signed artifact, exported IPA, guest-import request, ready HTTPS server or
queued installation is **not an installed app**. Direct-install results are
`submittedForGuestImport` and `submittedForInstallation`, not installed verdicts.

The UI combines transport state (`InstallerStatusViewModel`) with lifecycle
state (`InstallConfirmation.Phase`) through `InstallStatusPresentation`.
`InstallConfirmation` and the existing native acknowledgement/evidence rules
remain the installation authority. Submission does not bypass verification,
pairing, trust, entitlement or device prerequisites.

## State and security

- Core Data stores app/certificate/repository metadata in the existing
  `Infrastructure/Persistence/Database/VexSign.xcdatamodeld`; entity names and
  schema contents are not renamed by the source move.
- Sandbox files hold archives, signed bundles, exports and temporary workspaces.
  `AppOperationRegistry`, archive limits, URL/redirect policies and cleanup
  admission protect active work and untrusted input.
- Secret material remains in Keychain or protected files, not in new
  configuration files or ordinary metadata. Backup encryption and existing
  diagnostic redaction remain in force.
- `Services/Cloud` and `Services/WebManager` are optional. Local certificate-based
  signing does not require either service, and this migration does not enable
  cloud transmission of passwords/private keys.
- `Configuration/Build/{Debug,Release}.xcconfig` include shared project settings
  extracted without changing their values. Existing target-specific signing,
  version, SDK and product settings remain in the Xcode project.

See [security policy](../../../SECURITY.md), [threat model](../Security/THREAT_MODEL.md)
and [native account handoff](../Security/NATIVE_SIGNING_HANDOFF.md).

## README feature coverage

This is implementation/source presence, not native or device acceptance.
App-relative paths below share the prefix `VexSign/App/iOS/VexSign/`.

| README area | Existing implementation owners |
| --- | --- |
| On-device signing, batch, reusable profiles, entitlements | `Infrastructure/Signing/`, `Application/Signing/`, `Presentation/Features/Signing/`, `VexSign/Packages/Vendor/Zsign/` |
| IPA inspection, import, cloning and tweaks | `Infrastructure/Archives/`, `Infrastructure/Signing/Transformation/`, `Presentation/Features/{Import,Library,Signing}/` |
| Sources, discovery, GitHub imports and offline catalogues | `Infrastructure/Repositories/`, `Presentation/Features/Repositories/`, `VexSign/Packages/AltSourceKit/` |
| Downloads, integrity and firmware browsing | `Infrastructure/Downloads/`, `Application/Downloads/`, `Security/Validation/FileIntegrity.swift`, `Presentation/Features/Downloads/` |
| Certificates, OCSP, profile/device coverage | `Infrastructure/Identity/`, `Infrastructure/Signing/Verification/`, `Security/Certificates/`, `Presentation/Features/Certificates/` |
| Local HTTPS installation, OTA export, pairing and queue | `Infrastructure/Devices/`, `Application/Installation/`, `Presentation/Features/Installation/` |
| Repository builder, WebDAV and device-local web tools | `Presentation/Features/Repositories/`, `Infrastructure/Networking/WebManager/`, `VexSign/Services/WebManager/` |
| Update rules and self-update | `Infrastructure/Updates/`, `Presentation/Features/Updates/` |
| App lock, credentials, privacy and URL/archive policies | `Security/`, `Platform/`, `Presentation/Features/Settings/` |
| Automation, Shortcuts, task history and Live Activities | `Infrastructure/Tasks/`, `Platform/iOS/AppIntents/`, `Presentation/Features/Tasks/`, `VexSign/App/Extensions/` |
| Encrypted backups, cleanup, analytics and diagnostic export | `Infrastructure/{Backups,Persistence,Diagnostics}/`, `Presentation/Features/{Backups,Diagnostics}/` |
| Appearance, tint, icons, accessibility and navigation | `Presentation/DesignSystem/`, `Presentation/Shared/Navigation/`, `Presentation/Features/Customization/`, `App/Navigation/` |
| TV, Vision and Watch companions | `VexSign/App/{TV,Vision,Watch}/`, `Infrastructure/Devices/Transport/` |
| Experimental account provisioning, cloud and guest host | `Infrastructure/Accounts/`, `VexSign/Packages/NativeSigning/`, `Infrastructure/Signing/Engines/Cloud/`, `VexSign/Services/Cloud/`, `VexSign/Integrations/EmbeddedContainer/` |

Native Apple-account signing remains `.notIntegrated` until its strict native
CMS, production-wiring and physical-device evidence gates pass. The anisette
catalogue is reference data, not an endorsement or an automatic fallback service.
Companion targets are not standalone signers. There is no universal computer-free
initial installation or guaranteed unattended iOS renewal.

## Architecture drift ratchet

The old view and refactored-presentation scans now cover the **whole Presentation
subtree**, including moved legacy utility/observable files. Expanded matches
were checked against their original Git bytes, not accepted as new coupling.
The [ratchet baseline](../../Tools/Validation/architecture-rules/architecture-drift-baseline.json)
now has zero matches across all twelve guarded categories. Its original
`migrationReview` and previous rule/file lists remain in history. Positive and
negative synthetic fixtures keep the expanded rules active; actual zero debt
is allowed. New matches fail; baseline changes require an intentional review.

```sh
make verify
python3 VexSign/Tools/Validation/architecture-rules/test_architecture_excellence.py --report
make test                 # macOS/Xcode simulator tests
```

`test_repository_layout.py` checks the main tree, original-file inventory,
Foundation-only Domain/Application, engine/work boundaries, compatibility/feed
bytes, resource bytes, Xcode groups/exceptions/configuration and service paths.
`test_architecture_boundaries.py` retains the original strict presentation-file
coverage as well as the new ViewModels. `test_feature_workspace_boundaries.py`
pins consumed wiring, cancellation, consent and mutation ordering.
`audit_feature_preservation.py` optionally compares actual original Git blobs,
not just asserted map hashes, with target/settings/legal/protected-input checks.
Its 22 synthetic positive/negative fixtures run in `make verify` and CI without
requiring the original revision. None of these checks proves Swift type checking,
Xcode resource-bundle placement or a real installation.

The [initial architecture audit](../Decisions/Research/architecture-excellence-audit.md),
[source-guided decisions](../Decisions/Research/source-guided-architecture-decisions.md)
and earlier [drift ADR](../Decisions/History/architecture-excellence-drift-guard.md)
remain historical evidence. The current decision is
[ADR-0001](../Decisions/ADR-0001-feature-layered-source-tree.md).
See [device testing](../DeviceTesting/DEVICE_TESTING.md) for acceptance that a
Linux structural/test pass cannot supply.
