<div align="center">
  <img src="logo.svg" alt="VexSign logo" width="120">

  # VexSign

  **Sign, customize, and install IPAs on your Apple devices.**

  [![Release](https://img.shields.io/github/v/release/raynmahbub/VexSign)](https://github.com/raynmahbub/VexSign/releases)
  [![CI](https://github.com/raynmahbub/VexSign/actions/workflows/ci.yml/badge.svg)](https://github.com/raynmahbub/VexSign/actions/workflows/ci.yml)
  [![License](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)
</div>

## Features

- **On-device signing:** import `.p12` certificates and provisioning profiles, sign with Zsign, verify output, and install locally.
- **IPA tools:** edit bundle details and entitlements, inject tweaks, thin Mach-O binaries, clone apps, and explore archives.
- **Library and sources:** manage signed apps, AltStore-compatible repositories, downloads, updates, backups, and cleanup.
- **Automation:** batch jobs, signing presets, Shortcuts, widgets, Live Activities, and per-app update rules.
- **Web Manager:** authenticated HTTP/WebDAV transfers plus a companion API.
- **Companion apps:** tvOS, visionOS, watchOS, and widgets.

> Requires iOS 16 or later and a valid signing identity. Installation methods and entitlements depend on your device, certificate, and provisioning profile. Native Apple ID provisioning and the guest-host container remain experimental; they are not represented as production-ready.

## Install

Download the latest IPA from [Releases](https://github.com/raynmahbub/VexSign/releases), or add the AltStore-compatible source:

```text
https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json
```

See [Free Apple ID setup](docs/FREE_APPLE_ID_SETUP.md), [companion signing](docs/COMPANION_SIGNING.md), and [platform support](docs/PLATFORMS.md) for the relevant limitations.

## Build

Requirements: macOS, a current Xcode version supported by the project, and Git submodules.

```bash
git clone --recursive https://github.com/raynmahbub/VexSign.git
cd VexSign
open VexSign.xcworkspace
```

Select your development team in Xcode. The command-line build is unsigned:

```bash
make                 # packages/VexSign.ipa; sign before installation
make verify          # fast repository, resource, and policy checks
make test            # simulator tests; auto-selects an available iPhone
make lint            # optional local SwiftLint check
```

CI runs fast checks first, then the unsigned build and simulator tests in parallel. Component workflows cover the Python server, TypeScript cloud signer, and companion targets only when their files change. See [Releasing](docs/RELEASING.md) for tagged builds and manual build-only runs.

## Repository map

| Path | Purpose |
| --- | --- |
| `VexSign/`, `VexSignTests/` | iOS app and simulator tests |
| `NativeSigning/` | Experimental native account/provisioning package |
| `AltSourceKit/`, `NimbleKit/` | Source parsing and shared Swift utilities |
| `VexSignTV/`, `VexSignVision/`, `VexSignWatch/` | Companion apps |
| `server/` | Python backend and browser tools |
| `cloud-signing/` | TypeScript cloud-signing service |
| `EmbeddedContainer/` | Experimental guest-host packaging |

Additional guides: [native signing architecture](docs/NATIVE_SIGNING_ARCHITECTURE.md), [web tools](docs/WEBTOOLS.md), and [changelog](CHANGELOG.md).

## Contribute

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Keep changes focused, add regression coverage, and run `make verify` plus the affected tests before submitting a pull request.

## Acknowledgments

Built on [Feather](https://github.com/claration/Feather). VexSign also uses [Zsign](https://github.com/zhlynn/zsign), [idevice](https://github.com/jkcoxson/idevice), [ElleKit](https://github.com/everythingappletech/ElleKit), Vapor, Nuke, ZIPFoundation, and other open-source projects. See the bundled license notices.

VexSign is not affiliated with Apple. Use sideloading tools in accordance with applicable terms and laws.
