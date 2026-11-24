# Architecture

VexSign is a feature-oriented, modular iOS application.

## App source layout

The main application source lives under `VexSign/`:

- `App/` - app lifecycle, composition, and navigation.
- `Features/` - feature screens, presentation state, and feature UI.
- `Shared/` - types and utilities genuinely shared across features.
- `Services/` - application workflows and coordination.
- `Storage/` - database, Keychain, and file persistence.
- `Networking/` - HTTP clients, API communication, and downloads.
- `Security/` - certificate validation, cryptography, and security policies.
- `System/` - device communication, background execution, and OS integrations.
- `DesignSystem/` - shared visual components and styling.
- `Resources/` - assets, localizations, fonts, and configuration resources.

## Repository layout

- `Packages/` - independently maintained Swift packages and vendored dependencies.
- `Services/` - separately deployable backend services (`Cloud`, `WebManager`, and integrations).
- `Tests/` - automated verification.
- `Tools/` - scripts and validation utilities.
- `Configuration/` - build settings, entitlements, signing, and related project configuration.
- `VexSign.xcodeproj` / `VexSign.xcworkspace` - Xcode project and workspace.

## Dependency rules

- Features communicate with application services through explicit interfaces.
- Shared models must not become feature-specific dumping grounds.
- Services coordinate operations; they do not contain SwiftUI screens.
- Storage owns persistence implementations.
- Security owns security-sensitive validation and cryptographic responsibilities.
- System owns operating-system integrations.
- `AppContainer` composes dependencies.
- No circular dependencies between features.
- Backend services must not be coupled to the iOS application target.
