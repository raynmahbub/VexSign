# Repository root map

This is the adopted root layout for VexSign. It is the on-disk counterpart of
[`README.md`](README.md); the rules that cannot be expressed in prose are enforced by
`Tools/Validation/architecture-rules/test_repository_layout.py`.

```text
VexSign/                         repository root
├── .github/                     workflows, templates, Dependabot
├── .githooks/                   opt-in local hooks
├── Configuration/               BuildSettings, Entitlements, Signing
├── Documentation/               Architecture, CI, Development, Deployment,
│                                Release, Security, Testing
├── Packages/                    NativeSigning, DeviceBridge, SideSign,
│                                AltSourceKit, NimbleKit, Vendor
├── Platform/                    Extensions/WidgetExtension, TV, Vision, Watch
├── Services/                    deployable backends: Cloud, WebManager, Integrations
├── Tests/                       VexSignTests source root
├── UITests/                     VexSignUITests source root (sibling, never nested)
├── Tools/                       Audit, Build, Fixtures, Release, Scripts, Validation
├── VexSign/                     the single iOS app source root
├── VexSign.xcodeproj/
├── VexSign.xcworkspace/
└── curated root files only      README, Makefile, licences, dotfiles, five aliases
```

## Target-to-root mapping

| Xcode target | Source root | Notes |
| --- | --- | --- |
| `VexSign` | `VexSign/` | The iOS/iPadOS app. `Platform/` holds only the *extra* targets. |
| `VexSignTests` | `Tests/` | Unit, integration, security, performance and fixture support. The folder is **not** renamed to `VexSignTests/`; the target already carries that name. |
| `VexSignUITests` | `UITests/` | Real UI automation target. It stays a sibling of `Tests/` because nested synchronized roots are claimed by more than one target. |
| `VexSignTV` | `Platform/TV/` | Separate entry point and asset catalog. |
| `VexSignVision` | `Platform/Vision/` | Separate entry point and asset catalog. |
| Watch app + widgets | `Platform/Watch/VexSignWatch*`/ | Two separate synchronized roots. |
| Widget extension | `Platform/Extensions/WidgetExtension/` | Separate entry point and asset catalog. |

## Why there is no `Platform/iOS/`

`VexSign/` *is* the iOS target. Creating `Platform/iOS/` would either be an empty
placeholder (forbidden by `test_no_placeholder_or_empty_scaffolding`) or a second
synchronized root for the same code. iPadOS is a destination of the same target, not a
separate folder.

## Why `Tests/` and `UITests/` are siblings

An earlier layout placed UI sources at `Tests/UI`. That produced a nested synchronized
root and broke Xcode target membership. The current arrangement keeps a real
`VexSignUITests` target with its own root at `UITests/`, which CI verifies as
`ui-tests · VexSignUITests (simulator)`. Do not reintroduce `Tests/UI/`,
`VexSignTests/UITests/` or a root `VexSignUITests/` directory.

## Root aliases

Five root files are generated mirrors, not owners. The guard asserts byte equality with
their canonical paths and `Tools/Validation/repository-validation/sync_repo_aliases.py`
refuses drift.

| Alias | Canonical owner |
| --- | --- |
| `icon.png` | `VexSign/Resources/icon.png` |
| `app-repo.json` | `VexSign/Resources/Templates/app-repo.json` |
| `repos.json` | `VexSign/Resources/Templates/repos.json` |
| `license_plist.yml` | `Configuration/Signing/license_plist.yml` |
| `render.yaml` | `Services/WebManager/Configuration/render.yaml` |

No other data or configuration file may be added at the repository root without updating
this map and the root-file contract in the layout guard in the same commit.

## Rejected root shapes

Do not reintroduce these; the layout guard fails on them:

```text
App/  Apple/  DesignSystem/  Networking/  Shared/  Storage/  Resources/
Integrations/  Core/  Infrastructure/  VexSignTests/  VexSignUITests/
Sources/  Platform/iOS/  Tests/UI/  VexSign/App/iOS/
```

The rationale for each boundary lives in
[`adr/0001-production-architecture.md`](adr/0001-production-architecture.md).
