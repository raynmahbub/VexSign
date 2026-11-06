# NativeSigning

`NativeSigning` contains VexSign's experimental Swift building blocks for Apple ID authentication, development identities, provisioning profiles, and signed-archive validation. It is a library package, not a standalone app.

> **Status:** experimental. The package and its tests do not prove end-to-end account provisioning, signing, installation, renewal, or production UI integration. Do not enable it for production accounts without native/device acceptance testing.

## Modules

| Directory | Responsibility |
| --- | --- |
| `Authentication/` | Consented anisette access and native account backends |
| `Identity/` | Development certificate validation and IPA/signature inspection |
| `Provisioning/` | Profile CMS, registration, creation, and transport policies |
| `Security/` | Credential storage, resume journals, and runtime policy |
| `Services/` | Authentication state and account-session coordination |
| `Signing/` | Strict archive, Mach-O, entitlements, and signature verification |
| `Tests/` | Swift package tests |
| `PythonTests/` | Dependency-free preparation and policy regression tests |

The package links Swift Crypto, ASN.1, Certificates, OpenSSL, Zsign, NimbleKit, and SideSign. Zsign is vendored under `Vendor/Zsign`, so the package graph needs no Git submodules.

## Anisette protocols and renewal metadata

Provider descriptors distinguish legacy header JSON from v3. The v3 path drives
SideSign/AnisetteKit's ADI provisioning protocol, persists its provider-bound UUID
and ADI blob in primary-runtime, device-only Keychain storage, and rejects silent
legacy fallback. Catalogue membership is not a live-health or compatibility
certificate. Neither provider health checks nor ADI provisioning authorize Apple
account mutations. Native compilation and real-provider/device acceptance remain
required.

Authenticated profile operations can record a separate, owner-bound device-only
receipt index with the actual identity UUID, bundle ID, UDID, expiry and CMS hash.
The mutation journal remains hash-only. Local receipt inventory is not Apple's
complete portal inventory or installation quota; legacy journal rows have no
invented identity, device or expiry metadata. Receipts are historical discovery
facts, not current CMS validation, renewal approval or signing authority.

Background discovery populates a review queue. It does **not** generate fresh
certificates, create approvals, re-sign archives or install apps. Unattended
renewal still needs an explicit scoped grant, fresh portal/CMS validation, an
owned identity, signing input and device-side installation evidence. The default
CMS promotion gate remains closed.

## Validate

```bash
python3 -m unittest discover -s NativeSigning/PythonTests -v
swift test --package-path NativeSigning
```

The opt-in **Native account signing · link smoke** workflow can also stage isolated dependency graphs, run synthetic macOS unit regressions (`unit_tests`, enabled by default), and compile device/simulator link checks. It does not log in to Apple, create certificates, publish IPAs, or open listeners.

`prepare_server_compatibility.py` stages the app's Vapor factory and compatibility tests in an ignored build directory. `prepare_combined_smoke.py` validates the proposed combined package graph. These preparation scripts fail closed on pin or reviewed-source drift.

## Integration rules

- Require explicit user consent for account, certificate, device, and provisioning operations.
- Never revoke unrelated certificates automatically to free a slot.
- Keep credentials in the approved Keychain stores and redact logs.
- Treat parsed certificates and archives as untrusted input; bound reads and reject ambiguous structures.
- Keep imported-certificate signing separate until the native pipeline has passed device acceptance tests.
- Update dependency review inputs and regression tests whenever package pins or upstream reviewed sources change.

See [the architecture guide](../docs/NATIVE_SIGNING_ARCHITECTURE.md) for integration boundaries.
