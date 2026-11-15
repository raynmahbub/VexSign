# On-device implementation and acceptance status

**2026-11-13 · working branch `arena/53ca8fed-vexsign`**

This report supersedes the earlier foundation-only status. The renewed request
was to fully implement the feature in VexSign. Actual inventory, package
validation, submission, confirmation, Library and task-history integration is now
written in the existing owners. **This is not yet a complete supported
SideInstaller-equivalent feature.** The native mutation gate remains closed;
modern Remote Pairing/host transport and native-account signing promotion are
still outstanding. Source code, synthetic tests and a successful build cannot
substitute for those dependencies or physical acceptance.

The base commit is `e68423687674cbddd75052db19fb6e0f70dd7173`, not the identity
of the new candidate. Use the actual candidate commit and CI run head SHA when
reviewing results. The user authorized pushing this working branch and running
the existing full CI; no merge, release, account operation or device mutation was
authorized by that decision.

## Implemented source integration

| Existing owner | New behavior | Limit |
| --- | --- | --- |
| `PairingBridge` / `DeviceBootstrapModel` / `TunnelView` | Explicit consent, reviewed-record lifecycle, intended UDID/peer, fresh identity query and an experimental read-only app version/build query. The explicit setup selection is remembered only in this process. | No startup/foreground handshake, automatic VPN activation, Developer Mode claim, implicit re-pair or modern-host advertisement. |
| `DeviceServiceSession` / `InstallationAppProxy` | CoreDevice App Service uses the already identity-checked adapter/RSD handshake, its typed client/list destructors, bounded strict UTF-8 conversion and positive-only records. | No legacy plist-pointer-array lookup, private LaunchServices fallback or absence inference. Binary/header ABI and partial native failure ownership are not accepted yet. |
| `PairedInstallationValidation` | Checks the copied payload before zipping: actual identifier/version/build, all executable slices, iOS/arm64/minimum-OS compatibility, contained nested manifest, authenticated Apple profiles, actual authorized signers and the existing complete cryptographic seal verifier. | No re-signing, “Sign Anyway” exception, private-key export or account call. Watch/simulator/other-platform code is refused by this path. |
| `ArchiveHandler` / `AppInstaller` | Hashes the actual finished IPA and freezes exact metadata, earliest profile/signer expiry and verified device OS in the package target. | No target is constructed from just a database success flag or a native callback. |
| `InstallationProxy` | Scoped native clients, no-follow regular-file archive read, bounded 1 MiB autoreleased buffers, SHA-256 of transmitted bytes, file/EOF checks, positive non-link AFC staging checks and authorization/OS recheck immediately before submission. | Installation remains refused before side effects by the unchanged computed-false mutation gate. No private suspension or self-replacement. |
| `DeviceInstallationControl` / `InstallQueue` | Stop and the native command boundary share an atomic order. Stop first prevents submission; Stop after handoff only ends monitoring. | A waiter cannot interrupt/free an executing FFI call. A timed-out worker keeps the sole native admission slot until cleanup. |
| `InstallWatcher` / `PairedDeviceInstallationProbe` | After acknowledgement, freshly queries the same selected device and frozen record. Requires exact bundle/version/build, matching device/record binding and an observation after acknowledgement. Retains the actual reading. Paired polls get a 30-second handshake budget within bounded verification. | No acknowledgement-to-success shortcut. Empty/error/filtered/stale/cross-device/build-mismatched responses stay unconfirmed; no automatic reinstall. |
| `LibraryStatusStore` | Accepts only fresh positive observations with exact build and selected-device binding. Target/consent/record changes invalidate in-flight reads and cached evidence. Request identity and a revocation generation prevent late results from resurrecting selection, even when the same record/device is reselected. Displays actual observed version/build. | Short-lived in-memory evidence only; restored history never seeds current installed badges. A late callback cannot reselect a revoked target. |
| `TaskContext` / queue / receipts / restoration | Persists the actual schema-versioned dated observation, expected binding, archive hash and command timestamps. Decodes optional proof fields conservatively. Reason strings alone cannot promote completion. Exports metadata without raw device/record/app identifiers. | A receipt is a dated local observation, **not** a portable cryptographic installation attestation or proof the app is still installed. |

### Evidence chain

```text
User names and explicitly queries intended device + reviewed pairing record
  -> process-local selected request (not enduring trust)
  -> fresh identity query for the attempt
  -> copy library bundle into attempt-owned Payload
  -> existing authenticated profile + full cryptographic output verification
  -> zip actual verified copy -> SHA-256 + exact metadata/expiry/OS target
  -> fresh selected-device session -> AFC transfer, rehash and unchanged-file check
  -> atomic Stop/submission boundary -> native command acknowledgement
  -> fresh identity-bound CoreDevice version/build observation after acknowledgement
  -> shared confirmation engine retains actual reading
  -> queue, Library observation and dated task receipt
```

Every mutation still stops at the lower native acceptance gate in this build.
The source above describes the integrated path behind that gate, not a device run.

## Deliberate safety boundaries

- Pairing input remains at most **2 MiB**, with bounded flat XML/binary preflight,
  classic/remote/combined validation and preserved original bytes. The remote
  host UUID is never a device UDID. Parsing is not authorization.
- `PairingFileStorage` remains the sole owner: no-follow bounded reads, protected
  0700/0600 storage, backup exclusion, reviewed no-clobber/atomic lifecycle,
  exact-byte exports, collision-preserving migration and bounded local recovery.
- Local recovery on launch is not a transport query. VPN installation and
  activation remain explicit user actions. The usual peer is `10.7.0.1`;
  `10.7.1.1`, localhost, owned interfaces and inappropriate public peers are refused.
- Cancelling a native waiter never force-frees its handles or admits overlapping
  work. The query wait is normally 30 seconds; an install waiter may use up to
  300 seconds. These are waiter budgets, not guaranteed native execution limits.
- Only an attempt-owned remote staging directory may be removed. Before command
  submission and after known command completion it is cleaned up. If the command
  response is lost, the package is retained rather than deleted while installd
  might still consume it. Recovery/reclamation of that ambiguous remote staging
  requires a separate reviewed, explicit operation; no broad staging sweep ships.
- OTA delivery is a separate potentially unconfirmed handoff. It never silently
  falls back to pairing, private progress or another install attempt.
- Imported paid-certificate signing still uses the existing local certificate
  store and signer without Apple Account login. No backend key/pairing upload,
  unrelated revocation, automatic quota consumption or trust bypass was added.
- Self-update remains unavailable in-app; there is no private suspend selector or
  signing-key upload to an updater. Use an eligible external installer.

## Native dependency and remaining implementation blockers

The wrapper stays at `claration/IDeviceKit`
`837cf1e14d4875771dd5ee1b754a4c86215c5db3`, with its MIT notice and unchanged
`Package.swift`. The binary stays at idevice **v0.1.57**, checksum
`40cd5c769b60d1879a96c9caa27666037f9d5321844addec40ae99727b142d10`, source
commit `99ea020acabd0579375a09fd690261ea6ca37f68`.

1. The old `installation_proxy_get_apps`/browse outer plist array has no accepted
   typed destructor and remains unused. The distinct typed CoreDevice appservice
   list has matching successful-result cleanup. Its native intermediate CString
   construction failures can still leak; Swift cleanup cannot repair memory that
   native code never returns. The local official binary download failed; no
   downloaded archive/header/symbol acceptance is claimed here.
2. idevice v0.1.68 resolves to
   `d32c8189c51c2789496b0768039419c3705498c3`. Its lower-level host APIs require a
   real Bonjour/listener/PIN/FD/context lifecycle. Reviewed source also exposes
   TXT allocation concerns, remote credential debug logging and implicit
   pair-setup fallback. It was **not blindly adopted**. No modern host or modern
   imported-RP tunnel implementation ships in this patch.
3. Native-account CMS/profile/handoff code retains its independent promotion
   gates. `SigningMethodCapabilities.nativeAppleAccountSigning` remains
   `.notIntegrated`; the production account factory still defaults to unavailable
   CMS verification. Genuine Apple-issued CMS/security and physical evidence is
   not present and must not be replaced by synthetic success.
4. Complete transitive binary-license clearance, Apple platform permissions and
   all hardware scenarios remain unaccepted. The optional external VPN is not
   bundled or automatically activated.

Reviewed routing remains conservative: below 17.4 unsupported; 17.4–26.3 classic
experimental; 26.4–26.7 needs a modern Remote Pairing bridge that is unavailable;
26.8–26.x unknown; 27+ on-device host unavailable. These are policy boundaries,
not a fabricated physical compatibility matrix.

See the [vendor ownership review](../../Packages/Vendor/IDeviceKitten/LOCAL_PATCH_REVIEW.md)
and [initial architecture audit](on-device-foundation-audit.md).

## Validation ledger

| Check | Actual state |
| --- | --- |
| Local `make verify` | **PASS: 534 portable tests across 34 unittest invocations**, plus repository/project/package/localization/discipline gates. Final rerun required after any later edit. These are not native behavior tests. |
| Exact-source host graph | Seven production sources and five fixture/test files, including **55 synthetic host tests**. No IDevice binary/account/network dependency. The suite passed on CI at `128d5921e60511119ce234b92a6fe72781e44eb3` ([run](https://github.com/raynmahbub/VexSign/actions/runs/43691204516)); local Swift execution is unavailable. This does not mean that run's iOS app build passed. |
| App regressions | Added actual-evidence, binding/build/freshness, receipt/restoration, polling, library revocation and invalid-payload cases; existing version-only fixtures migrated to actual synthetic observations. App tests require macOS/Xcode. |
| Local Swift build/type checking | **UNRUN:** this workspace has no Swift/Xcode. Tree-sitter grammar review is not a type check. |
| iOS unsigned Debug build + warnings gate | **PASS** at `0a58bde2e6ae45271286d92ab45f97cc2ff4e028` ([run](https://github.com/raynmahbub/VexSign/actions/runs/43692521608)). That run's simulator job stopped on a pre-existing test's attempt to write a read-only SwiftUI environment value; it is not a simulator-test pass. The repair preserves system Reduce Motion precedence and adds explicit policy coverage. |
| Candidate full CI | Branch code is published and full runs have been dispatched. Use [the branch's CI runs](https://github.com/raynmahbub/VexSign/actions/workflows/ci.yml?query=branch%3Aarena%2F53ca8fed-vexsign), matching the actual head SHA and individual conclusions. This static source report does not automatically become a CI pass. Earlier runs exposed native count signedness, filesystem checks and pre-existing certificate isolation/swipe-call errors; those are addressed in source without weakening gates/baselines. |
| Signing core | **PASS: 36 production C++ regressions under ASan+UBSan plus independent plistlib interoperability**, rerun locally using ignored generated headers matching the installed OpenSSL 3.0.20. CI's Linux sanitizer step also passed. No Apple trust or physical signing is inferred. |
| Physical device/account/installed version | **UNRUN:** all [F01–F20 and I01–I06](../DeviceTesting/ON_DEVICE_FOUNDATION_ACCEPTANCE.md) remain PENDING. No device logs, signed IPA hash, account outcome or installed version was invented. |

## Manual build and test instructions

On an authorized macOS/Xcode machine with the repository's required iOS SDK:

```bash
xcodebuild -version
swift --version
make bootstrap
make verify
make test-device-foundation
make test SIMULATOR=auto
make
```

`make test-device-foundation` copies exact production/test bytes, the retained
license and `source-hashes.json` into ignored `.build/device-foundation`. It runs
no native service and proves neither iOS Data Protection nor device trust.
`make` produces an unsigned build artifact, not an IPA that is installable just
by opening it. Do not include credentials, pairing files or private device logs
in simulator/public CI inputs or artifacts.

The user authorized the following branch-only publication/validation, not a merge
or release. Inspect the actual run head SHA and job results:

```bash
git branch --show-current
git diff --check
git push origin arena/53ca8fed-vexsign
gh workflow run ci.yml --ref arena/53ca8fed-vexsign -f validation=full
gh run list --workflow ci.yml --branch arena/53ca8fed-vexsign --limit 5
```

For real-device testing, use a dedicated spare device, a legitimate already
configured development/installer route and valid signing/profiles. An explicit
`CONFIRM_DEVICE_INSTALL=YES make device-smoke` using a chosen `DEVICE_ID` and
actual `SIGNED_APP` replaces that selected app; obtain separate device-operation
approval first. This installs VexSign using Apple's development tooling, **not**
proof that VexSign's own installation path works.

Before enabling mutations, complete native ownership/header/build review and the
physical matrix against the exact reviewed source and actually signed IPA. Do
not flip one Boolean, relax CMS/profile/output checks, infer absence from an empty
inventory, or manufacture evidence to make the feature appear complete.
