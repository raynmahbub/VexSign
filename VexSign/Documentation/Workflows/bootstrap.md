# iPhone-only bootstrap

## Current status

VexSign does not currently publish a production-signed, iPhone-installable bootstrap artifact. The existing GitHub release workflow builds an **unsigned IPA**, publishes checksums/provenance and does not upload to App Store Connect. Opening/downloading that IPA in Safari or Files does not install it. VexSign cannot bootstrap itself from an ordinary unsigned IPA.

The existing local OTA server serves a signed app to iOS only when its certificate/profile, device and local trust conditions are valid. It is not a remote public bootstrap service. Do not use it as a claim that arbitrary users can install VexSign.

## Supported initial routes once configured

1. **TestFlight (preferred public beta route):** a maintainer uploads an eligible signed archive through App Store Connect, waits for Apple's processing, configures internal/external testers as applicable, and publishes an invitation link. The user opens the invitation in Safari/TestFlight and accepts installation. GitHub Actions does not currently perform this upload.
2. **Ad Hoc:** a paid developer team registers the specific device UDID, issues a matching profile/certificate, exports the IPA and hosts the IPA plus a valid manifest over HTTPS. Only devices included in the profile can install. VexSign currently has no release-signed Ad Hoc build pipeline or public portal.
3. **Enterprise:** only eligible organizations may distribute internal-use apps to eligible users/devices. It is not a public-download workaround.
4. **Managed deployment:** an organization uses its MDM service and eligible enrollment. Not a general consumer bootstrap route.
5. **App Store or eligible regional alternative distribution:** requires the relevant Apple program, region and review/entitlement process; not configured here.

A free Personal Team install is a developer provisioning/test path, not unrestricted public OTA distribution; the account setup in this repository is experimental and not a supported end-to-end bootstrap.

## Safari checklist for a future portal

A deployable portal must display stable/beta build, exact version/build, minimum iOS, channel, verified artifact hash, release notes, signing class, certificate/team fingerprint where safe, profile/device eligibility, expiry, and the platform handoff. It must hide or disable installation unless the artifact's Apple signing eligibility is actually established. Downloads and installation handoff must be separate statuses. A user should be told to use TestFlight, Files, or their organization when those are the legitimate route.

The release verifier currently has no production trust key. Until a protected Ed25519 signing key is created, its public key embedded in the app, and matching signed release envelopes published, existing GitHub release checksums are not an authenticity guarantee.

## Maintainer setup required

- Choose and configure App Store Connect app record, bundle ID `com.vexsign.app`, SKU, team, signing capabilities, beta review/testing metadata.
- Choose protected GitHub environment(s); keep distribution signing credentials out of CI/test jobs and artifacts.
- Produce a signed archive/export appropriate to each channel; inspect every extension's profile and entitlements.
- For OTA, host artifacts/manifests on HTTPS with correct MIME types, no auth wall, stable URLs and rollback retention. Validate actual download and device-specific installation before showing an Install action.
- Deploy and test a mobile-first portal over HTTPS from physical Safari. The repository currently has no portal deployment workflow or stable portal URL.

See [TestFlight](testflight.md), [OTA](ota.md), [release process](release-process.md), and [real-device testing](device-testing.md).
