# Distribution release process

## Current available release

The existing release process in [RELEASING.md](../RELEASING.md) builds/tests on GitHub-hosted macOS, creates an IPA, writes `BUILD.json`/`RELEASE.json` and SHA256 checksums, and may publish to GitHub Releases. `tools/write-build-provenance.py` and `tools/prepare-release-assets.py` explicitly mark the IPA `unsigned: true`. It is source/build provenance, not a signed installable release, TestFlight submission, cryptographic attestation, or public OTA authorization.

## Before a stable release

1. Run `make verify` and CI full on the exact candidate; inspect macOS build and simulator test reports.
2. Validate project version/build and release target identifiers using existing scripts.
3. Review the release assets, source commit, provenance and checksums.
4. Never add a P12, private key, provisioning profile, password, Apple ID, or UDID to an artifact.
5. Publish only via the existing protected release process. No production release is triggered by these distribution foundations.
6. If TestFlight is enabled in a future phase, separately confirm Apple processing and tester availability.
7. If OTA is enabled, sign the manifest, verify device eligibility, host under HTTPS and physically test the exact signed artifact.
8. Retain a previous eligible version and its signed manifest for rollback. Rollback is another user-authorized eligible install, not a silent downgrade.

## Channel contract

- **Stable**: reviewed release intended for general use.
- **Beta**: explicitly labeled preview; TestFlight if configured or an eligible restricted OTA route.
- **Alpha**: early opt-in preview; no public installation claim without actual signing/eligibility.
- **Development**: build/test artifacts only; not a public release.

Current GitHub workflow uses stable/nightly naming and does not implement this four-channel signed manifest contract. Do not silently map nightly into a production alpha/beta installer until the artifact and channel are explicit.

## Manifest signing tool (not wired to publication)

`tools/sign-release-manifest.mjs` can sign an authenticated **download-only** manifest for a non-empty artifact. It refuses to sign install-eligible claims: it does not inspect the IPA's actual Apple signature/profile/device eligibility. Example invocation after configuring the protected `VEXSIGN_RELEASE_MANIFEST_PRIVATE_KEY` and `VEXSIGN_RELEASE_MANIFEST_KEY_ID` environment variables:

```bash
node tools/sign-release-manifest.mjs \
  --artifact upload/VexSign-1.2.1.ipa \
  --output upload/manifest.json \
  --application-identifier com.vexsign.app \
  --version 1.2.1 --build-number 1020304 --channel stable \
  --minimum-os 17.0 \
  --download-url https://downloads.example.invalid/VexSign.ipa \
  --expiry-seconds 86400 \
  --distribution-method artifactDownload --signing-class unsigned
```

Use the actual hosted HTTPS URL, not the illustrative `.invalid` host. This command signs metadata; it does not sign the IPA, publish it, or authorize installation. It is deliberately not called by `.github/workflows/release.yml` until a production key and public-key trust configuration have been reviewed.
