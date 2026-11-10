# Real-device acceptance plan

Simulator tests do not prove certificate compatibility, OTA installation, trust prompts, Keychain behavior or physical installation. Record the exact commit, artifact SHA-256, iPhone model, iOS version, distribution method, signing class and results. Never include private credentials, UDIDs or profiles in public reports.

## Matrix and prerequisites

| Test | Required prerequisite |
| --- | --- |
| TestFlight bootstrap / update | Processed build, configured TestFlight tester group/invitation, compatible iPhone |
| Ad Hoc OTA install | Paid developer team, registered device UDID, matching valid Ad Hoc profile and certificate, HTTPS host |
| Enterprise install | Eligible Enterprise Program organization, compliant internal distribution and eligible device |
| MDM installation | Enrolled/managed organization device and operational MDM |
| Personal Team signing | Apple-supported Xcode provisioning, Personal Team account, valid device/profile; tests of VexSign native provisioning remain blocked pending integration |
| Imported paid identity signing | Test P12/profile for a non-production app with compatible entitlements; valid device registration as required |
| App Store Connect release | App record/team/API role and protected environment; physical TestFlight tester |

## Checklist

1. Install VexSign through TestFlight (only when configured) and record actual invitation/install state.
2. Open the bootstrap portal in Safari; check mobile layout, channel, version, min OS and honest eligibility messaging.
3. Attempt OTA only with an eligible Ad Hoc/Enterprise signed artifact; confirm the ineligible artifact remains blocked.
4. Launch VexSign and enter guest mode without a configured signing identity.
5. Import a test `.p12` and profile; inspect type, expiry, key match, bundle and entitlements.
6. Import a harmless IPA from Files and validate archive contents.
7. Sign using an eligible identity; exercise nested app/extension signing and output signature verification.
8. Confirm failed/cancelled signing preserves source and last known-good output; confirm success record includes attempt ID/hash/provenance.
9. Hand off install using an eligible mechanism and distinguish pending/unconfirmed from installed.
10. Inspect the installed app's bundle ID/version on device.
11. Check release availability for stable/beta/alpha without crossing channels.
12. Download, interrupt, resume and verify the exact hash before handoff; test insufficient disk.
13. Relaunch during download/sign/install-monitoring; verify recoverable interrupted state and no stale callbacks.
14. Test certificate/profile near expiry and expired mismatch handling.
15. Test a Personal Team route only where Apple-supported provisioning was completed; verify limits and unavailable capabilities are reported (do not claim that VexSign native provisioning works).
16. Test paid Development and Ad Hoc classes separately; test Enterprise only with an eligible organization.
17. Verify unsupported method/certificate combinations, invalid signature/hash and version/build regression fail closed.

For each step mark **pass**, **fail**, or **not run**, with observed evidence and exact artifact hash. No physical-device results are recorded by this repository yet. Existing [device acceptance procedure](../DEVICE_TESTING.md) provides additional local-device reporting commands; it requires a Mac for Xcode/devicectl workflows.
