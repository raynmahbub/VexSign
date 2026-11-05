# Native signing architecture

## Goal

VexSign should own one coherent signing experience. Account authentication, provisioning, certificate handling, archive signing, installation, and renewal belong behind the existing product UI—not in a second embedded account app.

The `NativeSigning` package is the experimental implementation area. The ordinary imported-certificate pipeline remains the supported path until every native stage has passed build and device acceptance checks.

## Boundaries

```text
VexSign UI / task state
        │
        ▼
AppleAccountSessionCoordinator
        │
        ├── Authentication + consented anisette provider
        ├── Team/device/App ID registration
        ├── Development identity + provisioning profile creation
        ▼
Protected signing handoff
        │
        ▼
SigningService / Zsign
        │
        ├── Signed archive and nested-bundle audit
        ├── Entitlement and code-signature verification
        ▼
Installation + device-side evidence
        │
        ▼
Expiry tracking and quota-safe renewal
```

## Security and correctness rules

1. **Explicit consent:** authentication, certificate creation, device registration, and profile creation are separate user-approved operations.
2. **No destructive quota workaround:** never revoke an unrelated certificate automatically.
3. **Least exposure:** credentials and private keys stay in approved Keychain storage; logs use redacted errors.
4. **Fail closed:** invalid CMS, certificate purpose/trust, profile inventory, entitlements, archive layout, or signature evidence stops the operation.
5. **Bounded parsing:** certificates, property lists, Mach-O data, and ZIP entries are untrusted and must be size/structure checked.
6. **Evidence-based UI:** a requested operation is not a completed operation. Report installation only after device-side evidence.
7. **Single writer:** account/session stores and renewal jobs must not race across app entry points.

## Dependency strategy

The package uses pinned or constrained Swift Crypto, ASN.1, Certificates, OpenSSL, Zsign, NimbleKit, and SideSign dependencies. Preparation scripts stage isolated graphs under ignored `.build/` directories and verify reviewed pins/source hashes before a link smoke build.

A successful source-preparation script is not a native build. A successful link build is not an Apple account acceptance test. Keep those claims separate in reviews and release notes.

## Validation ladder

1. Python preparation and policy regressions.
2. `swift test --package-path NativeSigning`.
3. Isolated Vapor/Crypto compatibility tests.
4. Combined dependency resolution and device/simulator link smoke builds.
5. Physical-device tests with a dedicated test Apple ID and explicit consent.
6. End-to-end provisioning, signing, installation, expiration, renewal, cancellation, and failure-recovery tests.

## Production promotion checklist

- The app links the reviewed dependency graph without solver overrides.
- UI exposes only implemented stages and accurately reports pending/failed states.
- No test backend, synthetic identity, or compatibility stub is selected in production.
- Keychain, 2FA, team selection, quota, revocation, and offline behavior have device coverage.
- Output verification and installation evidence are enforced before success is published.
- Cancellation and relaunch cannot duplicate registration or resume with the wrong account/team.
- Documentation and release notes distinguish experimental and supported behavior.
