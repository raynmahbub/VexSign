# Build VexSign

VexSign is a native Xcode workspace. The fast checks run anywhere Python and
Git are available; the app and simulator tests need macOS with Xcode.

## Requirements

| | |
| --- | --- |
| OS | macOS 15 or later for the current SDK |
| Xcode | A current Xcode supported by the project. The app uses iOS 26 SDK APIs, so Xcode 16 cannot build the default branch. |
| Deployment target | iOS 16.0 and later |
| Tools | `git`, `make`, Python 3, and the Xcode command-line tools |
| Optional | `swiftlint` for `make lint`; Docker for `make deploy-server` |

A plain clone is enough. The signing engine and device bridge are vendored
under [`Vendor/`](../Vendor/README.md); other packages resolve through SwiftPM.

## 1. Clone

```bash
git clone https://github.com/raynmahbub/VexSign.git
cd VexSign
```

## 2. Bootstrap

```bash
make bootstrap
```

This checks that you are on macOS, that `xcodebuild` exists, that the two
vendored package manifests are present, prints the Xcode version, and resolves
the Swift package graph. `make bootstrap` does not build or launch the app.

If package resolution reports a network error, note that
`Vendor/IDeviceKitten/Package.swift` declares an upstream `IDevice` binary
target. Xcode downloads that xcframework once and caches it. The remaining
SwiftPM packages resolve from their upstreams and are cached by Xcode.

## 3. Open and run

```bash
open VexSign.xcworkspace
```

1. Select the `VexSign` scheme.
2. Choose your development team in **Signing & Capabilities**.
3. Pick a device or simulator.
4. Build and run.

The app requires a signing identity only for the signing features, not to
launch. Some install paths need a paired device, a provisioning profile or a
local network connection; see [Platforms](PLATFORMS.md).

## 4. Verify and test

```bash
make verify      # fast, Xcode-independent gates
make             # unsigned IPA in packages/
make test        # simulator tests
```

`make verify` is the same quick gate CI runs: project structure, localisation,
error discipline, singleton and concurrency policy, workflow policy,
embedded-container tests and native-signing preparation tests.

`make test` auto-selects an available iPhone simulator. To pin one:

```bash
make test SIMULATOR="platform=iOS Simulator,name=iPhone 16"
```

## Build order in CI

```text
push to main
   │
   ├── quick  (Linux/Python checks)  ── required
   │       │
   │       ├── build  (unsigned iOS device build)
   │       └── tests  (simulator tests)
   │
   └── platform-check (manual or relevant changes: tvOS, visionOS, watchOS)
```

- `quick` runs first; `build` and `tests` run concurrently after it.
- `platform-check` is a separate workflow because it compiles the companion
  targets and is intentionally not a per-PR cost.
- `release` builds and publishes on a tag, or by a manual build-only dispatch.
- Component workflows (server, cloud signer, embedded container) run only when
  their paths change.

The machine-readable rules live in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) and
[`tools/test_workflow_policy.py`](../tools/test_workflow_policy.py).

## Command reference

| Command | Purpose |
| --- | --- |
| `make bootstrap` | Validate the toolchain and resolve packages. |
| `make` | Build `packages/VexSign.ipa` unsigned. |
| `make clean` | Remove build products and staging directories. |
| `make verify` | Run the fast repository and policy gates. |
| `make test` | Run simulator tests. |
| `make lint` | Run SwiftLint if installed. `make lint FIX=1` auto-corrects. |
| `make strict-concurrency` | Report Swift 6 concurrency warnings in the local packages. |
| `make deploy-server` | Build the optional Python repository server image. |

## Troubleshooting

### `xcodebuild: error: tool 'xcodebuild' requires Xcode`

Install Xcode, then select it:

```bash
sudo xcode-select --switch /Applications/Xcode.app
sudo xcodebuild -license accept
```

### Package resolution fails

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/VexSign-*
make bootstrap
```

If only the `IDevice` binary target fails, check network access to GitHub
releases or warm the Xcode package cache on a machine that can reach it.

### No iPhone simulator

Install a simulator runtime in **Xcode → Settings → Components**, or pass an
explicit `SIMULATOR=` destination to `make test`.

### The app builds but signing fails

Signing failures usually come from the identity, profile scope, entitlements or
an expired/revoked certificate. Check **Settings → Certificates** and
[Free Apple ID setup](FREE_APPLE_ID_SETUP.md) before changing build settings.

### Linux or a bare CI shell

`make verify` works without Xcode. `make` and `make test` do not; they require
macOS and a full Xcode installation.

## Updating vendored packages

See [`Vendor/README.md`](../Vendor/README.md). The pinned commits, upstream
repositories and licence files are recorded in
[`Vendor/manifest.json`](../Vendor/manifest.json).


## Optional service validation

Component workflows run automatically for matching PRs and main pushes; unrelated
app changes do not trigger the server or cloud suites. You can also dispatch them
manually. Reproduce their core checks locally:

```bash
# Python: use a virtual environment; CI uses Python 3.12.
python3 -m venv server/.venv
. server/.venv/bin/activate
python -m pip install -r server/requirements.txt pytest cryptography
make test-server

# Cloud: Node 22; npm ci respects the committed lockfile.
(cd cloud-signing && npm ci)
make test-cloud
```

Cloud checks compile TypeScript, run tests and regenerate the OpenAPI contract;
contract drift fails the command and leaves a diff to review. These checks do not
prove a deployed PostgreSQL/Redis/object-store/signing-worker installation works.


## Repository layout and early error checks

`Tweaks/FilePickerFix.m` is the source of the injected picker-fix dylib. Its Xcode
build phase declares the same path as a source input; keep both references in sync
when moving it. Native-signing Python preparation tests live in
`NativeSigning/PythonTests/`, separate from Swift `Tests/` to avoid case-insensitive
macOS filesystem collisions.

`make verify` and the existing CI quick checker now reject unnecessary single-child
folder chains, case/Unicode-normalised path collisions, hidden path whitespace,
missing declared Xcode source inputs and Python/shell syntax errors. Python checks
compile syntax without importing/running code; shell checks use `bash -n`.
Generated/untracked ignored trees are not inventoried. The checker includes its
own offline regressions (`quick_check.py --self-test`), with no extra workflow.

SwiftPM `Sources/<target>`, Xcode workspace/project metadata and pinned `Vendor/`
layouts are intentional exceptions: GitHub may still compact those in its browser.
Do not flatten required tool layouts or add placeholder files just to hide arrows.
Swift syntax parsing remains in CI's Swift container; full SDK builds, simulator
results and [physical-device acceptance](DEVICE_TESTING.md) remain separate gates.
No static check can guarantee a perfect build on every Xcode/device combination.


Developer entry points are grouped in `tools/`: `bootstrap.sh`, `device-smoke.sh`,
`update-repo.sh`, verification tools and their tests. Prefer `make help` for the
supported commands; no generated files or placeholder directory markers belong
in these folders. Presentation graphics belong in `docs/assets/`. Root `icon.png`
and repository feeds are retained as published compatibility URLs; `render.yaml`
and `license_plist.yml` remain where their consumers discover them.

## Download a temporary CI IPA

Run **Actions → CI → Run workflow → validation: full** on the branch you want to
check, or use a relevant PR/main CI run. After the device build and warning gate
succeed, the build job reuses its `Debug-iphoneos/VexSign.app` to produce an
unsigned IPA—there is no extra Release build or publication.

The run summary contains a download link. Under **Artifacts**, select
`VexSign-unsigned-<commit>-<run>-<attempt>`. The ZIP contains the IPA, `BUILD.json`
(commit, version and run metadata) and `SHA256SUMS`. New IPA artifacts expire after 14
days; existing uploads keep their original expiry. Verify the checksum and re-sign before device installation. This is a
Debug build for testing, not a production release or Apple-authorized install.

The simulator-test job runs separately: it may still be running or may fail even
when the build artifact exists. Check the entire run before calling a commit
green. Quick-only validation skips both the build and artifact; compilation or
warning-gate failures do not produce an IPA. No signing secrets or release
permissions are added to CI. New artifacts require running the updated workflow;
unpushed edits cannot be built by GitHub Actions.


### Experimental combined host test build

The separate **Guest-host prototype · build only** workflow packages a
LiveContainer host with embedded SideStore and a bundled VexSign guest. It is
manual-only and does not replace ordinary VexSign releases or implement the final
VexSign-primary architecture. New combined test artifacts retain for **14 days**;
logs retain for **3 days**. The artifact contains the IPA, integration sources,
`.build.json` metadata and `.checksums.txt`. Follow the
[combined-build instructions](../EmbeddedContainer/README.md) for re-signing,
first-run setup and physical-device acceptance. A successful build or an
**Imported guest** badge does not prove a device installation, guest launch,
Apple login or renewal.

### Home navigation and search

The default tab order is **Library · App Store · Home · Activity · Settings**,
placing Home in the middle without changing persisted tab identifiers or launch
preferences. Home's **Search VexSign** opens query buttons for Library,
Apps & Sources, and Settings. The query is handed to the destination's existing
search, including when that page has not mounted yet. Search does not enumerate
hidden apps outside those pages or bypass app locks.

When the embedded combined runtime is loaded, Home also shows the existing
process-local LiveContainer and SideStore switch controls. They require explicit
confirmation and no active tasks because switching closes the current guest
session. These controls are not external-app launchers and do not make the normal
VexSign IPA a combined native host.
