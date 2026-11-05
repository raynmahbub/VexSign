# Documentation

Start with the guide that matches what you are doing. Everything here is
versioned with the code.

## Get started

| Guide | Use it when |
| --- | --- |
| [Build from source](BUILD.md) | You want to compile VexSign, run the tests or understand the CI order. |
| [Free Apple ID setup](FREE_APPLE_ID_SETUP.md) | You are signing with a free Apple ID and need the provisioning walkthrough. |
| [Platforms](PLATFORMS.md) | You need to know what works on iPhone, iPad, Apple TV, Watch and Vision Pro. |
| [Companion signing](COMPANION_SIGNING.md) | You are signing or installing for another device. |

## Understand the system

| Guide | Use it when |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | You are changing the app shell, task pipeline, storage or packages. |
| [Design](DESIGN.md) | You are adding a screen or component and need the visual and accessibility rules. |
| [Native signing architecture](NATIVE_SIGNING_ARCHITECTURE.md) | You are working on the experimental on-device account and provisioning backend. |
| [Web tools](WEBTOOLS.md) | You are integrating with the browser manager, API or WebDAV. |
| [Source signing](SOURCE_SIGNING.md) | You publish a repository and want signed source metadata. |

## Operate and ship

| Guide | Use it when |
| --- | --- |
| [Device acceptance](DEVICE_TESTING.md) | You are validating installation on a physical iPhone/iPad. |
| [Releasing](RELEASING.md) | You are cutting a stable tag, using the nightly pre-release or running a build-only dispatch. |
| [Maintenance](MAINTENANCE.md) | You are reviewing dependency updates, automated issues or repository hygiene. |
| [Security](../SECURITY.md) | You are reporting a vulnerability or reviewing the trust boundaries. |
| [Changelog](../CHANGELOG.md) | You need the user-visible history. |

## Repository conventions

- `make verify` is the fast gate; it must pass on every change.
- New user-facing text needs a `Localizable.xcstrings` entry; `tools/sync-strings.py --write`
  adds missing English keys.
- New screens use the tokens in `VexSign/Extensions/Theme.swift` and the
  components in `VexSign/DesignSystem/`.
- Third-party source lives in `Vendor/` with its licence and pinned commit.
  See [Vendor/README.md](../Vendor/README.md).

## Component guides

Keep deployment instructions beside the component they describe:

- [Repository server and web tools](../server/README.md)
- [Cloud signing service](../cloud-signing/README.md)
- [Anisette service](../AnisetteServer/README.md)
- [Native signing package](../NativeSigning/README.md)
- [Experimental embedded container](../EmbeddedContainer/README.md)
- [Vendored dependencies and licenses](../Vendor/README.md)

## Why separate documents?

The root README is the product overview, not a second operations manual. Build,
release and security details have different audiences and need precise caveats;
collapsing them would hide important limits. Use this index instead of duplicating
instructions. Update the existing authoritative guide before adding a new one.
Keep legal/security/community files at the root for GitHub discoverability.

Run `make docs-check` for offline file-link validation. It does not check remote
URLs, heading anchors or claims about feature behaviour.
