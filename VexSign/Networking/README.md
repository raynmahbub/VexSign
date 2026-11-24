# Networking

HTTP clients, API communication, download transport, and network-facing coordination used by
VexSign services.

| Folder | Contents |
| --- | --- |
| `HTTP/` | `TransferSecuritySession`, `BoundedResponseFetch`, `HTTPTimeoutPolicy` — the one place a request leaves the app. |
| `API/` | `VexSignAPIClient`, `NetworkTransferAdapter` — endpoints and typed responses. |
| `Downloads/` | `PackageDownloadRedirectDelegate` — redirect and byte-cap enforcement for untrusted package files. |
| `Authentication/` | `AuthenticatedRequestBuilder` — premium API key/UUID headers, applied before the request is handed to `HTTP/`. |
| `Monitoring/` | `NetworkReachabilityMonitor`, `LocalNetworkHost` — reachability and LAN detection. |

## Where the rules live

Transport here moves bytes. The decisions about those bytes stay in `VexSign/Security/`:

- `Security/Policies/PackageDownloadURLPolicy` decides whether a package URL and its redirects are
  acceptable. `Downloads/PackageDownloadRedirectDelegate` only asks it.
- `Security/Policies/TransferAcceptancePolicy` owns the accepted HTTP statuses (2xx only) and the
  8 GiB package ceiling. `HTTP/`, `API/` and `Downloads/` ask it directly, which is what keeps this
  layer from depending on `Services/Download`.
- `Services/Download/DownloadIntegrity` applies that same ceiling plus the declared size and
  SHA-256 verdict once a file has landed; it delegates to the policy rather than copying the rule.

## Layer rules

`Networking` compiles without SwiftUI, UIKit, Core Data or Nuke, and without naming a type from the
`Services/Download` workflow. `Tools/Validation/architecture-rules/test_architecture_boundaries.py`
enforces both. A new network type belongs in one of the five folders above; a new *rule* about what
may be fetched, verified or trusted belongs in `Security/`.
