# Repository System

AltStore-compatible repository discovery, sync, and management.

## Overview

VexSign supports multiple repository formats with a unified discovery and update system.

## Repository Formats

### AltStore / AltSourceKit (Primary)

Native AltStore JSON format with ESign encryption support.

```json
{
  "name": "My Repo",
  "identifier": "com.example.repo",
  "iconURL": "https://example.com/icon.png",
  "apps": [
    {
      "name": "My App",
      "bundleIdentifier": "com.example.app",
      "version": "1.0.0",
      "versionDate": "2024-01-15T10:00:00Z",
      "downloadURL": "https://example.com/app.ipa",
      "iconURL": "https://example.com/app-icon.png",
      "size": 12345678,
      "tintColor": "#FF0000"
    }
  ]
}
```

### ESign Encrypted Sources

Legacy ESign format with AES-256 encryption. Parsed via `AltSourceKit`.

### GitHub Release Sources

Public GitHub repos with exactly one `.ipa` asset in latest release.

```swift
let source = GitHubReleaseSource(repoURL: "https://github.com/owner/repo")
// Bundle ID matching not guaranteed (no bundle ID in release metadata)
```

## Sync Engine (`RepositorySyncEngine`)

### Conditional Refresh

Uses ETag / Last-Modified headers:

```swift
let engine = RepositorySyncEngine()
let result = await engine.refresh(source: source)
// result: .unchanged | .updated(apps) | .failed(error)
```

### Offline Catalog

Last successful snapshot kept on disk:
- `Documents/Sources/<sourceID>/source.json`
- `Documents/Sources/<sourceID>/apps.json`
- Clearly marked as saved copy when refresh fails

### Health Dashboard (`SourceHealthDashboardView`)

Shows per-source:
- Last successful refresh
- Failure reasons + retry count
- Rate-limit status
- Priority
- Duplicate app resolution

## Source Management (`SourcesViewModel`)

```swift
@MainActor
class SourcesViewModel: ObservableObject {
    @Published var sources: [AltSource] = []
    @Published var health: [SourceID: SourceHealth] = [:]
    
    func refreshAll() async { ... }
    func refresh(_ source: AltSource) async { ... }
    func addSource(_ url: URL) async throws { ... }
    func deleteSource(_ source: AltSource) { ... }
}
```

## Discovery (`AppStoreView`)

Multi-term search with suggestions:
- Favorites (user-pinned apps)
- Categories (from repository metadata)
- Collections (curated lists)
- Trending (local ranking by install/update activity)
- Recently updated

### Bundle ID Grouping

Apps with same bundle ID from multiple sources grouped:
- User selects preferred source
- Updates from preferred source prioritized
- Other sources shown as alternatives

## Premium / Gated Sources

### API Key Authentication

```swift
// User redeems VEX-XXXX-XXXX-XXXX key
try await PremiumManager.shared.redeem(key: apiKey)

// Key attached to all requests to premium hosts
VexSignAPI.applyAuthHeaders(to: &request)
// Adds: vexSignUUID, X-API-Key (EsignSourceKey.customApiKey)
```

### Catalog Filtering

Premium sources support query parameters:
```
?category=games&sort=updated&minVersion=1.0
```

Configured in `PremiumFilterPreferences`.

## Repository Builder (`RepositoryBuilder`)

In-app tool for creating/editing repositories:

1. **Create/Import** - New project or import JSON/URL
2. **Edit Apps** - Add/remove/modify app entries
3. **Validate** - `RepositoryValidator` checks:
   - Required fields (name, identifier, bundle ID format)
   - URL validity (HTTPS, no credentials)
   - Duplicate bundle IDs
   - Date format (ISO 8601 or YYYY-MM-DD)
   - Tint color format (#RRGGBB)
4. **Probe Links** - HEAD requests to verify downloads
5. **Export** - `source.json` + `apps.json`
6. **OTA Export** - Generate `manifest.plist`, installation links, QR codes

### Validation (`RepositoryValidator`)

```swift
let issues = RepositoryValidator.validate(document)
for issue in issues {
    // issue.severity: .warning | .error
    // issue.fix: .trimURLs | .removeDuplicateScreenshots
}
```

## OTA Manifest Generation

For each app, generates:
- `manifest.plist` - iTunes Services manifest
- Installation URL (`itms-services://`)
- QR code for easy mobile install
- Optional: screenshots, changelog, app images

```swift
let manifest = ServerInstaller(app: signedApp).installManifest
let plistData = ServerInstaller(app: signedApp).installManifestData
```

## Security

### HTTPS-Only Transport

```swift
// RepositoryValidator.webURL rejects non-HTTPS
static func webURL(_ value: String) -> URL? {
    guard !value.contains(where: { $0.isWhitespace }),
          let url = URL(string: value), let host = url.host, !host.isEmpty,
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.user == nil, url.password == nil else { return nil }
    return url
}
```

### Signed Metadata Verification

Supported publisher signatures verified via `SourceProvenance`:
- Ed25519 signatures over source JSON
- Verified publisher ≠ safe IPA (user beware)

### Anti-Revoke DNS

Optional DNS profile to block Apple's certificate verification hosts:
- Not a guarantee against revocation
- User must review blocked hosts

## Testing

Key test files:
- `SourceFeedLoaderTests.swift` - Feed parsing
- `AltSourceKit` tests - Format parsing
- `RepositorySyncEngineTests.swift` - Sync logic
- `RepositoryValidatorTests.swift` - Validation
- `GitHubReleaseSourceTests.swift` - GitHub source
- `SourceProvenanceTests.swift` - Signature verification