# TestFlight distribution

## Current implementation status: not configured

There is no TestFlight/App Store Connect upload in `.github/workflows/release.yml`. The existing release workflow compiles the app and emits an explicitly unsigned IPA plus `BUILD.json`, `RELEASE.json`, and checksums. It does not archive/export a distribution-signed build or wait for App Store Connect processing. No upload success or tester availability is claimed.

## Required workflow before enabling

A dedicated workflow should be added only after a maintainer configures a real App Store Connect app record and protected `testflight` environment. It must:

1. Run the existing full CI and simulator tests against the exact release commit.
2. Archive the `VexSign` scheme on a supported macOS/Xcode image.
3. Validate app and nested extension bundle IDs, entitlements, profiles and version/build.
4. Export with App Store distribution signing (not Ad Hoc/Enterprise), and inspect the resulting IPA/archive.
5. Authenticate using an App Store Connect API key supplied as protected GitHub secrets, never committed or logged.
6. Upload through Apple's supported API/tooling.
7. Poll App Store Connect until it confirms processing state; distinguish upload accepted, processing, processed, invalid, and tester-visible states.
8. Publish release notes and a tester/public link only when configured and actually available.

Use separate read-only CI and protected release credentials, restrictive workflow permissions, environment approvals, and no self-hosted device containing production signing assets. Never claim an upload succeeded from an HTTP request initiation alone.

## Maintainer configuration checklist

- Apple Developer Program membership and App Store Connect role with required permissions.
- App record for `com.vexsign.app`; matching team and all capability entitlements approved.
- App Store Connect issuer ID, key ID and private key stored in a protected environment as Actions secrets; restrict key role and revoke/rotate through Apple as needed.
- A certificate/profile strategy appropriate to Xcode archive export; do not place long-lived private signing material in logs or GitHub artifacts.
- TestFlight groups, internal/external tester policy, export compliance answers, beta review metadata, release notes and invitation link.
- Verify processing and actual install on supported physical devices; processing is not the same as external beta approval.

Apple's workflow guidance describes uploading an archive to App Store Connect for TestFlight/App Store and offers distinct Ad Hoc and Enterprise export methods: [Apple distribution documentation](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases.md). Review current App Store Connect API documentation before implementation; this document is not proof of a configured pipeline.
