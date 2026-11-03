# Native account backend: dependency promotion blocker

This is an immutable-source review, **not a resolved combined dependency graph**.
The current Xcode app pins were not edited. The isolated native graph must remain
separate until the blocker is addressed and the result compiled/tested.

## Confirmed incompatibility

The Xcode project **exactly requires Vapor 4.104.0**, pinned at
`236025b6a213f372f81b732ff792f95789c089d4`.
Both [Package.swift](https://github.com/vapor/vapor/blob/236025b6a213f372f81b732ff792f95789c089d4/Package.swift)
and its compiler-specific
[Package@swift-5.9.swift](https://github.com/vapor/vapor/blob/236025b6a213f372f81b732ff792f95789c089d4/Package@swift-5.9.swift)
require Swift Crypto `1.0.0 ..< 4.0.0`.
The isolated SideSign/CodeSignKit graph requires Crypto **4.3.1**, including
`CryptoExtras`. Those requirements have no intersection. Editing only
`Package.resolved`, adding the SDK's products, or using `canImport` cannot solve it.

Other reviewed consumers do not have that **version-range** blocker:

| Current consumer | Immutable revision | Crypto requirement |
| --- | --- | --- |
| Swift Certificates 1.17.1 | `7d5f6124c91a2d06fb63a811695a3400d15a100e` | `3.12.3 ..< 5.0.0` |
| Swift NIO Extras 1.32.1 | `3df009d563dc9f21a5c85b33d8c2e34d2e4f8c3b` | `3.0.0 ..< 5.0.0` |

Crypto 4.3.1 at `bb4ba815dab96d4edc1e0b86d7b9acf9ff973a84` still
exports both `CryptoExtras` and the legacy `_CryptoExtras` product consumed by
Certificates. This is not proof of source/API compatibility.

The IDeviceKitten gitlink at `837cf1e14d4875771dd5ee1b754a4c86215c5db3`
was also reviewed: its manifest has a binary IDevice target and Swift wrapper,
not an additional Vapor/Crypto constraint. Binary linkage remains unverified.

## Review evidence and limits

`NativeSigning/app-dependency-review.json` records SHA-256 values of all **42**
main-app pinned root manifests, their revisions, the app lockfile, and Vapor's
alternate manifest. The preparation regression checks this report against the
current app pins, requiring a review update when they change. It does not fetch
or resolve packages and is not a claim that incompatible app integration passes.
Root manifests for all pins were inspected for Crypto references. Compiler-specific
manifests were checked for Vapor, Certificates, NIO Extras and IDeviceKitten only;
this is not a complete alternate-manifest, binary, transitive API or license audit.

## Next promotion work

1. Select and pin a reviewed Vapor release whose actual compiler-selected manifest
   permits Crypto 4.3.1. Review the local HTTPS installation server's Vapor/NIO
   calls, TLS configuration and server lifecycle against that release. Do not
   replace the server or weaken TLS to satisfy the SDK dependency.
2. Resolve the **whole app** graph on the intended Xcode/Swift toolchain, accounting
   for Crypto/ASN1 version changes and existing OpenSSL/Zsign binaries. Preserve
   the logging privacy overlays in whatever packaging is promoted.
3. Compile app and native tests; check server/TLS, certificate import, both signing
   backends and cancellation/Keychain recovery on-device before enabling account
   credential collection. A separate dynamic smoke library is not evidence that
   incompatible package versions can coexist in the final application.

No app pin upgrade, workflow dispatch, successful Apple login, live installation-
server regression result or native build is claimed here. Candidate staging below
is separate from app promotion.

## Candidate migration gate added

The selected **candidate**, not an app upgrade, is stable Vapor **4.122.3** at
`48852309b11230e62a89b41a9c578c93f4d2d916` (release 2026-10-21). Its only root
manifest permits Crypto `1.0.0 ..< 6.0.0`. Versions 4.110.2, 4.115.1,
4.119.2 and 4.121.4 were also inspected; all permit Crypto 4.x. The newer stable
candidate avoids deliberately choosing an older release just for its wider range.
This does **not** establish that pinned Crypto 4.3.1 contains every current
security fix; dependency advisories and SDK compatibility with newer Crypto remain
separate review gates. Vapor 5 beta was not selected.

### Source/API review

The candidate's relevant APIs still exist:

| Real app usage | Candidate source reviewed | Result/limitation |
| --- | --- | --- |
| `Application(environment)` / `shutdown()` | `Application.swift` | Synchronous APIs retained but deprecated/noasync; preserve current synchronous lifecycle, do not call directly from async contexts |
| Setup-time `threadPool` replacement | `Core/Core.swift` | Public setter retained; must be before boot |
| `app.server.start()` / shutdown | `Server/Server.swift`, `HTTP/Server/HTTPServer.swift` | Synchronous entry points remain; listener behavior not exercised |
| TLS configuration, bind address, port, TCP no-delay | `HTTP/Server/HTTPServer.swift` | Public configuration retained; no TLS bypass or custom verification callback added |
| Body cap / case-insensitive routing / `ByteCount` | `Routing/Routes.swift`, `Utilities/ByteCount.swift` | Public setters/literal conversion retained |

`candidate-review.json` hashes these **seven upstream files**, including the
manifest, and records the five exact candidate version/revision expectations.
This is a targeted configuration/lifecycle API review, not a review of every
WebDAV/upload/auth route, all compiler features, dependency security or binary ABI.
The candidate enables newer Swift upcoming features; the actual selected Xcode
must compile them before promotion, regardless of its manifest's tools-version.

The real installer and web manager now call the same `ServerApplicationFactory`.
The disposable candidate build copies that **actual source byte-for-byte**, not a
handwritten approximation of server configuration. HTTPS requires an explicit
configuration; missing hostname/identity still throws in `ServerInstaller` before
allocating the app. HTTP mode, binding policies, 128-MiB/32-MiB body caps, case
sensitivity and thread counts are preserved. Certificate generation/loading,
trust handling and existing server start/shutdown call sites are not replaced.

### Disposable gate, deferred native execution

```sh
python3 NativeSigning/prepare_server_compatibility.py
swift package --package-path .build/server-dependency-compatibility resolve
python3 NativeSigning/prepare_server_compatibility.py --verify-resolved
swift test --package-path .build/server-dependency-compatibility --force-resolved-versions
```

Use a fresh `--work` directory when inputs change; the script never overwrites or
deletes an existing directory. Preparation itself is offline. Resolution uses
SwiftPM and requires network access. Verification rejects unexpected revisions,
unreviewed alternate Vapor manifests and reviewed-source/first-party drift before
compilation. It records **all resolved pins**, including otherwise unconstrained
transitives, in an attestation. This graph is not claimed to be fully locked or
hermetic; five direct versions are constrained and transitive resolution must be
reviewed before app promotion.

This package puts Vapor, Crypto/CryptoExtras 4.3.1, ASN1 1.6.0, NIO 2.94.0 and
NIOSSL 2.36.0 in one candidate graph. The last two match the current app pins.
It is **not the full app + SideSign/Zsign/binary graph**. Its four native cases
check configuration, HTTPS preservation, distinct web-manager policy and a Crypto
hash; they do not start listeners, perform handshakes, use Keychain or contact
Apple. They are written **but unexecuted**.

The existing manual native smoke workflow has a new **default-off**
`server_compatibility` input to resolve/verify/build/run these cases on macOS.
No workflow was dispatched. macOS success would still not prove iOS availability,
full-app source compatibility, installer TLS operation or device behavior.
Eight additional Python preparation regressions pass without Swift.

**Still pending:** native candidate resolution/build, full combined app/SDK
resolution, actual Xcode pin promotion and device/server regression validation.
The original 4.104.0 app pin and its incompatibility remain unchanged. No normal
app account credential UI is enabled by this gate.

## Combined app-package + native SDK candidate

`NativeSigning/prepare_combined_smoke.py` now stages the next, larger gate. Unlike
server-only compatibility, this candidate brings **all 42 current app remote
package versions**, four local app packages (NimbleKit, AltSourceKit, Zsign and
IDeviceKit), and the actual privacy-patched SideSign SDK/backend into one root
manifest. Only three proposed remote states differ from the app baseline:
Vapor 4.122.3, Crypto 4.3.1 and ASN1 1.6.0. OpenSSL remains at the existing app
version/revision; its repository and product identity are shared with Zsign.

This deliberately constrains baseline transitive versions as root exacts to find
whether that **specific migration** is viable. It is stricter than the original
app's version ranges, not a claim that no other valid resolution exists. A solver
failure must prompt an explicit dependency review, not relaxing every pin.

### One real shared-library identity

The original isolated SDK preparation used local Crypto/ASN1/OpenSSL overrides.
The combined gate converts those SDK declarations to the **same remote URLs and
exact versions** as the root app constraints. The real remote Vapor and app
transitive manifests are not rewritten or stripped of their requirements. This
avoids manufacturing a passing graph by simply overriding Vapor's Crypto range
with a local directory. SDK library-only packaging and hash-checked logging
privacy overlays remain in place; original manifests/patch inputs are retained.
Unused shared-library clones from base preparation are not referenced by the
combined manifest and are excluded from active-source attestation.

NimbleKit/AltSourceKit manifests and Sources are snapshotted without .git/caches.
IDeviceKit is fetched at the actual app gitlink; its manifest hash and absence of
alternate manifests are checked. Its XCFramework download/slices/ABI are still
unvalidated. The root compiles imports for the app library products alongside
the native backend and actual server factory. LicensePlist and its dependency
constraints are present, but its build plugin is **not executed** by this probe.
This is not an app target, UI/extension build, final executable or license audit.
Use an iOS device destination; NimbleKit's UIKit products are not a macOS test suite.

### Preparation and verification

```sh
python3 NativeSigning/prepare_combined_smoke.py
swift package --package-path .build/combined-signing-smoke resolve
python3 NativeSigning/prepare_combined_smoke.py \
  --verify-resolved .build/combined-signing-smoke/Package.resolved
```

After an Xcode-native resolution, pass that real `Package.resolved` and its
checkouts directory with `--verify-resolved` / `--checkouts`; do not synthesize
resolved revisions or copy in the app's incompatible lockfile. Then compile the
candidate's `NativeSigningLinkSmoke` scheme for `generic/platform=iOS` with signing
disabled and Xcode's resolved-file-only options, preserving the verified lockfile.
A successful SwiftPM resolution alone is not proof that Xcode used the same graph;
verify the actual Xcode lock/checkouts too, before the device build. No signing,
Apple requests or credential collection are part of this gate.

The verifier checks app baseline, all prepared active source hashes (including
added/deleted files), the exact complete expected resolution, reviewed Vapor
source/manifest hashes, and shared remote manifest hashes. It emits a resolution
attestation only after those checks. It is a local consistency gate, not a signed
security attestation or complete audit of every remote package source/binary.
App/source changes require a fresh preparation directory; existing output is
never reused or deleted by the preparer.

The existing manual workflow has a new **default-off `combined_dependencies`**
input for preparation, real SwiftPM resolution and verification only. The workflow's
usual isolated SDK build remains separate; it must not be represented as a combined
build result. No workflow was dispatched.

### Actual outcome this increment

Source preparation **did run successfully** at
`.build/combined-signing-smoke-v3`, including all locked SDK source checkouts,
manifest hash/privacy overlay checks, app local snapshots and IDeviceKit checkout.
The two earlier directories were preserved after preparation failed closed on
unused local shared-library declarations and normal OpenSSL framework symlinks;
the corrected gate excludes those inactive clones rather than weakening active
source checks. Build inputs stay in ignored `.build`, not Git artifacts.

Nine new lightweight regressions exercise constrained manifest generation,
single shared remote identities, snapshot filtering and source/pin drift guards.
**No SwiftPM/Xcode resolution or native compilation was run**: the sandbox still
has no Swift toolchain. App pins and unavailable-account UI remain unchanged.
The next acceptance gate is actual combined resolution, then an iOS device build
and native/device tests—not a claim that the original conflict is already solved.
