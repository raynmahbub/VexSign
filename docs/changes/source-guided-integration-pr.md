# Source-guided integration: pull request description and final report

Branch `arena/b2a817eb-vexsign`, based on `main` at `f05d4a1`. The research behind it is in
[the integration notes](../research/source-guided-integration.md).

## Pull request description

### Summary

Changes drawn from a source-level reading of other signers, written as VexSign's own code:

- Tweaks are checked before any file is placed in the app. A library no app could load
  (wrong architecture, arm64e only, wrong platform, encrypted, a required path outside the
  sandbox) stops the run with the reason. Hook-runtime paths are rewritten and read back.
- Certificate status is one assessment used by the certificate list, the dashboard and
  Home. "Valid" needs a good revocation answer from the last 24 hours; no answer is shown
  as unavailable, not as valid or revoked. Signing refuses an expired certificate.
- Tabs are Home, Discover, Library, Tasks, Settings, with a migration for saved orders.
- The signing screen shows ten evidence-based steps.
- A signed app can be removed from the paired device, after confirmation.
- Scheduled signing needs a permission the user gives for one certificate and a limited
  time.

### Type of change

- [x] Bug fix
- [x] New feature
- [x] Documentation
- [x] Dependency or vendored update (local patch to `IDeviceKitten`, recorded in `Vendor/manifest.json`)

### Validation

- [ ] `make verify` passes locally — **not run**: no Swift toolchain in the authoring environment
- [ ] `make test` — **not run**; five new XCTest files and edits to nine others have never executed
- [x] New user-facing text added to `Localizable.xcstrings`
- [x] Python gates: `quick_check.py`, `check-pbxproj`, `error-discipline`, `singleton-freeze`,
      `concurrency-discipline`, `check-docs`, `check-native-handoff`, `check-package-graph`,
      `sync-strings --check`, every `tools/test_*.py`
- [ ] Component checks (Platform check, Server tests, Ecosystem contracts) — not run

### Notes for reviewers

- **Nothing here has been compiled.** Every changed Swift file parses, which is a grammar
  check only. Expect compile errors on the first CI run and treat them as part of review.
- **Behaviour change:** users with the "sign and queue" policy get notifications instead of
  background signing until they allow it once. This includes the Shortcuts update action
  and the companion bridge, which run as background passes.
- **Device removal is destructive and untested on hardware.** Review
  `DeviceAppRemoval.swift` and the vendored `deleteApp(for:)` patch first.
- **Tweak checks are stricter.** A tweak that used to be injected and then crash at launch
  now fails the signing run.
- Device steps are listed at the end of the integration notes.

### Checklist

- [ ] Change is focused — it is not; it is four passes of one integration brief and could be split by area
- [x] Regression tests added or updated (not executed)
- [x] Documentation updated
- [x] No keys, certificates, profiles, tokens or UDIDs included
- [x] Third-party code keeps its license; no code was copied from the reference projects

## Final report

1. **Scope.** 53 paths touched: 40 modified, 13 new. Nothing committed or pushed.
2. **References read.** 21 repositories; licences and what each informed are tabled in the
   integration notes. GPL, AGPL, unlicensed and non-commercial sources were used for
   concepts only.
3. **Rejected from the references.** One project's certificate check uploads the p12 and
   its password to a third party. Not adopted.
4. **Tweak compatibility.** New `TweakCompatibility`; `TweakHandler` checks before placing,
   requires the hook runtime when a tweak links it, verifies rewrites, reports unmet
   package dependencies. Import applies the same check to single libraries. Failures to add
   a tweak to an app extension now reach the signing log.
5. **Mach-O.** `MachOInspector.cpuType` masks the subtype, which fixes arm64e detection.
6. **Certificate status.** New `CertificateStatusAssessment`, used by the list, dashboard,
   Home and the signing gate. The batch check now uses the earlier of certificate and
   profile expiry, and shows "Not Checked" rather than "Valid" when revocation was not
   established.
7. **Signing gate.** `SigningService` refuses an expired certificate before the engine
   runs; the preflight override does not excuse it.
8. **Navigation.** Tab titles, default order, preference migration (version 5), Shortcuts
   section names, and the Discover header and appearance setting.
9. **Signing checklist.** Ten rows from recorded evidence; unreported stages are skipped,
   never marked done.
10. **Device removal.** Vendored call patched (client freed, tunnel supported); rules,
    confirmation, read-back; capability report follows the pairing session, which the
    device sheet now probes instead of assuming absent.
11. **Background signing permission.** `UnattendedSigningGrant`: one scope, one
    certificate, at most 30 days, revocable, holds no secret. `BackgroundAutomation`
    downgrades an unattended signing pass to notify-only without it.
12. **Tests.** New: `TweakCompatibilityTests`, `CertificateStatusAssessmentTests`,
    `SigningChecklistTests`, `DeviceAppRemovalTests`, `UnattendedSigningGrantTests`.
    Extended: tab, import, workflow-trace, device-connectivity and tweak-import tests.
    None executed.
13. **Checks that passed.** The Python gates listed above; the `try?` baseline was
    regenerated one lower (203).
14. **Checks not run.** Swift compilation, XCTest, simulator tests, the strict-concurrency
    report, every GitHub Actions workflow, anything on a device.
15. **Not done.** Unattended renewal of free Apple ID profiles: the native backend refuses
    all profile operations in this build because no CMS verifier is configured, so the
    attended flow stops there too; the `scoped_unattended_renewal` device check stays
    pending. Performance: one unmeasured change (the Discover header's date formatter is
    built once), nothing else.
16. **Risks, in order.** Uncompiled code; device removal on real hardware; the background
    signing behaviour change for existing users; stricter tweak rejection.
