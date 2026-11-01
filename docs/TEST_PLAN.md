# Test plan — the phase after the code

Every item in `docs/ROADMAP.md` that could be settled without a compiler has been settled. What is
left needs Xcode, a simulator, and one real device, because the remaining claims are about things a
sandbox cannot observe: whether it builds, whether a signature verifies against a real certificate,
whether iOS accepts an install.

This document is the order to run things in, what each step is protecting, and how to tell a pass
from a plausible-looking failure. Numbers and file names are current as of 2026-11-01; the code is
the source of truth if they drift.

---

## 0. Gates that need no toolchain (run first, they take a minute)

```sh
make verify
```

Runs, in order: `quick_check.py --no-swiftc` (conflict markers, duplicate types and file names,
resource parsing, pbxproj), `sync-strings.py --check` (no literal without a catalogue key),
`error-discipline.py` (no file above its `try?` baseline), `singleton-freeze.py` (no new global
singleton), `concurrency-discipline.py` (no new `@unchecked Sendable` / `nonisolated(unsafe)` /
`@preconcurrency`).

Expected: five green lines. Current baseline: **2,463 catalogue keys · 404 unjustified `try?` in 112
files · 56 singletons in 55 files · 3 concurrency escapes in 3 files**.

These checks run automatically for relevant pushes to `main`, not pull requests. Before merging, run them locally or manually dispatch CI on the current head branch. Select `full` to include compilation and simulator tests; a passing `quick` run alone is not a passing native build. Also run `python3 tools/test_workflow_policy.py` (included in `make verify`) to guard the trigger policy.

---

## 1. Build and run the suite

```sh
make test                    # resolves an iPhone simulator at run time
make test SIMULATOR="platform=iOS Simulator,name=iPhone 16"
```

`-parallel-testing-enabled NO` is deliberate: several suites touch process-wide state
(`UserDefaults.standard`, the Core Data stack, the tweak library) and parallel clones would make a
failure unreproducible.

**350 test functions** in `VexSignTests/`. Nothing here has ever been compiled — that is the first
thing this step finds out, and it will find out loudly. Expect a first pass of compile errors
before any test runs; fix them in the order the compiler reports, because a missing member usually
explains several later failures.

### What the newest suites protect

| Suite | Protects |
|---|---|
| `LogRedactionTests` (11) | A log a user can export must not contain their password, token or URL credentials. |
| `DownloadIntegrityTests` (9) | A truncated download is refused **before** the unarchiver sees it, with both byte counts in the message. |
| `NovaDNSDynamicTests` (10) | The anti-revoke endpoint is https-only, visible, resettable, and the feature is off until asked for. |
| `SourceProvenanceTests` (11) | A source that claims a signature and fails verification is refused; unsigned sources keep working. |
| `InstallPreflightTests` (11) | Each install route names its missing prerequisite instead of failing later. |
| `TweakInjectionDefaultsTests` (8) | Bulk "inject by default" never switches on a disabled tweak and never touches exceptions. |
| `OCSPTests` (20) | Request/protocol bytes and the revocation policy, including "a stale answer never blocks". |
| `OCSPResponderVerificationTests` (16) | Nothing produces a revocation decision until a responder has signed the bytes. |
| `SourceFeedLoaderTests` (7) | Feed decoding is off the main thread and a synthetic 5 MB feed round-trips. |
| `NestedBundleAuditTests` (14) | Nested frameworks and plug-ins are enumerated with their entitlements. |

If one of these fails, it is a real defect, not a flaky test: none of them touches the network, the
clock (times are fixed constants), or a real keychain.

---

## 2. Device checks — one per item that changed behaviour

Order matters: each step leaves state the next one reads.

### Download integrity
1. Add a source whose `size` is wrong by a few kilobytes (edit a `source.json` locally and serve it).
2. Download that app. **Expect:** no import; an alert titled *Download failed a check* with "N
   bytes, but the source says M bytes", the line *Nothing was imported*, and two buttons —
   **Import Anyway** and **Delete**. The download row is gone, exactly as it is after any failed
   import.
3. Tap **Import Anyway**. **Expect:** the file imports, once, and the log records the bypass with the
   full reason. Run the same download again: it is checked again, not remembered.
4. Repeat and tap **Delete**. **Expect:** the staged file is removed — check Settings → Files, or
   the log line *Discarded …*. (A `UIAlertController` cannot be dismissed by tapping outside, so
   every mismatch ends in one of the two buttons. Force-quitting with the alert up leaves the file
   in the app's temporary directory, which iOS purges; it is never imported.)
5. Download an app with a correct `size`. **Expect:** no alert, and a log line *… matches all 1
   check(s) the source published.*

### Anti-revoke endpoint
1. Settings → Installation → Anti-Revoke. **Expect:** the toggle off, the endpoint shown as
   `https://api.novadev.vip/api/novadns-dynamic/rules.json`.
2. Enter `http://example.com/rules.json`, tap **Use This Endpoint**. **Expect:** refused with "Enter
   an https:// URL for the rule list."; the shown endpoint does not change.
3. Enter a valid https URL, save, then **Reset**. **Expect:** the shown endpoint returns to the
   default, and the log records both changes (`category: antirevoke`).
4. Turn the toggle on, install anything. **Expect:** one log line naming the endpoint, not one every
   ten seconds.

### Inject-by-default screen
Tweaks → ⋯ → **Inject by Default**. Search, toggle two tweaks, **All Off**, **All On**.
**Expect:** the count updates, a disabled tweak cannot be switched on, and the tweak's own detail
screen shows the same flag afterwards (one source of truth).

### Signed repositories
1. Sign a local `source.json` with the recipe in `docs/SOURCE_SIGNING.md`, add it.
**Expect:** refresh succeeds and the repository row shows **Signed by …** in teal.
2. Edit one app name in the served document without re-signing, refresh. **Expect:** the refresh for
   that source fails with a signature error, the previous catalog stays, and the row shows **Bad
   signature** in red.
3. Add an unsigned source. **Expect:** it works exactly as before, no badge.

### Install-method preflight
Settings → Installation. **Expect:** four rows with a status word each. With no certificate the
server row says *Needs setup* and names the certificate; with no pairing file the idevice row does
the same; TrollStore says *Not available* on a device without it, and *Ready* where it is installed.
The selected route carries a checkmark.

### Revocation evidence — nothing to check yet
No request is built and no UI shows a verdict. If a revocation UI appears in a build, something was
wired without this plan being updated — treat that as a defect.

---

## 3. What a pass looks like

- `make verify` green.
- `make test` green, 350 tests, no retries needed.
- The five device checks above behave as written.
- No new warnings in first-party code (`build-check` runs with `BUILD_WARNINGS_AS_ERRORS=true`).

## 4. Known blockers before this can go green end to end

| Blocker | Owner | Effect |
|---|---|---|
| `make deps-pin` has not been run | maintainer | Release CI stays red; `deps/` is absent in a clean checkout |
| `Zsign/`, `IDeviceKitten/` submodules empty | submodule init | Engine-dependent tests and any signing path cannot build |
| second half | engine API | Per-extension profiles need a `SignFolder` that takes more than one asset; the pinned engine does not |
| chain check | `SecTrust` + a captured live response | Revocation evidence stops at "signed by the responder" |
| app-target flip | a machine with Xcode | `SWIFT_STRICT_CONCURRENCY=complete` is a one-line change that must be measured first |

## 5. When something fails

1. Reproduce with `-only-testing:VexSignTests/<Suite>/<test>` before changing anything.
2. Check the gates from step 0 — a red gate is usually the cause of a mysterious build failure.
3. For a device-only failure, capture the log from Settings → Logs first: redaction means it
   is safe to share, and the category (`download`, `install`, `antirevoke`, `backup`, `tweaks`)
   usually says which subsystem to look at.
