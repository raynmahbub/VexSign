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

No Git submodules or recursive clone is required. The signing engine and
device bridge are vendored under [`Vendor/`](../Vendor/README.md); other
packages resolve through SwiftPM.

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
