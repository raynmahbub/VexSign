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

## State and storage

- **Core Data** stores certificate pairs, imported/signed apps and repository
  sources (`Backend/Storage/VexSign.xcdatamodeld`).
- **Files** under the app sandbox hold imported archives, signed outputs,
  exports and logs. `StorageManager` owns the layout and cleanup rules.
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
