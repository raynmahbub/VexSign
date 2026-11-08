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
