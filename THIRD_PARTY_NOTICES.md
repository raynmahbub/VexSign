# Third-party notices and licensing boundaries

This file is an orientation to the license files shipped in this repository,
not legal advice or a substitute for reviewing the complete license text and
specific distribution. Preserve the relevant notices when copying, modifying,
redistributing, or bundling any component. The repository's top-level
[`LICENSE`](LICENSE) remains the primary license for VexSign's covered work;
component licenses apply to their respective code and may impose additional or
different obligations.

## Components with in-repository license files

| Component | License indicated by repository | License text / notice |
| --- | --- | --- |
| VexSign app and repository-level work | GNU GPL version 3.0 (see top-level license and README) | [`LICENSE`](LICENSE) |
| ElleKit-derived / ElleKit-related code | BSD 3-Clause | [`LICENSE_ELLEKIT`](LICENSE_ELLEKIT) |
| `AltSourceKit` | MIT | [`AltSourceKit/LICENSE`](AltSourceKit/LICENSE) |
| `NimbleKit` | MIT | [`NimbleKit/LICENSE`](NimbleKit/LICENSE) |
| `SideSign` | GNU AGPL version 3.0 | [`SideSign/LICENSE`](SideSign/LICENSE) |
| `EmbeddedContainer` sources | GNU AGPL version 3.0 | [`EmbeddedContainer/LICENSE`](EmbeddedContainer/LICENSE) |
| `Vendor/Zsign` | MIT, plus an Apache-2.0 component notice | [`Vendor/Zsign/LICENSE`](Vendor/Zsign/LICENSE), [`Vendor/Zsign/LICENSE_LC`](Vendor/Zsign/LICENSE_LC) |
| `Vendor/IDeviceKitten` | MIT | [`Vendor/IDeviceKitten/LICENSE`](Vendor/IDeviceKitten/LICENSE) |
| Anisette server attribution | See bundled notice for applicable terms | [`VexSign/Resources/AnisetteServers-LICENSE.txt`](VexSign/Resources/AnisetteServers-LICENSE.txt) |

`Vendor/README.md` and `Vendor/manifest.json` identify the vendored upstream
projects, pins, and retained notices. Some package manifests also resolve
external dependencies or binary targets at build time; consult those manifests
and the upstream license files for their terms. This table is not a complete
software bill of materials.

## Distribution considerations

- Do not assume one license in this repository overrides another. The GPL-3.0
  top-level license, BSD/MIT notices, and the AGPL-3.0 licenses for particular
  components each apply according to their scope and the way code is combined
  or distributed.
- GPL and AGPL have source and redistribution obligations. App Store policies,
  platform agreements, and technical distribution requirements may raise
  compatibility questions for a particular bundled build. The presence of an
  Xcode target or a component in this repository does not itself resolve those
  questions; determine which components are compiled or shipped in the artifact
  and obtain qualified legal advice when needed.
- Preserve copyright and license notices, provide corresponding source and
  required license texts where applicable, and review requirements for linked
  libraries and binary dependencies before distributing an IPA or service.
- `LICENSE_ELLEKIT` applies to the ElleKit-related component identified by that
  project; it does not relicense unrelated VexSign code.

When adding or updating third-party code, record the upstream project and exact
revision, retain its license and notices, and update this document and
[`Vendor/README.md`](Vendor/README.md) as appropriate. For a full legal
interpretation, consult counsel familiar with software licensing and Apple
platform distribution.
