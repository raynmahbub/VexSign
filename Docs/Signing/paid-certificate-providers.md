# Paid and external signing identities

This document records what VexSign actually supports today. It deliberately does
not describe unverified provider APIs as integrations.

## Current state

VexSign has **no verified paid-certificate provider integration**. No remote
provider account, token, certificate order or paid portal workflow is asserted
to work. The only external catalogue already in the app is the unofficial
[NexCerts community catalogue](../../VexSign/Services/Identity/NexCerts.swift),
which publishes a shared identity together with its password. It is labelled as
untrusted in the UI and requires explicit acknowledgement.

The following code is present and exercised by deterministic tests:

- `UnifiedSigningIdentity`: a read-only projection of the existing certificate
  store and the existing Keychain vault. It is not a second vault.
- `SigningIdentityProvenance`: explicit provenance recorded by an importing
  integration. Source is never inferred from a nickname or filename.
- `SigningProviderRegistry` / `NexCertsProviderAdapter`: a provider boundary
  where a verified workflow can be added. Only capabilities that actually exist
  are advertised; no generic HTTP client or invented endpoint is present.
- `UnifiedIdentityCompatibility`: reuses the vault evaluator and adds explicit
  engine-readiness and distribution restrictions.
- `SigningIdentityLifecycle`: expiry/refresh/replacement decisions that keep
  existing valid identities on refresh failure.
- `UnifiedSigningIdentitiesView`: SwiftUI screen backed by the real store and
  vault state; networking and Keychain access stay in services.

## Supported material

| Source | Import | Native signing | Notes |
| --- | --- | --- | --- |
| User-imported `.p12` / `.pfx` + `.mobileprovision` | Yes | Yes | Password stored only in Keychain; staged p12 is consumed by Zsign. |
| Keychain certificate vault | Yes | No | iOS cannot export its `SecIdentity` as PKCS#12, so it is shown as vault-only. |
| Apple Account handoff | Existing free-account flow | Via ordinary imported-store path | Handoff provenance is recorded; free vs paid enrolment is not guessed. |
| Paid Apple Developer Program certificate files | Yes, as imported PKCS#12 | Yes | No paid portal API is claimed; the user supplies the files. |
| Enterprise distribution profile | Can be imported for inspection | Blocked for ordinary device installation | Reported as enterprise, not as a paid personal certificate. |
| Community NexCerts catalogue | Yes | Yes, after local validation | Shared, untrusted identity; status is advisory. |

## Deliberately unsupported

- Certificate resale, sharing or an unauthorised certificate marketplace.
- Enterprise distribution misuse or treating enterprise profiles as personal paid signing identities.
- Apple Account authentication bypass, unofficial Apple-like login forms or an Apple ID password sent to a third party.
- Remote signing services and provider-specific APIs whose endpoints/workflows have not been verified from real documentation or source.
- New signing algorithms or tweak injection.
- A second signing engine: all eligible identities resolve to the existing `SigningEngineRequest` and Zsign adapter.

## Security decisions

- Provider credentials use `SecureSecretStore` (Keychain, non-synchronisable, device-only). Credentials are never written to `UserDefaults`, JSON inventories, logs or SwiftUI state as readable values.
- Only idempotent catalogue reads are retried, at most twice with a capped delay. Certificate downloads and imports are never retried automatically.
- TLS, final-host checks and bounded response sizes follow the existing catalogue client. A 429/503 from the declared source surfaces a rate-limit error instead of a retry loop.
- Redaction is fixed-string; neither a token nor a prefix of it can reach a log.
- Disconnecting a provider revokes its acknowledgement. It never revokes a certificate or deletes imported identities.
- Signature verification remains mandatory; compatibility is necessary but never a substitute for the verification report.

## Testing boundary

`VexSignTests/UnitTests/Signing/UnifiedSigningIdentityTests.swift` uses only
deterministic fixtures and injected closures. It covers identity metadata,
provenance, expiry/key loss, compatibility, provider capability discovery,
bounded retry, rate limit, malformed/empty catalogues, cancellation, disconnect,
redaction, orphan detection and end-to-end signing eligibility. These tests are
**not** live provider, Apple portal, Keychain or device-installation proof.
No GitHub Actions run is claimed in this document.
