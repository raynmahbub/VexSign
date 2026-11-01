# Contributing

VexSign is a modern on-device iOS signer and installer built with SwiftUI and open source components.

Any contributions should follow the [Code of Conduct](./CODE_OF_CONDUCT.md).

## Rules

- **No usage of any exploits of any kind.**
- **No contributions related to retrieving any signing certificates owned by companies.**
- **Modifying any hardcoded links should be discussed before changing.**
- **If you're planning on making a large contribution, please [make an issue](https://github.com/iamsmmh/VexSign/issues) beforehand.**
- **Your contributions should be licensed appropriately.**
  - VexSign: GPLv3
  - AltSourceKit / NimbleKit / Zsign / IDeviceKitten: MIT
  - ElleKit: BSD-3-Clause
- **Typo contributions are okay**, just make sure they are appropriate.
- **Code cleaning contributions are okay.**

## Building from source

#### Requirements

- Xcode 16.0+ (synchronized groups, `objectVersion 77`)
- Swift 6.0
- iOS 16.0 deployment target

1. Clone the repository with submodules:
    ```sh
    git clone https://github.com/iamsmmh/VexSign --recursive
    ```
    - `Zsign` and `IDeviceKitten` are submodules — `--recursive` is required.

2. Create the local-server TLS identity:
    ```sh
    cd VexSign && make deps
    ```
    - Offline, and no key is downloaded: `deps/` gets a self-signed development identity
      generated with `openssl`, and it is kept across builds so a CA profile you trusted once
      stays valid. Trust it on device via *Settings → Installation → Server & SSL → Export Root
      CA Profile*, then enable full trust in *Certificate Trust Settings*.
    - Release builds use the published identity with its digest pinned — `make deps-pin` then
      `make deps-release`; see `docs/RELEASING.md`.

3. Open with Xcode:
    ```sh
    open VexSign.xcworkspace
    ```

#### Signing for development

Set your own team / enable automatic signing in Xcode's target settings, or use the unsigned CLI path (`make`, which builds with `CODE_SIGNING_ALLOWED=NO`).

#### Localizations

- Localizations live in `VexSign/Resources/Localizable.xcstrings` (String Catalog). You need Xcode 15+.
- **Do NOT edit the catalog by hand** — use Xcode's String Catalog editor.
- After localizing, please have another native speaker review your work.

#### Making a pull request

- Keep contributions in their own branch, not `main`.
- Don't be afraid of reviewers requesting changes.
- Every PR is compiled by the `Release` workflow; the resulting unsigned IPA is attached to the run as an artifact if you want to try it on a device.
- PRs also get a one-minute **Quick check** (syntax, duplicates, missing cross-module imports, broken resources), a Debug **Build check**, the **Unit tests** workflow (the `VexSignTests` scheme on a simulator, ~10 minutes with the SwiftPM cache) and automatic **SwiftLint** fixes. Features from related projects are collected by the **Upstream feature radar**; see [docs/AUTOMATION.md](docs/AUTOMATION.md).
- Everything that needs no toolchain runs with one command: `make verify` — the quick check, the localisation catalogue, and the three discipline gates (`tools/error-discipline.py`, `tools/singleton-freeze.py`, `tools/concurrency-discipline.py`). It takes a minute and is exactly what **Quick check** runs, so a green `make verify` means CI's fast job will be green too.
- Run the same tests locally with `make test` (it picks an available iPhone simulator) or `make test SIMULATOR="platform=iOS Simulator,name=<device>"`. A new behaviour is expected to come with a test in `VexSignTests/`; the suite is the reason a change can be trusted without a device. Note that the simulator is resolved at run time by `.github/scripts/select_simulator.py`, so please don't hard-code a device name in a new workflow.
- [docs/TEST_PLAN.md](docs/TEST_PLAN.md) is the order the testing phase runs in: the gates, the suite, and the device checks that no test can stand in for — with what a pass looks like and the known blockers.

## Releasing

Releases are cut by pushing a tag (`vX.Y.Z`, matching `MARKETING_VERSION`); CI builds, verifies and publishes automatically. To try a build from any branch without publishing, run the `Release` workflow manually with `build_only` left ticked. See [docs/RELEASING.md](docs/RELEASING.md).

## Contributing to Zsign

Zsign is maintained upstream at [claration/Zsign-Package](https://github.com/claration/Zsign-Package/tree/package).
