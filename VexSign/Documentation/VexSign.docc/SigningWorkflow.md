# Signing Workflow

Complete guide to the signing process in VexSign.

## Overview

The signing workflow transforms an unsigned or previously signed IPA into a signed, installable app bundle.

## Pipeline

```
Import → Validate → Preflight → Sign → Verify → Install/Export
```

## Steps

### 1. Import (`AppFileHandler`)

```swift
let handler = AppFileHandler(file: ipaURL)
try await handler.copy()
try await handler.extract()
let payloadURL = try await handler.move()
let objectID = try await handler.addToDatabase()
```

- Validates archive safety (no symlinks, traversal, unsupported entries)
- Extracts to temporary work directory
- Moves Payload to `Documents/Unsigned/<UUID>/`
- Creates `Imported` Core Data entity

### 2. Preflight Checks (`PreflightChecks`)

Before signing, validates:
- Certificate expiration
- Provisioning profile validity
- Bundle ID / Team ID matching
- Entitlement compatibility
- Nested bundle coverage
- PPQ (Platform Profile Qualifier) protection needs

```swift
let result = await PreflightChecks.run(
    app: importedApp,
    certificate: selectedCert,
    options: signingOptions
)

if result.hasBlockingIssues && !overridesBlockingPreflightIssues {
    throw VexSignError.signing("Preflight failed", code: .preflightFailed)
}
```

### 3. Signing (`SigningHandler` → `SigningService` → Zsign)

```swift
let request = SigningRequest(
    id: UUID().uuidString,
    app: importedApp,
    options: options,
    icon: customIcon,
    certificate: certificate,
    overridesBlockingPreflightIssues: false
)

let signedApp = try await SigningService.shared.sign(request) { event in
    // Handle stage updates
    switch event {
    case .stage(let stage): updateProgress(stage)
    case .signatureVerified: onVerified()
    case .compatibilityRemoved(let components): onCompatibility(components)
    case .finished(let signed): onComplete(signed)
    case .failed(let error): onError(error)
    case .cancelled: onCancel()
    }
}
```

Zsign stages:
1. **Copy** - Duplicate app to work directory
2. **Modify** - Update Info.plist, entitlements, inject tweaks
3. **Thinning** - Remove non-target architectures
4. **Sign** - Codesign with certificate + profile
5. **Verify** - Validate signature, nested bundles
6. **Register** - Move to `Documents/Signed/<UUID>/`, create `Signed` entity

### 4. Post-Sign Verification (`SignatureVerifier`)

```swift
let report = try SignatureVerifier.verify(signedAppURL)
guard report.isValid else {
    throw VexSignError.signing("Signature verification failed", code: .signingFailed)
}
```

Checks:
- Code signature validity
- Embedded provisioning profile
- Entitlement matching
- Nested bundle signatures
- Bundle ID consistency

### 5. Installation (`InstallQueue` → `AppInstaller`)

Two transport methods:

#### Local HTTPS (OTA)
```swift
let installer = AppInstaller(app: signedApp)
try await installer.prepareForQueuedOTA()
installer.start()
```

- Generates device-specific TLS identity
- Serves `manifest.plist` + IPA via local HTTPS
- Triggers `itms-services://` URL
- Monitors `installd` progress via `InstallConfirmation`

#### idevice (AFC)
```swift
let installer = AppInstaller(app: signedApp)
try await installer.installViaIDevice(pairingFile: pairingData)
```

- Requires valid pairing file
- Uses USB/Network connection
- Direct `installd` via `InstallationProxy`

## Error Handling

Errors map to `VexSignError` codes:

| Stage | Error Codes |
|-------|-------------|
| Import | `.archiveInvalid`, `.archiveExtractionFailed`, `.diskSpaceInsufficient` |
| Preflight | `.preflightFailed`, `.certificateExpired`, `.entitlementsMismatch` |
| Signing | `.signingFailed`, `.signingCancelled`, `.signingBusy` |
| Verification | `.signingFailed` |
| Installation (HTTPS) | `.httpsTrustRequired`, `.installationUnconfirmed` |
| Installation (idevice) | `.pairingFileInvalid`, `.pairingFileMissing`, `.deviceUnreachable` |

## Customization Points

### Signing Options (`Options`)

```swift
struct Options {
    var signingOption: SigningOption        // auto, manual, adhoc
    var injectPath: InjectPath              // tweak injection location
    var ppqProtection: PPQProtection        // PPQ handling
    var dynamicProtection: Bool             // dynamic codesign
    var fileSharing: Bool                   // UIFileSharingEnabled
    var enableJIT: Bool                     // com.apple.security.cs.allow-jit
    var fixFilePicker: Bool                 // document picker fix
    var removeAppExtensions: Bool           // strip unsupported extensions
    var keychainIsolation: Bool             // keychain-access-groups
    // ... more
}
```

### Signing Profiles (`SigningProfileStore`)

Reusable named configurations:
```swift
let profile = SigningProfile(
    name: "Development",
    options: customOptions,
    certificateUUID: certUUID,
    tweakUUIDs: [tweak1, tweak2]
)
```

### One-Shot Tweaks (`OneShotTweakFiles`)

Files added for a single sign run (not saved by path):
```swift
var oneShotTweaks: [OneShotTweakFiles] = []
// Added via signing sheet → only used for this run
```

## Monitoring

- `UnifiedTaskCenter` - Unified progress across download/sign/install
- `SigningLiveActivityManager` - Dynamic Island / Live Activity
- `SigningLog` - Detailed stage logs with timestamps
- `TaskContext` - Execution trace for diagnostics

## Testing

Key test files:
- `SigningServiceTests.swift` - Service orchestration
- `SigningHandlerTests.swift` - Handler logic
- `ZsignEngineTests.swift` - Engine integration
- `ProfileCompatibilityTests.swift` - Preflight logic
- `SignatureVerifierTests.swift` - Verification logic