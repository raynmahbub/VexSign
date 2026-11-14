# Documentation

Start with the guide that matches what you are doing. Everything here is
versioned with the code.

## Get started

| Guide | Use it when |
| --- | --- |
| [Build from source](Engineering/BUILD.md) | You want to compile VexSign, run the tests or understand the CI order. |
| [Free Apple ID setup](Security/FREE_APPLE_ID_SETUP.md) | You are signing with a free Apple ID and need the provisioning walkthrough. |
| [Platforms](Engineering/PLATFORMS.md) | You need to know what works on iPhone, iPad, Apple TV, Watch and Vision Pro. |
| [Companion signing](Distribution/COMPANION_SIGNING.md) | You are signing or installing for another device. |

## Understand the system

| Guide | Use it when |
| --- | --- |
| [Architecture](Architecture/ARCHITECTURE.md) | You are changing the app shell, task pipeline, storage or packages. |
| [Dependency rules and diagrams](Architecture/dependency-rules.md) | You need the six-layer dependency direction, owner diagrams, or the drift-ratchet rules. |
| [Component map](Architecture/component-map.json) | You need the machine-readable owner, dependency, concurrency, persistence and test inventory. |
| [Architecture excellence audit](Research/architecture-excellence-audit.md) | You need the initial audit, migration evidence, security/performance findings, limitations and assessment. |
| [Source-guided decisions](Research/source-guided-architecture-decisions.md) | You need pinned upstream evidence for specific feature boundaries and licence notes. |
| [Architecture drift ADR](Engineering/Changes/architecture-excellence-drift-guard.md) | You need the accepted migration decision and gate discipline. |
| [Design](Design/DESIGN.md) | You are adding a screen or component and need the visual and accessibility rules. |
| [Native signing architecture](Architecture/NATIVE_SIGNING_ARCHITECTURE.md) | You are working on the experimental on-device account and provisioning backend. |
| [Free Apple ID handoff](Security/NATIVE_SIGNING_HANDOFF.md) | You are wiring (or reviewing) the join between native provisioning and the signer — read this before promising a Free Apple ID flow. |
| [Signing and import reliability](Engineering/Changes/native-signing-and-import.md) | You need native execution ownership, input validation, extraction guarantees and their acceptance tests. |
| [Web tools](Engineering/WEBTOOLS.md) | You are integrating with the browser manager, API or WebDAV. |
| [Source signing](Architecture/SOURCE_SIGNING.md) | You publish a repository and want signed source metadata. |
| [Distribution architecture and audit](Distribution/architecture.md) | You need the iOS bootstrap/signing feasibility matrix and phased repository map. |
| [iPhone-only bootstrap](Distribution/bootstrap.md) | You need to understand which initial installation routes are actually available. |
| [TestFlight / OTA / signing](Distribution/testflight.md) · [OTA](Distribution/ota.md) · [on-device signing](Distribution/on-device-signing.md) | You are implementing or validating a specific Apple distribution/signing route. |
| [Apple account limitations](Distribution/apple-account-limitations.md) · [security](Distribution/security.md) | You need Personal Team limits, trust boundaries and security requirements. |
| [GitHub Actions / releases / device acceptance](Distribution/github-actions.md) · [release process](Distribution/release-process.md) · [device testing](Distribution/device-testing.md) | You are configuring CI, cutting a release or planning physical-device validation. |
| [Distribution troubleshooting](Distribution/troubleshooting.md) | You need help diagnosing download, profile, signing or installation failures. |

## Operate and ship

| Guide | Use it when |
| --- | --- |
| [Validation status](Engineering/Changes/feature-validation-status.md) | You need the source-pinned implementation and acceptance record for the changes it covers. |
| [Root layout migration](Engineering/Changes/root-layout-migration.md) | You need the original-to-new ownership map, compatibility aliases, portable gates and Xcode/device limitations. |
| [Streaming backup format](Engineering/Changes/backup-streaming-format.md) | You need backup container framing, compatibility and limits. |
| [Signing code audit](Engineering/Changes/signing-code-audit.md) | You need the signing review's scope and device handoff. |
| [Device acceptance](QA/DEVICE_TESTING.md) | You are validating installation on a physical iPhone/iPad. |
| [Releasing](Releases/RELEASING.md) | You are cutting a stable tag, using the nightly pre-release or running a build-only dispatch. |
| [Maintenance](Engineering/MAINTENANCE.md) | You are reviewing dependency updates, automated issues or repository hygiene. |
| [CI repair assistant](Engineering/CI_REPAIR_ASSISTANT.md) | You are configuring or reviewing AI-proposed draft PRs for failed CI. |
| [Signer file audit](Research/signer-file-audit-2026-11.md) | You need the current in-progress source inventory and file-level review. |
| [Performance and reliability comparison](Research/performance-and-reliability-review.md) | You need the 17-project comparison, implemented fixes, remaining gaps, workflow review scope and device checklist. |
| [Public signer integration assessment](Research/public-signer-integration-assessment.md) | You need the 2026-11-08 pinned source inventory, feature dispositions, first integration batch and remaining gates. |
| [Signing comparison notes](Research/public-signer-comparison.md) | You need the concise public-source comparison, reviewed revisions and licensing context. |
| [Security](../SECURITY.md) | You are reporting a vulnerability or reviewing the trust boundaries. |
| [Translation guide](../TRANSLATING.md) | You want to add or review a language in the Xcode String Catalog. |
| [Changelog](../CHANGELOG.md) | You need the user-visible history. |

## Repository conventions

- `make verify` is the fast gate; it must pass on every change.
- New user-facing text needs a `Localizable.xcstrings` entry; `Tools/Development/sync-strings.py --write`
  adds missing English keys.
- New screens use the tokens in `App/iOS/VexSign/Extensions/Theme.swift` and the
  components in `App/iOS/VexSign/DesignSystem/`.
- Third-party source lives in `Packages/Vendor/` with its licence and pinned commit.
  See [Packages/Vendor/README.md](../Packages/Vendor/README.md).

## Component guides

Keep deployment instructions beside the component they describe:

- [Repository server and web tools](../Services/API/server/README.md)
- [Cloud signing service](../Services/CloudSigning/cloud-signing/README.md)
- [Anisette protocol mock](../Services/Anisette/AnisetteServer/README.md)
- [Native signing package](../Packages/NativeSigning/README.md)
- [Experimental embedded container](../Integrations/EmbeddedContainer/README.md)
- [Vendored dependencies and licenses](../Packages/Vendor/README.md)
- [Third-party code adaptations](Security/THIRD_PARTY_ADAPTATIONS.md)

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

- [Remaining roadmap implementation and acceptance](Research/remaining-roadmap-implementation.md) — recovery, preflight, release tracking and validation boundaries.
