# Remaining roadmap implementation and acceptance handoff

**Latest Apple validation:** the full CI run for app/test-source commit
`3ae30e2643adc918797207eeb58fc71a6e63f737` passed repository gates, the macOS
unsigned app build/IPA checks, and the simulator XCTest suite:
[CI run 42602611745](https://github.com/raynmahbub/VexSign/actions/runs/42602611745).
The historical “not run” notes below describe earlier local-only checkpoints,
not this final remote result. Physical-device acceptance remains outstanding.

This continues the [performance/reliability review](performance-and-reliability-review.md).
It records code changes, not a claim that every roadmap goal or device acceptance
step has passed. No Apple compiler is available in this workspace.

## Implemented in this follow-up

| Area | Implementation | Boundary / remaining acceptance |
| --- | --- | --- |
| Source-independent maintenance | Empty source lists no longer return before native-readiness-gated profile renewal and cleanup. Stale cached repositories are excluded; cancellation is checked between stages. | Existing Game Mode and opt-in policy still apply. No native capability was promoted. Test actual scheduled execution on device. |
| Indexed update matching | An identifier index is built once per detached catalog scan. Exact identifiers outrank name fallback; differing installed identities fail closed. Selected version, UUID, name and URL come from the same record. | Name fallback still scans the library when explicitly enabled. No fuzzy-name index or benchmark improvement is claimed. |
| Source ambiguity | Preferred repositories are resolved by source ID rather than display name. Published cache/set/count are recomputed after filtering. Maintenance queues skip multiple remaining candidates for one installed UUID. | Manual candidate review remains necessary without a preferred source. |
| Network policy transitions | Main-queue reconciliation on path, battery and preferences changes holds running transfers as waiting, distinct from manual pauses. Foreground entry does not resume explicitly paused rows. | URLSession/iOS may deliver already-buffered bytes. No zero-byte cellular guarantee; test actual restored/background transfers. Existing Game Mode resume preference is retained. |
| Progress overhead | Download progress publication is capped at five updates/second per transfer, with final progress exempt. Background UI publication uses existing throttling and manager-owned keepalive instead of per-packet assertions. | Energy, p95 callback costs, and background survival require device measurement. |
| Library size invalidation | Core Data saves and explicit import/sign move notifications invalidate the size task, cancelling stale measurements. | External filesystem edits outside known app mutation paths require view refresh. |
| Interrupted transfer recovery | Atomic phase checkpoints in Application Support; credential/query-bearing source URLs are omitted. Task Center offers retained-IPA review/share, explicit redownload, and forget. No automatic import replay. Unowned restored system tasks are cancelled instead of running without ownership. | This is conservative recovery, not exactly-once crash-safe import/database commit, automatic resume-data restoration, or automatic mismatch approval. Check Library before retrying an interrupted import. A move-before-checkpoint crash may leave an unreferenced staged file. |
| Shared preflight evidence | Bounded read-only selected-slice Mach-O inspection reports encryption, arm64/device platform, deployment target/device/plist disagreement, and low available-space warning alongside existing identity/profile/entitlement/nested checks. Repeat-sign readiness also displays these issues on explicit refresh. | Not an all-slices/all-nested-binaries auditor. Unknown evidence stays unknown. The 128 MiB disk threshold is a warning, not an exact working-space budget. UI preflight is not a new native execution gate. |
| GitHub tracking | Explicit repository, bundle ID, release ID, asset ID/name and prerelease preference persist. Manual checks use ETag/304, bounded metadata, persisted cooldown/rate-limit reset, single-flight checks, and per-app disable/ignore/preferred-source rules (`github:owner/repo` source ID). Every replacement asset requires user selection. | No background polling, version inference from filenames, automatic matching to an imported app, automatic installation, or signed-identity continuity claim. Ignored versions compare exact release tags. Source/asset changes must be reviewed. |
| Backup portability | Existing VexSign schema 1–3 support now rejects unknown component bits, negative counts, duplicate source/certificate identities and library payloads in old schemas. Restore review identifies schema and unsupported cross-signer formats. | No proprietary third-party format adapters. Existing credential consent, encryption, bounded extraction, collision skip and rollback paths remain. Installed app private data is not backed up. |
| Repeatable fixtures | Deterministic synthetic IPA-shaped corpora, nested bundles, many small files, source catalog and library snapshots; portable hash timing emits raw samples/median/p95 and null device-only metrics. Generator regression is in `make verify`. | Fixtures deliberately contain no runnable Mach-O, keys, or profiles. They are not signing/device fixtures or a real-device baseline. |

## Why one new singleton is registered

`GitHubSubscriptionStore` is main-actor isolated and owns the single persisted
tracking file. Sharing that owner prevents multiple view/window instances from
clobbering each other's subscriptions or issuing overlapping checks. The singleton
baseline explicitly registers this one owner; no concurrency escape baseline was
increased.

## Repeatable portable corpus

Generate outside the checkout (the destination must not exist):

```sh
python3 Tools/Development/performance-fixtures.py generate /home/user/vexsign-performance
python3 Tools/Development/performance-fixtures.py benchmark /home/user/vexsign-performance --iterations 10
```

Use `--payload-mib 512 --small-files 10000 --catalog-apps 30000` for a larger run.
These archives are for parser, hashing, extraction and failure-path measurements;
the executable is intentionally invalid. Use your own authorized, runnable IPA for
successful signing and installation measurements.

On device, record device model, iOS version, build commit, scenario, file/entry
count, input size, phase start/end, elapsed and p95 across repeated runs, peak
memory, physical bytes read, cancellation latency, and observed outcome. Leave
unmeasured fields blank/null. Do not copy portable-host timings into device results.

## Acceptance matrix still to run

1. Build app + widget with the configured Xcode/SDK, run new and existing XCTest.
2. Compare exact-ID, name fallback, cloned identifiers, ambiguous names and two
   same-named repositories. Confirm automatic maintenance never chooses ambiguity.
3. No configured sources: exercise notify-only and sign/queue policy, cancellation,
   busy signing queue, cleanup, and gated renewal independently.
4. Wi-Fi → cellular → Wi-Fi, unplug/replug, settings changes, user pause, Game Mode,
   foreground/background, and restored URLSession tasks. Count actual bytes.
5. Kill at download, staged verification, mismatch, import before commit, after
   database commit but before completion, and during journal writes. Relaunch,
   review Library and retained input; verify no automatic duplicate import.
6. Protected-file access, full disk, corrupt journal/subscription JSON, deleted
   retained IPA, symlink inputs, repeated retry and forget. Preserve corrupt state.
7. GitHub 200 → 304, 403/429 Retry-After/reset, disconnect/cancel, changed asset
   names, multiple assets, prereleases, ignored tags and disabled per-app updates.
8. Backup schemas 1–3, wrong password/device key, future schema/components,
   duplicate identities, library collision and rollback/storage failures.
9. Real-device performance measurements on authorized runnable apps, including
   large payloads, nested apps/extensions, many small files and tweak injection.

These device results and full cross-signer format support have **not** been
implemented or fabricated. Security/CMS/native promotion gates remain unchanged.

## Validation actually performed

`make verify` passed after coding, including the new deterministic fixture test.
Localization coverage and `git diff --check` passed. Log:
`/home/user/remaining-roadmap-verify.log`.

New Swift tests cover matching precedence/ambiguity/row coherence, policy holds,
checkpoint round trips and unsafe paths, encrypted/malformed Mach-O evidence,
subscription persistence/corrupt-state preservation, and manifest validation.
They have **not** run without Swift/Xcode. No IPA was built, no device test was
performed, and no release was published.

## Completion pass (supersedes the initial boundaries above)

- Recovery now records `.committing` / `.committed` plus the intended library UUID.
  A failed pre-commit checkpoint prevents the database write; a failed post-commit
  checkpoint never reverses a successful write. Only `.verifying` and
  `.awaitingDecision` inputs can be explicitly re-verified/re-imported. Uncertain
  commit phases are never replayed.
- Resume blobs use UUID-owned paths, atomic protected writes, an 8 MiB bound and
  backup exclusion. Explicit interrupted-transfer recovery uses a blob only when
  its recorded original URL exactly agrees with the public source URL. Unknown
  formats fall back to a fresh request. Termination callbacks remain best effort.
- Launch cleanup preserves journal-referenced staged inputs, and keeps staging
  intact when journal state cannot be read. An explicit user purge can still
  remove temporary files; the UI handles missing retained input.
- Mach-O inspection now validates 32/64-bit headers and every supported fat slice
  within its own nonoverlapping range, including declared CPU, alignment and load
  command bounds. A shared bundle audit checks declared app/extension/framework/XPC
  executables and dylibs. Signing review runs that audit and working-space estimates
  off-main; the certificate/ad-hoc worker repeats structural/encryption checks on
  the modified tree under engine ownership. Known Watch subtrees are not incorrectly
  required to have host-iOS CPU/platform evidence. Unknown platform evidence stays
  a warning, not a compatibility claim. Unsupported formats are rejected structurally.
- GitHub checks now require successful cooldown persistence before networking,
  share cooldown/cache across subscriptions to the same repository, and recheck
  per-app preferences before publication. New injected transport/clock/rule seams
  cover 200/304, 429, storage failure and mid-request rule changes without network.
  Optional **Check during enabled maintenance** consent is persisted per
  subscription; it uses the existing opt-in automation runner and never downloads
  or picks a replacement asset. Cached release review works without another
  network request. Older releases after the chosen release in API order are not
  surfaced as updates.
- Update matching cancels superseded workers. Pending-update display reuses the
  published immutable results rather than rebuilding an index for every source
  app; the old secondary scan path now delegates to the shared worker.
- Removal of completed/cancelled rows uses object identity, avoiding a stale
  callback removing a newer row that reused an external string ID.

Validation: `make verify`, localization coverage and diff whitespace checks pass;
log `/home/user/completion-pass-verify.log`. An additional Tree-sitter parse of
changed/new Swift files found no newly introduced syntax errors (one grammar
limitation also occurs in the original `UpdateAllManager`). This is **not** Swift
type checking or an Apple build. The existing build/test CI is the next gate;
no release dispatch or capability promotion is authorized by that test run.


## Apple CI result and final handoff

The app and simulator suite were actually compiled and run remotely, after coding:

| Run | Source commit | Actual result |
| --- | --- | --- |
| 42597902440 | `cc6f3ab` | Build found missing `IDeviceSwift` import in readiness view; fixed rather than suppressing the compiler error. Superseded simulator job cancelled. |
| 42599193514 | `77fb89f` | App build, unsigned packaging and artifact validation passed. Simulator result: 901 tests, 895 passed, four new matching fixtures failed on missing required `iconURL`, two skipped. |
| 42602611745 | `3ae30e2` | **All CI jobs passed:** repository gates, macOS unsigned Debug build/IPA validation, and simulator XCTest. The fixture schema was corrected, with no relaxed decoder, native/CMS gate, or assertion. |

The final documentation/Python-only commit adds `iconURL` to generated synthetic
source catalogs too, with a portable regression. It does not change Swift app or
test sources from the successful Apple run. `make verify` was rerun after that
correction.

[Unsigned IPA artifact](https://github.com/raynmahbub/VexSign/actions/runs/42602611745/artifacts/13666608671)
(`VexSign-unsigned-3ae30e2643adc918797207eeb58fc71a6e63f737-42602611745-1`).
This is a CI test artifact, not a published release, and it requires appropriate
signing before installation on a physical device. Artifacts expire under CI's
retention policy. No release was dispatched and no PR was merged.

Only `arena/0e283629-vexsign` was pushed. The app's runtime capability gates remain
unchanged. Actual device installation, native capability acceptance, force-quit
recovery/fault injection and real-device performance measurements still require
the acceptance matrix above. Full proprietary cross-signer backup adapters and a
whole-file audit of every upstream repository are not claimed.
