# Direct OTA

## Current status

VexSign implements device-local installation/OTA handoff and an OTA exporter in `VexSign/App/iOS/Infrastructure/` and `VexSign/App/iOS/Infrastructure/Devices/Installation/OTAExporter.swift`. That path does not publish VexSign remotely, supply a public eligible signing identity, or turn arbitrary IPAs into installable packages. The release workflow publishes unsigned IPAs, which cannot be installed as-is.

## Semi Local is not private

*Settings → Installation → Server & SSL* offers two server types. **Fully Local** (the
default) keeps the manifest on the device over its own HTTPS identity and needs the
installing device to trust the exported root CA. **Semi Local** exists because
`itms-services` only accepts a manifest from a publicly trusted host: the app asks a
third-party manifest service to build the plist around this device's payload URL.

That means:

- the payload URL — `http://<lan-ip>:<port>/<session>-<install-token>.ipa` — is sent as
  the `fetchurl` query parameter to `vexsign-install.vexsign.workers.dev` and
  `api.palera.in`, whose operators see it in their logs;
- the signed IPA is then served over **plain HTTP** on the local network, because the
  installing device does not trust the local CA in this mode;
- anyone who obtains that URL before the install finishes can download the IPA, and the
  token is only secret for as long as the link is.

The app shows this in the server picker before the first Semi Local attempt. Use it for
a device that cannot trust your CA, and use Fully Local for everything else.

## Eligibility

An OTA manifest is transport metadata, not an authorization or signing format. The IPA must be signed for an eligible route:

- **Ad Hoc:** profile includes the target device; the device is registered with the developer team; profile and distribution certificate are valid and match.
- **Enterprise:** eligible Enterprise Program organization, valid enterprise identity/profile and organization-use policy. Do not expose as unrestricted public distribution.
- **App Store:** App Store distribution output is for App Store Connect/TestFlight; do not relabel it as an Ad Hoc OTA IPA.
- **Personal Team:** short-lived development profile/device scope; not an unrestricted public route.

Apple's Xcode guidance requires registered devices for Ad Hoc distribution. An ordinary iOS app cannot call a public API to silently install arbitrary IPA files. Safari/system install behavior still depends on a valid signed package and user confirmation. See Apple's [registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices.md), [distribution-method overview](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases.md), and [MDM overview](https://developer.apple.com/documentation/devicemanagement.md).

## Release validation required before enabling a link

- HTTPS artifact and manifest access without credentials, redirect breakage, or unsafe filename assumptions.
- Parse the IPA as an untrusted ZIP using `ArchiveSafetyValidator` and verify exactly one main app, bundle ID, versions, nested extensions, signatures, embedded profiles, expiration, device UDID scope, and signing certificate class.
- Validate manifest signature against a pinned release public key, then validate SHA-256 after complete download. Current code provides verifier primitives but no configured release key or OTA coordinator.
- Ensure manifest package URL, bundle ID and version match the inspected IPA. Set conservative expiry and prevent replay.
- Generate `itms-services` links only for a valid OTA manifest and eligible artifact. Display required device/profile trust actions and an explicit user handoff.
- Verify both successful public download and installation on a physical eligible iPhone. A download response is not installation evidence.

Do not publish an install button if the signing class, registered-device condition, Enterprise eligibility, or profile match is unknown. Use TestFlight when public beta testing is the intended audience.
