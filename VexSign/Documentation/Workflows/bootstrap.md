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

## After VexSign has been installed and launched

The existing **Settings → Installation Engine → Pairing file and VPN setup** now
contains the guided implementation candidate and experimental read-only queries. First installation remains separate from
pairing, signing and subsequent installation. No public Apple RPPairing-host API,
Developer Mode detection API or special entitlement was established by this
review; the app cannot silently enable Developer Mode or another app's VPN.

| Running iOS | Conservative route in this draft |
| --- | --- |
| Below 17.4 | Paired route unsupported. Use an eligible external installer or signed IPA export. |
| 17.4–26.3 | Compatible classic record plus manually activated transport; an explicitly consented read-only device identity/service query is experimental and physically unverified. |
| 26.4–26.7 | Compatible Remote Pairing import required; a computer may be necessary. Lockdown is not equivalent. Storage/export are available in source, but the modern native loopback bridge is not accepted. |
| 26.8–26.x | Outside the reviewed compatibility matrix; no paired route enabled. |
| 27+ | No accepted on-device RPPairing host or modern imported-record transport in the pinned dependency. Use a compatible companion; no host/PIN is advertised. |

These are restrictions, not supported-device acceptance claims. A recognized
record, reachable socket or even a successful fresh query is **not** signing or
installation readiness. Paired installation/removal remain gated pending native
binary/failure-path and physical acceptance of the now-wired same-device exact
version/build confirmation; paired self-replacement is gated with them, because it
would be the same mutation over the same unaccepted transport. Updating VexSign does
not depend on that route: the update sheet signs the release locally and hands it to
the app's own OTA installer, which needs no pairing at all. Removal has an independent
gate: a positive inventory list cannot prove absence. The app never turns an OTA
handoff or native acknowledgement into installed success.

To inspect metadata without starting an install, explicitly approve queries,
check the intended UDID and VPN peer, then choose **Verify selected device**.
That remembers target selection only for this process, not enduring trust.
**Read selected app's installed version** performs a fresh positive CoreDevice
query. A missing result is Unknown, not Not installed; this action does not
unlock mutation/signing gates or complete an installation task. Changing the
target, record, peer or consent invalidates the selection and cached evidence.

Import accepts bounded original pairing plist bytes without format conversion;
replacement/deletion require an unchanged reviewed fingerprint. Exports contain
private credentials and require an explicit destination. Preparing/exporting a
file does not verify companion compatibility or receipt. Never attach a pairing
file to an issue or CI artifact. Imported paid-certificate signing continues to
use the existing certificate store/engine without Apple Account login; native
account signing uses strict CMS verification in the experimental factory; genuine Apple-profile/security and physical-device acceptance remain pending. The account flow now offers an exact-identity continuation into ordinary signing review, without automatically signing or installing.

See the [source audit](../Architecture/on-device-foundation-audit.md),
[implementation status and build instructions](../Architecture/on-device-foundation-status.md)
and [pending physical foundation checks](../DeviceTesting/ON_DEVICE_FOUNDATION_ACCEPTANCE.md).

For a maintainer with a Mac and an already eligible iOS 17.4–26.3 iPhone,
[the read-only classic validation runbook](../DeviceTesting/CLASSIC_PAIRING_READ_ONLY_RUNBOOK.md)
now provides exact UI steps and a blank private worksheet. It does not authorize
bootstrap installation, account operations or opening the mutation gate, and it
does not convert subset observations into full physical acceptance.

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
