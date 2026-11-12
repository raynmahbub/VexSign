# VexSignError

Unified error type for VexSign with structured metadata for diagnostics.

## Overview

`VexSignError` provides a consistent error handling approach across the VexSign codebase. It includes:
- Categorized error codes for different subsystems
- Structured context for debugging
- Automatic logging integration
- Bridging from existing error types

## Error Codes

### Storage Errors
- ``VexSignError/Code/storeUnavailable``
- ``VexSignError/Code/storeCorrupt``
- ``VexSignError/Code/storeMigrationFailed``
- ``VexSignError/Code/entityNotFound``

### Certificate/Identity Errors
- ``VexSignError/Code/certificateImportFailed``
- ``VexSignError/Code/certificateNotFound``
- ``VexSignError/Code/certificateExpired``
- ``VexSignError/Code/certificateRevoked``
- ``VexSignError/Code/certificatePasswordInvalid``
- ``VexSignError/Code/keychainOperationFailed``
- ``VexSignError/Code/provisioningProfileInvalid``

### Signing Errors
- ``VexSignError/Code/signingFailed``
- ``VexSignError/Code/signingCancelled``
- ``VexSignError/Code/signingBusy``
- ``VexSignError/Code/preflightFailed``
- ``VexSignError/Code/entitlementsMismatch``
- ``VexSignError/Code/bundleIdMismatch``
- ``VexSignError/Code/teamIdMismatch``

### Installation Errors
- ``VexSignError/Code/installationFailed``
- ``VexSignError/Code/installationCancelled``
- ``VexSignError/Code/installationUnconfirmed``
- ``VexSignError/Code/installationNeverStarted``
- ``VexSignError/Code/httpsTrustRequired``
- ``VexSignError/Code/pairingFileInvalid``
- ``VexSignError/Code/pairingFileMissing``
- ``VexSignError/Code/deviceUnreachable``

### Download/Import Errors
- ``VexSignError/Code/downloadFailed``
- ``VexSignError/Code/downloadCancelled``
- ``VexSignError/Code/downloadPaused``
- ``VexSignError/Code/downloadSizeExceeded``
- ``VexSignError/Code/downloadIntegrityFailed``
- ``VexSignError/Code/importFailed``
- ``VexSignError/Code/archiveInvalid``
- ``VexSignError/Code/archiveExtractionFailed``
- ``VexSignError/Code/archiveSizeExceeded``
- ``VexSignError/Code/archiveUnsafePath``
- ``VexSignError/Code/diskSpaceInsufficient``

### Repository/Source Errors
- ``VexSignError/Code/sourceUnreachable``
- ``VexSignError/Code/sourceInvalidFormat``
- ``VexSignError/Code/sourceAuthFailed``
- ``VexSignError/Code/sourceRateLimited``
- ``VexSignError/Code/appNotFoundInSource``

### Tweak/Injection Errors
- ``VexSignError/Code/tweakNotFound``
- ``VexSignError/Code/tweakInjectionFailed``
- ``VexSignError/Code/tweakDependencyMissing``
- ``VexSignError/Code/elleKitNotFound``

### Backup/Restore Errors
- ``VexSignError/Code/backupCreationFailed``
- ``VexSignError/Code/backupRestoreFailed``
- ``VexSignError/Code/backupCorrupt``
- ``VexSignError/Code/backupPasswordInvalid``

### Network/Connectivity Errors
- ``VexSignError/Code/networkUnavailable``
- ``VexSignError/Code/networkTimeout``
- ``VexSignError/Code/serverError``
- ``VexSignError/Code/invalidResponse``

### Permissions/Privacy Errors
- ``VexSignError/Code/permissionDenied``
- ``VexSignError/Code/privacyServicesDenied``

### Generic Errors
- ``VexSignError/Code/invalidInput``
- ``VexSignError/Code/operationCancelled``
- ``VexSignError/Code/operationTimeout``
- ``VexSignError/Code/unknown``

## Usage

### Creating Errors

```swift
// Using convenience constructors
let error = VexSignError.signing("Certificate expired", code: .certificateExpired)
let error = VexSignError.download("Network timeout", code: .networkTimeout)
let error = VexSignError.source("Invalid repository format", code: .sourceInvalidFormat)

// With context
let error = VexSignError.certificate(
    "Import failed",
    code: .certificatePasswordInvalid,
    context: ["certName": "MyCert", "uuid": certUUID]
)
```

### Bridging from Other Errors

```swift
do {
    try someOperation()
} catch {
    let vexError = VexSignError(from: error, defaultCode: .signingFailed)
    vexError.log(category: "signing")
    throw vexError
}
```

### Using with VexResult

```swift
func signApp(_ app: AppInfo) async -> VexResult<SignedApp> {
    await VexResult.catching(
        defaultCode: .signingFailed,
        context: ["appID": app.uuid]
    ) {
        try await signingService.sign(app)
    }
}
```

## Logging

All `VexSignError` instances include structured logging:

```swift
error.log(category: "signing", level: .error)
```

This logs to OSLog with privacy-aware formatting.