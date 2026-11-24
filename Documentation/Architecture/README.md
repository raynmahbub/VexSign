# Architecture

VexSign is a feature-oriented, modular iOS application. This document is the long-term
architecture baseline: new code goes into the layer and sub-area listed here, and a change that
needs a new area changes this document in the same commit.

## Layer responsibilities

| Layer | Responsibility |
| --- | --- |
| `App` | Application lifecycle, bootstrap and dependency composition. |
| `Features` | User-facing functionality and feature-specific presentation. |
| `DesignSystem` | Reusable UI components and visual consistency. |
| `Shared` | Common models, protocols, errors and utilities. |
| `Services` | Application workflows and business-operation orchestration. |
| `Storage` | Database, Keychain and filesystem persistence. |
| `Networking` | HTTP communication, API clients and downloads. |
| `Security` | Signing, cryptography, certificate validation and security policies. |
| `System` | Device communication and operating-system integrations. |
| `Platform` | Separate Apple platform targets. |
| `Packages` | Independently maintained reusable components. |
| `Tests` | Automated verification. |
| `Tools` | CI, validation, auditing and release automation. |

`Security`, not `Apple`: Apple frameworks are an implementation detail inside these areas, not a
top-level layer. Security responsibilities are broader than Apple's platform APIs.

## App source layout

The single application source tree is `VexSign/`. There is no second root inside it.

- `App/` — `VexSignApp.swift`, `AppDelegate.swift`, `Bootstrap/`, `Composition/`, `Navigation/`.
- `Features/` — `Dashboard`, `Library`, `Import`, `Signing`, `Certificates`, `Accounts`, `Devices`,
  `Installation`, `Sources`, `Downloads`, `Updates`, `Tasks`, `Backup`, `Settings`.
- `DesignSystem/` — `Components/`, `Styles/`, `Typography/`, `Modifiers/`.
- `Shared/` — `Models/{Entities,ValueObjects,Enums,Policies,Results}`, `Protocols/`, `Errors/`,
  `Extensions/`, `Localization/`.
- `Services/` — `Signing`, `Identity`, `Accounts`, `Import`, `Installation`, `Repository`,
  `Download`, `Backup`, `Tasks`, `Updates`, `Diagnostics`.
- `Storage/` — `Database/`, `Keychain/`, `FileSystem/`, `Repositories/`.
- `Networking/` — `HTTP/`, `API/`, `Downloads/`, `Authentication/`, `Monitoring/`.
- `Security/` — `Certificates/`, `Cryptography/`, `CodeSigning/`, `Entitlements/`,
  `Provisioning/`, `ArchiveValidation/`, `Trust/`, `Credentials/`, `Policies/`.
- `System/` — `DeviceCommunication/`, `BackgroundTasks/`, `Notifications/`, `Compatibility/`,
  `FileCoordination/`, `AppIntents/`, `Haptics/`, plus the OS-surface adapters that predate this
  list and stay here because they are integrations, not features: `DocumentPicker/`, `Sharing/`,
  `ShareSheet/`, `URLHandling/` and the install-queue window presenter in `Installation/`.
- `Resources/` — `Assets.xcassets/`, `Localizations/`, `Templates/`, `Settings.bundle/`.

Two groupings are deliberate exceptions rather than unfinished moves:

- `Shared/Services/` holds Foundation-only domain computation that is shared by more than one
  layer but is neither a model nor an application workflow (`VersionOrder`, `RepositoryValidator`,
  `ProfileEntitlementAuthorization`, `RenewalSchedule`, …). It must stay pure Foundation; the
  architecture tests enforce that for `Shared/Models` and it applies here too.
- `Shared/Models/Workspace/` groups the workspace snapshot/lease types that features observe. They
  are entities and value objects; the folder exists because they are only meaningful together.

## Security is a first-class area

| Area | Owns |
| --- | --- |
| `Certificates` | P12 parsing, certificate-chain validation and identity inspection. |
| `Cryptography` | CMS, hashes, cryptographic operations, file integrity. |
| `CodeSigning` | Bundle signing policies, signature validation and signing integrity. |
| `Entitlements` | Entitlement parsing, comparison and rewriting. |
| `Provisioning` | Provisioning-profile parsing and compatibility. |
| `ArchiveValidation` | IPA inspection, archive safety and extraction policies. |
| `Trust` | Trust decisions, OCSP and revocation. |
| `Credentials` | Secret handling and credential-protection policies. |
| `Policies` | The accepted input/source/URL/manifest rules and their gateway. |

Three areas cooperate rather than duplicate:

- **Security** decides and validates. It answers "may this be trusted / fetched / extracted".
- **System** integrates with the OS: keychain *APIs*, device transport, background tasks, pickers.
- **Storage/Keychain** persists secrets. It stores what Security hands it and never re-decides.

Cross-area calls go through the protocols in `Shared/Protocols/` (for example
`SecureTransferProviding`, `SecurityPolicyValidating`), which is what keeps
`Networking/Downloads/PackageDownloadRedirectDelegate` from importing a policy implementation.

## Repository layout

- `Platform/` — `Extensions/WidgetExtension`, `TV`, `Vision`, `Watch`.
- `Packages/` — `NativeSigning`, `DeviceBridge`, `SideSign`, `AltSourceKit`, `NimbleKit`, `Vendor/`.
- `Services/` — separately deployable backends: `Cloud`, `WebManager`, `Integrations`.
- `Tests/` — `UnitTests`, `IntegrationTests`, `SecurityTests`, `PerformanceTests`, `UITests`,
  `Fixtures`.
- `Configuration/` — `Signing`, `Build`, `Environment`.
- `Tools/` — `Scripts`, `Validation`, `Audit`, `Release`.
- `Documentation/` — this document plus `Development`, `Security`, `Testing`, `Release`.

## Dependency rules

- Features communicate with application services through explicit interfaces.
- Shared models must not become feature-specific dumping grounds.
- Services coordinate operations; they do not contain SwiftUI screens.
- Storage owns persistence implementations; Security owns the policy about what may be persisted.
- System owns operating-system integrations and never decides a security question on its own.
- `AppContainer` composes dependencies; only `App/Composition/AppEnvironment` injects them.
- No circular dependencies between features.
- Backend services must not be coupled to the iOS application target.

## Guards

`Tools/Validation/architecture-rules/` pins this layout (`test_repository_layout.py`), the layer
boundaries (`test_architecture_boundaries.py`), the feature workspace edges
(`test_feature_workspace_boundaries.py`) and the quality ratchets. A structural change that this
document describes but the tests do not yet assert is an incomplete change.
