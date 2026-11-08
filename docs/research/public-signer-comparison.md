# Signing comparison notes

Snapshot: 2026-11-08. This reference compares selected public implementations with
VexSign; it is not a runtime audit or a claim of full feature parity.

## VexSign coverage

| Area | Reference apps | VexSign implementation / distinction |
| --- | --- | --- |
| Certificate signing and app customization | Feather, KSign, RyukSign | Typed native requests, bundle customization, preflight, native-result checks and verification before library registration. |
| Batch signing | KSign | Per-app options, request ownership, cancellation and retry handling. |
| Tweak management and file transfer | RyukSign | Tweak specifications, injection/removal and HTTP/WebDAV workspace access. |
| Backup and Files access | FeatherPlus, RyukSign | Selective encrypted backups now optionally include signed/imported app bundles and metadata (chunked file encryption, 8 GiB extraction limit); not unbounded migration or installed-app data. |
| Download records and browsing | MySignReincarnated, MySign | Unified persisted task history and source browsing, with local thumbnails for newly successful imports; existing receipts and failed downloads retain glyph fallback. |
| Pairing packaging | KorSign | Adapted fast compression for pairing payloads when the user selected no compression; export settings remain unchanged. Device benchmarks pending. |
| Safe IPA exports | KorSign | Adapted bounded Unicode filenames and non-overwriting collision handling for local and browser exports; save errors now propagate. |
| Import reliability | KorSign | Bounded-buffer extraction, CRC checks, pause/resume/stop controls and safe output ownership. Performance equivalence has not been measured. |
| Discovery and certificate status | Odysseus | Catalog discovery and consent-based system revocation inspection. Apple ID provisioning remains experimental; implementations are not claimed equivalent. |

## Signing design decisions

- Keep native failures separate from successful signing, and signing separate from confirmed installation.
- Validate custom entitlements and executable paths before native operations.
- Serialize native signing, stdout capture and cache cleanup with cancellation-aware FIFO ownership.
- Retain VexSign’s existing provisioning-flag translation, structural inspection and commit boundaries.
- Do not add signing engines or dependencies solely to match another app’s implementation.

See [native signing and import reliability](../changes/native-signing-and-import.md)
for implementation details, tests and device acceptance requirements.

## Reviewed sources

The links pin the reviewed revisions. KSign is the repository confirmed by the
user. Source paths examined include each app’s signing handler and native wrapper;
additional import, history, backup and certificate modules were reviewed where relevant.

| App | Public repository / reviewed commit | License observed |
| --- | --- | --- |
| Feather | [claration/feather](https://github.com/claration/feather/tree/31ab6de455f2a6108f6830e343dee826310c03be) (`31ab6de455f2a6108f6830e343dee826310c03be`) | GPL-3.0 |
| FeatherPlus | [TomerGamerTV/FeatherPlus](https://github.com/TomerGamerTV/FeatherPlus/tree/9af4713cf6d5c1db3a1f24ddabca53008a46ac5a) (`9af4713cf6d5c1db3a1f24ddabca53008a46ac5a`) | GPL-3.0 |
| RyukSign | [faroukbmiled/RyukSign](https://github.com/faroukbmiled/RyukSign/tree/844466cee6f212291913ba5216f8f19a9c016dea) (`844466cee6f212291913ba5216f8f19a9c016dea`) | GPL-3.0 |
| MySignReincarnated | [gliddd4/MySignReincarnated](https://github.com/gliddd4/MySignReincarnated/tree/c21554d69de8821d6fd3a323371badbeb7d764e0) (`c21554d69de8821d6fd3a323371badbeb7d764e0`) | GPL-3.0 |
| KorSign | [korboybeats/KorSign](https://github.com/korboybeats/KorSign/tree/f20892f43177476ef769b2ac76fc038f87d963ec) (`f20892f43177476ef769b2ac76fc038f87d963ec`) | GPL-3.0 |
| Odysseus | [mirazbakis/Odysseus](https://github.com/mirazbakis/Odysseus/tree/2664dadedf9aca36fda0925a8aada92e2c79323f) (`2664dadedf9aca36fda0925a8aada92e2c79323f`) | GPL-3.0; vendored SideSign is AGPL-3.0 |
| MySign | [gliddd4/MySign](https://github.com/gliddd4/MySign/tree/c5a41629ad5dba5c804438fc3c2f2e6c421d4633) (`c5a41629ad5dba5c804438fc3c2f2e6c421d4633`) | No standard license detected; README says “You can use the code however you want”. No code copied. |
| KSign (confirmed) | [Nyasami/Ksign](https://github.com/Nyasami/Ksign/tree/c14dedc0c9dadb669021cce83435b14f781b8412) (`c14dedc0c9dadb669021cce83435b14f781b8412`) | GPL-3.0 |


## Licensing and attribution

The comparison is reference material, not a replacement for upstream notices.
The signing and import safeguards described above were independently implemented.
The later IPA export naming and collision-handling integration adapts KorSign
source code; its revision, original notice, license and modifications are recorded
in [Third-party code adaptations](../THIRD_PARTY_ADAPTATIONS.md). No signing
binaries or identities were imported. Existing project derivation notices and
dependency attribution remain applicable.

Keep [the project license](../../LICENSE), [ElleKit notices](../../LICENSE_ELLEKIT),
[vendored dependency notices](../../Vendor/README.md), and the licenses shipped
with each package. Public availability alone does not establish permission to
copy code; check the actual license before any future integration.

## OTA queue follow-up

VexSign now overlaps one upcoming OTA archive preparation with the current app's
transfer/verification. Server activation and install prompts remain serial. Private
workspace leases are retained by HTTP response completions and native uploads,
with cooperative cancellation and last-owner cleanup. This is bounded lookahead,
not unrestricted concurrent OTA installs; device performance and lifecycle tests
are still required before claiming parity or a speed improvement.
