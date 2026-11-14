# Repository-wide directory audit

## Scope and result

This is a layout-only follow-up from `9513903b3f9604b8d8ce2d5e78d6eb6c46922c93`.
It retains the preceding platform-root cleanup on the same working branch and
extends the audit to the whole repository, including hidden configuration and
workflow files, integrations, all nine `VexSign/` ownership categories, vendored
packages, Xcode projects/workspaces and legal/public entry points.

Inventory is based on existing tracked files plus new nonignored files:

```bash
git ls-files --cached --others --exclude-standard -z
python3 .github/scripts/quick_check.py --no-swiftc
python3 VexSign/Tools/Validation/architecture-rules/test_repository_layout.py
```

Git internals, ignored dependency installs, caches and generated build output
are not source-layout candidates. Hidden tracked inputs, including the Core
Data current-version file, are included. A single-child wrapper means a parent
with **exactly one immediate child, which is a directory**. A parent with real
sibling files/subfolders is preserved; a directory containing one file is not
a wrapper. Symlinks are not followed to invent additional source ownership.

At the start of this repository-wide pass there were 1,591 files, 397 directories
and 16 single-directory chains, after the four platform moves below. Twelve
project-owned wrappers (58 files) are flattened: 50 files retain identical bytes;
eight change only paths, links or build/test root lookups. All moved Swift and
TypeScript sources, images, patch, license and lock remain byte-identical. After
adding this audit there are 1,592 files, 385 directories and **four retained
tool-owned chains**. All 286 multi-child directory owners retain their immediate
child names after relocation. No project-owned redundant wrapper remains, and
no placeholder siblings were added.

## Before → after

Paths in these two tables are relative to `VexSign/`. A row moves all contents,
including hidden tracked inputs, while preserving file names and modes.

### Platform pass retained on this branch

| Before | After |
| --- | --- |
| `App/iOS/VexSign/` | `App/iOS/` |
| `App/TV/VexSignTV/` | `App/TV/` |
| `App/Vision/VexSignVision/` | `App/Vision/` |
| `App/Extensions/WidgetExtension/` | `App/WidgetExtension/` |

The empty `App/Extensions/` directory is removed. `App/Watch/` still contains
both original targets, and `App/SharedPlatformInfo/` is unchanged.

### Repository-wide pass

These before-paths use the already-flattened iOS platform root from the first pass.

| Before | After |
| --- | --- |
| `App/iOS/Presentation/Features/About/Views/` | `App/iOS/Presentation/Features/About/` |
| `App/iOS/Presentation/Features/Diagnostics/Views/` | `App/iOS/Presentation/Features/Diagnostics/` |
| `App/iOS/Presentation/Features/Onboarding/Views/` | `App/iOS/Presentation/Features/Onboarding/` |
| `App/iOS/Presentation/Features/Updates/Views/` | `App/iOS/Presentation/Features/Updates/` |
| `Packages/AltSourceKit/Sources/AltSourceKit/` | `Packages/AltSourceKit/Sources/` |
| `Services/Cloud/Security/Authentication/` | `Services/Cloud/Security/` |
| `Services/WebManager/Dashboard/Assets/` | `Services/WebManager/Dashboard/` |
| `Resources/Assets/Branding/` | `Resources/Assets/` |
| `Resources/Templates/RepositoryMetadata/` | `Resources/Templates/` |
| `Documentation/Features/Design/` | `Documentation/Features/` |
| `Documentation/Workflows/Distribution/` | `Documentation/Workflows/` |
| `Integrations/EmbeddedContainer/` | `Integrations/` |

Tools, Tests and Configuration were fully inventoried and had no redundant
single-directory wrapper to remove. Their multi-child hierarchy and single-file
leaf owners remain. The same applies to the multi-target NimbleKit source root,
all multi-role app features, NativeSigning, SideSign, the two service owners and
all other multi-child directories.

## Four retained chains

These paths are repository-relative, outside the shorthand used above.

| Parent → only child | Why it is retained |
| --- | --- |
| `VexSign.xcodeproj/project.xcworkspace/xcshareddata/` → `swiftpm/` | Xcode-owned package-resolution metadata location. |
| `VexSign.xcodeproj/xcshareddata/` → `xcschemes/` | Xcode discovers the five unchanged shared schemes here. |
| `VexSign.xcworkspace/xcshareddata/` → `swiftpm/` | Xcode-owned workspace package-resolution metadata location. |
| `VexSign/Packages/Vendor/IDeviceKitten/Sources/` → `IDeviceSwift/` | The vendored manifest uses SwiftPM's default source-target layout. Preserve the upstream snapshot, module identity and attribution rather than relocating third-party internals. |

The quick checker admits only these exact tool-owned parent/child edges; it no
longer exempts arbitrary feature-role, resource, service, vendor or Xcode
subtrees. Its category roots remain stable ownership anchors. An independent
whole-repository regression additionally requires the complete wrapper inventory
to equal these four entries, including any chain under an ownership anchor.
Synthetic negative tests prove the exceptions do not admit extra descendants.

## Consumers and invariants

- Xcode synchronized roots, all four iOS resource-library search paths and
  bridge-relative includes follow the platform move. IDs, targets, products,
  bundle identifiers, scheme contents and target-relative membership exceptions
  are unchanged. Feature views remain under the same synchronized iOS root.
- `AltSourceKit` retains its package/product/target/module names and platforms;
  its manifest adds only `path: "Sources"`. A byte-exact preservation rule and
  positive/negative fixtures reject any accompanying target, dependency or flag
  change. Its seven Swift files retain their bytes.
- Cloud relative TypeScript imports use `Security/security.js`; Docker still
  copies the same `Security/` source owner and launches `dist/API/main.js`.
  WebManager's `/static/icon.png` reads `Dashboard/icon.png`; a response-byte
  regression checks the real PNG. Docker contexts and Render entry points do
  not move.
- Integration build/test root calculations, local patch/overlay/lock lookups,
  Makefile discovery, current setup links, CI triggers/build commands/cache
  inputs and release tooling use the flat integration directory.
- Relative Markdown links are recomputed from both the relocated source and
  destination, including links in moved documentation. README HTML graphics,
  lint/coverage inputs, source-reading fixtures, warning/security/architecture
  path baselines and alias/release scripts follow the actual file owners.
- Root `icon.png`, `app-repo.json`, `repos.json`, `license_plist.yml` and
  `render.yaml` remain byte-identical to their canonical owners. Binary assets,
  license texts, vendored sources, dependency locks and pinned upstream inputs
  are preserved. Only path-valued baseline entries change, not allowed counts.
- The [original migration map](feature-layout-migration-map.json) retains all
  1,375 original paths and before-hashes, as well as its original revision/branch
  provenance. Current destinations and derived added/rewritten inventories are
  refreshed. Old paths in explicitly historical records, negative fixtures and
  this before/after table are evidence, not active filesystem consumers.
- No signing/install engine, security policy, library behavior, credential or
  deployment setting is changed. No build target, bundle, Swift module or scheme
  is renamed. Publication does not establish native/device acceptance; merging,
  releasing and deploying remain separate operations.

## Verification and limits

- `make verify`: passes, including the full-tree layout regression, stricter
  quick checks, Markdown links, aliases, Xcode inputs/membership, package graph,
  localization, security/boundary policies and preparation/packaging fixtures.
- Cloud TypeScript build, 14 tests and contract generation: pass; generated
  OpenAPI content and dependency lock remain unchanged.
- WebManager: 217 tests pass, including the real static-icon response regression;
  no skips after installing the optional test-only certificate parser. One
  upstream Starlette/httpx deprecation warning remains.
- Original-Git preservation and optional tree-sitter Swift grammar comparison:
  pass. Existing grammar findings remain separate from Swift type checking.
- Independent before/after inventories check every moved destination and file
  mode, unchanged multi-child owners, original hashes, protected resources,
  Xcode target/package identities and all five shared schemes.
- `git diff --check`: passes.

This Linux environment has no Xcode, Swift compiler, SwiftLint, SwiftFormat or
Docker. **`make test`, Apple target compilation/XCTest, Swift linters and Docker
image builds were not run.** Portable checks, TypeScript compilation and backend
unit tests do not establish native resource placement, a deployed service,
installation or physical-device acceptance. Historical CI results from other
revisions are not acceptance for this working tree.
