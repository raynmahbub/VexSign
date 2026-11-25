# Security boundaries

VexSign signs and installs applications. That makes the trust boundary more important
than the folder names: a UI screen must never be able to quietly become a signing or
trust decision.

## Ownership

| Area | Owns | Does not own |
| --- | --- | --- |
| `VexSign/Security/Certificates` | P12 parsing, chain validation, identity inspection | persisting the identity |
| `VexSign/Security/Cryptography` | CMS, hashes, integrity verification | choosing which source is trusted |
| `VexSign/Security/CodeSigning` | Bundle signing policy and signature validation | presenting a signing screen |
| `VexSign/Security/Entitlements` | Parsing, comparison, rewriting | provisioning profile storage |
| `VexSign/Security/Provisioning` | Profile parsing and compatibility | installation |
| `VexSign/Security/ArchiveValidation` | IPA inspection and safe extraction | downloading bytes |
| `VexSign/Security/Trust` | Trust, OCSP and revocation decisions | UI state |
| `VexSign/Security/Credentials` | Secret handling rules and password migration | the Keychain container itself |
| `VexSign/Security/Policies` | Accepted source, URL, manifest and transfer rules | transport implementation |
| `VexSign/Storage/Keychain` | Persisting what Security hands it | re-deciding acceptability |
| `VexSign/Networking` | Transport, redirects and bytes | policy decisions |
| `VexSign/System` | Keychain APIs, device transport, OS adapters | security policy |
| `VexSign/Features` | User interaction and workflow invocation | any signing engine |

## Cross-area contract

```text
Feature -> Shared/Protocols port -> App-injected Service -> Security decision
                                                      -> Storage persistence
                                                      -> Networking transport
                                                      -> System OS call
```

Cross-area calls go through `VexSign/Shared/Protocols/` — for example
`SecureTransferProviding` and `SecurityPolicyValidating`. This is why
`Networking/Downloads/PackageDownloadRedirectDelegate` names a protocol instead of
importing a policy implementation.

## Invariants

1. `Security` imports no SwiftUI, UIKit, Core Data or Nuke. It is checked by
   `test_architecture_boundaries.py` and `test_architecture_excellence.py`.
2. `Security` may call `Storage/Keychain` for the certificate-password bridge; `Storage`
   must not import a signing or trust implementation to make its own decision.
3. Private keys are handled through `Security/Credentials`; features never receive raw
   key material for display, logging or persistence.
4. Transfer acceptance is decided once in `Security/Policies/TransferAcceptancePolicy`
   (2xx only, 8 GiB ceiling) and enforced by `Networking/HTTP` and
   `Networking/Downloads`.
5. Archive extraction rules live in `Security/ArchiveValidation`; extraction code in
   `Services/Import` consumes them rather than duplicating path checks.
6. No new singleton owns a security decision. `singleton-freeze.py` and
   `test_concurrency_audit.py` protect the existing graph.
7. Device acceptance is evidence, not folder structure. A green portable gate does not
   claim physical-device signing or installation success.

## Verification map

| Question | Gate |
| --- | --- |
| Does a feature import an engine or UI-leak a managed object? | `test_architecture_excellence.py` |
| Did security gain a UI framework? | `test_architecture_boundaries.py` |
| Did a singleton or unsafe escape appear? | `singleton-freeze.py`, `concurrency-discipline.py`, `test_concurrency_audit.py` |
| Did transport or archive policy change? | `test_archive_extraction_policy.py`, `test_network_timeout_policy.py`, `test_public_blur_policy.py` |
| Did a credential path regress? | `test_signing_identity_policy.py`, `test_private_launch_policy.py` |

See also [`dependency-rules.md`](dependency-rules.md) and
[`adr/0001-production-architecture.md`](adr/0001-production-architecture.md).
