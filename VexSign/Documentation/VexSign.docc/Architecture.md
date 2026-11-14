# Architecture Overview

Understanding VexSign's layered architecture.

## Layers

### App Shell
The entry point and scene lifecycle management.

Key files:
- `VexSignApp.swift` - App entry point, scene setup, onboarding, app lock
- `Presentation/Features/` - Tab bar, navigation, tab selection

### Design System
Reusable UI components and styling.

Key files:
- `Presentation/DesignSystem/Colors/Theme.swift` - Color, typography, spacing tokens
- `Presentation/DesignSystem/Modifiers/WorkspaceStyle.swift` - Surface, card, material styles
- `Presentation/` - Reusable controls (buttons, cards, sheets)

### Features
Screen-level composition organized by domain.

| Feature | Location | Responsibility |
|---------|----------|----------------|
| Library | `Presentation/Features/Library/Views` | App list, signing, IPA tools |
| Sources | `Presentation/Features/Repositories/Views` | Repository browser, discovery |
| Signing | `Presentation/Features/Signing/Views` | Signing options, profiles, presets |
| Settings | `Presentation/Features` | Certificates, storage, automation |
| Downloads | `Presentation/Features` | Download management, progress |
| Files | `Presentation/Features/Files/Views` | File browsing, QuickLook |
| Tweaks | `Presentation/Features/Signing/Views` | Tweak injection, management |

### Core Services
Business logic and state management.

| Service | Location | Responsibility |
|---------|----------|----------------|
| DownloadManager | `Infrastructure/Downloads/DownloadManager.swift` | Background downloads, progress, Live Activities |
| UnifiedTaskCenter | `Infrastructure/Tasks/UnifiedTaskCenter.swift` | Unified task pipeline (download→sign→install) |
| InstallQueue | `Infrastructure/Devices/Installation/InstallQueue.swift` | Sequential OTA installs, failure handling |
| SigningService | `Infrastructure/Signing/Execution/SigningService.swift` | Signing orchestration, Zsign integration |
| Storage | `Infrastructure/Persistence/Database/Storage.swift` | Core Data stack, write serialization |
| CleanupManager | `Infrastructure/Persistence/Cache/CleanupManager.swift` | Storage cleanup, orphan removal |

### Models & Storage
Data persistence layer.

- `Infrastructure/Persistence/Database/VexSign.xcdatamodeld` - Core Data model
- `Infrastructure/Persistence/Database/Storage+*.swift` - Entity-specific queries
- `Infrastructure/` - Archive handling, import/export

### Utilities
Low-level functionality.

| Utility | Location |
|---------|----------|
| Mach-O parsing | `Infrastructure/Archives/IPA/MachO/` |
| IPA inspection | `Infrastructure/Archives/IPA/` |
| Certificate handling | `Infrastructure/Identity/Certificates/`, `Security/` |
| OCSP verification | `Infrastructure/Identity/OCSP/` |
| Logging | `Infrastructure/Diagnostics/`, `Infrastructure/Diagnostics/FileLogger.swift` |

### Local Packages
Separate Swift packages for reusable code.

| Package | Purpose |
|---------|---------|
| NimbleKit | SwiftUI helpers, extensions, logging |
| AltSourceKit | AltStore-compatible source parsing |
| NativeSigning | Experimental Apple account provisioning |
| VexSign/Packages/Vendor/Zsign | Pinned signing engine |
| VexSign/Packages/Vendor/IDeviceKitten | Swift device bridge |

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
- `VexSign/Tools/Validation/security-validation/concurrency-discipline.py` prevents new `@unchecked Sendable` escapes
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
5. New third-party code → `VexSign/Packages/Vendor/` with license + pin