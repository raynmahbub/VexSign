# Clean root/source architecture migration

**Status:** implemented and portable-gated on `arena/562440f7-vexsign`; **not** `Build-verified` or `Device-verified`. Prepared for pull-request review; Git publication does not establish build or device verification. No merge, release, tag or deployment is part of this change.

This stage gives the repository clear top-level ownership roots while preserving the Xcode project/workspace, SwiftPM package references, CI/workflow behavior, published compatibility URLs and legal notices. It is a staged filesystem/refactor pass, not a claim that the app builds in Xcode or works on a physical device.

## Ownership roots

| Root | Owns |
| --- | --- |
| `App/` | iOS app, tests, tvOS, visionOS and shared platform-info sources |
| `Extensions/` | widget and watchOS extension sources |
| `Integrations/` | experimental guest-host/LiveContainer integration |
| `Packages/` | SwiftPM packages and vendored dependencies |
| `Resources/` | branding, repository metadata and licensing inputs |
| `Services/` | API, cloud-signing and anisette services |
| `Tools/` | development, architecture, CI and release tooling |
| `Documentation/` | guides, research, QA, security, distribution, releases and DocC |

Root project/legal/published files remain at the root: `VexSign.xcodeproj/`, `VexSign.xcworkspace/`, `Makefile`, `.github/`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, the licence and notice files, and the five compatibility aliases below.

## Original-to-new mapping

The machine-readable record is [root-layout-migration-map.json](root-layout-migration-map.json). It contains the 28 prefix rules, 1,365 file-level original-to-new entries, manual notes, rewritten-file list and the preservation/limitation metadata.

| Measure | Count |
| --- | ---: |
| Inventoried working-tree files | 1,365 |
| Original-to-new path mappings | 1,317 |
| Relocated files | 1,312 |
| Canonical copies with retained root aliases | 5 |
| Intentionally unchanged root files | 48 |
| Text files rewritten for references/links | 219 |
| Relative links rewritten | 182 |
| Path references rewritten | 2,415 |

The five expected manual-snippet warnings are recorded in the map. They were caused by the general rewrite already changing the same lines; they are not unresolved path requirements.

## Compatibility aliases and published URLs

[`Tools/Development/sync_repo_aliases.py`](../../../Tools/Development/sync_repo_aliases.py) keeps these root aliases byte-identical to their canonical copies. `--check` runs locally and in CI; `--write` runs after `update-repo.sh` in the release-listing workflow.

| Canonical copy | Root alias |
| --- | --- |
| `Resources/Branding/icon.png` | `icon.png` |
| `Resources/RepositoryMetadata/app-repo.json` | `app-repo.json` |
| `Resources/RepositoryMetadata/repos.json` | `repos.json` |
| `Resources/Licensing/license_plist.yml` | `license_plist.yml` |
| `Services/API/render.yaml` | `render.yaml` |

Published source and release URLs keep the `raynmahbub/VexSign` repository slug. Historical commit-pinned release-note URLs retain the paths that existed at those commits. A broad stage-1 rewrite briefly inserted an ownership path into some URLs; those were restored, and [`Tools/Architecture/test_repository_layout.py`](../../../Tools/Architecture/test_repository_layout.py) now fails if that pattern returns. `app-repo.json`, `repos.json`, `icon.png`, `license_plist.yml` and `render.yaml` remain root-compatible.

Legal notices are preserved: `LICENSE`, `LICENSE_ELLEKIT`, `THIRD_PARTY_NOTICES.md`, vendored README/licence files, `Resources/Licensing/license_plist.yml` and its root alias. The product-facing README credit was reframed to VexSign ownership without deleting required third-party attribution.

## Xcode, SwiftPM and workflow preservation

- `VexSign.xcodeproj/project.pbxproj` synchronized root groups now point to `App/`, `Extensions/`, and their new subpaths. App/extension plists, entitlements, bridging headers, the companion plist and `Tools/Development/FilePickerFix.m` build-setting paths were rewritten.
- [`Tools/CI/check-pbxproj.py`](../../../Tools/CI/check-pbxproj.py) now validates each `PBXFileSystemSynchronizedBuildFileExceptionSet` relative to the synchronized root group that owns it, plus plist/entitlement/header and `SRCROOT` paths. This checks target-membership exceptions structurally; it does not prove resource-bundle behavior at runtime.
- `VexSign.xcworkspace/contents.xcworkspacedata` and `XCLocalSwiftPackageReference` paths point to the new `Packages/` locations.
- `Packages/NativeSigning/Package.swift` local dependencies are `../Vendor/Zsign`, `../NimbleKit` and `../SideSign`; a layout test resolves every local SwiftPM dependency to a real `Package.swift`.
- CI path filters were broadened for `App/**`, `Extensions/**`, `Integrations/**`, `Packages/**`, `Resources/**`, `Documentation/**` and `Tools/**`; service workflows cover the API, cloud-signing, anisette and render paths. Root compatibility aliases are explicit CI triggers. Existing workflow-policy tests still pass.
- Moved Python tooling/test fixtures had their repository-root calculations corrected for the extra ownership directory. The quick check no longer skips the first-party `server/` or `cloud-signing/` service roots; it still skips generated `node_modules`, `dist` and cache directories.
- `make deploy-server` now uses `Services/API/server` as its Docker build context. A regression test checks that context and both Render blueprints against the moved API files; neither a Docker build nor a live Render deployment has been performed.

## Portable gates after the stage

| Gate | Local result |
| --- | --- |
| `make verify` | exit 0 |
| `python3 .github/scripts/quick_check.py --self-test` and `--no-swiftc` | exit 0 |
| `python3 Tools/CI/check-pbxproj.py` | exit 0; strict group-relative membership exceptions |
| `python3 Tools/CI/check-package-graph.py` | 42 pins agree |
| `python3 Tools/Development/sync_repo_aliases.py --check` | 5 byte-identical aliases |
| `python3 Tools/Development/test_repo_aliases.py` | 3 tests OK |
| `python3 Tools/Architecture/test_repository_layout.py` | 7 tests OK: layout, mapping, URL, SwiftPM, workspace, workflow and deployment paths |
| `PYTHON=/tmp/vexvenv/bin/python make test-server` | 215 passed, 1 skipped |
| `make test-cloud` | 14/14 plus OpenAPI drift clean |
| `python3 -m unittest discover -s Integrations/EmbeddedContainer/tests` | 31 tests OK |
| `python3 -m unittest discover -s Packages/NativeSigning/PythonTests` | 74 tests OK |

These are Linux/Python/Node portable checks. The Swift syntax portion of the quick check was explicitly skipped with `--no-swiftc`; no Swift compilation occurred here.

## Deliberately deferred / honest limitations

- No Xcode build, simulator XCTest, generic unsigned iOS build, physical-device install or fresh current-branch macOS CI run proves the moved tree. The local Linux sandbox has no `swiftc`, Xcode, simulator or iPhone.
- Resource-bundle behavior, target membership and file-system-synchronized groups are structurally validated only; they are not runtime-verified.
- Deeper App source-tree layer refactoring is deferred. Target names, bundle identifiers and product/runtime resource names were not changed.
- There is no universal computer-free initial install. Free Apple Account and LiveContainer paths remain experimental. Real-device acceptance remains **0/14** until physically tested.
- Production CMS wiring, unattended profile renewal and cloud-signing infrastructure remain gated. `SigningMethodCapabilities.nativeAppleAccountSigning` remains `.notIntegrated`.

## Change record

- **PR title:** `refactor(repo): adopt ownership-based layout with migration safeguards`
- **Commit message:** `refactor(repo): migrate sources to ownership-based roots`

The directory migration and its coordinated reference updates belong in one atomic commit. This change is prepared for pull-request review, not for merge, release, tag creation or deployment. Portable gate results are independent of Git publication and do not establish Xcode or device acceptance.
