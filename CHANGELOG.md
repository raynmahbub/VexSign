# Changelog

All notable changes to VexSign are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut from a tag whose name matches `MARKETING_VERSION` — see
[VexSign/Documentation/Release/RELEASING.md](VexSign/Documentation/Release/RELEASING.md).

## [Unreleased]

### Added

- Build provenance for releases. The publisher attests the IPA, `SHA256SUMS` and
  `RELEASE.json` with `actions/attest-build-provenance` after verifying the
  checksums, so a download can be traced to this workflow at this commit with
  `gh attestation verify` instead of only to a checksum list that ships in the
  same release.
- Plural forms for countable strings. Fifty-four user-facing counts now carry
  `one`/`other` variations in English (`%lld item`, `Added %lld file`,
  `%lld day remaining`, …), the certificate renewal lines moved from Swift
  string interpolation into the catalogue so they can be translated at all, and
  `sync-strings.py --check` now fails a countable string that ships without
  plural forms.
- The quarantine notice after an unreadable library store is finally shown. The
  Library explains that the app list was rebuilt, names the folder the old store
  was moved to, and can be dismissed; before, the notice was published and never
  read, so the only visible symptom was an empty library.
- A populated feature-oriented iOS source tree under one main `VexSign/` root,
  with App, Presentation, Application, Domain, Infrastructure, Platform, Security
  and Resources owners. The [migration record](VexSign/Documentation/Architecture/feature-layout-migration.md),
  [complete file map](VexSign/Documentation/Architecture/feature-layout-migration-map.json)
  and [ADR](VexSign/Documentation/Decisions/ADR-0001-feature-layered-source-tree.md)
  cover preservation and remaining native/device acceptance.
- Consumed Domain ports for signing work/engine, opaque installation requests,
  anisette configuration, incoming-file coordination and routing diagnostics;
  Foundation-only Domain/Application, explicit App bootstrap/lifecycle ownership,
  populated feature-local view models and real xcconfig inputs. Existing engine,
  task center, device coordinator and library registry remain authoritative.
- Layout/boundary/resource/membership regressions and expanded whole-Presentation
  architecture coverage. Initial legacy matches were audited against original
  source; consumed feature ports now bring all guarded categories to zero while
  retaining the review/history. Added workspace/identity/consent/cancellation
  regression sources; native compilation and device acceptance remain pending.
- A read-only original-Git preservation auditor and 22 offline positive/negative
  fixtures covering license/index text, protected inputs, target/product/config
  identities, pins, shared membership and published aliases. Its optional Swift
  grammar comparison is not a native build or device-verification claim.
- The signing screen shows ten steps: identity, preflight, the seven stages the
  engine reports, and install. A step is marked done only from recorded evidence;
  stages a run did not need are shown as skipped, and install is shown as a
  separate step.
- Remove from Device, on a signed app's detail screen. It uses the pairing
  session, refuses VexSign itself and Apple's apps, asks for confirmation, and
  reports "Removed" only when the app is seen to be gone. Not yet tested on a
  device.
- Permission for background signing (Settings, Automation). You allow it for the
  selected certificate for 1, 7 or 30 days and can turn it off at any time.
- Regression tests for Swift 6 build errors, manifest endpoint selection,
  server URL ports, extended log redaction, and deep-link base64 staging.
- A machine-readable architecture owner map, six-layer dependency rules and
  diagrams, source-guided feature decisions, and a permanent architecture drift
  ratchet that fails when new Presentation→Infrastructure shortcuts appear.
- A pure support-environment port and UIKit adapter so feedback/diagnostic
  actions no longer couple the Application layer to UIKit or platform globals.
- A clean top-level ownership-root layout with an original-to-new
  [migration map](VexSign/Documentation/Decisions/History/root-layout-migration-map.json),
  byte-identical published compatibility aliases, portable layout gates and a
  [migration report](VexSign/Documentation/Decisions/History/root-layout-migration.md).
  This organizes App, Extensions, Integrations, Packages, Resources, Services,
  Tools and Documentation; it is not an Xcode-build or device-verification claim.
- A privacy manifest for every shipped bundle. `PrivacyInfo.xcprivacy` now declares
  what the app and its widget, watch, tvOS and visionOS extensions actually do:
  no tracking, nothing collected off the device, and the required-reason APIs each
  bundle touches — user defaults (app and app group), file timestamps, disk space
  and boot time — with the reason codes that justify them.
- Tests for four pieces of untrusted-input logic that had none: the provisioning
  profile reader (oversized file, missing plist envelope, missing expiry, a key
  file that is not PKCS#12), the bounded certificate file reader, the storage
  warning threshold, the download speed smoothing, and the clone guards that
  refuse an app whose bundle is not on disk.

### Changed

- Hidden apps are hidden from the automation surface too. `GET /api/library`,
  `GET /api/updates`, the `/api/status` counts and the `/api/cleanup` report omit
  apps in the Hidden Apps Vault, matching the Library rows, instead of naming
  their bundle IDs and versions to whoever holds the Web Manager password or API
  token. The Web Manager still authenticates independently of App Lock, which is
  what lets it work while the phone is locked.
- Deep links wait for the lock. A link that arrives behind the App Lock is held
  by the container (bounded, in arrival order) and replayed after unlock, so it
  can no longer stage a package into the library or raise an alert above the lock
  screen.
- The app-switcher snapshot can no longer show the unlocked library. A
  non-interactive cover is installed at `.inactive`, one phase before App Lock
  engages, for users who turned App Lock on.
- Device backups no longer carry the folders the app can rebuild. Firmware, the
  Web Manager inbox and the log folder are marked `isExcludedFromBackup` by the
  launch sweep, which keeps a multi-gigabyte `.ipsw` and a device's diagnostics out
  of iCloud; the library folders stay backed up because they are the user's own
  content.

### Fixed

- Release notes linked two documents that no longer exist at those paths
  (`Documentation/Engineering/PLATFORMS.md`, `Documentation/Design/assets/…`),
  so every published release body carried two 404s. The platform limits and the
  interface-preview links now resolve.
- Documentation references in tooling point at the files' real locations
  (`Documentation/Release/RELEASING.md`, `Documentation/Security/NATIVE_SIGNING_HANDOFF.md`,
  `VexSign/Documentation/Development/PLATFORMS.md`), and `make docs-check` now
  resolves `Documentation/...` paths written in workflows and tools that the
  Markdown link check never saw.
- `MockPlatformAdapter.presentYesNoAlert` recorded the alert title where a test
  would expect the confirm button's, which made a consent assertion pass for the
  wrong reason.
- The certificate deep-link branch has tests: parsing (including the malformed
  and non-base64 cases), validate-before-prompt, install-only-after-consent, the
  declined path leaving nothing installed, and the export callback template
  being refused unless it is ours.
- `TRANSLATING.md` now states the real localisation coverage (twelve locales at roughly
  20% each, English fallback at runtime, `sync-strings.py --report` as the source of
  truth), and the CI run summary carries the same table.
- Free-account renewal schedule: `RenewalPlanner` answers "which signed app stops
  opening next, and can it be fixed here?" for imported, cloud and Apple Account
  credentials. Windows are proportional and clamped to 1–7 days, revocation and
  non-renewable credentials report `blocked` rather than scheduled work, and a
  credential with no readable expiry is never treated as healthy. Pure Domain
  rule plus a `@MainActor` coordinator and 23 boundary tests; the reference
  register and license decision tree are in
  [REFERENCE_PROJECTS.md](VexSign/Documentation/Architecture/REFERENCE_PROJECTS.md).
  Wired into the certificate row, the certificate header and the background
  pass; the header's `expiring` count now comes from the planner instead of an
  inline seven-day check. Two sources (imported certificates, Apple Account
  profiles) share one coordinator keyed by source, so neither refresh erases
  the other.
- Corrected the renewability source. Renewal was derived from
  `SigningMethodCapabilities.nativeAppleAccountSigning`, which is held
  `.notIntegrated`, so every free-account certificate was reported as
  "Cannot renew here" — wrong, and the most alarming status the screen could
  show. Renewal is a different question from in-process CMS signing: an
  imported pair is renewed by provisioning and re-importing fresh material,
  which the account hand-off (`exportToCertificateStore`) already does.
  Renewability now follows the signed-in session via `Renewability`;
  `NativeRenewalSeamTests` pins the separation and keeps the promotion gate
  closed. Promoting the native capability needs committed genuine-Apple-profile
  and device-ladder evidence (`check-native-handoff.py`), not a source edit.
- Strict Hiding now holds on the two surfaces that are not views. The widget
  payload and the backup archive used to include vaulted apps: the tile counted
  them and a backup file carried their names, bundle IDs and descriptions. Both
  now read the vault's published snapshot instead of re-deriving it, and a hidden
  app never reaches either.
- The Web Manager's phone relay no longer silently drops the user's TLS trust. A
  `TypeError` from the checked transport fell back to a client with neither the
  custom CA nor the certificate pin, so a relay configured to trust a private
  phone certificate connected against the system store instead. Trust settings
  now fail loudly, and the transport tests that had been passing *because* of the
  fallback pass on their own.
- The background-transition flag follows `didEnterBackground`, not
  `willResignActive`. Pulling down Control Center or the app switcher marked the
  app as backgrounded, which rerouted new downloads onto the background
  `URLSession` and posted completion notifications for a download still on screen.
- The launch-time "storage is over the warning limit" check no longer walks every
  file in Documents on the main actor. The walk runs off it and only the
  comparison and the toast come back, so the first frame after launch is not
  waiting on a directory traversal.

### Security

- `feather://` is no longer registered or parsed. The app declared another
  product's URL scheme, so any installed app could name it to reach the whole
  `vexsign://` command set — installs, `import-certificate`, source adds — without
  the user typing anything. The scheme is gone from `Info.plist` and from the
  parser, and a test pins that those URLs are now unsupported.
- `signing-assets/` is gitignored and validated: the folder is imported at launch as the
  *default* identity from `cert.p12` + `cert.mobileprovision` + `cert.txt` (plaintext password),
  and nothing previously stopped it from being committed or bundled. `check-pbxproj.py` also
  fails when a target carries a deployment target for another platform, or when any target sits
  below the floor `PLATFORMS.md` documents; the iOS target's stale
  `TVOS_DEPLOYMENT_TARGET`/`XROS_DEPLOYMENT_TARGET` values were removed and the `FilePickerFix`
  shim now defaults to the app's own iOS 17 floor.
- The premium backend's admin surface no longer hands over the key inventory. `GET
  /api/admin/keys` now returns a masked key and a stable id; handing a key out is the
  explicit `POST /api/admin/keys/reveal`, and every mint, state change, reveal and app
  upload is written to a new `admin_audit` table with the key id and client address
  (`GET /api/admin/audit` reads it). `ADMIN_TOKEN` accepts a comma-separated list for an
  overlapping rotation, and `ADMIN_TOKEN_FILE` is read per request so a rotation no longer
  needs a redeploy. An unreadable token file disables the surface instead of falling back
  to the previous secret.
- The premium rate limiter no longer trusts a short `X-Forwarded-For`. When the header
  carried fewer hops than `VEXSIGN_TRUSTED_PROXY_HOPS`, the old code clamped to
  `entries[0]` — the value the caller chose — so a request that bypassed a proxy could
  pick a fresh bucket per attempt. It now falls back to the socket peer. The bounded client
  table also fails closed: past `_MAX_CLIENTS` new clients share one overflow bucket
  instead of evicting a live one, so a flood of keys cannot reset an attacker's budget.
- Premium activation validates the URL list it receives before trusting any of it. Only
  `https` URLs with a host and no credentials or fragment may become premium sources, and
  a host is recorded only after its feed actually loaded, so a failed activation no longer
  leaves a "premium" badge on an arbitrary host. Local mode (operator-configured, possibly
  a LAN address over HTTP) keeps its exemption through an explicit origin parameter.
- The archive-extraction gate now covers the extraction routes it claims to. It matches
  ZIPFoundation's `Archive(url:)` alongside the writer calls, skips the validator itself,
  and counts `IPAExtractor.extract` call sites so a route that stops using the validating
  wrapper fails the gate instead of quietly leaving the scan empty.

### Fixed

- A `vexsign://import-certificate` link no longer installs a signing identity silently. The
  staged pair is validated first, the user is asked to confirm, and the staged `.p12`/
  `.mobileprovision` copies are deleted once the outcome is known. A custom-scheme link is an
  untrusted sender; a handed-over backup was already staged for review, and a certificate can
  sign every later install.
- Cloud signing claims a job with `UPDATE … WHERE state='queued'` and stops when it loses that
  transition, so a dispatcher re-publish or a BullMQ retry can no longer sign the same IPA twice
  or overwrite a finished result. `PendingJobDispatcher` resets a `running` row whose Redis job
  is gone (older than 30 minutes) to `queued` so it stays claimable.
- `decodeAndWrite` rejects an oversized deep-link payload on the encoded length, before
  whitespace filtering, base64url substitution and the decode copy the payload, and skips those
  passes entirely when the input needs none of them.
- The background download task now arms `com.vexsign.background.refresh`; the identifier was
  registered and permitted but never scheduled, so its handler could never run. Submission
  failures are logged instead of swallowed, and `BGContinuedProcessingTask` is gated on iOS 26
  (the release that ships it) rather than an `iOS 19.0` that does not exist.
- Home's title and stat text use semantic fonts, so they follow the system text size.
- Download headers, the download bubble and the device picker carry accessibility labels; the
  bubble also exposes its progress as an accessibility value.

- Direct Install owns/cancels its screen task, serializes overlapping imports,
  and binds each once-only warning confirmation to the reviewed request. A
  dismissed sheet cannot submit a later installation; registered artifacts and
  accepted handoffs survive cancellation. Confirmation retains the actual guest
  vs device-submission outcome instead of always displaying a device install.
- All app snapshot projections now share one throwing store-admission gate,
  including typed signing/batch outputs and workspace reads. Foreign-context,
  deleted and temporary rows cannot bypass validation through a typed overload.
- Backup completion delays and Restart actions are bound to the visible
  operation and consumed once. Dismissal/reappearance cannot revive stale
  callbacks, and cancellation does not pretend to undo committed restore data.
- Retired batch installer callbacks cannot resume a later entry. Stop/skip after
  an iOS handoff preserves delivery without claiming installation confirmation.
- Certificate mutation saves are isolated; failed deletion retains credentials
  and durable recovery files. Undo preserves nil dates and eligible app links;
  old status checks cannot publish for an undone/reimported row.
- Signing completion side effects use the reviewed request/output and are
  consumed at most once. Explorer/companion dismissal forwards cancellation,
  waits for active readers and cannot trigger a stale install/session switch.
- Direct-import results distinguish guest-import and installation submission from
  device-confirmed installation. Unknown routing fails closed. Temporary work,
  confirmation handles and existing verification remain with their real owners.
- Workflow/source-test/resource paths follow the feature migration without
  rewriting bundle-relative fixtures, public feed URLs or upstream attribution.
- The workspace support use case no longer imports UIKit, presents alerts
  directly, or reads device/user-default/pairing globals; those facts are
  injected through a Domain port and a Platform adapter, with XCTest coverage.
- The app target compiles under Swift 6 diagnostics again: the Anisette provider
  use case no longer evaluates a main-actor singleton in a default argument, and
  shared-file import failures now use a real `Error` type instead of `String`.
  Portable source guards cover both regressions; a fresh macOS CI build is
  required to confirm the compile on this branch.
- Public server URL probes reject malformed ports and malformed IPv6 URLs on
  both the DNS and fast paths, so a hostile redirect can no longer crash the
  probe/decode endpoints or skip port validation.
- External OTA installs no longer fall back to an unverified manifest endpoint.
  Every candidate must return an XML plist, and the install is refused with an
  error when none does.
- Shared diagnostic logs now redact imported certificate/session payloads,
  pairing secrets, hardware identifiers, device names, UDIDs and the local part
  of email addresses, while keeping ordinary errors and domains readable.
- Certificate/profile base64 deep links accept standard base64, base64url,
  missing padding and whitespace, and reject oversized payloads before staging.
- Task history written before the build fields existed loads again. One such
  record used to make the whole history unreadable.
- Concurrent first writes to the library can no longer each create their own
  write context, which let two new apps take the same sort position.
- A library entry whose executable is gone is reported as incomplete. The check
  never ran because nothing told it which file to look for; it now reads the
  name from the bundle's Info.plist.
- Scheduled signing checks its permission for each app against the certificate
  that app will actually be signed with, so a per-app pinned certificate is not
  covered by a permission given for another one, and turning the permission off
  stops the rest of a running queue.
- Signing refuses a certificate whose last status check recorded a revocation,
  even if the certificate entry itself was not updated.
- The ordinary app registers its background tasks again. Their availability had
  been tied to the embedded runtime being loaded, which is never true in the
  ordinary build, so no scheduled work was registered.
- A symlink or a folder named like a library at the top of an app is no longer
  treated as a library to sign, matching what is already done inside the app's
  subfolders.
- The tvOS and visionOS companion apps build again.

- The batch certificate check shows "Not Checked" for a certificate that is in
  date but whose revocation was not established, instead of "Valid". The
  Shortcuts action reports those separately.
- The batch certificate check reports the certificate's own expiry when it ends
  before the profile's, matching the certificate list and Home.
- The device sheet tests the pairing session when it opens instead of always
  reporting it as unavailable, so paired install and removal show their real
  state.
- When a tweak cannot be added to an app extension, the signing log now says
  which extension is without it.
- The Discover screen's header and its appearance setting are named Discover.
- Published GitHub/raw compatibility URLs, the `VexSign/Packages/NativeSigning` SwiftPM
  local dependency path, pbxproj membership-exception validation and moved
  Python tool/test roots were corrected after the ownership-root move. Portable
  gates cover these regressions; Xcode, simulator and device checks remain open.

### Changed

- CI's cost policy is split from its validation policy. Only jobs that spend premium
  runner minutes (every `macos-15` job) and workflows that write to the repository stay
  gated on the repository being public; the Linux validation jobs now run for private
  repositories and private forks too. Before this, making the repository private — or
  working in a private fork — skipped every workflow while the check stayed green. The
  rule is asserted in `test_workflow_policy.py` and described in `MAINTENANCE.md`.
- `make verify` runs every gate in one pass and lists the failures together instead of
  stopping at the first, runs the Swift syntax parse when a `swiftc` is installed (it used
  to pass `--no-swiftc` unconditionally), and covers the gates that were CI-only:
  `test_docs.py`, `test_capability_disclosure.py`, `test_task_history_resilience.py` and
  `sync_repo_aliases.py --check`.
- SwiftPM's `-skipPackagePluginValidation` and `-skipMacroValidation` are gone from CI,
  `platform-check.yml`, the `Makefile` and `bootstrap.sh`. The package graph declares no
  build-tool plugin and no macro, so the flags only hid the question; a build that ever
  needs one should name it and skip only that.

### Changed

- Flattened platform source roots to `VexSign/App/{iOS,TV,Vision,WidgetExtension}/`
  and twelve further single-child wrappers in feature views, package sources,
  services, resources, documentation and integrations. The
  [repository audit](VexSign/Documentation/Architecture/repository-layout-audit.md)
  records all moves and four retained tool-owned chains. Multi-child folders,
  Watch/shared platform-info paths, target/module names, bundle identifiers and
  schemes are unchanged. All affected inputs, automation and path baselines
  follow the new layout; portable checks do not replace an Apple build.
- Scheduled "sign and queue" passes now sign only while that permission is
  active. Without it they notify instead. If you already use "sign and queue",
  allow background signing once to keep it; runs you start yourself are
  unchanged.

- Tweak injection now checks every library before it places any of them. A
  library with no arm64 slice (including arm64e-only builds), built for another
  platform, still encrypted, malformed, or hard-linked to a file outside the app
  sandbox is refused with the reason named, and the app bundle is left as it was.
  The tweak's info screen applies the same rules, so it previews that outcome.
- A `.deb` is read from one tree only. Rootful and rootless (`var/jb/`) payloads
  are no longer merged: the package's files decide the layout, the control
  file's `Architecture` distinguishes rootful from roothide, and a package with
  payload in both trees is refused.
- Every absolute hook-runtime load path (`CydiaSubstrate`, `libsubstrate.dylib`,
  `libellekit.dylib`, rootful or rootless) is redirected to the bundled ElleKit,
  not only the one rootful Substrate spelling.
- Certificates are shown with one assessed status: Valid, Expired, Revoked,
  Unknown, Check Unavailable or Check Unsupported. Valid requires a positive
  revocation answer less than a day old; an unreachable responder is reported as
  such and is never shown as valid or revoked.

- The default tab order is Home, Discover, Library, Tasks, Settings. "App Store"
  is now "Discover" and "Activity" is now "Tasks". A tab order you arranged
  yourself is kept; an order that was never changed follows the new default.
- A tweak that needs a hook runtime is refused when the bundled ElleKit cannot be
  found, instead of producing an app that stops at launch. A hook path that could
  not be rewritten, or a load command that could not be added, also stops the run.
- Package dependencies that nothing in the injection provides are named in the
  signing log.
- Home shows the same certificate status as the certificate list.
- Signing stops before it starts when the signing certificate itself has expired,
  even if the profile has not. The date comes from the last status check.
- Importing a single tweak library refuses one that no app could load, and says
  why, instead of accepting it and failing at signing.
- The signing workflow lists the stages each run actually reported under its step.
- Shortcuts call the sections Discover and Tasks, matching the tabs.

### Fixed

- arm64e Mach-O slices were reported as arm64. The subtype was compared without
  masking the capability bits, and toolchains write arm64e as `0x80000002`, so
  the comparison never matched. The bundled ElleKit's second slice is the case
  in point.
- A cached "verified" certificate status stayed on screen after the certificate
  or profile expired, and for as long as the cache entry existed.
- A certificate whose revocation policy could not be created made the whole
  inspection fail, hiding its expiry dates. A status check that could not read
  the certificate files returned silently; it is now logged.

### Fixed

- Two of the new pipeline tests tripped the main-actor runtime check. They awaited
  the `nonisolated` `SigningPipeline().run(...)` from a `@MainActor` test while
  passing a `Signed` fixture that belongs to `Storage.context`, the *view*
  context — the exact cross-queue use `Storage` documents as forbidden. The
  refused-identity cases now assert `SigningIdentityPolicy.rejection(for:)`
  directly, which is the property they were checking; the ordering that makes the
  gate effective is already pinned by
  `testThePipelineAsksTheIdentityPolicyBeforeStarting`. A duplicate modify-only
  test was dropped, since `testModifyOnlyNeverNeedsAnIdentity` covers it plus the
  expired-certificate case. The same fix applies to
  `testTheRealPipelineRefusesAnExpiredIdentityBeforeTouchingTheBundle`, which was
  the last test still taking that illegal hop; it now asserts the gate reports the
  certificate's own expiry.
- Four of the new acceptance tests failed on their first real run, which is what
  they were for. `CertificateRemovalDurabilityTests` and the
  `SigningIdentityPolicyTests` fixture created a `CertificatePair` without
  `ppQCheck`, `isDefault` or `date` — non-optional in the model — so Core Data
  refused the save with *ppQCheck is a required value*.
  `testArchiveRejectsDuplicatesThatDifferOnlyInUnicodeNormalization` asserted
  `precomposed != decomposed`, but `String` compares by canonical equivalence and
  the two spellings are equal; the assertion now compares UTF-8 bytes, which is
  the difference the archive and the filesystem actually see. Suite totals before
  the fix: 1339 tests, 1330 passed, 7 failed.
- `testExistingSymlinkCannotAliasSourceOrEscapeInbox` was right to fail.
  `resolvingSymlinksInPath()` leaves a path that does not exist yet unaltered, so
  a destination of `alias/new` was never resolved and the alias stopped being
  visible exactly before the write that would follow it. Fixed in
  `WebDAVTransferPolicy` (7d6b624) by resolving the deepest existing ancestor and
  re-appending the rest. The test fixture deliberately keeps its unresolved
  `temporaryDirectory` root, so it fails again if that fix is reverted.
- The post-sign certificate check was in the wrong function and did not compile.
  Phase 2 put `expectation.expectsFreshSignature` inside
  `_signatureIssues(in:executable:)`, which has no `expectation` parameter —
  *cannot find 'expectation' in scope*. The parameter is now threaded through, so
  the check still reads the certificate out of the signature zsign produced and
  still runs only for bundles this run signed. Caught by the macOS `build` and
  `tests` jobs (runs 43168765711).
- The `DownloadManager` split did not compile. Swift's `private` is scoped to the
  *file*, not the type, so five members the moved code uses became invisible:
  `isBatchControllingDownloads`, `ensureKeepAlive` and `releaseKeepAliveIfIdle`
  (declared in `DownloadManager.swift`, used by `+TransferControl.swift`) and
  `networkPolicyAllowsStarting` and `networkPolicyDidChange` (moved out, still
  used by `DownloadManager.swift`). `fileprivate` does not help either — it is
  file-scoped too, and the build failed again with *is inaccessible due to
  'fileprivate' protection level*. Reaching across a split needs `internal`, the
  default, which is still module-scoped and so does not widen the public
  interface. All five now use it.
- `VexSign/Tools/Validation/security-validation/test_cross_file_privacy.py` pins this: for each type split across files,
  no `private` member may be referenced from a file that does not declare it.
  It follows braces to attribute a member to the type it is private *inside* (a
  file can declare several), treats top-level directories as separate modules,
  and counts `self.member` as a real reference.
- `CertificateFileHandler.clean()` did not compile after that. An `OSLogMessage`
  interpolation is an `@escaping @autoclosure`, so an *instance property* inside
  one needs an explicit `self.`: `\(_uuid)` became `\(self._uuid)`. The other four
  sites interpolate locals or a captured `error`, which are unaffected.
- Five log calls added by the storage-durability change did not compile. OSLog's
  `Logger.fault`/`Logger.error` take an `OSLogMessage`, which is built by string
  interpolation, so joining the message with `+` is a type error — the macOS
  `build` and `tests` jobs rejected all five with *cannot convert value of type
  'String' to expected argument type 'OSLogMessage'*. They are now single
  interpolated literals. The same edit marks each redacted description
  `privacy: .public`: OSLog interpolation defaults to `.private`, so those
  messages would otherwise read as `<private>` in Console — hiding the very
  failures that change was written to surface.
- `VexSign/Tools/Validation/security-validation/test_logging_message_policy.py` pins both properties: no `Logger` call
  concatenates its message, and no `LogRedaction.redact(...)` reaches OSLog
  without `privacy: .public`. Neither is visible to the localisation, docs or
  `swift-syntax` checks, which is why only the Apple jobs caught it.

### Changed

- Free Apple ID and paid-certificate signing no longer share wording that implies
  the wrong one runs. `SigningMethod.shortDescription` said **Weekly refresh**
  for Free Apple ID, and the method picker renders that string: it promised an
  automatic renewal that does not exist in this build. It now says **Renew by
  hand each week**. The unused `supportsAutoRefresh` property is gone — it
  answered `true` for Free Apple ID with nothing behind it.
- Two internal names described work the app does not do. `NativeSigningManager`
  exposed `renewExpiringProfiles()` and `BackgroundAutomation` a scheduled
  `renewFreeAppleIDProfiles()` step; both only refetched the list of profiles
  close to expiry, and the scheduled step's doc comment claimed it "renews them".
  They are now `refreshRenewalCandidates()` and
  `trackExpiringFreeAppleIDProfiles()`, and the comments say renewal is manual
  and needs an explicit grant this build does not have. No behaviour changed.
  `VexSign/Tools/Validation/security-validation/check-native-handoff.py` fails if either name, or the "Weekly refresh"
  copy, comes back.
- `DownloadManager` is split along a boundary it already had. Network policy and
  the transfer lifecycle — pausing, cancelling, resuming, and finishing a
  download when its task ends — moved to `DownloadManager+TransferControl.swift`,
  matching the existing `+PackageImport`, `+Recovery`, `+Delegates` and
  `+LiveActivity` extensions. No behaviour changed; the bodies are identical.
- The launch screen uses a rounded version of the existing VexSign mark. Home
  actions stack at accessibility text sizes, and the app-icon picker reuses its
  preview images instead of decoding them each time the view is constructed.
- Library grid swipe actions respect Reduce Motion and button-animation settings,
  with selection haptics and an optional, off-by-default interface sound. The
  sound setting is in Appearance and currently applies to revealing that action.
- **Delete Signed App** (Settings → Auto Cleanup → After Signing) now removes the
  signed copy a re-sign was *started from*, once the new copy is in the library.
  In the signing sheet and when signing with saved settings it used to delete
  the *new* copy whenever the run was not set to install it, so that signing
  produced nothing. The copy a successful run produced is no longer deleted
  when the sign finishes, whatever the settings are.
- **Re-sign with Last Settings** keeps the signed copy it was started from. In
  Library rows, in Library details and in the Shortcuts action Sign App it used
  to replace that copy on every run. It now removes it only when Auto Cleanup
  and Delete Signed App are both on, and the review in Library details says
  which of the two will happen. With the default settings a re-sign therefore
  adds a signed copy instead of replacing one. Batch jobs follow the same
  switch for the signed copies they re-sign; they never removed one before.
- **Clean Now** leaves temporary files and leftovers alone while a sign or an
  install is running, as the automatic passes do, and says what it left: in a
  message when the button is used, and in the answer of the Shortcuts action.
  They are cleared by the next pass that finds nothing running.
- The contents of a backup are now stated where the component list is defined: no
  task-history component, because the Activity log marks itself
  `isExcludedFromBackup` and describes what one install did on one device.
- `make` builds through `VexSign.xcworkspace`, the same graph CI builds and tests.
  The workspace and project `Package.resolved` files had drifted apart, so the
  released IPA was compiled against pins CI never exercised. Both now hold one
  identical set of 42 versioned pins, and `VexSign/Tools/Validation/repository-validation/check-package-graph.py` fails on
  drift or an unsatisfied requirement.
- Code coverage is enabled on the shared `VexSignTests` scheme; CI reports the
  overall number and the least-covered first-party files (reporting only).
- Weekly hygiene prunes localisation keys that are both stale and absent from the
  source, and reports per-language coverage. Thirteen dead keys were removed;
  in-use keys Xcode had merely marked stale keep their translations.
- Error-discipline baseline lowered from 386 to 244 unjustified `try?` sites and
  the singleton freeze from 62 to 61, with the reasoning recorded at each site.
- The three largest files were split along existing seams, moving code verbatim
  into extensions: `AppStoreView` 1487 → 765 lines (`+Discover`, `+Repositories`),
  `DownloadManager` 1081 → 824 (`+PackageImport`), and `VexSignApp` 840 → 644
  (`AppDelegate+BackgroundTasks`). Only the access levels Swift requires for a
  cross-file extension changed.

- Add an opt-in extension compatibility mode that preserves covered bundles and
  the main app while removing only known-uncovered nested extensions; the log
  identifies each removed path and bundle identifier.
- Keep strict extension preflight when compatibility mode is off, and explain
  when compatibility mode will remove an uncovered extension.
- Close the signing sheet automatically on success and use one presentation
  state for preflight and signing logs.
- Make deletion of custom entitlements files and individual entitlement keys
  easier to discover and confirm.

### Security

- Signing now refuses an identity that cannot produce an installable app, on
  every path rather than only in the Signing screen. Certificate expiry used to
  be checked by the preflight sheet alone, so **batch**, **Update All**,
  **Shortcuts** and **self-update** handed an expired or revoked certificate to
  zsign: the run reported success and the app was rejected at install with an
  error that names the signature, not the cause. `SigningPipeline` now asks
  `SigningIdentityPolicy` before it copies anything, and the run's log says
  which identity problem stopped it. Modify-only runs are unaffected, because
  they never use a certificate. The **Sign Anyway** override does not excuse
  this: an expired certificate cannot install, unlike the profile and
  entitlement problems that override exists for.
- After signing, the verifier reads the certificate that actually signed the
  bundle out of the produced signature and fails the run if it has expired.
  This catches a certificate that lapsed since it was imported, or a stored row
  with no date — the row is a cache, the signature is the evidence. Bundles
  signed elsewhere are unaffected: installing without signing still accepts an
  app whose signing certificate has since expired, which iOS allows.
- The Apple TV and Vision Pro companions store the Web Manager password and API
  token in the Keychain instead of `UserDefaults`. Both keys were written on every
  edit, so a reusable password and a token with the same reach sat in every
  preferences dump, backup and diagnostics bundle. Existing values migrate on
  first launch, and the plaintext copy is removed only after the Keychain write
  succeeds — a locked Keychain therefore keeps a working credential instead of
  losing it, and the connect screen says so. A failed write is reported in place;
  no credential value is logged.
- The companion client defaults to HTTPS. An address typed without a scheme used
  to become `http://`, which sent Basic credentials and the token in cleartext.
  Plain HTTP now requires an explicit **Allow HTTP on this network** switch *and* a
  local-network host (private IPv4, IPv6 link-local/unique-local, `*.local` or
  loopback); a public address is refused and an `https://` address is never
  downgraded after a failed connection. Redirects are refused rather than followed,
  so `URLSession` cannot forward `Authorization` and `X-VexSign-Token` to another
  host.
- The app no longer writes SwiftUI's undocumented
  `com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck` preference to force the Liquid
  Glass redesign. The stale value is cleared once from the container, and
  `VexSign/Tools/Validation/security-validation/test_private_defaults_policy.py` now fails on any first-party write to a
  `com.apple.*` default.
- The archive validator folds Unicode normalization into an entry's identity, so
  the same file shipped once precomposed and once decomposed (`Café.app` as NFC
  and NFD) is a duplicate rather than two paths that collide on APFS. It also
  rejects an archive that uses one path as both a file and a folder, whichever of
  the two entries comes first; previously the extractor decided that by order.
  `VexSign/Tools/Validation/security-validation/test_archive_extraction_policy.py` keeps every extraction route behind
  `ArchiveSafetyValidator.validate(_:destination:)`.

### Fixed

- Deleting a certificate no longer reports success when its private key could
  not be erased. The certificate's folder holds the imported `.p12` and its
  profile; the removal used to swallow every error and then delete the row, so
  the screen said the certificate was gone while usable key material stayed on
  disk — reclaimed only if **Remove Leftovers** happened to be on. The row is
  still deleted, and a failed removal is now recorded so the leftover is named
  and can be reclaimed. The same silence in the failed-import cleanup is fixed
  there too, where no row exists to own the staged key.
- A library stored under the old `Feather.sqlite` name can no longer appear to
  vanish. If the one-time migration to `VexSign.sqlite` failed, the app used to
  open a new, empty store beside the intact original: every app, certificate
  and source looked deleted, and nothing was reported. The store is now opened
  in place at its old name so the library keeps working, and the move is
  retried on the next launch. The corrupt-store recovery is also refused while
  that fallback is active, because it deletes the store file together with the
  signed, unsigned and certificate folders.
- `make verify` no longer fails on a source archive. `VexSign/Tools/Development/device-acceptance.py`
  called `git rev-parse HEAD` unconditionally, so running the suite from an
  unpacked zip (no `.git`) ended in `fatal: not a git repository` and failed the
  native acceptance test for a reason unrelated to acceptance. The commit now
  comes from `--commit`, then `VEXSIGN_SOURCE_COMMIT`/`GITHUB_SHA`, then git, and
  a run with none of them exits with a one-line diagnostic instead of a traceback
  and without writing a report. The commit binding itself is unchanged, and the
  new tests cover the archive case, the CI case and a mismatched report.

- Home no longer describes an empty update list as proof repositories are up to
  date, or claims a URL download started when the manager rejected it. It keeps
  rejected input and points tracked downloads to their status. Source setup is
  described as optional; Home also improves large-text and URL-field access.
- Library cards and icon tiles now reveal a Delete action on a left swipe, like
  the existing compact-list action. Delete still asks for confirmation and only
  removes the stored library copy; swipe right to close the action.
- Debian tweak archive members must now be single safe filenames and cannot
  repeat (including case-only variants) before either analyzer or injector
  writes them. Conventional trailing slashes on short ar names are accepted.
- Web Manager and WebDAV deletion report a conflict when removal fails, and
  not found for a missing item, instead of always reporting success. WebDAV
  also recognizes normalized aliases of the inbox root before deleting.
- Web Manager upload, download and inbox deletion reject filenames that resolve
  to `.` or `..`, or contain control characters, rather than treating them as
  file names. Download response filenames are escaped as quoted HTTP parameters.
- WebDAV MOVE and COPY reject transfers involving the inbox root or overlapping
  source and destination paths before deleting an existing destination. This
  prevents a same-path or parent-directory overwrite from deleting the source.
  A failed destination removal now returns a conflict instead of being ignored.
- A backup archive is treated as untrusted input when it is opened. Its
  certificate identifiers are used as directory names on both sides of a restore
  (`certs/<uuid>` inside the archive, `Certificates/<uuid>` in the app
  container) and were checked only for being distinct, so a crafted archive
  could name a path such as `../../..` and have a restore copy into — or, on
  rollback, delete — a directory outside the certificate folder. They must now
  be real UUIDs, which every identifier this app writes already is. The
  repository URLs a restore reinstates are held to the shape half of
  `SourceURLPolicy`: `http` or `https`, a host, and no credentials embedded in
  the URL. The documented exemption that lets a saved LAN repository restore
  without the HTTP opt-in still works, while `file:`, `javascript:` and other
  schemes are rejected, and a source's icon URL is held to the same rule.
- The multi-source property on a discovery group is computed from its sources.
  It was `versions.count > 1`, so one repository listing 1.0 and 2.0 of the
  same app reported itself as available from several sources. Nothing rendered
  it yet; the next caller would have inherited the wrong answer.
- `InstallConfirmation.Verdict.notInstalled` and `InstalledState.notInstalled`
  are now documented as what they are: not reachable from the shipping probe,
  which reports an app or reports nothing, because a refused or filtered private
  lookup and a deleted app look identical. The engine reports such an install as
  `timedOutVerifying` ("Not confirmed") and never as not installed, which is
  pinned by a test that drives every answer the three probe entry points can
  return. The boundaries of `LibraryStatusStore.attemptTimeout` are covered too:
  an attempt started exactly the bound ago is still active, one second later it
  is abandoned.
- A restore decides what it may write in one place, `BackupRestorePlan`: an item
  the store already tracks is never replaced, an entry whose files are missing
  from the container is skipped and counted instead of aborting the entries after
  it, and a directory that exists with no record pointing at it is never
  replaced either. Restoring the same archive twice therefore adds nothing the
  second time. Those rules were inline branches in `BackupManager.restore`,
  which had no test of any kind, and certificate and library restores now apply
  the same order. The library loop's missing-payload branch could only be
  reached through a container damaged *after* `open` checked every bundle was
  present, so this consolidates the rule rather than fixing a defect there.
- A backup no longer carries credentials. The settings filter accepted everything
  under `VexSign.` and `vexsign.`, so `IdentityVault`'s `VexSign.vault.*` values —
  cloud-signing API key, premium activation, device UUID — and any key named
  `…apiKey`, `…token`, `…secret`, `…password` or `…passphrase` were written into
  the archive and written back into `UserDefaults` by a restore on another
  install. The plaintext `VexSign.cloudSigningKey` that earlier builds kept in
  preferences is denied under both spellings, for installs whose Keychain
  migration did not complete.
- Version precedence is decided in one place, `VersionOrder`. Three comparators
  answered "is this newer?" before, and they disagreed: `AppUpdateChecker` was
  SemVer-aware, while `DownloadButtonView` had two copies that compared dotted
  integers and dropped every other component. `"1.1-beta"` therefore compared as
  `[1]` and lost to `"1.0"`'s `[1, 0]`, so the App Store detail screen showed no
  update for a beta of a newer version while the Updates list offered that same
  version as one. The firmware browser's own compare delegates to the same rule.
- Choosing which installed copy represents a source app now prefers a copy whose
  version can actually be ordered, instead of letting a later copy with a missing
  or unparseable version displace one that has it. Equal versions keep the first
  candidate, which is the signed copy before the imported one.
- The in-app cloud-signing client now speaks the contract its service documents.
  `POST /api/upload` takes `kind` as a **query** parameter and exactly one multipart
  file, and answers `{id,kind,bytes,sha256}`; the app sent `kind` as a form field and
  decoded `{id,key,size}`, so an upload against a reachable cluster answered 400 and a
  success could not have been read even then. The request is built by
  `CloudUploadBody`, which the tests check against the documented shape.
- Cloud uploads no longer load the archive into memory twice. The body used to be
  `Data(contentsOf:)` plus a concatenated `Data` copy — up to 4 GiB for the 2 GiB IPA
  the service accepts. It is now written to a temporary file one 1 MiB chunk at a
  time, off the main actor, and streamed with `URLSession.upload(for:fromFile:)`;
  the temporary copy is removed when the request ends.
- The cloud-signing bearer token is stored in the Keychain instead of
  `UserDefaults`. The token was kept in plaintext preferences, where it appeared in
  backups and preference dumps. It is migrated once on first launch and the plaintext
  copy is removed only after the Keychain write succeeds; a locked Keychain leaves the
  old value in place and reports why.
- The install card's status line is resolved from the installation lifecycle as well
  as the transport. It used to start with `guard case .installing = viewModel.status`,
  so every other transport status discarded the lifecycle: an OTA install read
  **Ready** while iOS was showing its own confirmation prompt, and verification was only
  shown on the one status the OTA path happens to pass through. A single
  `InstallStatusPresentation` now decides the line, the icon and the number together —
  a terminal transport answer wins, the lifecycle outranks a transport status that has
  not caught up, and a timeout reads **Not confirmed** or **Not started** instead of
  **Ready**. The batch queue line uses the same resolution, a device-proved completion
  says **Installed** rather than **Completed**, and the progress ring's VoiceOver label
  follows the same state instead of always saying "Installing".
- **Re-sign with Last Settings** and **Update All** no longer stop in the
  Customize step after a sign that used one-time tweak files. Files added "just
  for this sign" are staged in the temporary directory, and their paths were
  saved with the app's signing settings and with named presets. The engine moves
  what it injects, and the temporary directory is emptied at launch and by Auto
  Cleanup, so every later run that reused those settings stopped on a file that
  no longer existed, with a bare "no such file". A run now injects its own copies
  (a second attempt in the same sheet still has its inputs), saved settings keep
  the file *names* and never the paths, settings and presets already on disk are
  cleaned when they are read, and a run that reuses them logs which files it left
  out. A file that is missing is reported by name in the preflight, and again
  before anything is injected.
- **Sign Anyway** in Library details is honoured. The repeat-signing review listed
  the blocking preflight issues and offered the override, then started the run
  without it, so the run stopped on the issue that had just been accepted.
- A certificate or profile refusal is shown on the **Sign** step. Everything
  before the engine started signing was reported as Customize, so a profile that
  does not cover a retained extension read "Customize: Failed, Sign: Not run" for
  a bundle whose customization had finished.
- Library details no longer shows **Failed** for a valid signed copy after a
  re-sign that failed. A run is recorded against the copy it started from; the
  screen showed the newest such run as the copy's "last recorded signing result".
  It now shows the run that *produced* the copy as "Signing result for this copy",
  and a later attempt separately as "Latest re-sign attempt from this copy" with
  its redacted reason, its own steps and the statement that it did not change the
  copy. The receipt of a failed or cancelled signing attempt says the same.
- **Re-sign with Last Settings** in a Library row's context menu reports its
  result. It discarded the outcome, so a failure said nothing; it now takes the
  same path as the swipe action (app-lock check, success and failure messages).
- Automatic cleanup no longer empties the temporary directory while another
  signing or installation is running. One operation finishing could delete the
  work directory of a sign still in flight, or the archive an install was handing
  to iOS. The directory is cleared by the next pass that finds nothing running,
  and at the next launch. **Clean Now** follows the same rule; see Changed.
- An install can no longer stay on **Verifying installation** with nothing left
  to end it.
  - Once the payload has been handed to iOS the whole attempt is bounded from
    outside the polling loop (390 s of running time), not only the verifying
    phase. Reaching that bound is reported as **Not confirmed**, never as a
    success or a failure.
  - The polling loop no longer runs at background priority, which the system may
    hold back indefinitely.
  - Device checks are spaced out (0.5 s growing to 3 s) with a lookup timeout
    that grows from 1 s to 4 s, instead of one check a second with one second to
    answer. The card shows "Verifying installation (check N)" from the second
    check, and the count is written to the log and the task receipt.
  - One unanswered check no longer ends verification for an app iOS was
    reporting a moment earlier; the short no-evidence deadline applies only when
    the device has given no answer for 10 s.
  - Deadlines kept beside the polling loop count time while VexSign is running.
    Timed as one sleep they also ran out while the app was suspended and closed
    the card as "Not confirmed" on return, ahead of the check that could have
    confirmed it.
  - An install treated as declined (VexSign regains focus and iOS never asks
    for the payload) closes that app's task record as Cancelled. The record was
    left open: for the last app in a queue it was then marked Completed, and
    otherwise the next app ran on the declined app's record.

  None of the entries above has been exercised on a device yet; see
  [the follow-up record](VexSign/Documentation/Decisions/History/signing-and-installation-lifecycle.md#follow-up--re-signing-with-saved-settings-the-record-of-a-signed-copy-and-install-verification)
  for what was and was not validated.
- A sign that succeeds can no longer leave no copy in the library. With Auto
  Cleanup's **Delete Signed App** on and settings that do not install after
  signing, **Re-sign with Last Settings** deleted the copy it was started from
  and Auto Cleanup then deleted the new one; the signing sheet deleted the copy
  it had just produced the same way. Every flow that signs a library app now
  settles its copies through one rule: the new copy always stays, and the copy
  the run was started from is removed only when a flow or a setting asks for
  it, only after the new copy is confirmed to be in the library with its bundle
  on disk, and never when the two are the same copy. If the removal is refused
  because the copy is in use, both copies stay.
- **Remove Leftovers** can no longer delete a copy that is being signed or
  imported. A copy's bundle is in the library before its entry is, and a
  cleanup pass in between could take the folder for a leftover, leaving an
  entry without files. Signing and importing now announce the copy before its
  folder exists, every check for leftovers asks about it at the moment a folder
  is judged, and leftovers wait while any operation is running.
- **Keep only the newest signed copy** keeps the newest. A re-signed copy has
  the version of the copy it was started from, and the rule compared versions
  only, so which of the two it deleted depended on the order they were read in.
  Among copies of one version the one added last is now kept, versions are
  compared number by number (1.2 and 1.2.0 are the same version), and a copy
  that is in use no longer stops the other duplicates from being removed.
- Cleanup no longer reports an app as removed when the removal was refused. The
  message and the cleanup history could name apps that were still in the
  library, because a copy in use by another operation is not deleted.

  These four entries, and the three at the top of Changed that go with them,
  have not been exercised on a device or compiled against the iOS SDK yet; see
  [the second follow-up](VexSign/Documentation/Decisions/History/signing-and-installation-lifecycle.md#follow-up-2--what-a-successful-sign-leaves-in-the-library)
  for what was and was not validated.
- An OTA install that iOS never reported on is no longer called **Failed**. On
  modern iOS the private LaunchServices lookups are filtered, so `InstalledAppProbe`
  returns nothing even when the app installed correctly. That hit the 30-second
  no-evidence deadline and produced a receipt reading `Install · Failed`,
  `installation-evidence-unavailable`, telling people to retry an app already on
  their Home Screen. There is now a terminal **Not confirmed** task phase: not a
  success claim, not a failure. The receipt says iOS did not expose the result, the
  suggested next step is to check the device rather than re-run the installation
  checklist, and retry is still available.
- An app iOS is still writing is no longer cut off by that same deadline. A
  placeholder probe is positive evidence of an in-progress install and now gets the
  full verification window; only a probe that returns nothing at all uses the short
  one.
- Import failures say what actually went wrong. `ImportError` printed only
  `Detail: <domain> (<code>)`, which is identical in shape for every archive-safety
  rejection and names neither the entry nor the reason. It now includes the
  underlying message (which names the offending path) and keeps the domain/code as
  a separate `Source:` line.

- Certificates sign app extensions again (#137). Three defects combined into
  "extensions stopped being signed after the update":
  - The preflight judged extensions by the bundle identifier they had *before*
    the rename. Both `SigningHandler._modifyPluginIdentifiers` and the pinned
    engine (`ZBundle::ModifyPluginsBundleId`) replace the old app identifier
    inside every nested bundle, so a profile covering the new identifier covers
    the renamed extensions too. Coverage is now evaluated on the identifier the
    signer will actually produce, which is what the handler already used — the
    two disagreed before.
  - "Sign Anyway" was offered by the preflight sheet and honoured by the post-sign
    verifier, but the nested-bundle audit threw regardless, so confirming the
    override still aborted the run with no way through.
  - The one-time options migration forced extension compatibility mode — which
    *deletes* extensions — back on over a saved "off". A saved choice is now left
    alone; blobs that predate the key still decode to the default.
- The simulator test suite is green again (#136). `ProtectedCertificateFiles`
  applied `.protectionKey` with `setAttributes`, which the simulator refuses
  because it has no data-protection classes. That ran before the first move, so
  certificate migration aborted with nothing copied and fell back to the legacy
  directory. A volume that does not implement protection classes is no longer
  treated as a migration failure; every other error still propagates, so a device
  cannot silently lose protection.
- Storage cleanup no longer deletes certificates when the library cannot be
  read. `StorageManager` built its orphan list from `try? context.fetch(...)`:
  a failed fetch produced an empty certificate set, which read as "none
  installed", so *Clear leftovers* removed every certificate on disk. The
  snapshot now records whether the list is complete and treats an incomplete one
  as "protect everything", with a log line and regression tests.
- Web tools no longer render untrusted text as markup. The Repository Decoder
  and Creator (app names, versions, developers and issues from any remote feed),
  the UDID Grabber (device-reported attributes), the Signer Console (certificate
  name from the phone, chosen file names), Certificate Check (fields from an
  uploaded provisioning profile) and the App Installer (content type and redirect
  URLs from the probed host) all passed values into `innerHTML` unescaped, so a
  malicious feed, profile or host could run script in the tool's origin and reach
  the relay endpoints. A shared `esc()` helper now covers every such field, with
  regression tests that execute the helper and the page helpers that use it.
- Three silent failures now report themselves: an unreadable web-manager inbox
  no longer looks like an empty one, a failed temporary-directory listing is
  logged, and a web upload that cannot create its destination directory records
  why before returning 500.
- `AnisetteProviderDescriptor.defaultHTTPS` propagates a validation failure
  instead of `try!`-trapping on an endpoint the descriptor refuses.
- The bundled `AnisetteServer` is labelled and documented as the protocol mock it
  is: its headers are fabricated and Apple rejects them. Its manifest declared a
  non-existent SwiftPM Linux platform while importing Apple-only `Network`, so it
  could not build as declared; it now targets macOS and drops the force-tries.

- TrollStore hand-off now uses the scheme TrollStore actually registers.
  TrollStore 1.3+ replaces Apple's `apple-magnifier` scheme and parses only
  `install` and `enable-jit` (`TSSceneDelegate.m`); VexSign previously opened
  `trollstore://install?url=…`, which no release handles. The IPA URL is now
  built with `URLComponents`, so an IPA URL with its own query is carried
  intact, and the result is reported as a hand-off — iOS opening the URL is not
  evidence that TrollStore installed anything.
- "TrollStore detected" no longer comes from a scheme probe. Every iOS device
  answers `canOpenURL("apple-magnifier://")` (it is Magnifier), so detection now
  reads TrollStore's `_TrollStore`/`_TrollStoreLite` marker beside the app
  bundle and is described as *this copy of VexSign was installed by TrollStore*.
  A missing marker is no longer presented as proof that TrollStore is absent,
  and **Share Signed IPA Instead** covers that case.
- The "Refresh All (TrollStore)" sheet no longer claims to have triggered a
  refresh. TrollStore accepts no refresh URL command; the sheet explains that and
  offers to open TrollStore instead.

### Documentation

- Document the Free Apple ID handoff gap instead of leaving it to be
  rediscovered: `VexSign/Documentation/Security/NATIVE_SIGNING_HANDOFF.md` names the three closed gates
  (no production CMS verifier, no profile export, no identity export reachable
  from the app), the six-stage design that closes them, and the order that keeps
  each intermediate state honest. `VexSign/Documentation/Security/FREE_APPLE_ID_SETUP.md` now says at the
  top that the flow cannot sign yet.
- Add an independently generated CMS fixture for the Apple-profile parser.
  Every existing case in `NativeAppleProfileCMSTests` builds its envelope with
  the same DER helpers the parser was written against, so it could only prove
  self-consistency. `VexSign/Packages/NativeSigning/Fixtures/make_cms_fixture.py` now produces an
  envelope with OpenSSL and asserts the exact subset
  `NativeProfileCMSEnvelope.parse` accepts (v1, definite lengths, one SHA-256
  digest algorithm, attached `id-data`, issuerAndSerialNumber, DER-sorted
  signed attributes with a matching `messageDigest`, 256–512-byte RSA
  signature). The bytes back three new cases: it parses, it still fails Apple
  trust as a self-signed certificate, and tampering is rejected at the right
  layer — a payload edit fails parse, a signature edit parses and fails
  verification (`openssl cms -verify` agrees on both). The fixture is inlined
  as base64 rather than a bundle resource, because the test file compiles in
  two different package layouts; `--check` verifies the inline copy against the
  committed DER so they cannot drift. It runs in `make verify` and in CI.
- `VexSign/Tools/Validation/security-validation/check-native-handoff.py` (wired into `make verify`) keeps the
  `nativeAppleAccountSigning` capability tied to its wiring: flipping it to
  `.implemented` without an export adapter and a package-side profile export
  fails, as does deleting the "handoff is not enabled" copy while the flag still
  says `.notIntegrated`.

- `VexSign/Tools/Release/update-repo.sh` no longer writes a markdown image into the source
  "news" caption. Release bodies open with the app icon, and the raw markdown
  image reference landed in `app-repo.json` verbatim for 1.1.0 and 1.2.0;
  image-only lines and inline link syntax are now stripped to their text. The
  v1.2.1 listing, which the release workflow skipped, is backfilled with the
  script.
- The app and its widget extension now declare the same minimum iOS, 17.0. The
  widget sat at 26.0 while the app said 16.0 — an embedded extension may not
  require a newer iOS than its host (ITMS-90362), and a signer that validates
  nested bundles can reject that mismatch before installation. The app's 16.0
  was a claim, not a floor: the widget uses `containerBackground`,
  `AppIntentConfiguration` and `LiveActivityIntent` buttons with no availability
  guards, and 24 app-side App Intent APIs are `@available(iOS 17.0, *)`.
  Lowering the widget would have meant replacing the configurable Repository
  Apps widget with SiriKit `IntentConfiguration`; raising the app keeps every
  feature and is a one-line change if the floor should instead be restored.
  `VexSign/Tools/Validation/repository-validation/check-pbxproj.py` now fails on this class of mismatch.

## [1.2.0] - 2026-11-07

### Fixed

- "Signing failed." now says what the engine refused and what to do about it (#113).
  The pinned engine answers a profile that does not belong to the .p12, an unreadable
  .p12, a missing profile or a profile without a team id with a `-1` and **no**
  completion callback, so all VexSign ever saw was `succeeded == false` and no message.
  1.0 discarded that bool and reported "Signed successfully"; 1.1 refused without a
  reason. `ZsignEngine.identityProblem` mirrors `ZSignAsset::Init` and names the case
  ("the provisioning profile was not issued for this certificate…", "the .p12 could not
  be opened with the password saved for this certificate…"), and an engine refusal that
  still has no reason of its own points at the signing log instead of a bare sentence.
- Deleting an app reports failure instead of doing nothing (#113). File removal was
  `try?`-swallowed and a failed save only reached the unified log, so a delete that did
  not happen looked like a tap with no effect — which is what a re-signed copy in the
  library could look like. The rows are resolved onto the main-queue context before
  deletion (a row handed over from another context used to be a silent no-op), the save
  is checked, `deleteApp`/`deleteApps` report whether the row is gone, and the library
  says so when it is not. Covered by `VexSign/Tests/PerformanceTests/StorageConcurrencyTests.swift`,
  which now deletes a signed row with a certificate attached, not just an imported one.
- Signing no longer fails *after* the tap on the very problems the preflight sheet
  already let the user accept. "Sign Anyway" used to be defeated one stage later:
  the post-sign inspection reported the same expired profile, uncovered extension
  or ungranted entitlement as a failure and the freshly signed bundle was thrown
  away. Those issues are now logged as warnings, kept on
  `SigningHandler.verification`, and the bundle is registered, which is the
  behaviour 1.0 shipped before the inspection existed. Paths that never show the
  sheet (batch, Update All, automation, self-update) keep the strict failure.
- An extension the selected profile does not cover is a blocking preflight issue
  instead of a warning. The post-sign inspection already failed that bundle, so the
  sheet promised a "Start Signing" run that could only end in an error; it now says
  so before the two-minute sign and offers the override. Covered by
  `VexSign/Tests/UnitTests/Signing/ProfileCompatibilityTests.swift` and
  `VexSign/Tests/UnitTests/Application/SignatureVerifierTests.swift`.
- Deleting a certificate is no longer a silent no-op when the Keychain refuses the
  delete (a locked device, or an item written by an older build): the error is
  logged and the row, files and status records are removed, instead of tapping
  Delete and watching nothing happen.
- `VexSign/Tests/UnitTests/Application/SelfUpdateNotificationTests.swift` compiles again: one call site
  passed `decide(active:surfaced:)` against a `decide(surfaced:active:)`
  declaration, which failed the whole simulator test bundle on `main`.
- The app-storage delete path imports `OSLog` explicitly, fixing the `Logger not found`
  build error reported by the main CI run (#118).
- `VexSign/Tools/Release/update-repo.sh` no longer word-splits its authorization header
  (curl used to receive `Bearer` as a URL and failed every authenticated
  run), and the stale workflow name in `VexSign/Documentation/Development/BUILD.md` was corrected.
- Tapping Reinstall (or Install) no longer ends in the dead end "The updater
  server isn't available in this build." with a Try Again button that repeated
  the same sentence. The update flow now evaluates a method plan before the tap
  (`SelfUpdateManager.plan`), names the actual blocker, offers the other install
  method when it is ready, and switches to it instead of failing when only the
  selected method is unconfigured. Settings → Updates gained an editable
  updater address (http(s) only, https assumed) so the server route can be set
  up in-app, plus a one-tap switch to IDevice when a pairing file exists. A
  stored address is validated before it is saved, a dismissed sheet no longer
  reopens on a stale failure, and the plan is covered by
  `VexSign/Tests/UnitTests/Application/SelfUpdateReadinessTests.swift`.
- The Settings → Signing Methods screen no longer reports placeholder data:
  `SigningMethodAvailability` now exposes only real availability (paid
  mirrors imported certificates, TrollStore mirrors the device detector,
  free Apple ID stays selectable while live session state renders from
  `NativeSigningManager`), unavailable rows display why they cannot be
  selected, and the always-true availability tests were replaced with real
  assertions.

### Added

- The Home tab has a round import button, in both layouts: a FlareStore-style floating
  circle over the bottom-right of the content that opens the IPA/TIPA picker. The
  dashboard tile and the Flare import card stay, but the tap that starts an import no
  longer moves with the theme or with the scroll position. It sits inside the tab bar's
  safe-area inset, so it never covers the bar or the last row, and it carries
  `A11y.Home.importPackages` (`vexsign.home.import`) for the UI tests; the universal
  search bar now uses `A11y.Home.search` instead of a literal.
- A local notification the first time a newer VexSign release appears, controlled
  by **Settings → Updates → Release Notifications** (on by default; the
  permission is requested only when the switch is turned on). It fires once per
  version, never for a version marked as ignored, and never on top of the launch
  prompt that is already showing that release — if the prompt is dismissed, the
  next check announces it instead. Tapping the banner opens the update sheet.
  Because iOS schedules background work, the alert is posted by the update check
  at launch, in Update settings, or during a scheduled automation pass; it is not
  an instant server push. The scheduled automation pass now also checks for a new
  VexSign release before it looks at sources. The decision is pure and covered by
  `VexSign/Tests/UnitTests/Application/SelfUpdateNotificationTests.swift`.
- Settings now opens with a compact identity header — the VexSign logo, app name
  and version — directly above the About section. It replaces the full-width
  "Star on GitHub" card that used to sit at the bottom of the list with a small
  star pill in the same header row, so the link stays reachable without a
  dedicated section. Debug and Nightly builds keep hiding the star, as before.
  `SettingsDonationCellView` is deleted.
- `VexSign/Documentation/Architecture/ARCHITECTURE.md` gained a **README feature coverage** table that maps
  every feature advertised in the README to the files that implement it, with an
  explicit statement of what that check does and does not prove.

### Changed

- All GitHub workflows were slimmed down and de-duplicated: the CI quick job
  runs its gates as three consolidated steps, failing-test diagnostics moved
  out of inline YAML into `.github/scripts/surface_test_failures.py`,
  unreachable release-mode branches and unneeded full-history checkouts were
  removed, and the unused `.github/scripts/git_identity.sh` was deleted.
- Repository-maintenance bot passes now run every 4 hours instead of hourly
  (75% fewer idle automation runs; weekly hygiene/audit unchanged).
- The cloud-signing `npm audit` gate runs only when `package.json` or
  `package-lock.json` actually changed (and on the weekly schedule), so
  source-only pull requests no longer fail on freshly published advisories.
- The standalone `native-signing-smoke` workflow was removed; its unique link
  diagnostics now live as the dispatch-only `link_smoke` job of the Combined
  native host workflow, which already ran the same gates and unit tests
  automatically. macOS job timeouts tightened (build 90→60, tests 60→45,
  platform legs 60→45 minutes).

## [1.1.0] - 2026-11-06

### Highlights

- Home is the middle of five tabs, with privacy-aware search across the workspace.
- Installation routes distinguish OTA, paired-device/IDevice and LiveContainer
  guest staging; a staged guest is never reported as an OS-installed app.
- Native account, anisette v3 and combined-host work is experimental. The public
  release artifact is the standalone app, not a device-accepted combined host.

### Added

- A rebuilt Home dashboard with a certificate-aware hero, one-tap import and
  quick-sign actions, a three-step getting-started checklist, live task and
  update status, recent apps and a compact workspace-tools card. It uses the
  shared design tokens and collapses empty sections instead of showing dead
  cards.
- A documented design system (`VexSign/Documentation/Features/DESIGN.md`) and reusable Home components
  under `VexSign/App/iOS/Presentation/`, including contrast-aware surfaces, responsive
  action tiles and accessible setup/status rows.
- A professional repository front page, architecture/build/design guides,
  documentation index and security policy.

### Automation

- The Release workflow now has two channels: stable tags/manual publishes and a
  daily **nightly pre-release** at 03:00 UTC. Nightly tags are unique
  (`v<version>-nightly.<date>.<run>.<attempt>`), immutable and never update the
  installation listing; stable releases still sync `app-repo.json`.
- Added Dependabot coverage for GitHub Actions, server Python, cloud npm,
  SwiftPM packages and Docker images, plus a weekly read-only audit for the
  root Xcode SwiftPM requirements that Dependabot cannot parse.
- Added deterministic repository maintenance (localisation sync → `make verify`
  → review PR) and automatic CI failure triage into issues. Neither bot guesses
  at behavioural fixes or pushes to `main`.
- Added the release/maintenance documentation and environment guidance.

### Changed

- Zsign and IDeviceKit are vendored under `VexSign/Packages/Vendor/` with pinned commits and
  licences; cloning and CI no longer require Git submodules or `--recursive`.
- `make bootstrap` validates the toolchain and package graph before the first
  Xcode build.

### Fixed

- Installation confirmation no longer treats a negative lookup after the short
  version-settle window as immediate failure. New matching-app appearances can
  confirm installs when iOS exposes no progress counter, but unknown/pre-existing
  app states are not proof of a new install. Completed queue sheets dismiss.
- Shorter install recovery alerts separate technical details, omit empty waiting
  counts, and distinguish unconfirmed installation from a known rejection.
- About is first in Settings. Corrected English setup wording, removed promotional
  attribution phrasing (retaining licenses), and added contextual install/setup haptics.

- Signing now stops before library registration when post-sign structural
  verification fails. Known uncovered retained extensions are rejected before
  signing; users must choose a compatible profile or explicitly remove extensions.
- Post-sign identifier checks read current Info.plist bytes rather than cached
  Bundle metadata. TLS diagnostics distinguish device-local identities from
  actual bundled files; structural inspection is not called cryptographic verification.

- Certificate import no longer starts Zsign's legacy native OCSP checker, which
  has unsafe response-pointer initialization and asynchronous certificate lifetime
  handling in the pinned dependency. Import, refresh and legacy certificate-check
  entry points now use the system-trust inspector. Only positive revocation
  evidence marks a stored certificate revoked; offline or unreadable results do not.
- Certificate and provisioning-profile reads are bounded to 10 MiB before parsing
  to avoid excessive allocation from oversized selections. Pending status results
  are discarded when their certificate row has been deleted.
- Provisioning failures now map certificate-limit, profile-limit, device and App ID
  conflicts before the generic quota message, and free-account expiry rounds up so a
  profile with 2 days and 20 hours left is reported as 3 days, not 2.
- Archive extraction rejects a path whose existing prefix is a symbolic link, closing
  an escape where `escape/outside` resolved outside the workspace because the final
  component did not exist yet.

### Build

- The simulator target now uses the same iOS 16 deployment target as the device
  target. The separate 18.5 override only produced deprecation warnings for APIs the
  app already guards at runtime.
- CI runs the unsigned build and simulator tests concurrently after the Linux checks,
  shares one SwiftPM cache across the companion-platform matrix, reuses the release
  package cache, and builds only the active simulator architecture. The known
  third-party `libunicorn.a` deployment-version lines are filtered from the live log
  while the full log stays in the failure artifact.

### Account and installation safety

- Added the pinned upstream anisette catalogue, explicit protocol selection and
  provider-bound, device-only ADI storage for the experimental v3 path. HTTP-only
  endpoints are blocked; catalogue inclusion does not imply verified health.
- Added owner-bound local identity/profile receipt inventory and a renewal review
  queue. Local history is not complete Apple portal inventory or installation quota.
- Removed simulated native signing/install success. Profile-only operations use
  actual registration results, separate explicit mutation approvals and an early
  CMS capability gate before quota-affecting work.
- Made native private-key export grants exact, single-use and revocable, with
  context/expiry checks before returning PKCS#12. Raw private-key DER stays inside
  the authoritative bridge.
- Preserved provider failures during authentication cleanup and rejected truncated,
  overflowing or trailing-data raw-DEFLATE streams with exact zlib consumption.
- Added architecture-bound physical-device acceptance reports. Native-primary
  builds require observations beyond standalone launch/install checks; reports
  start pending and are human attestations, not independent hardware proof.

### Experimental / not included as a stable combined artifact

- Added the native-primary VexSign/App/iOS/LiveContainer/SideStore bootstrap and packaging
  candidate, explicit session controls, separate OpenSSL namespaces, preserved
  runtime settings/legal panes and collision-checked localization merging.
- The combined host is not device-accepted and is not the standalone release IPA.
  Its packaging validation is separate; guest staging is not OS installation.
- Production native CMS verification remains gated. Full native-owned-key signing
  and verified installation, complete remote inventory and scoped unattended
  renewal are unfinished. Background discovery only prepares a review queue.
- Physical-iPhone/provider acceptance has not been performed. Simulator or
  synthetic native tests do not establish these properties.
