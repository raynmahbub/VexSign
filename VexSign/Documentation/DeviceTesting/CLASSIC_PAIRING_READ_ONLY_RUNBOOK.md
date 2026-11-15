# Classic pairing: private read-only validation

**2026-11-13 · preparation only · no physical result recorded**

For a maintainer with a Mac and an owned, dedicated iPhone running **iOS
17.4–26.3**. Selecting this target does **not** authorize installing/replacing an
app, operating an Apple Account, changing signing assets, removing an app or
opening a capability gate. This runbook prepares manual checks; the hosted agent
cannot reach or inspect your phone.

## 1. Stop conditions and prerequisites

- Use a spare device, with its data backed up. Read the actual iOS **version and
  build** in Settings → General → About. A simulator or a modern/unknown OS is
  not a substitute for this route. Stop below 17.4 or at 26.4 and later.
- The reviewed VexSign candidate must **already be legitimately installed and
  launchable**, with the identity/provisioning required by your existing route.
  If a new install/replacement, Developer Mode change, pairing/trust setup or VPN
  installation is needed, stop and arrange that separately. This target
  selection is not approval to perform it. Do not run `make device-smoke`, an
  installer, signing/account automation or a private pairing workaround as part
  of these read-only checks.
- Have an authorized classic lockdown record for **this intended device** and
  an already configured, trusted compatible transport. Preserve the original
  privately. Do not download somebody else's record, upload one to a service,
  change its fields or regenerate trust to make a test pass.
- The usual local VPN **peer** is `10.7.0.1`, but verify your actual configuration.
  `10.7.1.1` is normally the owned interface, not the peer. Never scan arbitrary
  hosts, substitute localhost or use a public IP. VexSign does not activate a VPN
  for you. If a prerequisite is missing, record **BLOCKED**, not pass.
- Keep full UDIDs, record/host UUIDs, device names, raw pairing bytes, pairing
  fingerprints and raw logs private. No P12, private key, Apple ID, password,
  cookie, token or anisette material is needed for this stage.

A successful identity query or inventory reading is **not** installation
acceptance, device trust for future attempts, signature verification, Developer
Mode verification or proof of a live session. Paired install/removal gates stay
closed. Do not sign/install a test IPA, set up an OTA CA, rotate trust, remove an
app or switch installation methods while following this procedure.

## 2. Bind observations to the actual build

The code candidate
`19ede8da4a9947a82d8e62b162b66bfd14ce1a34` passed the
[full macOS CI run 43699344181](https://github.com/raynmahbub/VexSign/actions/runs/43699344181):
unsigned iOS build/warnings, simulator tests, quick gates and concurrency report.
That is **not** a signed or device-accepted release. Its disposable unsigned IPA
cannot be installed simply by opening it. A legitimate external re-sign changes
its checksum and may change its bundle identifier; record the artifact actually
installed, not the original download.

Use that exact candidate, or another explicitly reviewed candidate with its own
matching full CI. Documentation-only follow-ups do not change the validated app
source, but are not the source identity embedded in the earlier artifact. Do not
substitute today's checkout SHA for the tested app's `VexSignSourceCommit`.

On your Mac, these commands inspect the checkout/toolchain only and do not
contact a device:

```bash
git branch --show-current
git rev-parse HEAD
git status --short
sw_vers -productVersion
xcodebuild -version
```

For a **previously authorized, actually used signed IPA**, the following reads
only that local archive, hashes its bytes and prints a whitelist of root app
metadata. It neither extracts files nor verifies signing, provenance or device
installation. Keep the output private until reviewed. Python 3 is sufficient.

```bash
python3 - /absolute/path/to/actually-used-signed.ipa <<'PY'
import hashlib, json, plistlib, re, sys, zipfile
from pathlib import Path

path = Path(sys.argv[1])
digest = hashlib.sha256()
with path.open('rb') as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b''):
        digest.update(block)
with zipfile.ZipFile(path) as archive:
    roots = [entry for entry in archive.infolist()
             if len(entry.filename.split('/')) == 3
             and entry.filename.split('/')[0] == 'Payload'
             and entry.filename.split('/')[1].endswith('.app')
             and entry.filename.split('/')[2] == 'Info.plist']
    if len(roots) != 1 or not 0 < roots[0].file_size <= 1024 * 1024:
        raise SystemExit('Stop: expected one bounded root app Info.plist')
    with archive.open(roots[0]) as handle:
        data = handle.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise SystemExit('Stop: oversized root metadata')
    info = plistlib.loads(data)
    if not isinstance(info, dict):
        raise SystemExit('Stop: invalid root metadata')
keys = ('VexSignSourceCommit', 'CFBundleIdentifier',
        'CFBundleShortVersionString', 'CFBundleVersion')
if any(not isinstance(info.get(key), str) or not info[key]
       or len(info[key]) > 256 or not info[key].isascii()
       or any(ord(c) < 32 or ord(c) == 127 for c in info[key]) for key in keys):
    raise SystemExit('Stop: missing or invalid provenance/version metadata')
if not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', info['VexSignSourceCommit']):
    raise SystemExit('Stop: source commit is not a full SHA')
print(json.dumps({'signed_ipa_sha256': digest.hexdigest(),
                  'root_metadata': {key: info[key] for key in keys}}, indent=2))
PY
```

If installed directly from an authorized Xcode build rather than an IPA, record
its actual source/build/signing provenance privately and say the IPA checksum is
unavailable. That can support exploratory read-only notes, **not** complete
artifact-bound acceptance. Do not manufacture a checksum or export signing keys
to fill the field. A metadata commit label is not independent source attestation.

## 3. Make a private pending worksheet

Copy [the blank worksheet](CLASSIC_PAIRING_READ_ONLY_WORKSHEET.json) into the
ignored workspace directory. This is only a notes template, not a validator or
an acceptance report. No result is pre-filled as passing. Do not edit the tracked
template to hold private observations.

```bash
umask 077
mkdir -p .build/private-classic-validation
chmod 700 .build/private-classic-validation
# Exclusive creation: stop rather than overwrite a prior session's notes.
python3 - <<'PY'
from pathlib import Path
source = Path('VexSign/Documentation/DeviceTesting/CLASSIC_PAIRING_READ_ONLY_WORKSHEET.json')
target = Path('.build/private-classic-validation/observations.local.json')
with target.open('x') as handle:
    handle.write(source.read_text())
target.chmod(0o600)
print('Pending private worksheet created. No device checks have run.')
PY
```

Fill the artifact/session fields without full device/record identities. UTC dates
use `YYYY-MM-DDTHH:MM:SSZ`. For each check choose `PENDING`, `OBSERVED_PASS`,
`OBSERVED_FAIL`, `BLOCKED` or `NOT_EXERCISED`; record what actually happened, its
time and private evidence references. Preserve failures. A refusal can satisfy
an explicitly negative check without satisfying a positive workflow.

The worksheet is **not consumed** by `device-acceptance.py`, release automation
or capability-promotion gates. Passing this subset never marks all of F07, F13,
F14, F20 or I01/I05 complete. Their remaining hardware/failure/ownership scenarios
in [the full matrix](ON_DEVICE_FOUNDATION_ACCEPTANCE.md) remain PENDING.

## 4. Manual read-only checks

Open **Settings → Installation Engine → Pairing file and VPN setup** in the
already running candidate. Do not start an installation queue.

### CR01 · artifact and route

- Record the actual model, iOS version/build and app source/version/build.
- The route should say **Classic pairing candidate — device testing pending**,
  not supported installation, a modern host or an accepted live connection.
- Confirm the app still discloses unavailable paired installation/removal.
- Stop if the candidate/artifact or route is not the one being reviewed.

This contributes only to the preparation portion of F01/F07, not first-install
acceptance.

### CR02 · local record and query consent

- Keep **Allow experimental local device-service queries** off initially.
- Review/import your authorized original classic record through the file picker.
  This changes local app storage only. If replacing an existing local record is
  not intended, cancel; do not overwrite it just to continue this test.
- Record only the recognized format and UI behavior, not the contents or digest.
  Recognized format must not produce a verified-device or installed-app claim.
- Confirm no device query was initiated merely by opening, importing or refreshing
  the record. With consent off, explicit query actions must remain unavailable.

This is a subset of F03/F04. It does not validate all malformed formats,
protection attributes, export recovery or native trust.

### CR03 · fresh identity and services

- Privately compare **Intended device UDID** to the owned device in Xcode/Finder
  or your trusted local pairing tool. Do not substitute the remote host UUID.
- Check the peer against the existing compatible transport. Manually activate
  that already approved transport if needed. Enable the query-consent toggle
  yourself only when ready for read-only protocol traffic.
- Tap **Verify selected device** once. Record reached stage, elapsed wait and the
  actual product/OS/build summary, or the exact redacted failure category.
- Compare identity privately; record only whether it matched. A model/OS summary
  alone is not a unique device identifier.
- The success explanation must say the session is closed, selection is
  process-local and installation readiness is not established.

A missing response, service failure, wrong identity or timeout is not positive
F07 acceptance. Do not edit or regenerate a record to hide the failure.

### CR04 · positive application inventory

- Only after a fresh successful identity check, use the **actual installed
  VexSign bundle identifier** (including any legitimate re-sign change). It is
  prefilled from the running app in an unmodified candidate.
- Tap **Read selected app's installed version**. Record the actual returned short
  version and build, observation time and whether both are comparable.
- Compare with independent local device evidence where available (for example,
  your trusted Mac device tool's installed-app information). Inspect the help
  for `xcrun devicectl help device info apps` before using your Xcode's read-only
  app-information command; choose the intended device explicitly and keep its
  identifier/output private. Do not install a second test app to create input.
- The running app's own version display can corroborate its version; the IPA's
  metadata supplies **expected** values, not independent installed-state proof.
  If an independent exact build comparison is unavailable, say so; do not mark
  that comparison observed.
- A positive metadata reading may refresh a Library presence badge on the
  explicitly selected target. It must not create an installed-success task,
  claim VexSign installed the app or unlock mutations.

This is partial I01/I05 evidence. App Clip coverage, native conversion failures,
allocation/cleanup ownership and a real install receipt remain untested.

### CR05 · missing result stays Unknown

- Read a well-formed, harmless **owned test bundle identifier known not to be
  installed** on the selected device. Do not install/remove anything first.
- An omitted/filtered result must say **unknown evidence**, not **Not installed**
  and not successful installation/removal. Do not infer absence from the list.
- Preserve CR04's observation in the private notes; its summary must not be
  reused for the new identifier. Change back and query again explicitly.

If you cannot establish a suitable test identifier privately, leave this check
NOT_EXERCISED rather than inventing absence evidence.

### CR06 · consent revocation and changed input

- After a positive reading, turn query consent off. Old verified/inventory
  summaries must clear; no late completion may resurrect them or select a target.
- Re-enable only for a new explicit read. Change the app identifier, or change
  the peer to the **known rejected owned interface** `10.7.1.1`; stale results
  must clear. The latter must refuse safely, not scan/fall back elsewhere.
- Restore your real peer and intended identifier before any new explicit query.
  Do not use another person's device ID or a public address as a negative test.
- Check that a Library badge backed only by the revoked selection is not kept as
  fresh selected-device evidence. Historical receipts are not current badges.

This covers visible revocation behavior only. Do not claim an in-flight race was
exercised unless a read was actually outstanding when you revoked consent.

### CR07 · cancellation, timeout and native retirement

- If a read genuinely stays outstanding long enough, tap **Cancel query** or
  revoke query consent. Record latency and the actual task/UI outcome.
- The screen's normal 30-second budget bounds the **waiter**, not FFI execution.
  A retiring native worker may keep the transport busy; do not run repeated
  retries, force-free handles or change gates to bypass that condition.
- After actual retirement, a fresh explicitly requested read may be attempted.
  If retirement never completes, stop, record the stall and reopen the app only
  as recovery. Do not relabel the stalled native call as a successful cancellation.
- If responses are too fast to exercise cancellation, record NOT_EXERCISED.
  Do not induce destructive faults or revoke actual device trust to slow it down.

UI observations do not prove native allocator correctness or all F13 failure
paths. Those still need instrumentation and dependency review.

### CR08 · foreground and relaunch

- Background and return to the app. Returning must not start a handshake or
  re-display a stale verified/inventory summary as current evidence.
- Close/relaunch the app. A stored record or persisted consent preference may
  remain, but process-local target authorization must not become durable trust.
  Obtain a new explicit query before describing a current result.
- A completed **device setup/read-only** task is not an installation task or an
  installation receipt. Record any incorrect wording or automatic query.

This is a read-only subset of F14/F20; it does not cover actual install/update
persistence or every interrupted native stage.

## 5. What to return, and what remains pending

Stop on a crash, wrong-device result, stale success, automatic mutation or a
privacy leak. Preserve raw evidence only on your controlled Mac; do not attach
pairing records or raw device/console logs to chat, Git or public CI. Do not
retry an unexpected installation prompt—nothing in this procedure should submit
one.

A useful **manually reviewed, redacted** summary contains:

- candidate source SHA and matching CI URL;
- actual iOS version/build, model and VexSign version/build;
- the first failing or blocked CR-number and its stage/message, or the checks
  actually observed, with UTC time and elapsed wait;
- whether intended identity and independent version/build comparison matched,
  without printing the identities, peer-specific network details or app list.

You can provide those facts without sharing the private worksheet or screenshots.
If VexSign is not already installed from an authorized matching build, report
that prerequisite first; an installation/credential/device-mutation decision is
separate.

**All full F01–F20 and I01–I06 scenarios remain PENDING in this repository.**
Nothing here enables paired mutation, modern Remote Pairing/on-device hosting,
native-account signing or full SideInstaller-equivalent behavior. See the
[current implementation and CI ledger](../Architecture/on-device-foundation-status.md)
for the remaining implementation, dependency and acceptance blockers.
