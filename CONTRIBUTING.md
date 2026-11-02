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

2. Enter the checkout (`cd VexSign`). No certificate-pack endpoint, TLS pin or
   build-time identity is needed. The app generates and preserves its own CA on
   the device. For local HTTPS installs, export/install its CA profile and enable
   Full Trust. See [release and device trust setup](docs/RELEASING.md).

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
- **No automatic PR validation.** Relevant pushes to `main` run path-filtered checks once, after merge. Before merging app changes, manually dispatch **CI → full** on the PR's head branch and review the result for the exact commit being merged. **quick** runs Linux gates only, not compilation or simulator tests.
- Manually run **Platform check**, **Server tests**, or **Ecosystem contracts** for affected components; their automatic runs are scoped to relevant `main` changes. The cloud dependency audit also runs weekly. **Release** stays tag/manual-only. SwiftLint is local (`make lint`), not a bot committing fixes.
- Run `make verify` for the repository quick check, localisation catalogue, three discipline gates and workflow-trigger policy regression tests. `make verify` skips Swift parsing; CI also parses Swift syntax with a Swift toolchain. macOS/Xcode is needed for native builds and simulator tests.
- **Branch protection migration:** old required PR checks must be removed or replaced in repository settings before merging, or PRs can remain blocked. Manual branch runs are review evidence, not a guaranteed substitute for PR/merge-queue required checks. See [automation policy](docs/AUTOMATION.md).
- Run the same tests locally with `make test` (it picks an available iPhone simulator) or `make test SIMULATOR="platform=iOS Simulator,name=<device>"`. A new behaviour is expected to come with a test in `VexSignTests/`; the suite is the reason a change can be trusted without a device. Note that the simulator is resolved at run time by `.github/scripts/select_simulator.py`, so please don't hard-code a device name in a new workflow.
- [docs/TEST_PLAN.md](docs/TEST_PLAN.md) is the order the testing phase runs in: the gates, the suite, and the device checks that no test can stand in for — with what a pass looks like and the known blockers.

## Releasing

Releases are cut by pushing a tag (`vX.Y.Z`, matching `MARKETING_VERSION`); CI builds, verifies and publishes automatically. To try a build from any branch without publishing, run the `Release` workflow manually with `build_only` checked. See [docs/RELEASING.md](docs/RELEASING.md).

## Contributing to Zsign

Zsign is maintained upstream at [claration/Zsign-Package](https://github.com/claration/Zsign-Package/tree/package).
