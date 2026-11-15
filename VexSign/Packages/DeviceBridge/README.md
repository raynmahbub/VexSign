# Source-built modern device integration

**Experimental; not physical-device acceptance.** This is VexSign-written glue
around the MIT-licensed `jkcoxson/idevice` source pinned by
[`inputs.lock.json`](inputs.lock.json), not copied SideInstaller implementation.
The exact upstream MIT notice is retained in `LICENSE.idevice.txt`. The old
unpatched binary is not silently upgraded to a newer unpatched release.

The new native ABI separates two actions:

- **Verify an existing Remote Pairing record:** bounded direct TCP → pair-verify
  → tunnel/RSD. It never calls upstream's `connect()` convenience method, which
  can fall back to new pair-setup and a default PIN. A declined/revoked pairing
  fails; it is never repaired behind the user's back. The configured VPN peer,
  not localhost or this device's interface, is used for both the control endpoint
  and the device's dynamically returned tunnel listener.
- **Explicit one-shot host enrollment:** create a fresh identity/TXT without
  networking, then accept a caller-owned socket with mandatory random-PIN
  presentation. Swift owns system Bonjour, the listening socket, consent,
  foreground lifetime, expected-device comparison and protected record commit.
  Native code duplicates the connected fd, requires cancellation/deadlines and
  returns bytes, not files. Host altIRK and device UDID stay in the same record as
  the signing keys. Pinless/automatic enrollment is not an ABI option.

The source overlay also compiles protocol tracing out in both native crates,
uses boxed-slice allocation/deallocation for byte buffers, rejects malformed
RPPairing magic/oversized outgoing frames and requires pair-verify response
states. It does not establish a new public Apple installation/Developer Mode
API, prove that the on-device OS accepts host advertisement, or promote the
separate installation/removal/signing gates. Source-built integration and
runtime/device acceptance remain different things.

## Reproducible preparation

Install Xcode and Rust **1.94.0** using your normal trusted toolchain setup. The
script will not install a compiler, run a privileged installer or contact a phone.

```sh
# Offline regression checks; no Swift, Rust or network needed.
python3 VexSign/Packages/DeviceBridge/test_prepare.py

# Verify the pinned archive and exact patch preconditions; no compilation.
python3 VexSign/Packages/DeviceBridge/prepare.py --prepare-only

# Host-only native unit tests, no credentials or device services.
python3 VexSign/Packages/DeviceBridge/prepare.py --test

# macOS: native tests plus iOS-device, universal simulator and macOS slices.
python3 VexSign/Packages/DeviceBridge/prepare.py --build
```

All generated sources, build caches, frameworks and provenance live under
ignored `.build` directories. Each cached framework is rehashed against its
complete artifact inventory and current source-overlay fingerprint before reuse.
A source/archive/license mismatch refuses preparation. The only upstream source
symlink (a README) is checked and flattened to its in-archive document; no archive
symlink is extracted.

The [source-build workflow](../../../.github/workflows/device-bridge.yml) runs
these synthetic native tests and builds the unsigned XCFramework; it neither
releases an IPA nor records successful device pairing. Native source license and
build provenance are not a claim of completed transitive redistribution review.
No new dependency is eligible for release merely because this job is green.
