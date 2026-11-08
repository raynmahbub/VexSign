# Feature integration and validation status

Updated 2026-11-08. “Implemented” means code is wired into a production path;
it does not mean that a device acceptance test has passed.

## Current integrations

| Area | Implementation | Validation still needed |
| --- | --- | --- |
| Signing lifecycle | Request-scoped Stop, duplicate-source ownership, retry release ordering, registration by database ID | Xcode tests and real certificate signing/cancellation |
| Native execution | Injected FIFO gate for native signing/capture/cache and dylib removal | Xcode tests, simultaneous jobs, queued cancellation |
| Input checks | Entitlements format and executable containment checks | Xcode tests and malformed input/device cases |
| IPA imports | Buffered extraction, CRC/size checks, pause/resume/stop controls, cooperative deadlines, storage and file access handling | Xcode tests, large archives, low storage, external Files providers |
| Install completion | Bounded positive-progress phase and new-app evidence handling | Device tests for first install, update, rejection and cancellation |
| IPA exports | KorSign-derived safe names and collision handling; save failures propagate | Xcode tests, repeated local/browser exports |
| Pairing upload | Bounded 1 MiB streaming, scoped native pointers, handle cleanup, cancellation forwarding | Real AFC transport and error-path device tests |
| Library backup | Version-3 manifest includes signed/imported bundles and metadata; VEXBK3 uses 1 MiB authenticated file records with an 8 GiB extraction limit; compatible with older manifests | Xcode tests, restore/certificate remap, partial failures and low storage |
| Offline history icons | Local 64×64 PNG thumbnails after successful import; bounded history pruning and glyph fallback | Xcode tests, relaunch/offline/clear-history acceptance |
| OTA queue preparation | One-app lookahead packages the next OTA entry during current transfer/verification; explicit workspace leases survive HTTP response bodies | Xcode tests, pause/skip/retry/settings changes, low storage and stream cancellation on device |
| Pairing packaging | KorSign-derived fast compression when pairing would otherwise send an uncompressed IPA | Xcode tests, real pairing upload, performance measurement |

Source revisions, licenses and modifications for adapted code are in
[Third-party code adaptations](../THIRD_PARTY_ADAPTATIONS.md). The broader feature
comparison is in [comparison notes](../research/public-signer-comparison.md).

## Completed verification

`make verify` passes in the Linux development workspace. It covers documentation,
Python policy tests, syntax-independent repository checks, project structure,
localization completeness, error discipline, singleton freeze, concurrency
policy, workflow policy, embedded-container packaging and native-signing
preparation tests. It explicitly skips Swift syntax/compiler validation here.

The missing entitlements localization entry was added. The signing gate is now
owned by the pipeline and injected into handlers instead of adding a global
singleton. Existing policy baselines were not raised to hide the failures.

## Remaining integration work

Not delivered as full parity:

- Unrestricted whole-library migration: backups retain an 8 GiB expanded-size and 50,000 ZIP-entry safety ceiling. They exclude installed-app data and have per-app rollback, not whole-batch rollback. The former 256 MiB limit is removed for new file-stream containers.
- Concurrent OTA prompts/install execution are intentionally not enabled. One-app parallel archive lookahead and response-owned archive lifetimes are now wired in, but still need device acceptance.
- History-icon backfill for existing receipts and icons for unsuccessful/unimported downloads. New successfully imported downloads now receive offline thumbnails.
- Complete production native Apple ID provisioning or an alternative signing engine.

Each needs its own design, compatible source/license review, tests and device
acceptance. Existing experimental features must remain labeled experimental.

## Release gate

Run the iOS XCTest target and signed device acceptance before claiming the app
fully works. Exercise preflight → sign → verify → register → export/install with
valid and invalid identities, tweaks, large apps, cancellation, retry, cleanup,
background/foreground transitions and low storage. Portable checks alone cannot
establish certificate acceptance or successful installation on iOS.

## Library and history scope

App Library is selectable alongside certificates, sources, settings and tweaks.
New containers use manifest version 3; versions 1 and 2 remain readable without
an `apps` field. Invalid UUIDs/bundle names, symlinks, missing bundles and oversized
staged content fail rather than silently dropping apps. Signed and imported app
records are recreated through the existing storage APIs, preserving existing UUIDs
and directories. Certificates are remapped by UUID when present; missing identities
do not become embedded private keys. Restored signatures still require validation.

Restore is incremental: if an app fails, its newly copied directory is removed,
but earlier restored apps and other selected components remain. Retrying skips
existing records. Idle checks run at entry and before each app/commit; there is no
global mutation lock, so avoid concurrent library edits during backup or restore.
A backup snapshot is not a transactional database/filesystem snapshot.

History thumbnails are stored separately in Application Support, keyed by hashed
task IDs, not fetched from remote icon URLs. They are pruned with the retained
200-record history while retaining active-task icons. Old receipts are not
backfilled. Thumbnail failures are logged without failing an already committed
import. Neither the new library nor icon XCTest cases have run on this Linux host.

## OTA lookahead and archive ownership

The queue prepares at most one upcoming OTA app once the current app has finished
packaging. It does not start the next server or prompt until that entry becomes
current. Export, pairing and guest-import entries do not opt into lookahead.
Pause parks a prepared package; failure, stop and clear discard it. Retry keeps
normal serial recovery. A changed installation/server/compression/IP-fix/NovaDNS
snapshot discards a prepared installer on activation. Preparation errors surface
when that entry becomes current, not as a false failure of the current install.

Installation workspaces are unique and reference-owned. Workers, installers,
fallback uploads and HTTP stream completions hold leases; only the last release
removes temporary files. Original library bundles and exported IPAs are not owned
by those leases. The extra copied Payload is removed after successful zipping.
Cancellation reaches both packaging workers and retained fallback uploads, but
blocking copy/ZIP calls finish at cooperative operation boundaries before cleanup.
A stopped server is shut down asynchronously; late statuses cannot complete a
retired installer. Metadata needed by the package worker is resolved on the main
actor before file work starts.

Four new XCTest cases cover workspace isolation, response-like lease retention,
partial-worker cleanup and OTA-only eligibility. These are authored, not executed
here: Xcode, UIKit, Vapor and signed-device validation remain release gates.

## Streaming-backup follow-up

BackupManager now uses `sealFile`/`unsealFile` for all file backups. Chunked
AES-GCM records authenticate the envelope, record order/length and terminal EOF;
the plaintext ZIP is hashed incrementally. Incomplete output is kept private and
removed on failure rather than published for extraction. ZIP safety validation
runs before sealing as well as before extraction. A 16 MiB metadata limit prevents
an oversized manifest from causing another whole-buffer allocation.

Older VEXBK0/1/2 containers remain readable up to 256 MiB of container data; their
whole-buffer cryptography cannot safely inherit the new large-file limit. Existing
Data-based helpers remain for compatibility, not the production file path. New
containers require this version or later to read. See the
[streaming backup format](backup-streaming-format.md) for exact framing and limits.

Twelve new streaming XCTest cases cover multi-record/empty round trips, integrity
failures, output preservation, old envelopes, a sparse oversized legacy file,
Keychain-backed wrapping, cancellation and an independently generated AES-GCM
fixture. The reference fixture and representative tampering checks were verified
with Python cryptography in the workspace; Swift tests have not run. Cryptographic
review, Apple compilation and large-library memory/disk/device tests remain release
requirements. Streaming removes whole-archive encryption allocations, not temporary
disk requirements or every allocation made by ZIP/JSON libraries.

## Signing code-side audit follow-up

The native outcome acceptance rule is now directly testable and rejects either
failure signal. Native input and post-sign inspection share executable-containment
checks; CodeResources must be a readable nonsymlink regular file. Registration
requires a current nonempty identifier and usable executable. Sign Anyway permits
only a narrow compatibility allowlist and cannot bypass structural damage or an
ignored requested identifier. Ten additional XCTest methods were authored, not
executed here. Portable verification and independent Swift grammar parsing passed;
compiler/type/link checks and end-to-end native signing remain unverified. See the
[signing audit and device handoff](signing-code-audit.md) for the exact scope and
on-device acceptance steps.

## Device-reported install-status follow-up

A device report showed a successfully installed app with a retained Installing
card and a Not installed library badge. The install baseline is now captured
before packaging/prompt presentation rather than after IPA delivery, so fast
installs cannot become their own already-installed baseline. A known old-to-new
version transition also provides independent completion evidence with an absent
or stale progress counter; an unchanged existing app or unknown baseline does not.

The device probe cross-checks LaunchServices workspace installation status instead
of relying exclusively on a cached proxy flag. Contradictory registered metadata
without positive installation evidence remains unknown, not a false negative.
Foreground activation refreshes known library rows. Private selectors remain
availability-checked; unsupported/restricted evidence cannot guarantee a verdict.

The progress query now calls its actual Objective-C BOOL argument signature rather
than passing a boxed Boolean through perform. Polling requests nonblocking reads;
nonfinite fractions are ignored. Nine regression XCTest methods were added.
Portable checks pass; these device-follow-up edits require a fresh Apple CI/device
run. The preceding workflow-fix revision 637d3c6 passed all triggered checks,
including simulator tests and all three companion builds, before these new edits.

The separately reported add-library crash awaits clarification of the import type
and a crash/reproduction report; no claim is made that it has been fixed. Existing
in-app self-updates still require an eligible method, valid signing identity and
iOS installation consent; silent unsigned replacement is not implemented.

## Tweak/library import and self-update hardening

Follow-up to the ambiguous add-library crash report (not a reproduced crash fix):

- Validate tweak input kinds, readable regular files and nonsymlink directory
  contents before and after copying. Local components are limited to 512 MiB and
  directory trees to 10,000 entries. Dylib and Debian package headers are checked
  before downstream processing; this does not prove full binary/archive validity,
  signature validity or injection compatibility. Versioned/symlink-based frameworks
  must be flattened to a self-contained nonsymlink iOS framework before import.
- Manual signing-screen imports stage security-scoped files on a worker, publish
  URLs only after successful validation, report errors, and clean up failed or
  cancelled batches instead of registering nonexistent paths after a failed copy.
- Repository feeds/files download to disk rather than response-sized Data buffers.
  A per-task delegate cancels oversized reported transfers (5 MiB feed, 100 MiB
  component), including unknown-length bodies as progress grows, and refuses
  HTTPS downgrades. Completed file sizes and final HTTPS responses are rechecked.
  Download staging is cleaned up; original library filenames are preserved without
  treating feed display names as paths. Concurrent repository imports are rejected.
- Failed/partial library imports no longer receive an unconditional success toast.
  Import failures are also written to the on-device log.
- Dylib browser exports resolve only regular files within the app bundle, including
  after symlink resolution. Mach-O command parsing honors the declared command
  region, caps iteration, rejects header-pointing/unterminated names and handles
  FAT64 offsets without truncating their high bits.
- Server-based in-app self-update now captures its install baseline before opening
  the iOS prompt and uses nonblocking progress polling, matching normal OTA installs.
  Existing in-app signing/update methods and iOS consent requirements are retained.

Seventeen additional XCTest methods cover import inputs, staging/cancellation,
repository limit decisions/filenames, local browser containment and malformed
Mach-O commands. Portable `make verify` passes (74 Python tests plus repository
checks); these new Swift tests and compilation require Apple CI. The previous
104944c revision's Debug build and simulator tests have passed. Device acceptance
still needs the specific failing add-library action/log and repeat installation
and self-update tests; CI success alone does not prove either reported device issue
resolved.

## Remaining library-binding / overlay follow-up

The add-library report remains ambiguous and has no reproduction or crash trace.
Signing's Add From Library rows and nested file editors now use identity-resolved
bindings rather than retaining SwiftUI array indices across insertion, reordering
and removal. Removed rows retain a read-only snapshot for their exit animation;
late writes are ignored instead of indexing an absent row or modifying its
neighbor. Four XCTest methods exercise current reads, reordering, removal and
nested removal. This addresses a plausible crash class, not a confirmed root cause.

Finished install queues now have a cancellable 0.6-second retirement fallback after
dismissing the sheet, so cleanup of the separate UIWindow does not depend solely
on SwiftUI delivering onDismiss after an OTA prompt/background transition. Reset
or enqueue cancels the fallback and it checks that the queue is still finished
and not presented. The sheet no longer writes presentation state from onDisappear,
which could otherwise dismiss a newer queue during an older sheet's exit.
Failures are still actionable and are not automatically discarded. This only
retires confirmed/completed queues; it does not manufacture install evidence.

Settings → Updates now explicitly labels the available release action Update in
App and explains the existing signing/install flow. Automatic update checks and
in-app signing/install are already implemented; unattended unsigned replacement
is not supported. Select the original signing certificate and configure IDevice
(pairing/tunnel) or Server installation, then approve the update in iOS. No external
manual re-sign/reinstall step is necessary when that configured path is eligible.

Portable make verify passes, including 74 Python tests. New Swift tests, compiler
checks, on-device sheet transitions and the exact reported crash need Apple/device
validation; none has been inferred from portable checks alone.

## False “Not installed” Library badge

The follow-up Aidoku screenshot still shows a negative badge for an installed app.
The runtime probe could turn legacy LaunchServices false results into absence,
even when those results were filtered or stale. It now first requests a modern
LSBundleRecord using bundleRecordWithBundleIdentifier:allowPlaceholder:error:
with placeholders disallowed. Positive evidence requires an LSApplicationRecord
for the exact identifier, an explicitly false placeholder flag, no known system
placeholder flag, and a file bundle URL returned by that record. Version/build
metadata comes from the record rather than the stale compatibility proxy. The
factory is called with a typed BOOL/error-pointer ABI and availability guards.
The selector's signature was checked against the runtime declarations at
https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/Frameworks/CoreServices.framework/LSBundleRecord.h
and LSApplicationRecord.h in that directory; no implementation code was copied.

If modern records are unavailable, legacy positive evidence remains usable.
Legacy negatives, individually or together, are now unknown rather than claiming
absence; the unknown state has no Library badge. A URL alone, a stored signed
copy, a container guest or a prior installation attempt still cannot establish
installation. This is intentionally conservative when iOS denies inventory
access, and does not weaken the install watcher's unknown-baseline checks.

Four new XCTest methods cover filtered negatives, canonical-record precedence,
version comparison, mismatching identity and placeholder/type/URL rejection.
Portable make verify passes (74 Python tests plus repository checks). Native
compilation/tests and confirmation on the affected device are still required;
this checkout cannot execute Apple frameworks locally.

## Confirmed install → Library handoff

A confirmed OTA/IDevice verdict now publishes installation evidence directly to
LibraryStatusStore before completing the queue item. Visible rows update
immediately, and newly mounted rows can use the same evidence. An inconclusive
background inventory read cannot erase that confirmation during the normal
30-second cache handoff. Confirmations are identifier-specific, version-aware,
nonpersistent, expire after 30 seconds and are cleared on full store reset; fresh
conclusive device evidence still wins. Failed, cancelled, exported or staged guest
packages do not create confirmations. This is not an assumption based on progress
reaching 100 percent.

Successful queue items now advance/dismiss after 0.25 seconds rather than 1.2
seconds, preserving the existing guarded overlay-window cleanup. Queued apps
continue in sequence; failures retain recovery controls. Three additional Swift
regression tests exercise immediate/late-mounted badges, background-read handoff,
version differences, identity isolation, reset and expiry. Portable make verify
passes (74 tests); native compiler/simulator and device validation remain pending.

## GitHub issue queue follow-up (#126, #128, #130)

Current main 2f03b49 passes CI run 42511925196: both the unsigned iOS Debug
build and simulator tests completed successfully. This supersedes the historical
simulator compile failures tracked by #126 (SigningServiceTests return type) and
#128 (main-actor canSkip tests). The later Release workflow_run successes did not
compile an IPA: only version-bump ran, while build/publish were skipped. They must
not be cited as proof that #128's separate Release dependency failure is fixed.

Release now prefetches the same checksum-verified binary archives used by the
companion validation workflow and shares an explicit job-owned SwiftPM cache
between make and make test. Local Makefile invocations keep Xcode defaults unless
SPM_CACHE_PATH is supplied. Pins, checksum verification, simulator testing and
publication permissions remain unchanged. A workflow-policy regression failed
before the change and passes afterwards; portable make verify passes. An explicit
unpublished build-only Release run is still required to validate the native path.

The previous merged fixes for #130 cover finished-overlay retirement, stable
library bindings, conservative installed-app lookup and confirmed-install badge
handoff. The add-library crash remains unreproduced. Keep that issue open pending
exact steps/crash logs and device confirmation rather than declaring it resolved
from portable checks or CI alone.

## Remaining add-library import work (#130)

A further audit found provider file copying, header/tree validation and allocated
size reads still executed synchronously in Tweak Manager UI actions, despite the
signing-screen picker having background staging. A slow provider can block the
main run loop and cause an iOS watchdog termination without a Swift throw.

Library add, add-version/add-files, extraction, repository downloads and both
Files/IPA Explorer/context-menu shortcuts now use asynchronous preparation.
Security-scoped copies, validation, size reads and collision naming happen on
workers. A prepared version is committed with a same-container directory rename;
component additions rename prepared files, not recopy their contents on the UI
thread. Failed/cancelled batches clean up, originals stay untouched, and only
committed components are added to the observable manifest on MainActor. Target
IDs are resolved again after await, so deleted/reordered tweaks cannot leave an
out-of-date array index in an import callback. Duplicate import submissions are
blocked in the library/detail/extraction screens and long library/extraction
imports show progress. Multi-file preparation is atomic; an invalid component
rejects that batch rather than silently committing a partial version.

Three added XCTest methods exercise prepared-version collision naming, source
preservation/cleanup, invalid batch rejection and cancellation. Portable checks
pass and all nine changed Swift files pass independent grammar parsing, which is
not an Apple compiler/type/runtime test. The original crash has no stack trace or
reproduction yet; these concrete blocking/stale-index risks are addressed, but
on-device confirmation is still needed before claiming the reported crash is
proven resolved. The separate #128 build-only Release run 42513935741 has passed
verified artifact prefetch and is executing the real IPA build; no skipped job is
being counted as build success.

Final import UI review: the detail screen now displays preparation progress and
repeated import/picker submissions are guarded. Cancelling extraction cancels the
worker task and waits for cancellation acknowledgement before removing the source
extraction directory; interactive sheet dismissal is disabled during preparation.
Already committed separate tweaks are retained if cancelling the remaining batch.
Portable verification passes. Device testing is deferred to the user once the
unpublished build for the final commit finishes; the earlier 42513935741 run tests
only the dependency-cache change, not the later import/UI code.

## Three-part Library and KSign-style quick workflows

Library's segmented header is now Files → Apps → Signed Apps. Apps includes only
imported originals; Signed Apps includes only signed copies. Scoped filtering,
selection, hidden counts and list contents stay within their partition; unrelated
aggregate update rows remain available in the standalone combined library/App Store
rather than mixing partitions. Existing Library defaults/deep links still target
Apps, with new signed/signedapps routes and signed-result/highlight routing to the
Signed Apps segment. Import actions return to Apps.

Native app-list rows offer trailing swipe Delete with confirmation and full-swipe
disabled; it deletes only the stored copy, not the installed device app. Successful
deletion clears that UUID from selection. Files retains its existing swipe Delete.
Card/icon layouts retain their context-menu Delete (native list swipes do not run
inside SwiftUI grids). Leading app-list swipes adapt KSign's Install/Re-sign for
signed copies and Sign & Install for imported originals. Explicit sign/install
intent is request-local and still requires successful checked signing before
entering VexSign's confirmed-install queue. See THIRD_PARTY_ADAPTATIONS.md for the
pinned source, original notice, license and exact adaptation boundary.

Four added XCTest methods cover ordered/exclusive partitions, signed routes and
highlights, action-kind selection and request-only signing options. Portable
verification passes; Apple compilation and device interaction checks are pending.

### Confirmed-install card completion

Confirmed outcomes now publish Completed and full install progress before the
queue schedules its existing automatic dismissal. Normal successful installs
also leave an “Installation completed” toast after dismissal. Cancellation,
export, guest preparation and signing success alone do not publish this state.
Late OTA transport callbacks cannot reopen a completed card. An observed partial
progress -> 100% transition begins independent device verification immediately;
an initial/stale 100% counter alone does not establish completion.

Six added XCTest methods cover these transitions and their negative cases.
`make verify` passes 74 portable tests. Changed Swift files pass grammar checks
(with an empty-tuple parser workaround); Apple compilation/XCTest and physical
device acceptance remain pending for this change.

### Early installation observation and same-version reinstalls

OTA monitoring now begins when payload transfer starts, not after it ends. The
installation-start timeout is held until the payload is served, so slow transfers
do not consume that deadline. Positive installed-record container changes can
confirm same-version reinstalls even without a readable progress counter; aliases
of the same path do not count. A matching placeholder observed during monitoring
can establish a placeholder-to-installed transition despite an unknown initial
baseline. Unknown/negative lookups alone still cannot establish new installation.

The card distinguishes waiting for iOS from verifying installation instead of
labeling every confirmation stage Installing. Phase changes enter the task log.
Seven additional XCTest methods cover early observation, the transfer deadline,
container replacement and negative/placeholder cases. Portable verification passes
74 tests; Apple compilation/tests and physical-device acceptance are not yet
confirmed for this change. These fixes are independently implemented; no new
upstream implementation was copied.
