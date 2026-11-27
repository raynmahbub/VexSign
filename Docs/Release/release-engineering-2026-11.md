# VexSign Production Release Engineering — 2026-11

Starting branch: `arena/d2c05cf4-vexsign`. Starting HEAD:
`2fad3a996bd8642779f7fede484be8c94ec54037`. All changes remain uncommitted and
unpushed. This document is the engineering record; the implementation is in
project settings, Swift sources, Python release tools and GitHub Actions.

## Existing infrastructure found

- Ten GitHub Actions workflows. `ci.yml` validates pushes/PRs, builds unsigned
  simulator/device artifacts, runs `VexSignTests` and `VexSignUITests`, and has
  an opt-in self-hosted device job. `release.yml` builds from tags, manual
  dispatch or a nightly schedule, runs `make verify`, checks CI status, produces
  `BUILD.json`/`SHA256SUMS`/`RELEASE.json`, attests provenance and publishes.
  No release workflow accepts a pull request.
- Xcode project has **four configurations already**: `Debug`,
  `Debug-distribution`, `Release`, `Release-distribution`, across six shared
  schemes and eight native targets. Distribution configurations define the
  `APPSTORE` Swift flag; no source currently reads it. No new scheme was added.
- Version `1.2.1`, build `2`, bundle id `com.vexsign.app` (widget
  `com.vexsign.app.widget`). `release-build-version.py` derives an Apple
  numeric build from the commit count; the hosted `make` path ad-hoc signs and
  packages an IPA that users must re-sign.
- Existing entitlements: app group plus `get-task-allow=false`; the widget has
  its own entitlements. Manual signing and hard-coded profile names exist in
  the project, but no certificate/private key is committed.
- Dependencies resolve through the checked-in `VexSign.xcworkspace` package
  resolution and local `Packages/*` manifests; `check-package-graph.py` and
  `sync_repo_aliases.py` gate them. `select_xcode.sh` pins the Xcode version via
  `BUILD_XCODE`, `RELEASE_XCODE` or a dispatch input.
- Persistence already migrates `Feather.sqlite` without deleting the legacy
  store on failure, quarantines unreadable Core Data stores, migrates legacy
  defaults, and has credential migration diagnostics. The Keychain bridge is
  read-through and does not delete locked secrets.

## Implemented build configuration separation

- The four VexSign app target configurations now inject an explicit
  `VEXSIGN_BUILD_CHANNEL`: `development` (Debug), `prerelease`
  (Debug-distribution), `release` (Release and Release-distribution).
  `Config/BuildSettings/iOS/Info.plist` consumes it as `VexSignBuildChannel`.
- Release configurations now state `SWIFT_OPTIMIZATION_LEVEL = "-O"` and
  `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` explicitly. Debug and
  Debug-distribution keep `-Onone` and the `DEBUG` compilation condition;
  Release and Release-distribution define no `DEBUG`.
- `VexSignApp.isUIAutomationLaunch` is now compiled only under `#if DEBUG`, so
  a command-line argument cannot skip onboarding in a production artifact.
- `Tools/Release/validate_release_config.py` blocks drift: inconsistent
  marketing versions, wrong bundle IDs/team/deployment target, missing
  entitlements, a release build with `DEBUG`, an optimized setting that is not
  explicit, a missing channel, or committed private-key material. Synthetic
  key text in tests/docs is excluded by path only.

## Version management

- `VexSign/Shared/Build/VexSignBuildInfo.swift` is the single application-level
  source for version, build, commit and configuration. All prior
  `Bundle.main.version` / `buildNumber` reads in the app now use it; values are
  bounded before use in UI, receipts or diagnostics.
- About shows version, build and channel, plus the source commit. The launch
  diagnostic event records `appVersion`, `appBuild`, `buildChannel` and
  `sourceCommit`; no credential or log text is added.
- `Tools/Release/release_version.py` centralizes SemVer/tag parsing, preserves
  the existing commit-count build-number algorithm, and rejects a tag whose
  `v<version>` does not match `MARKETING_VERSION`.
- Xcode `MARKETING_VERSION` remains the only product version. No invented
  future version number was introduced. `release.yml` still refuses a tag that
  disagrees with the project or the built `Info.plist`.

## Release scripts

| Script | Purpose |
| --- | --- |
| `Tools/Release/release_version.py` | SemVer/tag parsing, build-number policy. |
| `Tools/Release/validate_release_config.py` | Build-time config, entitlement and secret gate. |
| `Tools/Release/artifact_manifest.py` | Inspects an IPA, writes `ARTIFACT.json`, regenerates `SHA256SUMS`. |
| `Tools/Release/verify_artifact.py` | Independent offline verification; optional strict `codesign`/`security` checks. |
| `Tools/Release/export_signed_ipa.py` | Opt-in explicit manual signing export from an archive; `--dry-run` is secret-free. |

`ARTIFACT.json` contains product, marketing version, build number, full commit,
release tag, Xcode and Swift versions, configuration, channel, artifact name,
size, SHA-256, UTC timestamp, signing class and a plain-language verification
boundary. It contains no credential, key, token or profile secret.

`verify_artifact.py` checks archive readability, member uniqueness, absence of
development-only or credential-like members, root/nested bundle IDs, version,
build, minimum iOS, build channel, source commit, bundle list, file size and
SHA-256, plus manifest consistency. It rejects a manifest with secret-like
keys. Signature and provisioning-profile validation use `codesign --deep
--strict` and `security cms -D` only when explicitly requested; without those
tools the exact boundary is printed and `device_installable` remains false.

## Signing and provisioning behavior

- No production signing identity, certificate, password, profile or Apple
  account value is stored in the repository. The hosted release job remains an
  **ad-hoc signed, unsigned-for-installation artifact download**; its manifest
  states `signing.class = adHoc`, `distribution_method = artifactDownload`,
  `signature_verified = false`, `device_installable = false`.
- A new **opt-in** `signed-export` job and script support a protected
  self-hosted Mac (`VEXSIGN_SIGNED_RUNNER=true`, `release-signing` environment,
  `vexsign-signed` label). Identity, team and profile come from environment
  variables/secrets only, never from repository files. The archive is built
  unsigned, then `xcodebuild -exportArchive` uses an explicit manual
  `ExportOptions.plist`; verification runs `verify_artifact.py
  --require-signature`. There is no automatic signing fallback.
- The job does **not** publish, install on a device, or upload to App Store
  Connect. Development/ad-hoc profile membership, UDID matching and TestFlight
  processing remain unverified until an actual run with valid Apple material.

## Upgrade and migration safety

- Legacy default migration moved into `LegacyPreferenceMigration`, an injectable
  helper that only fills missing VexSign keys, never deletes legacy keys and is
  safe to repeat. No current value is overwritten.
- `VexSignTests/UnitTests/Application/PreferencesMigrationTests.swift` uses an
  isolated `UserDefaults` suite for representative Feather/Ryuk data,
  idempotence, current-value precedence, malformed legacy data and build
  metadata validation. Existing credential-migration and storage-quarantine
  tests remain in their suites.
- Core Data, Keychain, and protected-file upgrade paths were not rewritten:
  they already preserve legacy stores on failure and keep Keychain boundaries.

## GitHub Actions changes

- `ci.yml` quick gate now runs `test_release_engineering.py`,
  `validate_release_config.py` and `test_release_engineering_contracts.py`.
  Workflow-policy tests now cover the isolated signed-export runner too.
- `release.yml` now validates release configuration before building, records
  the Swift version next to the already-selected Xcode version, generates and
  independently verifies `ARTIFACT.json` before release notes, checks every
  checksum, and attaches the manifest to build artifacts and published assets.
- The opt-in `signed-export` job is isolated from publication. It has
  `contents: read`, a protected environment, explicit timeout, pinned actions,
  no checkout in the privileged publish job, and no secret values in logs.
- Concurrency groups already prevent overlapping publication. Third-party
  actions in all workflows are pinned to 40-character commit SHAs (contract
  test). No new dependency or download of an arbitrary build script was added.

## Commands executed here (Linux, no Xcode/Swift toolchain)

```
git branch --show-current && git rev-parse HEAD && git status --porcelain
python3 Tools/Release/test_release_engineering.py       # 13 tests OK
python3 Tools/Release/test_release_assets.py            # 9 tests OK
python3 Tools/Audit/test_release_engineering_contracts.py  # 9 tests OK
python3 Tools/Validation/repository-validation/test_workflow_policy.py  # 68 tests OK
python3 Tools/Release/validate_release_config.py        # configuration report OK
python3 Tools/Release/artifact_manifest.py --ipa <synthetic IPA> ...  # manifest written
python3 Tools/Release/verify_artifact.py --ipa <synthetic IPA> ...    # offline report OK
(cd <temp> && sha256sum --check SHA256SUMS)             # synthetic IPA + manifest OK
make verify                                            # 88 gate(s) passed
make docs-check                                        # OK
python3 Tools/Validation/repository-validation/check-pbxproj.py  # pbxproj structure OK
python3 Tools/Validation/repository-validation/sync-strings.py --check  # OK
yaml.safe_load(.github/workflows/release.yml, ci.yml)  # both parse
git diff --check                                       # clean
```

The manifest/checksum commands above used a **synthetic ZIP with a synthetic
Info.plist**, not an application built by Xcode. No real IPA was generated,
signed, installed or published in this environment. Swift files were parsed
with tree-sitter for syntax only; that is not compilation or type checking.

## Validation boundary and remaining work

Verified here: portable gates, configuration contract, synthetic manifest and
checksum round-trip, rejection of tampered/malformed artifacts, secret-like
manifest keys, missing tools for signature validation, and workflow structure.

Not verified here: `xcodebuild`, XCTest/XCUITest, `codesign`, provisioning
profile contents, real IPA packaging, GitHub Actions runs, device installation,
TestFlight/App Store processing, and Instruments. The opt-in signed export has
unit-tested input/dry-run behavior but has **not** executed against real Apple
distribution material. CI results must be read from an actual run; none was
started by this work.

Before calling any build production-ready on a device:
1. Run `make verify` and the full CI matrix on the intended commit.
2. Build with the pinned Xcode, generate `ARTIFACT.json`, verify checksums.
3. On a configured Mac, run the signed export with a valid profile and verify
   `codesign`/profile output in the report.
4. Install on a registered iPhone and record the OS build, bundle id, version,
   entitlements and first-launch behavior. A simulator pass is not a substitute.
5. Exercise upgrade from a representative older store and confirm preferences,
   library records, certificates and Keychain secrets survive.

## References

- Apple, [Building from the Command Line with Xcode FAQ](https://developer.apple.com/library/archive/technotes/tn2339/_index.html) — `xcodebuild -exportArchive` and `exportOptionsPlist`.
- Apple, [Automating Version and Build Numbers Using agvtool](https://developer.apple.com/library/archive/qa/qa1827/_index.html) — `CFBundleShortVersionString` vs `CFBundleVersion`.
- GitHub, [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use) — least privilege and SHA-pinned actions.
