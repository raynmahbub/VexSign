# VexResult

A `Result` type alias for VexSign operations with ergonomic helpers.

## Overview

`VexResult` is a type alias for `Result<T, VexSignError>` with additional convenience methods for common patterns.

## Type Alias

```swift
typealias VexResult<T> = Result<T, VexSignError>
```

## Methods

### Transformation

- ``map(_:)`` - Transform the success value
- ``flatMap(_:)`` - Transform the success value to another `VexResult`

### Access

- ``get()`` - Returns the success value or throws the error
- ``error`` - Returns the error if failed, `nil` if succeeded
- ``value`` - Returns the value if succeeded, `nil` if failed

### Side Effects

- ``onSuccess(_:)`` - Execute closure on success
- ``onFailure(_:)`` - Execute closure on failure
- ``logIfFailed(category:)`` - Log error if failed

### Async Creation

```swift
// From async throwing operation
let result = await VexResult.catching(
    defaultCode: .downloadFailed,
    context: ["url": downloadURL.absoluteString]
) {
    try await downloadManager.startDownload(from: url)
}

// From sync throwing operation
let result = VexResult.catching(
    defaultCode: .importFailed,
    context: ["file": filePath]
) {
    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
}
```

### Bridging Completion Handlers

```swift
// Convert legacy completion handler to async VexResult
let result = await VexResult.fromCompletion { completion in
    legacyAPI.performOperation { result in
        switch result {
        case .success(let value):
            completion(.success(value))
        case .failure(let error):
            completion(.failure(VexSignError(from: error)))
        }
    }
}
```

## Usage Patterns

### Error Handling in View Models

```swift
@MainActor
func performSigning() async {
    let result = await signingService.sign(app, options: options)
    
    switch result {
    case .success(let signedApp):
        self.signedApp = signedApp
        self.showSuccess = true
    case .failure(let error):
        self.errorMessage = error.message
        error.log(category: "signing")
    }
}
```

### Chaining Operations

```swift
func importAndSign(ipaURL: URL) async -> VexResult<SignedApp> {
    await VexResult.catching { try await importIPA(ipaURL) }
        .flatMap { importedApp in
            await VexResult.catching { try await signApp(importedApp) }
        }
}
```

### Guard Pattern

```swift
func processDownload(_ download: Download) async {
    let result = await VexResult.catching { try await verifyDownload(download) }
    
    guard case .success = result else {
        // Error already logged via logIfFailed
        result.logIfFailed(category: "download")
        return
    }
    
    // Use result.value or result.get()
    if let verifiedDownload = result.value {
        await processVerified(verifiedDownload)
    }
}
```