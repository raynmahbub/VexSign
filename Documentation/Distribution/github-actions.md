# GitHub Actions distribution configuration

## Existing workflow map

- `.github/workflows/ci.yml`: Linux quick gates plus macOS unsigned iOS build and simulator tests for relevant changes.
- `.github/workflows/release.yml`: protected publish build, release IPA/provenance/checksums and GitHub Release publication. `Tools/Release/release-build-version.py` validates the shipped IPA's root bundle ID, marketing version and minimum OS plus nested bundle build numbers/identifier namespace. Current build metadata explicitly labels the IPA unsigned. This workflow is not App Store Connect/TestFlight upload.
- `.github/workflows/services.yml`: backend/service checks.
- `.github/workflows/platform-check.yml`: platform/companion validation.
- `.github/workflows/docs.yml`: offline documentation checks.

Extend these rather than creating redundant CI/release pipelines. The new TestFlight workflow is not yet configured.

## Required before TestFlight

1. Create an App Store Connect app record for `com.vexsign.app` and validate all app/extension identifiers and capabilities.
2. Create a narrowly scoped App Store Connect API key with the permissions needed to upload and inspect builds.
3. Add a GitHub `testflight` environment restricted to the default branch and release workflow; require reviewers where available.
4. Store issuer ID, key ID and private key as environment secrets. Use temporary key-file permissions and guaranteed cleanup. Do not print, cache, archive or upload the key.
5. Keep distribution certificate/profile material separate from read-only PR/CI jobs. Do not add signing secrets to test artifacts or release archives.
6. Upload through supported Apple tooling/API, then query App Store Connect processing state and fail/report accurately. Do not announce tester link until processed and configured.

## Required before OTA

- Create `release-signing` protected environment for offline/controlled manifest signature generation; generate an Ed25519 PKCS#8 PEM key outside source control and keep the private key restricted. No production key is configured currently.
- Set `VEXSIGN_RELEASE_MANIFEST_PRIVATE_KEY` and `VEXSIGN_RELEASE_MANIFEST_KEY_ID` as protected environment secrets. `Tools/Release/sign-release-manifest.mjs` reads these variables; its invocation should be confined to a protected job, with no debug output, artifact caching, or private-key file upload.
- Add only the public verification key to app code via an explicit reviewed change and test key rotation/revocation.
- Publish signed manifest and IPA to HTTPS. Verify artifact URL and manifest accessibility after deployment.
- Include source commit, workflow run, channel, bundle ID, version/build, min iOS, signing class/team/fingerprint where safe, hash, notes URL and expiry. Exclude private key/certificate bytes, passwords, Apple account credentials, UDIDs and provisioning profiles.
- Current CI runs `node --test Tools/Release/test-release-manifest.mjs` on the macOS build job without production secrets. It uses ephemeral test keys and does not publish or call the signing key.
- Keep GitHub Actions `contents: read` by default. Grant `contents: write` only to a publication job; use artifact handoff and avoid executing repository code with a write token.

## General protection

Retain pinned action SHAs, `persist-credentials: false` where possible, least privilege, protected tags/environments, workflow concurrency, artifact checksums and code review for workflow edits. Do not run production signing jobs from untrusted pull requests. Action approval/settings and environment reviewers are repository configuration and cannot be established by workflow YAML alone.
