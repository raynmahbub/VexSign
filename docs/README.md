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
| [Free Apple ID handoff](NATIVE_SIGNING_HANDOFF.md) | You are wiring (or reviewing) the join between native provisioning and the signer — read this before promising a Free Apple ID flow. |
| [Signing and import reliability](changes/native-signing-and-import.md) | You need native execution ownership, input validation, extraction guarantees and their acceptance tests. |
| [Web tools](WEBTOOLS.md) | You are integrating with the browser manager, API or WebDAV. |
| [Source signing](SOURCE_SIGNING.md) | You publish a repository and want signed source metadata. |

## Operate and ship

| Guide | Use it when |
| --- | --- |
| [Validation status](changes/feature-validation-status.md) | You need the source-pinned implementation and acceptance record for the changes it covers. |
| [Streaming backup format](changes/backup-streaming-format.md) | You need backup container framing, compatibility and limits. |
| [Signing code audit](changes/signing-code-audit.md) | You need the signing review's scope and device handoff. |
| [Device acceptance](DEVICE_TESTING.md) | You are validating installation on a physical iPhone/iPad. |
| [Releasing](RELEASING.md) | You are cutting a stable tag, using the nightly pre-release or running a build-only dispatch. |
| [Maintenance](MAINTENANCE.md) | You are reviewing dependency updates, automated issues or repository hygiene. |
| [CI repair assistant](CI_REPAIR_ASSISTANT.md) | You are configuring or reviewing AI-proposed draft PRs for failed CI. |
| [Signer file audit](research/signer-file-audit-2026-11.md) | You need the current in-progress source inventory and file-level review. |
| [Performance and reliability comparison](research/performance-and-reliability-review.md) | You need the 17-project comparison, implemented fixes, remaining gaps, workflow review scope and device checklist. |
| [Public signer integration assessment](research/public-signer-integration-assessment.md) | You need the 2026-11-08 pinned source inventory, feature dispositions, first integration batch and remaining gates. |
| [Signing comparison notes](research/public-signer-comparison.md) | You need the concise public-source comparison, reviewed revisions and licensing context. |
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
- [Anisette protocol mock](../AnisetteServer/README.md)
- [Native signing package](../NativeSigning/README.md)
- [Experimental embedded container](../EmbeddedContainer/README.md)
- [Vendored dependencies and licenses](../Vendor/README.md)
- [Third-party code adaptations](THIRD_PARTY_ADAPTATIONS.md)

## Why separate documents?

The root README is the product overview, not a second operations manual. Build,
release and security details have different audiences and need precise caveats;
collapsing them would hide important limits. Use this index instead of duplicating
instructions. Update the existing authoritative guide before adding a new one.
Keep legal/security/community files at the root for GitHub discoverability.

Older integration and upstream snapshots removed from the working tree remain
available in [Git history at `e122b18`](https://github.com/raynmahbub/VexSign/tree/e122b187e30da2b508fff5588f0919a5f9cfaedf/docs).
Their historical validation results do not establish acceptance of later builds.

Run `make docs-check` for offline file-link validation. It does not check remote
URLs, heading anchors or claims about feature behaviour.

- [Remaining roadmap implementation and acceptance](research/remaining-roadmap-implementation.md) — recovery, preflight, release tracking and validation boundaries.
