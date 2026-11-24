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
- `Security/Cryptography/FileIntegrity` decides when a transfer has exceeded the package limit.
- `Security/Policies/SecurityPolicyGateway` is the interface features and services call; they never
  reach into `Networking/` for a policy.

A new network type belongs in one of the five folders above. A new *rule* about what may be
fetched, verified, or trusted belongs in `Security/`.
