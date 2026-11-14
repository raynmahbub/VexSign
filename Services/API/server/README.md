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
  private / loopback / link-local / CGNAT addresses unless
  `VEXSIGN_ALLOW_PUBLIC_TARGETS=1`. The relay is read-only (`status`, `library`,
  `updates`), so `POST /api/cleanup` is not reachable from a browser tab.
- **Repo decoder** fetches public feeds (that is the point), caps them at 4 MiB,
  and stores nothing.
- **App installer** hosts nothing and refuses cleartext on both the IPA and the
  manifest URL.
- **Repo creator** validates and exports. It never hosts your IPAs or the manifest —
  the OTA link points at whatever https URL you supply.
- **Cert checker** never accepts a `.p12` or a password (the endpoint has no such
  field), never contacts Apple, and reports a certificate as *unknown* unless its
  fingerprint appears in `Services/API/server/data/revoked_certs.json`. Parsing a profile is not
  CMS signature verification. Install the optional `cryptography` package to also
  parse public `.cer`/`.pem` certificates; without it you still get fingerprints.
- **UDID grabber** sessions live in process memory for 15 minutes, are capped at
  200, and are never written to disk. The generated profile is unsigned, so iOS
  says so — sign it with your own certificate to remove the warning. Anyone holding
  a session URL can read the UDID posted to it.

The pages are also reachable from the app: **Settings → Ecosystem → Web Tools**.

Tests for this surface live in `Services/API/server/tests/`:

```sh
pip install -r requirements.txt   # httpx is pinned there: the tools fetch/relay/probe
pip install pytest
python -m pytest tests/ -q        # 85 tests
```

`VEXSIGN_ALLOW_PUBLIC_TARGETS=1` relaxes the signer relay's private-network guard;
`PUBLIC_BASE_URL` overrides the base used for generated URLs (see
`request_base.py`).
