# Enforced service contracts

Two files used to carry contracts that gates read, and nothing else did. They live
here so the repository keeps a single README; the gates that enforce the text are
named in each section, and they fail if it disappears.


## Web Manager

The Web Manager is the one part of VexSign that listens on a socket. It is turned
on from **Settings → Web Manager**, runs while the app is foregrounded, and serves
three things on one port: a browser UI for uploading files and installing what is
already on the device, a WebDAV share over the same library, and a JSON automation
API for scripts and shortcuts.

This section is the contract: which routes exist, what authenticates them, and what
they refuse to reveal. `Tools/Validation/security-validation/test_webmanager_doc_routes.py`
compares it against the routes registered in `WebManagerServer*`, so a new endpoint
cannot ship undocumented and a removed one cannot leave a promise behind. The
headings `## Web Manager routes`, `### Authentication`, `### JSON API` and
`### WebDAV` are load-bearing: the gate splits on them.

### Authentication


Two gates apply, in this order.

1. **The server gate** (`WebManagerAuthMiddleware`) covers every route,
   including WebDAV. It accepts
   - HTTP Basic, when a password is configured and *Require Password* is on; or
   - the API token, sent as `X-VexSign-Token: <token>` or
     `Authorization: Bearer <token>`, compared in constant time.
   With neither configured, the server refuses requests that come from a
   non-loopback address — an unauthenticated server is only useful to this
   device, which is what "keep the server on this device" means.

2. **The sensitive gate** (`WebManagerSensitiveAccessMiddleware`) covers the
   routes that expose signing identity or destroy content: `/api/sign`, every
   `/api/certs*` route and every `DELETE`. On those routes an API token is
   mandatory when one is configured; without a token they fall back to Basic
   auth, and they are refused outright when the server runs with no password at
   all. The UI says the same thing: a token is as powerful as the password.

Before either gate, `Host` and `Origin` are checked
(`WebManagerAccessPolicy.isAllowedHostHeader`). A public hostname, a
cross-origin `Origin`, or `Origin: null` is refused, so a page on the internet
cannot rebind a name it controls onto the device's LAN address and drive the
server from the user's browser. The app's own Host/Origin checks are in `WebManagerAccessPolicy`.

### JSON API


All responses are JSON unless the route streams a file. `token` below means
"the sensitive gate applies".

| Method | Path | Auth | Notes |
| --- | --- | --- | --- |
| `GET` | `/` | server | The browser UI. |
| `GET` | `/api/status` | server | Certificate state, library and update counts. Hidden apps are excluded from the counts. |
| `GET` | `/api/library` | server | Every app the vault does not hide. Hidden apps are absent, not marked. |
| `GET` | `/api/updates` | server | Apps a source has a newer version of; hidden apps excluded. |
| `GET` | `/api/apps` | server | Full library payload, including artifact metadata. |
| `GET` | `/api/apps/:uuid/download` | server | Streams the stored IPA. |
| `DELETE` | `/api/apps/:uuid` | token | Destroys the app, its rows and its artifacts. |
| `POST` | `/api/sign` | token | Streams an uploaded IPA in, signs with the default certificate, streams the signed IPA back. |
| `POST` | `/api/cleanup` | server | Runs the cleanup sweep and reports bytes reclaimed. Hidden apps are left out of the report. |
| `POST` | `/api/widget` | server | Rewrites the Home Screen widget payload. |
| `GET` | `/api/files` | server | Files currently in the inbox. |
| `DELETE` | `/api/files/:name` | token | Deletes one inbox file. |
| `POST` | `/upload/:name` | server | Raw-body upload into the inbox. |
| `GET` | `/download/:name` | server | Serves an inbox file. |
| `GET` | `/api/tweaks` | server | Enabled tweaks with their active version. |
| `GET` | `/api/tweaks/:id/download` | server | Streams the active `.deb`. |
| `DELETE` | `/api/tweaks/:id` | token | Removes a tweak. |
| `GET` | `/api/certs` | token | Certificates, without their secrets. |
| `POST` | `/api/certs` | token | Imports a `.p12` + provisioning profile pair. |
| `GET` | `/api/certs/:uuid/download` | token | Streams the `.p12` — only when *Allow certificate export* is on. |
| `DELETE` | `/api/certs/:uuid` | token | Removes a certificate. |
| `GET` | `/api/compression` | server | Current compression option. |

### WebDAV


The share root is the same library directory, under `/` and `/webdav`:

| Method | Result |
| --- | --- |
| `OPTIONS`, `PROPFIND` | Capability and directory listing (`Depth: 1`). |
| `GET` | File download. |
| `PUT` | Streaming upload into the share. |
| `MKCOL` | Create a directory. |
| `DELETE` | Delete a file or directory. |
| `MOVE`, `COPY` | Rename/copy inside the share. |
| `LOCK`, `UNLOCK` | Accepted so Finder's write path works; locks are not enforced across connections. |

Every path is resolved through `WebDAVTransferPolicy.isContained(_:in:allowRoot:)`
and every name through `WebManagerFilenamePolicy.sanitizedFilename(_:)`, which
rejects control characters, `.` and `..`. A resolved path that leaves the share
root is a `403`, never a normalization trick.

### Deliberate decisions


- **App Lock is not part of this gate.** Browsing the Web Manager from a
  computer while the phone is locked on a desk is a normal thing to do, so this
  surface authenticates with its own password or token rather than the
  device-owner gesture. What the lock does change is *visibility*: a hidden app
  is absent from every surface that can name it.
- **Certificate export is off by default** and gated separately
  (`allowsCertificateExport`), because a `.p12` leaving the device is a different
  risk from an IPA leaving it.
- **`/api/sign` streams.** Neither side is buffered in memory; the request body
  and the response body are streamed, so a 500 MB IPA does not become a 500 MB
  allocation.

### Tests and the untested surface


The pure pieces are covered, and each is worth reading before changing the
behaviour:

- `Tests/UnitTests/Application/WebManagerAccessTests.swift` — Host/Origin
  checks, token extraction and constant-time comparison, hidden-app visibility.
- `Tests/UnitTests/Application/WebManagerFilenamePolicyTests.swift` —
  traversal and header-injection rules for names.
- `Tests/UnitTests/Application/WebDAVTransferPolicyTests.swift` — containment.
- `Tools/Validation/security-validation/test_webmanager_wiring.py` — a
  text gate that the middleware is installed in the expected order.

The server itself (`WebManagerServer.swift`, `+HTTP`, `+API`, `+WebDAV`) has no
request-level test: nothing boots it and asserts a response. That is the largest
untested surface in the app, and the table above is the checklist for fixing it.

### Keys and contact

- Premium keys are **single-use and device-bound**.
- Keys are issued exclusively through the official distribution channel —
  contact **[@iamSMMH](https://t.me/iamSMMH)** on Telegram.
- Keys found anywhere else are not valid; unknown, reused or disabled keys are
  rejected by design.

#### Contact

Questions about premium, key issues, or refunds: **[@iamSMMH](https://t.me/iamSMMH)**.
Security findings about this service: please report them privately to the same
contact before disclosing anything publicly.

### Self-hosted source

Besides premium keys, this backend can host an AltStore-compatible source of your
own: upload IPAs, and `/repo/source.json` lists them in the exact shape
VexSign's `ASRepository` decodes (add it under **Sources → Add**).

| Endpoint | Purpose |
| --- | --- |
| `GET /repo/source.json` | AltStore v1 source (public) |
| `GET /repo/appdata` | Legacy AltServer XML feed (public) |
| `GET /static/apps/<file>.ipa` | The IPAs themselves (public) |
| `GET /api/admin/health` | Whether the admin surface is enabled (no token) |
| `POST /api/admin/keys` | Mint keys, `{"count": 1..250}` (admin token) |
| `GET /api/admin/keys` | List keys: masked `key`, stable `id`, state, device (admin token) |
| `POST /api/admin/keys/reveal` | Return one key in full by `id` or by key (admin token, audited) |
| `POST /api/admin/keys/{disable,enable,reset,revoke}` | Change one key's state (admin token) |
| `GET /api/admin/audit` | Recent admin actions: action, key id, client address (admin token) |
| `POST /api/admin/apps` | Upload an IPA (multipart `file`, admin token) |
| `GET /api/admin/apps` | List the source (admin token) |
| `DELETE /api/admin/apps/{bundle_identifier}` | Drop an app (admin token) |

`GET /api/admin/keys` never returns key material: each row carries a masked key
(`****-****-IJKL`, enough to match a customer's screenshot) and a stable `id`. Handing
a key out is the explicit, audited `POST /api/admin/keys/reveal`. Every mint, state
change, reveal and app upload lands in the audit trail with its key id and client
address, because `ADMIN_TOKEN` is one shared secret and "who disabled this key" has to
be answerable afterwards.

Bundle id, name and version are read from the IPA's own `Info.plist`, so the feed
can never disagree with the package it points at. Uploading a new version of an
existing bundle id replaces it.

```sh
curl -X POST https://your-host/api/admin/apps \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -F "file=@MyApp.ipa" -F "developer=Me" -F "subtitle=My build"
```

Storage is a JSON index plus a folder of IPAs — no database. Point
`REPO_STORE_DIR` at a mounted volume so uploads survive a redeploy:

```sh
make deploy-server                 # builds the linux/amd64 image
docker run -p 8080:8080 -e ADMIN_TOKEN=<secret> -v vexsign-repo:/data vexsign-server
```

`ADMIN_TOKEN` accepts a comma-separated list, so a rotation can overlap: add the new
secret, redeploy, move clients over, drop the old one. To rotate without a redeploy at
all, mount a file and set `ADMIN_TOKEN_FILE` to its path — one token per line, read on
each request. A configured file that cannot be read disables the admin surface rather
than falling back to the older secret.

### Browser tools

`GET /tools` serves six pages for the parts of the workflow that happen outside
the app. They are public (no key, no admin token) and keep nothing: no writes to
the database, no logs of what you upload.

| Page | Purpose |
| --- | --- |
| `/Tools/signer` | Queue IPAs and get signed ones back — a relay to the phone's Web Manager |
| `/Tools/repo-creator` | Build, validate and export an AltStore-compatible feed, plus OTA manifests |
| `/Tools/repo-decoder` | Read any feed dialect, normalise it, export it in another schema |
| `/Tools/app-installer` | OTA install link from a hosted IPA, plus a reachability probe |
| `/Tools/cert-check` | Read a provisioning profile's validity window, team, entitlements and device scope |
| `/Tools/udid` | Read a device UDID through a one-time enrolment profile |

| Endpoint | Purpose |
| --- | --- |
| `POST /api/Tools/sign/proxy` | Read-only relay for the phone's `/api/{status,library,updates}` |
| `POST /api/Tools/sign/sign` | Relay an IPA to the phone, stream the signed IPA back |
| `POST /api/Tools/repo/validate` | Lint a repository draft (same rules as the app's builder) |
| `POST /api/Tools/repo/export` | `source.json` (AltStore / flat) or `apps.json` |
| `POST /api/Tools/repo/ota` | OTA manifest + `itms-services://` install link |
| `POST /api/Tools/repo/decode` | Normalise any feed dialect (URL or pasted text) |
| `POST /api/Tools/repo/convert` | Re-export a feed in another schema |
| `POST /api/Tools/install/manifest` | OTA manifest + install link for a hosted IPA |
| `POST /api/Tools/install/probe` | Check a hosted IPA is actually installable |
| `POST /api/Tools/cert/inspect` | Parse an uploaded `.mobileprovision` / public certificate |
| `GET /api/Tools/cert/revoked-list` | The curated local revocation list |
| `GET /api/Tools/udid/profile?token=…` | The enrolment `.mobileconfig` |
| `POST /api/udid/callback?token=…` | Where the device posts its attributes |
| `GET /api/Tools/udid/session/{token}` | Poll for the result |

Honest limits, in one place:

- **Signer console** does not sign: it relays to the phone's Web Manager, so the
  phone must be reachable *from this server* (self-host on your LAN or a tailnet —
  a public deployment cannot reach a phone behind NAT). Bare `host:port` inputs
  default to `https://` to match the phone's HTTPS-only listener, and an explicit
  64-hex leaf SHA-256 `tlsCertSha256` (or `caCertPem`) pins the phone's
  self-signed TLS certificate without globally disabling certificate verification. Targets are restricted to
  private / loopback / CGNAT (`100.64.0.0/10`) addresses unless
  `VEXSIGN_ALLOW_PUBLIC_TARGETS=1`; link-local and cloud-metadata addresses
  (`169.254.0.0/16`, `fe80::/10`) are never allowed. Both `/Tools/*` (`/api/Tools/*`)
  and lowercase `/tools/*` (`/api/tools/*`) routes are served. The endpoint path
  is built from the parsed address, so an address carrying `?` or `#` is refused
  rather than turning the appended endpoint into a query string. Read-only
  redirects are limited to the original origin and guarded at every hop; the
  upload relay does not follow them. All relay TCP connections re-check and bind
  the resolved address before dialing.
- **The relay is not an open proxy.** It can reach loopback, so a deployment
  with a public address should set `VEXSIGN_RELAY_TOKEN`; every relay request
  must then send the matching `X-Relay-Token` header (constant-time compare).
  Enter it in the signer page's **Relay token** field, separately from the phone's
  API token. It stays in the page and is sent only to the relay.
  Leave it unset for a LAN/tailnet self-host, where the tool is public by
  design. What the relay *writes* is bounded: `/proxy` is GET-only against
  `status`, `library` and `updates`, so `POST /api/cleanup` is not reachable
  from a browser tab.
- **Repo decoder** fetches public feeds (that is the point), caps them at 4 MiB,
  and stores nothing.
- **App installer** hosts nothing and refuses cleartext on both the IPA and the
  manifest URL. Public feed and probe connections bind checked public DNS answers
  to the TCP dial; environment HTTP proxies are intentionally not used for these
  tools or the signer relay.
- **Repo creator** validates and exports. It never hosts your IPAs or the manifest —
  the OTA link points at whatever https URL you supply.
- **Cert checker** never accepts a `.p12` or a password (the endpoint has no such
  field), never contacts Apple, and reports a certificate as *unknown* unless its
  fingerprint appears in `Services/WebManager/Configuration/data/revoked_certs.json`. Parsing a profile is not
  CMS signature verification. `cryptography` is a declared requirement, so public
  `.cer`/`.pem` certificates are parsed in full; you still get fingerprints if that
  import is somehow broken.
- **UDID grabber** sessions live in process memory for 15 minutes, are capped at
  200, and are never written to disk. The generated profile is unsigned, so iOS
  says so — sign it with your own certificate to remove the warning. Anyone holding
  a session URL can read the UDID posted to it.

The pages are also reachable from the app: **Settings → Ecosystem → Web Tools**.

This optional component keeps its entry points in `API/`, nonsecret deployment
inputs/reference data in `Configuration/`, tests in `Tests/` and the served icon
in `Dashboard/`. `PREMIUM_FEED_FILE` still overrides the default
`Configuration/premium.json`; no real feed, secret or deployment is added here.
The normal local iOS signing workflow does not require this backend. When
`VEXSIGN_DB` is explicitly set, its parent directory must be writable: startup
fails on a bad path rather than silently switching to the ephemeral default.
Use a persistent mounted volume and verify backups for production deployments.

Run the component tests from the repository root:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r Services/WebManager/Configuration/requirements.txt pytest
make test-server
```

Or, from this component's `API/` directory, run
`python -m pytest ../Tests/ -q`. These are local/HTTP-contract tests, not a Docker
image or deployed-service acceptance run.

`VEXSIGN_ALLOW_PUBLIC_TARGETS=1` relaxes the signer relay's private-network guard;
`PUBLIC_BASE_URL` overrides the base used for generated URLs (see
`request_base.py`) and is effectively required behind a proxy that does not
forward `X-Forwarded-Host`/`X-Forwarded-Proto`, because the feed URLs handed to
the app are otherwise built from the request's `Host` header;
`VEXSIGN_RELAY_TOKEN` turns the signer relay into a token-gated endpoint for
deployments that are reachable from the internet (see above);
`VEXSIGN_TRUSTED_HOSTS` is a comma-separated Host allowlist (exact names or
`*.example.com` wildcards) that makes a forged `Host` header a 400 instead of a
feed URL pointing somewhere else — unset keeps header inference, which is what an
existing reverse proxy already relies on.

The host and scheme taken from forwarding headers are validated as a host token
and `http`/`https` before they are interpolated, so a malformed header cannot
produce a URL that parses as something else.

Rate limits are per client, answered with `429` and `Retry-After`, and come in
four budgets because the endpoints they cover have very different traffic
profiles. Clients are bucketed by the socket peer; behind Render or another proxy
every request arrives from an internal proxy peer, so set
`VEXSIGN_TRUST_FORWARDED_FOR=1` (and optionally `VEXSIGN_TRUSTED_PROXY_HOPS`,
default `1`) there to extract the rightmost untrusted hop from `X-Forwarded-For`
only when the direct socket peer is an internal proxy address. Forged leftmost
`X-Forwarded-For` entries from untrusted clients cannot rotate buckets. Set any
limit to `0` to disable that budget.

| Budget | Endpoints | Environment | Default |
|---|---|---|---|
| credential | `POST /api/validate`, `GET /api/urls` | `VEXSIGN_RATE_LIMIT` / `VEXSIGN_RATE_WINDOW_SECONDS` | 60 per 60s |
| feed | `GET /repo/premium.json` | `VEXSIGN_FEED_RATE_LIMIT` / `VEXSIGN_FEED_RATE_WINDOW_SECONDS` | 300 per 60s |
| admin | every `X-Admin-Token` route in `admin.py` | `VEXSIGN_ADMIN_RATE_LIMIT` / `VEXSIGN_ADMIN_RATE_WINDOW_SECONDS` | 20 per 60s |
| udid | `GET /Tools/udid`, `POST /api/udid/callback` | `VEXSIGN_UDID_RATE_LIMIT` / `VEXSIGN_UDID_RATE_WINDOW_SECONDS` | 30 per 60s |

The credential budget covers the endpoints that answer yes/no about a guessable
credential — a key, or a device UUID that only has to *have* an activation row.

The feed budget covers `/repo/premium.json`, which accepts the same two
credentials and therefore answers the same question; it is looser because a
Cydia-style source is fetched by the app on every repo refresh, not by one user
typing in a key.

The admin budget covers the whole token-gated surface rather than one endpoint.
It is tightest because those routes mint and revoke keys, and because a wrong
token is still counted: the limiter runs as a dependency *before* the token
comparison, so a guessed token costs the caller its budget. `GET
/api/admin/health` is deliberately outside it — uptime probes need to succeed
while the budget is exhausted, and it only reports whether a token is configured.

`GET /api/urls` still accepts the device UUID as the primary credential — every
shipped client sends `vexSignUUID` and none persisted a key at release time, so
requiring `X-API-Key` would 401 the installed base. A *redeemed* key is accepted
as an equivalent second credential (the same rule `/repo/premium.json` already
uses), and the rate limit is what stops a peer from walking device IDs.

## Anisette protocol mock

A minimal macOS HTTP server that returns the **shape** of an Anisette provider
response for VexSign's Free Apple ID signing flow.

> ⚠️ **This is a mock, not a working Anisette provider.** The eleven header values
> are **fabricated** (a random serial number, a UUID-derived hash, a fixed routing
> number). Apple's services will reject them, so this server **cannot**
> authenticate an Apple ID or provision certificates. It exists only to exercise
> the client/server wire format locally and to document the expected response.
>
> For actual signing, deploy a real Anisette implementation (for example an
> anisette-v3 compatible service) and configure its HTTPS endpoint in VexSign.

`Tools/Audit/test_integration_contracts.py` parses the JSON example below and
requires it to match the client's field set, so the two cannot drift.

### Platform


macOS only. The server uses Apple's **Network** framework, which is not available
on Linux; the package therefore declares no Linux platform. Build and run with
Swift 5.9+ on macOS:

```bash
cd Services/Cloud/Anisette
swift run            # or: swift build -c release && ./.build/release/AnisetteServer
```

The server binds to loopback (`127.0.0.1`, overridable via `ANISETTE_HOST`) on
port `8080` by default; set `PORT` to change it, and caps inbound HTTP request
headers at 16 KiB (`431 Request Header Fields Too Large`).

```bash
curl http://localhost:8080/anisette
```

Example response (values are illustrative and fabricated):

```json
{
  "X-Apple-I-MD": "abc123...",
  "X-Apple-I-MD-M": "def456...",
  "X-Apple-I-MD-RINFO": "1710000000",
  "X-Apple-I-MD-LU": "1710000000",
  "X-Apple-I-SRL-NO": "123456",
  "X-MMe-Client-Info": "VexSign-Protocol-Mock/1",
  "User-Agent": "VexSign-Protocol-Mock/1",
  "X-Apple-I-Client-Time": "2024-01-15T10:30:00.000Z",
  "X-Apple-I-Timezone": "America/New_York",
  "X-Apple-Locale": "en_US",
  "X-Mme-Device-Id": "ABCDEF12-3456-7890-ABCD-EF1234567890"
}
```

### Required header fields


A real provider must return these eleven fields as one flat JSON object:

| Header | Description |
|--------|-------------|
| `X-Apple-I-MD` | Machine ID hash |
| `X-Apple-I-MD-M` | Machine ID hash (variant) |
| `X-Apple-I-MD-RINFO` | Routing info |
| `X-Apple-I-MD-LU` | Last-updated timestamp |
| `X-Apple-I-SRL-NO` | Serial number |
| `X-MMe-Client-Info` | Client information |
| `User-Agent` | Client user agent |
| `X-Apple-I-Client-Time` | ISO8601 client time |
| `X-Apple-I-Timezone` | IANA timezone identifier |
| `X-Apple-Locale` | Locale identifier |
| `X-Mme-Device-Id` | Device UUID |

VexSign's HTTPS transport requires an `https://` endpoint with no embedded
credentials, query string or fragment, and validates that exactly these fields
are present. See `Packages/NativeSigning/Authentication/HTTPSAnisetteProvider.swift`.

### Configuring a real provider in VexSign


1. Open **Settings → Signing Methods → Free Apple ID**.
2. Tap **Anisette Provider**.
3. Enter your provider's HTTPS URL (e.g. `https://your-server.com/anisette`).
4. Tap **Test** to verify the endpoint.

This mock serves plain HTTP on localhost and is intended for local protocol
testing only; it is not a production deployment and should not be exposed.
