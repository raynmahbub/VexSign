# Contributing

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). For large changes, open an [issue](https://github.com/raynmahbub/VexSign/issues) first.

## Ground rules

- Do not submit exploits, stolen certificates, or certificate-retrieval services.
- Discuss changes to hard-coded service links before opening a PR.
- Preserve upstream licenses and attribution. VexSign is GPL-3.0; dependencies retain their own licenses.
- Keep pull requests focused and include regression tests for behavior changes.
- Never commit private keys, certificates, provisioning profiles, tokens, or local environment files.

## Set up

```bash
git clone https://github.com/raynmahbub/VexSign.git
cd VexSign
make bootstrap
open VexSign.xcworkspace
```

The signing engine and device bridge live in `VexSign/Packages/Vendor/`; other SwiftPM packages
resolve normally. Use a supported current
Xcode and the iOS 17+ deployment target. Configure your own development team for device builds. Local HTTPS installation uses an identity generated on the device; no certificate pack is downloaded by the build.

## Source ownership

Project content lives under `VexSign/`. Keep the Xcode project/workspace,
`.github/`, root entry points and legal files where their tools expect them.
The iOS app is `VexSign/App/iOS/`. TV, Vision and widget sources live directly in
`VexSign/App/{TV,Vision,WidgetExtension}/`, without an extra target-name wrapper.
Keep both targets under `VexSign/App/Watch/` and the shared platform plist under
`VexSign/App/SharedPlatformInfo/` at their existing paths.

The iOS source layers are:

- `App/`: scenes, bootstrap, dependency composition, lifecycle and app navigation.
- `Presentation/Features/<Feature>/`: views, components, view models and UI models
  belonging to that feature. Reuse `Presentation/DesignSystem/` and `Shared/`.
- `Application/`: workflow orchestration through injected Domain interfaces.
- `Domain/`: Foundation-only contracts, values and deterministic policy; no UI,
  SDK, concrete persistence, file or HTTP implementations.
- `Infrastructure/`: actual signing/archive/account/device/repository/storage
  adapters. Keep the existing pipeline, registry and task/device coordinators.
- `Platform/`: Apple/iOS API and compatibility adapters.
- `Security/` and `Resources/`: real security policies/secret stores and bundled
  app resources, respectively.

Domain and Application must remain Foundation-only. New Presentation code must
not reach directly into signing, key/ZIP/device or concrete database APIs; legacy
coupling is recorded debt, not a pattern to copy. Add a consumed port and wire
its adapter in `App/Composition/AppContainer` when a workflow needs a new seam.

Keep genuine packages in `VexSign/Packages/`, optional services in
`VexSign/Services/`, existing test categories in `VexSign/Tests/`, and nonsecret
build/signing inputs in `VexSign/Configuration/`. Do not create empty example
packages, placeholder feature/suite folders or another catchall manager.
Single-child directory wrappers should be flattened; preserve parents with real
sibling files/subfolders and the exact tool-owned exceptions documented in the
[repository layout audit](VexSign/Documentation/Architecture/repository-layout-audit.md).
Single-file directories are not wrapper chains. Do not manufacture siblings to
silence the layout check or rename targets/modules to match folder names.

See the [architecture guide](VexSign/Documentation/Architecture/ARCHITECTURE.md),
[dependency rules](VexSign/Documentation/Architecture/dependency-rules.md) and
[migration record](VexSign/Documentation/Architecture/feature-layout-migration.md).
If a canonical public alias changes, run
`python3 VexSign/Tools/Validation/repository-validation/sync_repo_aliases.py --write`;
do not change historical feed or commit-pinned URLs by mass substitution.

## Validate changes

```bash
make verify
make test
make lint        # when SwiftLint is installed
```

`make verify` runs repository checks without Xcode. `make test` selects an available iPhone simulator. Do not hard-code simulator names in automation.

Before merging, manually dispatch **CI → full** on the branch. Run **Platform check**, **Server tests**, or **Ecosystem contracts** when those components change. CI runs automatically on relevant `main` pushes; it does not replace physical-device validation for installation, Keychain, provisioning, background execution, or hardware-specific behavior.

## Known build warnings

`ld` may print one line per archive member when linking the simulator app:

```text
libunicorn.a[arm64][n](....o) was built for newer 'iOS-simulator' version (26.5) than being linked (16.0)
```

That archive is the prebuilt Unicorn binary shipped by AnisetteKit. Upstream's
`build_xcframework.sh` sets the SDK and architecture but not
`CMAKE_OSX_DEPLOYMENT_TARGET`, so CMake stamps the slice with the runner's
macOS version. It is a packaging defect in the dependency, not an error in
VexSign; the simulator test suite never exercises local anisette provisioning.
CI filters only those `libunicorn.a` lines from the live log and keeps the
complete log in the failure artifact. The correct long-term fix is an upstream
rebuild with an explicit deployment target (for example `15.0`).

## Style and localization

- Prefer small, testable components and dependency injection over new global singletons.
- Do not add silent `try?` at user-visible failure boundaries.
- Preserve strict-concurrency boundaries; document any justified exception.
- Edit `VexSign/App/iOS/Resources/Localization/Localizable.xcstrings` with Xcode's String Catalog editor (or run `python3 VexSign/Tools/Validation/repository-validation/sync-strings.py --write`), then run `make verify`.
- Follow [Design](VexSign/Documentation/Features/DESIGN.md) for colour, type, spacing, motion and accessibility. Reuse the components in `VexSign/App/iOS/Presentation/` instead of adding another card style.
- Keep documentation concise and update only guides affected by the change.

## Releases

Push a `vX.Y.Z` tag whose version matches `MARKETING_VERSION`. For an unsigned test artifact without publishing, manually run **Release** with `build_only` enabled. See [VexSign/Documentation/Release/RELEASING.md](VexSign/Documentation/Release/RELEASING.md).

Zsign and IDeviceKit sources are vendored under `VexSign/Packages/Vendor/`. Send general Zsign
changes upstream to [claration/Zsign-Package](https://github.com/claration/Zsign-Package/tree/package);
if VexSign needs a new pin, follow [VexSign/Packages/Vendor/README.md](VexSign/Packages/Vendor/README.md) and
include the licence/commit update in the same PR.
