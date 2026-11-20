# VexSign Premium Backend

This directory contains the private backend that powers VexSign's premium
features — license-key validation and the gated premium source the app unlocks.

It is committed to the public repository **for transparency only**: anyone can
audit exactly what the app communicates with, what data is stored (key, device
binding, status — nothing else), and how keys are enforced. It is **not** a
deployment or self-hosting guide, and no setup instructions are published.

## Keys

- Premium keys are **single-use and device-bound**.
- Keys are issued exclusively through the official distribution channel —
  contact **[@iamSMMH](https://t.me/iamSMMH)** on Telegram.
- Keys found anywhere else are not valid; unknown, reused or disabled keys are
  rejected by design.

## Contact

Questions about premium, key issues, or refunds: **[@iamSMMH](https://t.me/iamSMMH)**.
Security findings about this service: please report them privately to the same
contact before disclosing anything publicly.

## Self-hosted source

Besides premium keys, this backend can host an AltStore-compatible source of your
own: upload IPAs, and `/repo/source.json` lists them in the exact shape
VexSign's `ASRepository` decodes (add it under **Sources → Add**).

| Endpoint | Purpose |
| --- | --- |
| `GET /repo/source.json` | AltStore v1 source (public) |
| `GET /repo/appdata` | Legacy AltServer XML feed (public) |
| `GET /static/apps/<file>.ipa` | The IPAs themselves (public) |
| `POST /api/admin/apps` | Upload an IPA (multipart `file`, admin token) |
| `GET /api/admin/apps` | List the source (admin token) |
| `DELETE /api/admin/apps/{bundle_identifier}` | Drop an app (admin token) |

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

## Browser tools

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
  a public deployment cannot reach a phone behind NAT). Targets are restricted to
  private / loopback / CGNAT addresses unless `VEXSIGN_ALLOW_PUBLIC_TARGETS=1`;
  link-local and cloud-metadata addresses (`169.254.0.0/16`, `fe80::/10`) are
  never allowed. The endpoint path is built from the parsed address, so an
  address carrying `?` or `#` is refused rather than turning the appended
  endpoint into a query string. Redirects are followed one hop at a time with
  the guard re-applied to each hop, and the upload relay does not follow them at
  all.
- **The relay is not an open proxy.** It can reach loopback, so a deployment
  with a public address should set `VEXSIGN_RELAY_TOKEN`; every relay request
  must then send the matching `X-Relay-Token` header (constant-time compare).
  Leave it unset for a LAN/tailnet self-host, where the tool is public by
  design. What the relay *writes* is bounded: `/proxy` is GET-only against
  `status`, `library` and `updates`, so `POST /api/cleanup` is not reachable
  from a browser tab.
- **Repo decoder** fetches public feeds (that is the point), caps them at 4 MiB,
  and stores nothing.
- **App installer** hosts nothing and refuses cleartext on both the IPA and the
  manifest URL.
- **Repo creator** validates and exports. It never hosts your IPAs or the manifest —
  the OTA link points at whatever https URL you supply.
- **Cert checker** never accepts a `.p12` or a password (the endpoint has no such
  field), never contacts Apple, and reports a certificate as *unknown* unless its
  fingerprint appears in `VexSign/Services/WebManager/Configuration/data/revoked_certs.json`. Parsing a profile is not
  CMS signature verification. Install the optional `cryptography` package to also
  parse public `.cer`/`.pem` certificates; without it you still get fingerprints.
- **UDID grabber** sessions live in process memory for 15 minutes, are capped at
  200, and are never written to disk. The generated profile is unsigned, so iOS
  says so — sign it with your own certificate to remove the warning. Anyone holding
  a session URL can read the UDID posted to it.

The pages are also reachable from the app: **Settings → Ecosystem → Web Tools**.

This optional component keeps its entry points in `API/`, nonsecret deployment
inputs/reference data in `Configuration/`, tests in `Tests/` and the served icon
in `Dashboard/`. `PREMIUM_FEED_FILE` still overrides the default
`Configuration/premium.json`; no real feed, secret or deployment is added here.
The normal local iOS signing workflow does not require this backend.

Run the component tests from the repository root:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r VexSign/Services/WebManager/Configuration/requirements.txt pytest cryptography
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

`POST /api/validate` and `GET /api/urls` are the endpoints that answer yes/no
about a guessable credential — a key, or a device UUID that only has to *have* an
activation row — so they are rate limited per client: `VEXSIGN_RATE_LIMIT`
requests per `VEXSIGN_RATE_WINDOW_SECONDS` (default 60 per minute, `0` disables
it), answered with `429` and `Retry-After`. Clients are bucketed by the socket
peer; behind Render or another proxy every request arrives from the proxy, so set
`VEXSIGN_TRUST_FORWARDED_FOR=1` there to bucket on the first `X-Forwarded-For`
entry instead. That header is caller-controlled, hence the opt-in.

`GET /api/urls` still accepts the device UUID as the primary credential — every
shipped client sends `vexSignUUID` and none persisted a key at release time, so
requiring `X-API-Key` would 401 the installed base. A *redeemed* key is accepted
as an equivalent second credential (the same rule `/repo/premium.json` already
uses), and the rate limit is what stops a peer from walking device IDs.
