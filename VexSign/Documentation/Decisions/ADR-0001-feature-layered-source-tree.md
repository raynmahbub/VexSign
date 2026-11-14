# ADR-0001: one main source root, feature-oriented iOS layers

- **Date:** 2026-11-13
- **Status:** accepted for source organization and explicit-boundary migration;
  native/device acceptance remains separate.
- **Specification:** [requested architecture](https://chatgpt.com/s/t_6af8130278148191bc92dd1663a4f27b)
- **Baseline:** `57d3aa65b0228071fa0d2589c232a00b5517ece2`

## Context

The earlier ownership-root migration retained separate App, Packages, Services,
Resources, Documentation, Tools, Extensions and Integrations roots. The requested
architecture instead needs one main `VexSign/` source tree and a feature-oriented
iOS app with explicit App/Presentation/Application/Domain/Infrastructure/Platform/
Security/Resources owners. A directory rename alone cannot establish dependency
inversion or native acceptance.

The inventory contains 1,375 original files and seven existing Xcode targets.
The project uses file-system-synchronized groups, local and pinned remote Swift
packages, runtime bundle lookups, optional Python/TypeScript services and public
root compatibility files. Those are compatibility constraints, not disposable
folders.

## Decision

1. Keep `.git/`, `.github/`, the existing Xcode project/workspace, root build/tool
   entry points and contributor/legal documents where their tools expect them.
   Preserve five published root aliases and all historical feed URLs.
2. Relocate source/project content under `VexSign/`, with complete original-to-new
   [inventory and before hashes](../Architecture/feature-layout-migration-map.json).
   Preserve companion targets and the real experimental host integration.
3. Organize iOS Presentation by populated feature/role; do not create empty
   use-case folders, example packages or fake test suites to imitate the diagram.
4. Make Domain and Application Foundation-only. Extract concrete provider,
   installation, file coordination, probe and signing-engine details behind
   consumed ports. Keep one existing signing/task/install/registry implementation.
5. Retain the legacy UIKit/Core Data signing request outside Domain. A generic
   `SigningWork` contract permits the Application event policy to be tested
   without manufacturing a second signing model or copying the pipeline.
6. Move actual configuration inputs and preserve target memberships/exceptions,
   resolved pins, build scripts, header includes, service entry points, package
   identities and licenses. Shared xcconfig extraction retains original values.
7. Expand architecture scans to all Presentation and verify initial baseline
   matches against original source bytes. Migrate guarded coupling through
   consumed feature ports while retaining the initial review/history. Do not
   accept new coupling or invent duplicate lifecycle engines to fit the tree.
8. Treat signed artifacts, guest import, installation submission and verified
   installation as distinct states. Do not promote experimental device/account
   capability based on folder organization or a portable test pass.

## Consequences

- New feature code has a clear owner and an enforced inward dependency rule.
- Existing package/service/native integration boundaries and published URLs work
  independently of the folder organization.
- App-level source boundaries are enforced by validation rather than artificial
  Swift modules. Package extraction remains a later evidence-based decision.
- The follow-up consumed-boundary work removes all currently guarded Core Data,
  direct I/O and engine-owner Presentation matches. Original debt/review lists
  remain historical evidence; a zero source ratchet is not exhaustive decoupling
  or native behavioral acceptance.
- Xcode compilation/resource placement, XCTest, simulator and physical-device
  operation must be validated separately on the appropriate toolchain/hardware.
- No release, deployment, capability promotion or credential change is implied.

See the [migration and validation record](../Architecture/feature-layout-migration.md),
[current architecture](../Architecture/ARCHITECTURE.md) and
[dependency rules](../Architecture/dependency-rules.md).
