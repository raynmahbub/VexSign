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
| `AltSourceKit` | MIT | [`VexSign/Packages/AltSourceKit/LICENSE`](VexSign/Packages/AltSourceKit/LICENSE) |
| `NimbleKit` | MIT | [`VexSign/Packages/NimbleKit/LICENSE`](VexSign/Packages/NimbleKit/LICENSE) |
| `SideSign` | GNU AGPL version 3.0 | [`VexSign/Packages/SideSign/LICENSE`](VexSign/Packages/SideSign/LICENSE) |
| `EmbeddedContainer` sources | GNU AGPL version 3.0 | [`VexSign/Integrations/LICENSE`](VexSign/Integrations/LICENSE) |
| `VexSign/Packages/Vendor/Zsign` | MIT, plus an Apache-2.0 component notice | [`VexSign/Packages/Vendor/Zsign/LICENSE`](VexSign/Packages/Vendor/Zsign/LICENSE), [`VexSign/Packages/Vendor/Zsign/LICENSE_LC`](VexSign/Packages/Vendor/Zsign/LICENSE_LC) |
| `VexSign/Packages/Vendor/IDeviceKitten` | MIT | [`VexSign/Packages/Vendor/IDeviceKitten/LICENSE`](VexSign/Packages/Vendor/IDeviceKitten/LICENSE) |
| Anisette server attribution | See bundled notice for applicable terms | [`VexSign/App/iOS/Resources/AnisetteServers-LICENSE.txt`](VexSign/App/iOS/Resources/AnisetteServers-LICENSE.txt) |
| zstd decoder derived from SayoSign (`VexZstd.c`) | GNU GPL version 3.0 (same as this repository) | [`LICENSE`](LICENSE); provenance below |

`VexSign/Packages/Vendor/README.md` and `VexSign/Packages/Vendor/manifest.json` identify the vendored upstream
projects, pins, and retained notices. Some package manifests also resolve
external dependencies or binary targets at build time; consult those manifests
and the upstream license files for their terms. This table is not a complete
software bill of materials.

## zstd decoder (`VexZstd.c`)

`VexSign/App/iOS/Infrastructure/Archives/Extraction/Zstd/VexZstd.c` is derived from SayoSign's
`core/src/zstd.c` (`murk-sus/SayoSign`, GPL-3.0, file last changed in commit
`f250ff324f7b7cad7bb87a33fa9ebc38c837aa8d`). It is GPL-3.0 code used in a GPL-3.0 repository, so
no additional licence obligation is introduced beyond the top-level `LICENSE`; the attribution
stays here and in the file header.

What changed in the copy: the decoder algorithm is upstream; the surrounding boundary is not.
The adapted file adds a caller-supplied output ceiling (bomb guard, also checked against the
frame's declared content size), verifies the 4-byte XXH64 frame checksum that upstream skipped,
checks `malloc` results, and keeps its buffer/error helpers private so nothing collides with the
app's other C sources. Its tests are `ZstdDecompressionTests`, whose fixtures are produced by the
reference `zstandard` implementation rather than by the code under test.

## Device bootstrap/pairing foundation

The IDeviceKitten wrapper remains pinned to
`claration/IDeviceKit` commit `837cf1e14d4875771dd5ee1b754a4c86215c5db3` with its
MIT license intact. Its six modified upstream Swift files and nine local additions
are identified by SHA-256 in the vendor manifest; see the
[local source/ownership review](VexSign/Packages/Vendor/IDeviceKitten/LOCAL_PATCH_REVIEW.md).
The unchanged `IDevice` binary target is `jkcoxson/idevice` v0.1.57. Its source
metadata declares MIT, but that is **not** an established transitive binary-license
closure or binary ABI review. Review linked components and retain their notices
before distribution. The wrapper is not LGPL; separately licensed
libimobiledevice-family tools must not be conflated with this wrapper.

SideInstaller was consulted only through its public README, technical notes and
license at `82452dfd2a575b5a031145de2b22b98d4b7b3a76`. No implementation, binary,
asset or protocol patch was copied or bundled. Its restrictive non-commercial /
source-only terms are not treated as a reusable GPL dependency. LocalDevVPN is an
optional external, user-installed and user-activated prerequisite, not bundled
code; its source/license closure was not accepted by this work. Existing SideSign,
Zsign and account/signing dependency boundaries are unchanged.

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
[`VexSign/Packages/Vendor/README.md`](VexSign/Packages/Vendor/README.md) as appropriate. For a full legal
interpretation, consult counsel familiar with software licensing and Apple
platform distribution.
