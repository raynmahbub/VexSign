# Signer file review — November 2026

Snapshot: 2026-11-10. This is an **in-progress** file-by-file review, not a
claim of feature parity, a complete security audit, or device validation. The
older [selected-module assessment](public-signer-integration-assessment.md)
remains useful; this pass rechecks the requested repositories' default branches.

## Inventory

The GitHub API returned complete recursive trees (not truncated). “Code files”
counts `.swift`, `.m`, `.mm`, `.h`, `.c` and `.cpp` blobs, including vendored
files where present; it is an inventory, not a count of files read or audited.
License values are GitHub metadata, not a compatibility opinion on every file or
submodule. Each revision below is immutable.

| Repository | Revision | License metadata | All blobs | Code files |
| --- | --- | --- | ---: | ---: |
| [Feather](https://github.com/claration/feather/tree/31ab6de455f2a6108f6830e343dee826310c03be) | `31ab6de455f2a6108f6830e343dee826310c03be` | GPL-3.0 | 223 | 154 |
| [FeatherPlus](https://github.com/TomerGamerTV/FeatherPlus/tree/9af4713cf6d5c1db3a1f24ddabca53008a46ac5a) | `9af4713cf6d5c1db3a1f24ddabca53008a46ac5a` | GPL-3.0 | 228 | 155 |
| [Ksign](https://github.com/Nyasami/Ksign/tree/c14dedc0c9dadb669021cce83435b14f781b8412) | `c14dedc0c9dadb669021cce83435b14f781b8412` | GPL-3.0 | 251 | 192 |
| [RyukSign](https://github.com/faroukbmiled/RyukSign/tree/dc5671793b53d19b98f32d96a20662840400c191) | `dc5671793b53d19b98f32d96a20662840400c191` | GPL-3.0 | 364 | 281 |
| [MySignReincarnated](https://github.com/gliddd4/MySignReincarnated/tree/c21554d69de8821d6fd3a323371badbeb7d764e0) | `c21554d69de8821d6fd3a323371badbeb7d764e0` | GPL-3.0 | 389 | 303 |
| [MySign](https://github.com/gliddd4/MySign/tree/c5a41629ad5dba5c804438fc3c2f2e6c421d4633) | `c5a41629ad5dba5c804438fc3c2f2e6c421d4633` | No standard license detected | 339 | 228 |
| [BatSign](https://github.com/8yy/BatSign/tree/d60dbee57228e74d4502c24ff825f154fa33c45b) | `d60dbee57228e74d4502c24ff825f154fa33c45b` | GPL-3.0 | 248 | 197 |
| [Odysseus](https://github.com/mirazbakis/Odysseus/tree/2664dadedf9aca36fda0925a8aada92e2c79323f) | `2664dadedf9aca36fda0925a8aada92e2c79323f` | GPL-3.0 | 287 | 214 |
| [SideStore](https://github.com/SideStore/SideStore/tree/4f3d18d98c5fbee72c80f787ceb2e8e09ded60a6) | `4f3d18d98c5fbee72c80f787ceb2e8e09ded60a6` | AGPL-3.0 | 665 | 410 |
| [LiveContainer](https://github.com/LiveContainer/LiveContainer/tree/9d6ea09b05afa2c8fc537c372795a294db631311) | `9d6ea09b05afa2c8fc537c372795a294db631311` | AGPL-3.0 | 264 | 147 |

RyukSign advanced one commit from the earlier snapshot: GitHub's compare API
reports only `repos.json` changed. All other listed default-branch revisions
match the earlier selected-module inventory. No recommendation list was imported
without a separate review of those URLs.

## First file-level batch: Debian tweak archives

The following files were read for this batch; the upstream file names below are
relative to RyukSign at the pinned revision, not a claim about the whole project.

| Upstream file | VexSign counterpart | Finding and disposition |
| --- | --- | --- |
| `RyukSign/Utilities/Handlers/TweakAnalyzer.swift` | `App/iOS/VexSign/Utilities/Handlers/TweakAnalyzer.swift` | Both analysis paths write ar members by their names. VexSign's existing logging differs; neither file established name containment. |
| `RyukSign/Utilities/Handlers/TweakHandler.swift` | `App/iOS/VexSign/Utilities/Handlers/TweakHandler.swift` | Both materialize ar members for tweak injection. Central validation is necessary because there are two consumers. |
| `RyukSign/Utilities/ARDecompression/AR.swift` | `App/iOS/VexSign/Utilities/ARDecompression/AR.swift` | VexSign's reader had length checks but accepted path-bearing names and duplicates. It now rejects unsafe names and case-insensitive duplicates and recognizes the conventional trailing slash on short ar names. The size comparison avoids adding an untrusted length to an offset. |
| — | `App/Tests/VexSignTests/ARArchiveSafetyTests.swift` | New parser tests cover ordinary names, ar terminators, traversal, duplicate names and a truncated member. They have not been run under XCTest here. |

The parser changes are VexSign changes, not a source-code import from the
reference repository. Long-name ar tables and BSD extended names are not
implemented; path-like or unsupported names are rejected. This batch does not
prove that the full `.deb` pipeline is safe against decompression bombs or that
injected tweaks work on a device. Follow-up reviews should inspect the archive
compression/extraction and install paths independently before claiming that.

## Remaining work and evidence

The other files in these ten trees have **not** been audited in this batch.
Continue by comparing related files in small workflow groups, record concrete
VexSign counterparts and gaps, and add tests for each change. Do not import
unlicensed MySign source; review AGPL obligations before adopting SideStore or
LiveContainer code. Existing native Apple-account and guest-host paths remain
experimental; upstream source presence is not proof they work in VexSign.

The repository's portable verification does not run XCTest or build an iOS
application. An Apple SDK build, XCTest, and physical-device acceptance remain
separate gates.
