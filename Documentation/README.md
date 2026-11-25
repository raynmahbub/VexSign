# VexSign documentation

[Project overview](../README.md) · [Contributing](../CONTRIBUTING.md) · [Security policy](../SECURITY.md)

## Guides

| Guide | Use it for |
| --- | --- |
| [Architecture](Architecture/README.md) | Source ownership, feature boundaries and dependency composition |

Other guides were removed. Use `make help`, `README.md`, `CONTRIBUTING.md`,
`SECURITY.md` and `.github/workflows/` for the retained operating instructions.

## Working from the root

- Open `VexSign.xcworkspace` in Xcode for app development.
- Run `make help` to discover supported commands.
- Run `make verify` for portable repository checks. Inspect warnings: without a
  Swift toolchain, syntax checking is skipped. Portable success does not prove
  an iOS build or physical-device acceptance.
- Run `make bootstrap` and `make test` on a compatible macOS/Xcode installation
  to resolve dependencies and execute simulator tests.
- Keep app workflows in `VexSign/Services/`; independently deployed backends
  belong in the repository-level `Services/` directory.
- Keep generated build output, local databases and signing material out of Git.
  Never include credentials in documentation, logs or issues.

## Root compatibility files

These root paths are intentional public entry points, not competing sources of
truth. Preserve their names for existing consumers.

| Root alias | Canonical file to edit |
| --- | --- |
| `icon.png` | [App icon](../VexSign/Resources/icon.png) |
| `app-repo.json` | [App repository template](../VexSign/Resources/Templates/app-repo.json) |
| `repos.json` | [Repository catalog template](../VexSign/Resources/Templates/repos.json) |
| `license_plist.yml` | [LicensePlist configuration](../Configuration/Signing/license_plist.yml) |
| `render.yaml` | [WebManager deployment configuration](../Services/WebManager/Configuration/render.yaml) |

After editing a canonical file, synchronize and validate its root copy:

```bash
python3 Tools/Validation/repository-validation/sync_repo_aliases.py --write
python3 Tools/Validation/repository-validation/sync_repo_aliases.py --check
```

The same tool checks the project and workspace dependency lockfiles for drift.
Keep both entry points consistent when intentionally updating dependencies.
