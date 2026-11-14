# Feature-oriented source migration

## Scope and source of truth

This change implements the physical source layout and consumed-boundary migration
from the [requested architecture](https://chatgpt.com/s/t_6af8130278148191bc92dd1663a4f27b).
It supersedes the earlier eight-root-only organization, not published URLs,
licenses, package pins, target identities or existing execution engines.

- **Branch:** `arena/bf87c593-vexsign`
- **Original revision:** `57d3aa65b0228071fa0d2589c232a00b5517ece2`
- **Original inventory:** 1,375 files; 1,322 relocated; 53 retain their locations.
- **Mapping:** [every original file, destination and before-SHA256](feature-layout-migration-map.json).
- **Preservation evidence:** [Git-blob and grammar comparison](feature-migration-preservation.json).
- **Decision:** [ADR-0001](../Decisions/ADR-0001-feature-layered-source-tree.md).
- **Current guide:** [architecture](ARCHITECTURE.md) and [dependency rules](dependency-rules.md).

All original files have unique existing destinations: 953 remain byte-identical
and 422 text originals are rewritten. Focused extractions and validation/docs add
191 files without replacing the original inventory or its recorded hashes. The
inventory includes this working tree's added/rewritten files, not an earlier
checkpoint; rerun the audit after any further edits.

## What changed

1. Main content is under `VexSign/{App,Packages,Services,Tests,Resources,
   Documentation,Tools,Configuration}`. The EmbeddedContainer integration and
   TV/Vision/Watch/widget companions are retained, not removed to fit a diagram.
2. The iOS app at `VexSign/App/iOS/VexSign/` has App, Presentation, Application,
   Domain, Infrastructure, Platform, Security and Resources owners. Populated
   feature folders replace generic Views/Managers roots. Shared tab/navigation
   presentation remains separate from App routing/composition.
3. Bootstrap, lifecycle and composition have explicit owners. `AppContainer`
   injects the same adapters into the main view tree and independent windows.
4. Domain and Application are Foundation-only. The Library, repository/discovery,
   signing/preferences, certificates, installation/session/batch, files/archive,
   tweaks/entitlements, tasks/recovery, account, backup, cloud configuration,
   repository builder and companion views consume ports/use cases over existing
   implementations. Core Data objects and secret-bearing archive/account state
   do not become UI snapshots.
5. Xcode synchronized groups/membership exceptions, resources, package/header
   paths, build scripts, xcconfig inputs, automation filters, service Docker
   contexts and runtime paths follow the new tree. Target identities, setting
   values, package identities and pins are retained.
6. Validation tools and source-reading fixtures follow real implementation paths.
   A new source-regression suite runs in both `make verify` and CI. Portable
   checks are never substituted for native compilation or device evidence.

## Execution and lifetime safeguards

| Boundary | Ownership and failure behavior |
| --- | --- |
| Library and repository snapshots | Read/resolve on the owning executor; opaque store identity plus UUID/signedness checks. Every app projection, including statically typed signing/batch results and workspace reads, requires a nondeleted permanent row in the exact owning context before reading relationships; reject foreign/stale/temporary records; isolated updates do not save unrelated view edits; failed refresh keeps the last good snapshot. `SourceCatalogStore` remains the existing cache/coalescing owner. |
| Signing | Existing `SigningService`/pipeline/engine/verifier remain authoritative. Invocation IDs reject retired callbacks. Completion actions use the reviewed inputs and registered output, and consume profile/staging capture and cleanup at most once. Success alone cannot synthesize signature verification or installation. |
| Installation and batch | Existing queue/installer remain authoritative. Direct Install owns its task and captures the reviewed mode; dismissal retires request-bound warning callbacks and cancels pre-handoff work. Duplicate admission is refused until the original worker/lease finishes; late registered imports release only their opaque handle, not the committed artifact. Guest and device-submission results stay distinct, including confirmation. Accepted queue/install handoffs survive dismissal. Batch callbacks require the current installer, generation and entry. Stop/skip after handoff preserves delivery and reports an unknown/unconfirmed outcome; a later callback cannot resume the next entry. |
| Certificate mutation and undo | Isolated insert/delete/relink saves; invalid/duplicate UUIDs (including case variants) are refused before Keychain replacement. Failed deletion retains credentials/files; a partial holding move refuses deletion. Undo preserves a nil ordering date, flags and still-eligible signed-app links. Holding uses the existing durable staging journal, not a temporary sweep target. An interrupted undo or failed re-stage retains journal ownership of the restored original until expiry/recovery. Cleanup checks committed and pending replacement UUID owners and defers on unreadable stores. The six-second offer expires independently of the banner and clears its captures. |
| Certificate checks | Results are tied to the original row identity and current generation. Deletion retires checks synchronously before UUID reuse/undo; a late result cannot revive a deleted row. The original protected certificate-directory getter is byte-identical. |
| Task/history/recovery | Immutable records over `UnifiedTaskCenter` and existing journals/download recovery. Actions re-resolve IDs; unconfirmed installation retry requires separate approval. History undo has an owner-enforced deadline. Observation termination releases subscriptions. |
| Files/archive/clone | Original engines remain; cancellation is forwarded and workers are awaited before scope/lease cleanup. Rebuild protects an existing destination, clone claims production before files, and a cancelled explorer cannot submit a new installation. |
| Accounts | Separate status, certificate, registration, profile and key-export approvals remain. Context/app/receipt/expiry checks stay in the adapter/manager. The closed CMS gate runs before quota-affecting operations. No signing or install handoff is introduced. |
| Backup and cloud | UI receives only allowlisted backup preview metadata and an opaque archive ID; existing backup crypto/schema/restore verification remain authoritative. Visibility/operation generations retire late picker, password, restore-alert and Restart callbacks. The owned completion delay is cancellable and its summary is consumed once; hiding the screen does not roll back already committed restore outputs. Cloud observation excludes bearer tokens, retains Keychain ownership and does not enable private-key upload. |
| Companion and temporary sharing | Retain owned output while share extensions or embedded staging read it. Dismissal cancels tracked work and cannot restart the host after completion. Once the host accepts an inbox copy, only the host may discard that independent copy. A staged/exported/shared file is not installation evidence. UIKit presentation/refusal still needs native acceptance. |

The three additional concurrency escapes have written lock/main-thread and
callback-outside-lock invariants in the
[concurrency audit](../../Tools/Validation/security-validation/concurrency-audit.json).
The singleton count did not grow. Optional display/decoding failures are separate
from failed mutations; refused writes/cleanup are surfaced or logged rather
than treated as success.

## Preserved compatibility

| Public/root file | Canonical owner under `VexSign/` |
| --- | --- |
| `icon.png` | `Resources/Assets/Branding/icon.png` |
| `app-repo.json` | `Resources/Templates/RepositoryMetadata/app-repo.json` |
| `repos.json` | `Resources/Templates/RepositoryMetadata/repos.json` |
| `license_plist.yml` | `Configuration/Signing/license_plist.yml` |
| `render.yaml` | `Services/WebManager/Configuration/render.yaml` |

`sync_repo_aliases.py --check` enforces equality. Published feeds and historical
commit-pinned URLs remain intact. The published
[pre-migration combined-host setup URL](https://github.com/raynmahbub/VexSign/blob/main/Integrations/EmbeddedContainer/README.md)
is retained for provenance; current UI links target the relocated integration
guide. Root legal/security/community documents, `.github/`, project/workspace and
normal tool entry points remain discoverable.

All 35 original binary files and ten license texts are byte-identical. The
separate `THIRD_PARTY_NOTICES.md` and both licensing-plist inputs retain their
complete text/settings except relocated repository paths; the root licensing
alias matches its canonical owner. The vendor manifest changes only package
paths, not revisions or attribution. These checks do not claim a complete SBOM
or establish distribution-license compliance.

The 28 protected inputs—including original plists, entitlements, model contents,
seven package manifests, all three resolved-pin files, the native input lock,
Cloud lock/OpenAPI, FilePickerFix and the certificate-directory getter—are
byte-identical. Bridge-header edits only relocate the same three unchanged
headers. All seven target objects/products and 157 original Xcode object IDs
remain; the four added IDs are xcconfig references/their group. All 32 declared
configuration setting sets are preserved after path relocation and xcconfig
extraction. This does not evaluate Xcode-expanded settings or bundle placement.

The only rewritten original app resource is the localization catalogue (relocated
path-display text and three new English error/consent keys); other original
translations are retained. No dependency update, license replacement, target
renaming or native promotion is part of this work.

## Architecture ratchet

The guarded whole-Presentation storage, Core Data, direct signing/installation,
consumed engine-owner, raw network, filesystem and managed-record-type matches
are now **zero**. Domain/Application platform/import guards are also clean.
This is a source-level result, not proof that every legacy UI detail has been
redesigned or that all possible dependency edges are covered.

The [baseline](../../Tools/Validation/architecture-rules/architecture-drift-baseline.json)
retains the original `migrationReview` and previous rule/file lists in history.
Zero real debt is allowed; synthetic positive and negative fixtures keep the
rules enabled, including distinguishing `app.isSigned` from a managed-object
cast. CI never regenerates a baseline to make a check pass.

## Validation record

The following checks were rerun for this local working tree after the final
projection, backup-presentation and direct-install lifetime follow-up. They are not results for a newly
created commit or release.

| Check | Observed result |
| --- | --- |
| `make verify` | Passed all portable command groups, including the 17-case workspace-boundary source suite and 22 preservation-auditor fixture tests |
| Layout / architecture | 19 layout, 7 original boundary, 17 workspace-boundary and 8 architecture-ratchet tests passed; all 12 ratcheted categories have zero matches |
| Normal quick check | 0 errors; 1 advisory warning because `swiftc` is unavailable; 53 resources checked and 0 Swift files compiler-parsed. The syntax-independent check in `make verify` explicitly skips the compiler |
| Xcode/project/package preservation | Seven unchanged target objects/products; all 157 original object IDs retained, four xcconfig IDs added; all 32 declared configuration setting sets retained. Workspace/project retain 42 agreeing pins, SideSign retains six; all three resolved-pin files byte-identical. No native build |
| Error / singleton / concurrency guards | 169 unjustified optional-error sites (13 below the existing allowance), 63 singletons, 7 documented concurrency escapes; no file above its reviewed baseline |
| Localization | Catalogue sync and 12 helper tests passed; three missing keys added without pruning translations |
| Original-file preservation | 1,375 Git originals accounted for; 1,322 relocations; no missing file, changed binary/license, executable-mode loss or removed real public/historical URL; exact counts in the linked JSON audit |
| Swift grammar comparison | 959 original vs 1,139 current Swift files; the same 25 known grammar findings and no new finding signatures. One known finding moved with the file-coordination extraction. This is **not** `swiftc` or type checking |
| Native-signing preparation | 74 offline Python tests; no native compile/link or capability promotion |
| Embedded-container packaging | 31 offline fixture tests; no combined native-host build |
| WebManager | 216 tests passed in the checkout and 216 in an isolated component copy; one upstream Starlette/httpx deprecation warning per run; optional cryptography test dependency installed, no skips |
| Cloud | TypeScript build, 14 tests and contract generation passed; OpenAPI and package-lock bytes remain identical to the original revision |
| `git diff --check` | Passed |
| Xcode build / XCTest / simulator / companion SDK builds | **Not run:** no Swift/Apple toolchain in this Linux workspace |
| Physical-device operation | **Not run:** no new device-acceptance evidence |
| Docker image / deployment | **Not run:** service source/build tests are not deployment proof |

Ten new native test files contain 71 XCTest methods for fake-provider signing,
account consent/serialization, backup release/serialization and retired presentation
callbacks, library identity/prevalidation, task/companion intent, observation
lifetime, deadline ownership and Core Data projection admission. Typed foreign-store,
foreign-context, temporary, pending/committed-deleted and detached app rows are covered
alongside valid own-store projections and temporary workspace-read recovery. A fake
restore owner can return a committed summary after cancellation without inventing
rollback; the retired screen still cannot present it. Fourteen Direct Install cases
cover overlapping admission, retirement/task cancellation after registration,
lease retention until the worker returns, accepted handoff preservation, unknown
routing, hidden-screen callbacks, stale/double confirmation, captured mode and the
actual guest outcome. Existing certificate/recovery files add 13 methods for transaction/undo-insert failure, nil-date/relink behavior,
replacement UUID ownership, unavailable stores, interrupted undo, failed
re-stage/erasure and durable journal retention. **All 84 added native methods remain
uncompiled and unexecuted here.** Source-reading fixtures fail
when an expected implementation file is absent; they do not silently skip
migration breakage. In particular, fixture/source passes are not delayed-OCSP,
UIKit, real protected-database, host-copy or actual installer callback acceptance.

Reproduce the portable checks from the repository root:

```sh
make verify
make test-server PYTHON=/path/to/python-with-server-test-dependencies
# After npm ci in VexSign/Services/Cloud:
make test-cloud
python3 VexSign/Tools/Validation/architecture-rules/audit_feature_preservation.py
# Optional grammar-only comparison, with tree-sitter and tree-sitter-swift installed:
python3 VexSign/Tools/Validation/architecture-rules/audit_feature_preservation.py --parse-swift
```

The preservation audit is read-only (apart from an explicitly requested JSON
report) and requires the recorded original Git revision locally; it never
fetches, stages or changes a baseline. Its 22 offline fixture tests run in normal
verification/CI without needing that historical Git object. The JSON records its
exact file, legal-index, protected-input, target/configuration and grammar
findings. The two intentionally incomplete URL-prefix sentinels from the old
negative-rewrite test are not exceptions for real URLs; the prior evidence report
is excluded from current URL evidence so it cannot hide a removed source URL.

## Required native/device acceptance

On macOS, build/test this exact working tree after saving it as a reviewed
revision—not an earlier checkpoint:

```sh
make bootstrap
make test
make VexSign
```

Also build the existing TV/Vision/Watch/widget targets and applicable native
signing/combined-host smoke schemes. Inspect bundled assets, strings, Core Data
models, plists, sounds, web data and shared-target membership. Specifically test:

- failed certificate save/undo-insert/re-stage/rollback moves, locked Keychain or
  unreadable protected database, delete/undo/expiry/UUID reuse, interruption after
  files are restored but before row insertion, stale delayed OCSP results and
  signed-app relinking without overwriting a separately changed identity;
- signing failure/cancel/retry, verifier evidence, one-shot input cleanup and
  completion handoff with and without the log sheet;
- installation stop/skip before and after handoff, delayed/double callbacks from
  retired installers, unknown outcomes and explicit retry decisions. Exercise
  Direct Install dismissal during transfer/import and warning presentation,
  reappearance/new requests followed by stale confirmation callbacks, duplicate
  Start and accepted handoffs that must not be revoked;
- cancelled archive rebuild/clone/backup/restore, archive replacement/release,
  cancellation after artifact registration, delayed restore alerts, existing
  destinations and unrelated pending edits preserved;
- sharing refusal/completion and disappearance while a worker or extension reads
  a file; embedded host-copy cancellation/acceptance and dismissal without stale
  session restart. An accepted independent inbox copy remains host-owned.

Follow [device testing](../DeviceTesting/DEVICE_TESTING.md) for actual transports,
background limits and evidence. Native Apple-account signing remains
`.notIntegrated`; free-account/guest-host flows remain experimental. Signing,
artifact registration, export, guest preparation and install submission do not
establish verified installation, unattended renewal or computer-free bootstrap.

Publishing this branch for a pull request and native CI was subsequently
authorized. The portable results above precede that publication and are not
native-build or XCTest results. Native CI findings must be recorded separately
for the revision actually tested. No merge, tag, release, deployment or credential
change is authorized by that verification step.
