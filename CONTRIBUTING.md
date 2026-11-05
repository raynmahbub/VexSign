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

No Git submodules are used; third-party sources live in `Vendor/`. Use a
supported current Xcode and the iOS 16+ deployment target. Configure your own development team for device builds. Local HTTPS installation uses an identity generated on the device; no certificate pack is downloaded by the build.

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
- Edit `VexSign/Resources/Localizable.xcstrings` with Xcode's String Catalog editor (or run `python3 tools/sync-strings.py --write`), then run `make verify`.
- Follow [Design](docs/DESIGN.md) for colour, type, spacing, motion and accessibility. Reuse the components in `VexSign/DesignSystem/` instead of adding another card style.
- Keep documentation concise and update only guides affected by the change.

## History maintenance

Rewriting `main` is exceptional. If merge commit messages must change, use the
reviewed runbook in [docs/REWRITING_HISTORY.md](docs/REWRITING_HISTORY.md): the
script rewrites the branch and its tags in a throwaway clone, verifies every
tree and tag, writes a bundle, and leaves the atomic force-push to a maintainer.
Coordinate with everyone who has a clone before pushing.

For new work, prefer squash merges: each PR lands as one commit and history
stays linear from here without replaying the old conflict resolutions. See the
same document for the repository settings.

## Releases

Push a `vX.Y.Z` tag whose version matches `MARKETING_VERSION`. For an unsigned test artifact without publishing, manually run **Release** with `build_only` enabled. See [docs/RELEASING.md](docs/RELEASING.md).

Zsign and IDeviceKit sources are vendored under `Vendor/`. Send general Zsign
changes upstream to [claration/Zsign-Package](https://github.com/claration/Zsign-Package/tree/package);
if VexSign needs a new pin, follow [Vendor/README.md](Vendor/README.md) and
include the licence/commit update in the same PR.
