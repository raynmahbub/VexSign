# Web tools

Six browser tools served by the Python backend in [`server/`](../server/), under
`/tools`. They cover the parts of the workflow that are easier in a browser than
on a phone: driving the signer, building and reading feeds, reading a profile,
and getting a UDID.

| Page | Purpose | Module |
| --- | --- | --- |
| `GET /tools` | Hub linking the tools | `server/web_tools.py` |
| `GET /tools/signer` | Queue IPAs and get signed ones back, via the phone | `server/web_signer.py` |
| `GET /tools/repo-creator` | Build, validate and export an AltStore-compatible feed | `server/repo_creator.py` |
| `GET /tools/repo-decoder` | Read any source feed, normalise it, export it elsewhere | `server/repo_decoder.py` |
| `GET /tools/app-installer` | OTA install link + reachability probe for a hosted IPA | `server/app_installer.py` |
| `GET /tools/cert-check` | Read a provisioning profile's validity, team, entitlements and device scope | `server/cert_inspector.py` |
| `GET /tools/udid` | Read a device UDID through a one-time enrolment profile | `server/udid_grabber.py` |

Shared page chrome (CSS + `page()`) lives in `server/web_chrome.py`. The app
links to all of them from **Settings → Ecosystem → Web Tools**.

## 1. Signer console

A browser UI for the phone's on-device signer — the piece sideloading tools have and
VexSign did not. It does **not** sign in the browser: it relays.

| Endpoint | Purpose |
| --- | --- |
| `POST /api/tools/sign/proxy` | Read-only relay for `GET /api/{status,library,updates}` on the phone |
| `POST /api/tools/sign/sign` | Multipart IPA in, signed IPA streamed back |

Workflow: start the Web Manager on the iPhone (**Settings → Web Manager**),
paste its address (and the API token / Basic-auth pair if set) into the page,
drop in IPAs, and each one is streamed to `POST /api/sign` and streamed back as
`Signed-<name>.ipa`. A queue is supported, signed one at a time, because the
phone signs serially.

Why a relay rather than calling the phone from the page? The Web Manager sends no
CORS headers, so a cross-origin `fetch` cannot reach it — and adding
`Access-Control-Allow-Credentials` to a server that also accepts Basic auth would
be worse. Relaying keeps the browser call same-origin.

Guards:

- **Private networks only by default.** The target host must resolve to a
  private, loopback, link-local or CGNAT (`100.64.0.0/10`, i.e. tailnet) address,
  so this endpoint cannot be used to probe arbitrary hosts. Set
  `VEXSIGN_ALLOW_PUBLIC_TARGETS=1` only if your Web Manager genuinely has a
  public address.
- **Read-only relay.** The proxy accepts `status`, `library` and `updates` and
  nothing else — `POST /api/cleanup` is not reachable from a browser tab.
- **This server must be able to reach the phone.** Self-host on your LAN or
  tailnet. A public deployment cannot reach a phone behind NAT; that is intended.
- Nothing is stored and tokens are never logged.

## 2. Repository creator

A form for repository metadata plus a repeatable app list, with import from a
file or URL, live validation, and export.

| Endpoint | Body | Returns |
| --- | --- | --- |
| `POST /api/tools/repo/validate` | `{"draft": {…}}` | `issues[]` (`error`/`warning`, message, suggestion, app), counts |
| `POST /api/tools/repo/export` | `{"draft": {…}, "format": "altstore"\|"flat"\|"apps"}` | `filename`, pretty `json`, `errorCount` |
| `POST /api/tools/repo/ota` | `{"app": {…}, "manifestURL", "displayImageURL", "fullSizeImageURL"}` | manifest plist, `installLink` |

The validation rules mirror `VexSign/RepositoryBuilder/RepositoryValidator.swift`
(missing identifiers, non-http(s) URLs, unparseable dates, duplicate screenshots,
duplicate bundle ids), so a feed that passes here imports cleanly in the app.
`altstore` emits `versions[]` history, `flat` the Feather/ESign-style schema,
`apps` the bare `apps.json` array.

**The OTA endpoint refuses cleartext**: both the IPA URL and the manifest URL
must be `https`, because `itms-services://` will not install over http. Nothing is
uploaded or hosted — you get a manifest file and a link to paste.

Hosting the feed is your job: this server's own `POST /api/admin/apps` reads each
IPA's `Info.plist` and publishes `/repo/source.json`, or use any static HTTPS
host.

## 3. Repository decoder

Feeds have four dialects in the wild and "my repo shows up empty" is usually a
spelling mismatch. This reads all of them, maps them onto one canonical shape,
and lints the result with the Repository Creator's own validator.

| Endpoint | Purpose |
| --- | --- |
| `POST /api/tools/repo/decode` | `{source: url}` or `{payload: text}` → format, normalised apps, issues, alias usage, stats |
| `POST /api/tools/repo/convert` | Same input plus `format` (`altstore` \| `flat` \| `apps`) → the re-exported feed |

Understood dialects: AltStore v1 `source.json`, the SideStore variant with
`versions[]`, the Feather/ESign flat schema (`bundleID`, `appDescription`,
`downloadUrl`), a bare `apps.json` array, and the legacy AltServer `appdata` XML
that this repo's own server still emits at `/repo/appdata`.

`aliasesUsed` reports which non-canonical spellings were mapped, so a broken feed
shows you the key it got wrong instead of just an empty list. Fetches are capped
at 4 MiB, follow redirects only over http(s), and are never stored.

## 4. App installer

| Endpoint | Purpose |
| --- | --- |
| `POST /api/tools/install/manifest` | `{ipaURL, manifestURL, name, bundleIdentifier, version, size, probe}` → manifest plist, `itms-services://` link, issues |
| `POST /api/tools/install/probe` | `{ipaURL}` → status, content type, length, redirect chain, installability verdict |

The probe exists because the two failure modes that waste an afternoon are
invisible in the plist: a host that answers `HEAD` with 405 (a ranged `GET` is
tried instead), and a URL that redirects to cleartext, which iOS refuses silently
while the device just spins. `Content-Length` also fills in the size field when
you do not know it.

Both URLs must be https or the request is rejected with 422. Nothing is hosted
here — you get a `manifest.plist` for your own HTTPS host and the link.

## 5. Certificate status checker

Parses what a provisioning profile actually says, and nothing more.

| Endpoint | Purpose |
| --- | --- |
| `POST /api/tools/cert/inspect` | multipart upload of a `.mobileprovision` (or public `.cer`/`.pem`) → status, team, App ID, entitlements, device count, expiry countdown, fingerprints, revocation lookup |
| `GET /api/tools/cert/revoked-list` | the curated list this deployment consults |

The page parses the profile **in the browser** (the plist is extracted from the
CMS blob and read with `DOMParser`); the upload button is opt-in for people who
want the server's parse and revocation lookup.

Status is computed from the profile's own validity window: `valid`, `expiring`
(≤30 days), `critical` (≤7 days), `expired`.

Hard limits, by design:

- **No `.p12`, no password.** The endpoint has no password field and rejects
  `.p12`/`.pfx` uploads with a 422. There is nothing to leak.
- **Apple is never queried.** "Revoked" means *listed in
  `server/data/revoked_certs.json` on this deployment*; an unlisted certificate
  is reported as **unknown**, never as valid. See
  [`server/data/README.md`](../server/data/README.md) for the format.
- **Parsing is not verification.** The plist is read out of the signed blob; that
  says nothing about who signed it.
- **Public certificates** (`.cer`/`.pem`) get subject, issuer, validity, CA flag
  and fingerprints when the optional `cryptography` package is installed, and
  fingerprints alone when it is not. It is not in `requirements.txt` on purpose —
  the profile path, which is the common case, is pure stdlib.

## 6. UDID grabber

| Endpoint | Purpose |
| --- | --- |
| `GET /tools/udid` | page; creates a one-time session token |
| `GET /api/tools/udid/profile?token=…` | the enrolment `.mobileconfig` |
| `POST /api/udid/callback?token=…` | where iOS posts the signed attribute plist |
| `GET /api/tools/udid/session/{token}` | the page polls this for the UDID |

The profile is a standard *Profile Service* payload (`PayloadType = Profile
Service`, `PayloadVersion = 1`) asking for `DEVICE_UDID`, `DEVICE_NAME`,
`PRODUCT`, `SERIAL`, `VERSION`, `IMEI` and `MEID`. iOS posts the result back as a
raw CMS-signed plist; the callback pulls the plist out of the body and stores the
attributes against the token.

Guards:

- Sessions live in process memory for **15 minutes**, capped at **200** (oldest
  evicted first). Nothing is written to disk and no UDID is logged.
- An expired session's callback gets **410 Gone** and the UDID is discarded.
- A response without a UDID gets **422**, so a malformed post cannot mark a
  session as received.
- The token is a bearer secret: whoever holds the page URL sees the UDID posted
  to it.
- The generated profile is **unsigned**, so iOS says so. Sign it with your own
  certificate to remove the warning.
- Install flow on iOS 16+: Settings → *Profile Downloaded* → Install; remove it
  afterwards.

## Deployment

Nothing extra is required: the tools ship with `server/main.py` and are mounted
by `app.include_router(web_tools_router)`. Set `PUBLIC_BASE_URL` if your proxy
does not forward `X-Forwarded-Host`/`X-Forwarded-Proto` — the UDID callback URL
is built from it (see `server/request_base.py`, the single implementation shared
with the premium API).

```sh
cd server
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000   # then open http://localhost:8000/tools
```

`httpx` (pinned in `requirements.txt`) is the one dependency the tools add: the
signer console relays to the phone, the decoder fetches feeds and the installer
probes URLs, all of which need streaming.

Environment variables:

| Variable | Default | Effect |
| --- | --- | --- |
| `PUBLIC_BASE_URL` | inferred from forwarding headers | Absolute base for generated URLs (UDID callback, OTA links) |
| `VEXSIGN_ALLOW_PUBLIC_TARGETS` | off | Let the signer relay reach non-private hosts |

## Untrusted values in the page

Every tool page displays data that did not originate on this server:

| Tool | Untrusted input |
| --- | --- |
| Repository Decoder | app names, versions, developers and issues from any remote feed |
| Repository Creator | a feed pulled in from a URL and rendered as editable cards |
| UDID Grabber | attributes reported by the device |
| Signer Console | certificate name from the phone, names of files you pick |
| Certificate Check | fields parsed from an uploaded provisioning profile, entitlement keys, revocation notes |
| App Installer | content type, status and redirect URLs returned by the probed host |

All of those reach `innerHTML`, so every one is passed through the shared `esc()`
helper that `web_chrome.page()` injects before the page script. `escapeAttr()` in
the repository creator delegates to the same helper, so there is one escaping
rule rather than two. Without it, a malicious feed
or a device named like markup would run script in the tool's origin — which can
then call the relay endpoints.

When adding a tool, escape any value you did not construct yourself, and add a
case to `server/tests/test_tool_xss.py`. Those tests execute `esc()` in Node when
it is available (and skip that part when it is not) rather than only grepping for
it, plus assert each page still routes its untrusted fields through the helper.

## Tests

| File | Covers |
| --- | --- |
| `test_web_tools.py` | Repo creator, certificate checker, UDID page/profile/callback |
| `test_signer_decoder_installer.py` | Target guard (private allowed, public refused, env override), read-only relay enforcement, upstream 401/412 passthrough, streamed signed IPA and filename, all five feed dialects, alias normalisation, validator errors, the 4 MiB fetch cap, dialect conversion, https-only manifests, every probe outcome (HEAD ok, HEAD refused → GET, 404, HTML body, cleartext redirect, connection failure) |
| `test_udid_sessions.py` | Session TTL/expiry, the hard cap with oldest-first eviction, touch-to-keep behaviour, CMS-wrapped plist parsing, attribute allow-listing, unsigned removable profile payload, callback rejection paths, and that sessions never touch the DB or disk |
| `test_tool_xss.py` | `esc()` executed against markup/quotes/nullish values, every tool page escaping its untrusted fields, and the `rows`/`issueRow`/`escapeAttr` page helpers extracted and run in Node against a payload |

Outbound calls go through `httpx.MockTransport`, so the suite never touches the
network.

```sh
cd server && python -m pytest tests/ -q
```
