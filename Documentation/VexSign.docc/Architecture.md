# Architecture Overview

Understanding VexSign's layered architecture.

## Layers

### App Shell
The entry point and scene lifecycle management.

Key files:
- `VexSignApp.swift` - App entry point, scene setup, onboarding, app lock
- `Views/TabView/` - Tab bar, navigation, tab selection

### Design System
Reusable UI components and styling.

Key files:
- `Extensions/Theme.swift` - Color, typography, spacing tokens
- `Extensions/WorkspaceStyle.swift` - Surface, card, material styles
- `DesignSystem/` - Reusable controls (buttons, cards, sheets)

### Features
Screen-level composition organized by domain.

| Feature | Location | Responsibility |
|---------|----------|----------------|
| Library | `Views/Library` | App list, signing, IPA tools |
| Sources | `Views/Sources` | Repository browser, discovery |
| Signing | `Views/Signing` | Signing options, profiles, presets |
| Settings | `Views/Settings` | Certificates, storage, automation |
| Downloads | `Views/Download` | Download management, progress |
| Files | `Views/FileManager` | File browsing, QuickLook |
| Tweaks | `Views/Tweaks` | Tweak injection, management |

### Core Services
Business logic and state management.

| Service | Location | Responsibility |
|---------|----------|----------------|
| DownloadManager | `Backend/Observable/DownloadManager.swift` | Background downloads, progress, Live Activities |
| UnifiedTaskCenter | `Backend/Observable/UnifiedTaskCenter.swift` | Unified task pipeline (download→sign→install) |
| InstallQueue | `Backend/Observable/InstallQueue.swift` | Sequential OTA installs, failure handling |
| SigningService | `Utilities/Signing/SigningService.swift` | Signing orchestration, Zsign integration |
| Storage | `Backend/Storage/Storage.swift` | Core Data stack, write serialization |
| CleanupManager | `Backend/Observable/CleanupManager.swift` | Storage cleanup, orphan removal |

### Models & Storage
Data persistence layer.

- `Backend/Storage/VexSign.xcdatamodeld` - Core Data model
- `Backend/Storage/Storage+*.swift` - Entity-specific queries
- `Utilities/Handlers/` - Archive handling, import/export

### Utilities
Low-level functionality.

| Utility | Location |
|---------|----------|
| Mach-O parsing | `Utilities/MachO/` |
| IPA inspection | `Utilities/IPAExplorer/` |
| Certificate handling | `Utilities/CertificateReader/`, `Security/` |
| OCSP verification | `Utilities/OCSP/` |
| Logging | `Utilities/Logging/`, `Utilities/FileLogger.swift` |

### Local Packages
Separate Swift packages for reusable code.

| Package | Purpose |
|---------|---------|
| NimbleKit | SwiftUI helpers, extensions, logging |
| AltSourceKit | AltStore-compatible source parsing |
| NativeSigning | Experimental Apple account provisioning |
| Packages/Vendor/Zsign | Pinned signing engine |
| Packages/Vendor/IDeviceKitten | Swift device bridge |

## Task Pipeline

All long-running operations flow through a unified pipeline:

```
queued → downloading → extracting → signing → installing → completed
                    ↘ failed / cancelled (from any stage)
```

`UnifiedTaskCenter` is the single source of truth. `DownloadManager` mirrors downloads into the same model.

## Concurrency Model

- UI and observable state: `@MainActor`
- Downloads, archive inspection, signing: off-main, report back via task center
- `Tools/Development/concurrency-discipline.py` prevents new `@unchecked Sendable` escapes
- `make strict-concurrency` reports remaining Swift 6 warnings

## Security Boundaries

1. **Archive boundary** - ZIPs validated before extraction
2. **Identity boundary** - Certificates/passwords in protected storage
3. **Network boundary** - Repository content treated as untrusted
4. **Device bridge** - idevice operations require valid pairing

## Adding Features

1. New screen → `Views/<Domain>/`
2. New background work → `UnifiedTask` + `Backend/Observable/`
3. New persisted model → Update `.xcdatamodeld` + migration
4. New repository field → `AltSourceKit` + decoding tests
5. New third-party code → `Packages/Vendor/` with license + pin