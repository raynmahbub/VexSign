# Source-guided integration: investigation, implementation map and results

Written 2026-11-13 against VexSign `f05d4a1`. It records what was read in VexSign and in
the reference projects, which ideas were taken or rejected and why, what was changed, and
what was and was not verified.

**Verification boundary.** The work was done on Linux with no Swift toolchain, Xcode,
simulator or device. No Swift in this change has been compiled and no XCTest has run. What
ran is listed under [Checks](#checks). Everything else is unverified until CI runs.

## Baseline

- Branch `arena/b2a817eb-vexsign`, one commit, no submodules, clean tree.
- About 900 Swift files. Targets: app, tests, widget extension, watch app and widgets, tvOS,
  visionOS. Local packages: `NativeSigning`, `SideSign`, `AltSourceKit`, `NimbleKit`,
  `Packages/Vendor/Zsign`, `Packages/Vendor/IDeviceKitten`. Xcode groups are file-system synchronised, so new
  files need no project edit.
- All repository gates passed before the change (see [Checks](#checks)).

## Implementation map

Where each responsibility already lives. Each has one owner; none was duplicated.

| Responsibility | Owner in VexSign | State found |
| --- | --- | --- |
| Signing engine | `Utilities/Signing/SigningService`, `ZsignEngine` over `Packages/Vendor/Zsign` | One engine. Preflight exists: `SigningPlan`, `ProfileCompatibility`, `NestedBundleAudit`, `SigningInputValidation`; output checked by `SignatureVerifier`. |
| Tweak injection | `Utilities/Handlers/TweakHandler`, `TweakAnalyzer`; library in `Backend/Observable/TweakManager` | Injected without checking the library; rootful and rootless trees merged; one hook path rewritten. **Changed here.** |
| Mach-O reading | `Utilities/MachO/MachOInspector` (bounded), `Utilities/MachOReader` | Bounds enforced. arm64e misread as arm64. **Fixed here.** |
| Certificate status | `Backend/Observable/CertificateStatusManager`, `CertificateDashboard/CertificateInspector`, `Utilities/OCSP` | On-device trust evaluation. Three states; cached verdict shown without regard to expiry or age. **Changed here.** |
| Task centre | `Backend/Observable/UnifiedTaskCenter` | Single source; `DownloadManager` mirrors into it. |
| Install | `Backend/Observable/AppInstaller`, `InstallQueueCore`, `Utilities/Installing/InstallConfirmation` | Honest phases and verdicts already exist; handoff is not reported as installed. |
| Downloads | `Backend/Observable/DownloadManager` | One manager. |
| Updates | `AppUpdateChecker`, `SkippedUpdatesManager` | Ignored versions already exist. |
| Backup | `Backend/Observable/BackupManager` | Present; not read in depth. |
| Navigation | `Views/TabView/TabEnum`, `TabBarPreferences` (stored version 4) | Five tabs, default Library / App Store / Home / Downloads / Settings, pinned by tests. |
| LiveContainer | `Integrations/EmbeddedContainer/`, `Backend/Companion`, `Documentation/Architecture/RUNTIME_MODELS.md` | Kept separate from installed apps. |
| Persistence | Core Data `VexSign.xcdatamodeld` via `Backend/Storage` | Not changed. |

Not read in depth: the bodies of `AppInstaller`, `NativeSigningManager`, `DeviceConnectivity`,
`BackupManager`, and the repository parsing in `AltSourceKit`. No claim is made about them.

## Reference projects

Revisions are the heads cloned on 2026-11-13. "Shared with Feather" counts source files
at the same path with identical contents, against `claration/feather` (102 files).

| Project | Revision | License | What it is, from its source | Disposition |
| --- | --- | --- | --- | --- |
| Feather | `31ab6de` | GPL-3.0 | VexSign's lineage for signing, sources and tweak handling. | Already inherited. |
| FeatherPlus | `9af4713` | GPL-3.0 | 83 of 103 files identical to Feather, 19 modified, 1 added (`MobileGestalt.swift`). | Nothing adopted; the differences were not reviewed line by line. |
| RyukSign | `46c6d15` | GPL-3.0 | Largest fork: 138 files added over Feather (batch signing, backup, download manager, update checker, WebDAV server). | Concept of separate inspect / check / inject steps taken. Rest already has VexSign counterparts. |
| KorSign | `f20892f` | GPL-3.0 | 230 files; added-file list almost the same as RyukSign's. | Duplicate of RyukSign for this purpose. |
| MySignReincarnated | `c21554d` | GPL-3.0 | 241 files in a directory still named `RyukSign`. | A RyukSign fork; duplicate. |
| Odysseus (mirazbakis) | `2664dad` | GPL-3.0 | Feather plus 26 files: own OCSP/X.509/DER code, Apple ID, catalogue UI. | Read for on-device OCSP comparison. |
| Odysseus (raynmahbub) | `ab74059` | GPL-3.0 | The above plus 9 files (certificate export/import link, local server TLS, device authentication); 65 paths differ. | Not distinct in design; same disposition. |
| BatSign | `d60dbee` | GPL-3.0 | Feather plus 45 files (bulk sign, install ledger/watcher, activity log). | Counterparts exist; nothing adopted. |
| KSign | `c14dedc` | GPL-3.0 | Feather plus 48 files (file browser, hex/plist editors, downloader). | Previously assessed in `THIRD_PARTY_ADAPTATIONS.md`. |
| NexStore | `d4c7fc1` | GPL-3.0 | Feather with 8 added files. Its certificate status has three states and is obtained by uploading the `.p12` and password to a remote checker. | **Mechanism rejected** (key material leaves the device). The six-state vocabulary in the brief is not in its source. |
| ForgeSign-iOS | `a08e679` | none | Swift app with preflight, provisioning audit, install coordinator, refresh planner. | No license: concepts only, no code. |
| iPASide | `6b72139` | MIT | Dart and Python, not Swift. | Not portable as code; account flow not implemented here. |
| Sideloader | `631abcc` | GPL-3.0 | D language desktop tool. | Not portable as code. |
| SideInstaller | `7d77e5b` | custom, non-commercial | Rust and Swift. | License incompatible with GPL: concepts only. |
| LiveContainer | `9d6ea09` | AGPL-3.0 | Already integrated through `Integrations/EmbeddedContainer/`. | No change. |
| SideStore / AltStore | `4f3d18d` / `56854e6` | AGPL-3.0 | Source format reference; `AltSourceKit` consumes it. | No change. |
| zsign | `9299685` | MIT | Vendored in `Packages/Vendor/Zsign`. | No change. The vendored copy was not diffed against this head. |
| libimobiledevice, libusbmuxd, ideviceinstaller | `fa0f791`, `93eb168`, `1762d5f` | GPL-2.0 / LGPL-2.1 | C libraries. | Not read beyond the tree. |

## What was changed

### Tweak load-time compatibility gate

`Utilities/Handlers/TweakCompatibility.swift` holds the rules as pure functions.
`TweakHandler` enforces them; `TweakAnalyzer` shows the same findings on the info screen.

- **Refused:** not Mach-O, malformed load commands, no arm64 slice, arm64e only, built for
  another platform, still encrypted, a required load path outside the app sandbox, and a
  package with payload in both the rootful and rootless trees.
- **Reported, not refused:** an optional (weak) load path outside the sandbox, a control
  file whose architecture disagrees with the files, a roothide package.
- **Order:** packages are unpacked and every input is checked before anything is copied into
  the bundle, so a refusal leaves the bundle untouched.
- **Layout:** one tree is read per package. The files decide rootful or rootless; the
  control file's `Architecture` separates rootful from roothide.
- **Hook runtime:** every absolute path to `CydiaSubstrate`, `libsubstrate.dylib` or
  `libellekit.dylib` is redirected to the bundled ElleKit.

This does not make tweaks universally compatible. It refuses the ones that cannot load.
A tweak that loads can still fail at run time for reasons no static check sees.

### arm64e detection

`MachOInspector` compared the CPU subtype to 2 without masking the capability byte.
Toolchains write arm64e as `0x80000002`; the bundled `ellekit.deb` confirms it. Every arm64e
slice was therefore reported as arm64. The subtype is now masked. This affects every caller
of `MachOInspector`, not only tweaks.

### Certificate status

`Utilities/Signing/CertificateStatusAssessment.swift` produces one status from the expiry
dates, the stored revocation flag and the last check's evidence.

| Status | Shown when |
| --- | --- |
| Valid | A positive revocation answer less than 24 hours old, and nothing expired or revoked. |
| Expired | The certificate or the profile is past its end date. Needs no network. |
| Revoked | The responder said so, or an earlier check recorded it. |
| Check Unavailable | The check ran and the responder did not answer. |
| Check Unsupported | A revocation check could not be set up for this certificate. |
| Unknown | Never checked, the evidence is too old, or the check failed for an unrelated reason. |

Only an explicit revocation answer counts as revoked; a failed check is never shown as
valid or revoked. The stored snapshot gains two optional fields (`gap`,
`certificateExpires`); older snapshots decode unchanged. The certificate list and the
dashboard use the assessment. `CertificateStatusValue` and its persisted raw values are
unchanged.

### Follow-up in the same areas

- **Hook runtime is required, not optional.** When a tweak links Substrate or ElleKit and the
  bundled ElleKit cannot be found, injection is refused. It used to log a warning and
  produce an app that stops at launch.
- **Rewrites are verified.** After redirecting hook-runtime paths the library is read back;
  an absolute path still present is a refusal. A load command that cannot be written to the
  app's executable is a refusal too, where the result used to be discarded.
- **Package dependencies are reported.** `Depends` is parsed; names that neither the
  jailbreak, the hook runtime nor another package in the same run provides are logged.
  They are not enforced: whether a missing package matters is only known at run time.
- **Home uses the assessed certificate status**, so it agrees with the certificate list.
- **Signing refuses an expired certificate, not only an expired profile.** The run reads
  the certificate's own end date from the last stored status check (no network) and stops
  before any work. An unread date is not a refusal; the post-signing verifier still applies.
- **Tweak import checks compatibility.** A single library that no app could load (wrong
  architecture, arm64e only, wrong platform, encrypted, damaged) is refused at import with
  the reason. Packages and bundles are still checked when unpacked for injection.
- **Shortcuts** name the sections Discover and Tasks, matching the tabs.
- **Tabs.** The default order is Home, Discover, Library, Tasks, Settings. "App Store" and
  "Activity" were renamed; their raw values (`appStore`, `downloads`) are unchanged, so
  stored preferences and deep links still resolve. A stored order that still equals the old
  default follows the new one; an order the user arranged is kept exactly, as are hidden
  tabs and the launch tab.

## Already present, not changed

An earlier draft of this document listed the following as not done. That was wrong: they
were not *touched*, but VexSign already has them. Each was located in source; none was read
in depth or executed.

| Area | Where |
| --- | --- |
| Apple account sign-in, sessions, two-factor resume | `Backend/Services/AppleAccountSessionCoordinator`, `AppleAccountAuthenticationState`, `Security/AppleAccountCredentialStore` |
| Anisette | `Backend/Services/AnisetteProvider`, `Views/Settings/AnisetteProviderConfigView` |
| Provisioning | `Packages/NativeSigning/`, `Backend/Services/NativeSigningManager`, `Views/Settings/ProvisioningFlowView` |
| Device layer | `Utilities/IDevice/` (`DeviceConnectivity` capability matrix, `LockdownClient`) |
| File transfer and WebDAV | `Backend/Server/WebManagerServer+WebDAV`, `WebDAVTransferPolicy`, `Backend/Observable/WebManager` |
| Automation and refresh | `Backend/Observable/BackgroundAutomation`, `AutoSignManager`, `Utilities/RenewalReadiness`, `Backend/AppIntents` |
| Backup | `Backend/Observable/BackupManager` |
| Signing progress | `Views/Signing/SigningWorkflowView` (five steps: Prepare, Customize, Sign, Verify, Install) |

## Added in the fourth pass

None of this has been compiled or run; see Checks.

- **Ten-step signing checklist** (`SigningChecklist.swift`). Identity, preflight, the seven
  stages the engine reports, and install. Each row is derived from recorded evidence. A
  stage the run did not report is shown as skipped only once a later stage was reached;
  Verify completes only when verification was recorded; Install is always shown as a
  separate step, because signing does not install.
- **Remove from a paired device** (`DeviceAppRemoval.swift`, `DeviceAppRemovalSection.swift`).
  The vendored `deleteApp(for:)` is patched to free its client and to connect through the
  tunnel the way `listApps` does (recorded in `Packages/Vendor/manifest.json`). VexSign refuses its
  own identifier, `com.apple.` identifiers and malformed ones, asks for confirmation, then
  reads the device back. The result is "Removed" only when the app is seen to be gone;
  otherwise it is "Removal requested" or "Still installed". **Not exercised on a device.**
- **Permission for background signing** (`UnattendedSigningGrant.swift`). A scheduled pass
  with the "sign and queue" policy now signs only under a grant the user issued: one
  certificate, 1, 7 or 30 days, revocable. Without one it notifies instead. The grant holds
  no secret. Existing "sign and queue" users will stop getting background signing until
  they allow it; runs they start by hand are unchanged.

## Not done, and why

- **Unattended renewal of free Apple ID profiles.** Blocked by a gate in the code, not by
  missing plumbing. Renewing means creating a profile through the native account backend,
  and that backend refuses every profile operation in this build:
  `NativeProvisioningProfileValidator` is constructed without a CMS verifier
  (`SideSignAccountBridge` default, `NativeSigningManager.initializeBackend`), so
  `profileOperationsAvailable()` is false and `requireProfileOperations()` throws before
  anything is requested. The attended flow in `ProvisioningFlowView` stops at the same
  place. The opt-in, `NativeProvisioningProfileValidator.appleCMS()`, is marked "do not
  select this merely because a plist parses" and `Documentation/QA/DEVICE_TESTING.md` requires it to
  be proven on macOS against genuine and tampered profiles first. Turning it on from an
  environment that cannot compile, let alone verify a CMS signature, would be removing a
  trust check to make a feature appear. Order of work when that is possible: promote the
  verifier, get the attended flow passing on a device, then add a renewal scope to
  `UnattendedSigningGrant` and a background step that ends in a verified installation.
- **Performance.** One change that is less work by construction: the Discover header no
  longer builds a `DateFormatter` on every render. Nothing was measured and nothing else
  was changed; an optimisation chosen without a profile is a guess.

## Checks

Run locally on 2026-11-13 after the change, all passing:

- `.github/scripts/quick_check.py --root .` (its Swift syntax step is skipped without a toolchain) and `--self-test`
- `Tools/CI/check-pbxproj.py`, `error-discipline.py`, `singleton-freeze.py`,
  `concurrency-discipline.py`, `check-docs.py`, `sync-strings.py --check`
- every `Tools/test_*.py`
- A tree-sitter parse of each changed Swift file: no syntax errors. This is a grammar check
  only. It does not type-check.

Not run: Swift compilation, XCTest (including the five new test files), simulator tests,
the strict-concurrency report, any GitHub Actions workflow, anything on a device.

Since then, CI run 422 on `main` at `ffceb89` compiled this work for the first time:

- `build · VexSign Debug (unsigned)`, scheme `VexSign`, `generic/platform=iOS`: passed.
- `tests · VexSignTests (simulator)`, scheme `VexSignTests`: the test target compiled;
  1701 tests ran, 1687 passed, 12 failed, 2 skipped. The run before this work
  (419, `a4e6035`) had 1606 tests and the same 12 failures.
- Platform check 180: watchOS passed; tvOS and visionOS failed to build, as they did
  before this work.

That is simulator and build evidence only. Nothing here has run on a device.

A later run on the working branch (CI run 43429740406, commit `f2c5bd5`) completed with the
quick check, the iOS device build, the concurrency report and the simulator test job all
successful. On commit `fdad1fd` the same four jobs succeeded again (CI run 43434795013) and
the platform check, started by hand for the branch, built the tvOS, visionOS and watchOS
targets (run 43434790840). `InstallConfirmationTests.testWatcherAcceptsNewAppearanceWithoutProgressCounter`
had failed once and passed once with no change to it; the watcher's scripted replay now uses a
lookup bound a busy runner cannot exhaust. One failure is not enough to confirm that was the
cause, so the test should be watched over further runs.

## Device acceptance for this change

1. Inject a rootful `.deb` and a rootless `.deb`; each should sign and the app should launch.
2. Inject an arm64e-only dylib; signing should stop with the reason, and the app bundle in
   the work directory should contain none of the tweak's files.
3. Inject a dylib linked against `/var/jb/usr/lib/libsubstrate.dylib`; the signed app
   should launch with ElleKit loaded.
4. Open Certificates online: a good certificate shows Valid. Turn on Airplane Mode, force
   a recheck: it should show Check Unavailable, not Valid and not Revoked.
5. Import an expired certificate: Expired, online or offline.

Fourth pass:

- Sign an app with no tweaks: the checklist should show Thin and Inject as skipped, Verify
  as done, and Install as a separate step.
- With the pairing session running, use Remove from Device on a signed, installed app:
  the app should disappear from the Home Screen. Try it on VexSign's own entry: refused.
- Stop the pairing session and try again: a failure message, and the app still installed.
- Open the device sheet with and without the pairing session: paired install and removal
  should read "supported" only with it.
- Set automation to "sign and queue" with no permission and let a scheduled pass run: it
  should notify and sign nothing. Allow background signing for 1 day: the next pass signs.
  Turn it off, or select another certificate: the next pass notifies again.
