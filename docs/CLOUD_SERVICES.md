# Cloud and companion services: what exists, and who calls it

Verified against the source on `main` at `94cc1b2` (2026-11-12). Every statement below was read
from the file it names; nothing here is copied from a README that was not also checked.

## The inventory

| Component | Language / runtime | What it does | Deployed by |
|---|---|---|---|
| `server/` | Python 3.12, FastAPI + uvicorn | The premium API: device-key validation, premium repository URLs, a self-hosted source feed, browser tools (repo decoder, signer relay, UDID sessions) | `render.yaml` (Render free web service) |
| `cloud-signing/` | Node 22, TypeScript, Fastify 5 | Durable asynchronous signing jobs: upload, queue, worker, OTA install pages, webhooks. PostgreSQL for state, Redis/BullMQ for the queue, S3-compatible object storage for artifacts | `cloud-signing/Dockerfile`, operator-managed |
| `AnisetteServer/` | Swift, macOS only | **A protocol mock.** Fabricated headers; cannot authenticate anything. Exists to exercise the Free Apple ID wire format locally | `swift run` on a Mac |
| `VexSign/Backend/Server/` | Swift, Vapor/NIO | In-app Web Manager and OTA manifest server (device-local, not a cloud service) | Ships inside the app |
| `VexSign/Companion/` | Swift | Companion/watch sync client and its stores | Ships inside the app |

There is no other backend. No queue, database or storage service is introduced by this document.

## Who talks to what

```
iOS app
 ├── PremiumManager ──HTTPS──▶ server/         POST /api/validate, GET /api/urls
 ├── FR / sources   ──HTTPS──▶ arbitrary JSON repository feeds (user-supplied URLs)
 ├── CloudSigningClient ─────▶ cloud-signing/  GET /health/live, POST /api/upload,
 │                                            POST /api/sign, GET /api/jobs/:id
 ├── HTTPSAnisetteProvider ──▶ a configured Anisette endpoint (mock, or the operator's real one)
 ├── AppStoreHelper / IPSWBrowser ▶ Apple public endpoints (read-only metadata)
 └── Companion client ───────▶ a paired device, local network
```

The app is usable with none of these reachable except the ones a given screen needs: the library,
signing on-device, and repository browsing of already-saved sources are local.

## Verified defects, by severity

| # | Severity | Finding | State |
|---|---|---|---|
| 1 | **Critical** | `CloudSigningClient` decoded `{jobId}` from `POST /api/sign`; the service sends `JobAccepted {id, state}`. Every accepted submission failed to decode. | **Fixed** — `CloudJobAccepted`, pinned by `tools/test_cloud_signing_contract.py` and three Swift tests |
| 2 | **Critical** | `CloudSigningClient` decoded `{status, progress, step, downloadUrl, installUrl, error}` from `GET /api/jobs/:id`; the service sends `{id, kind, state, result, error_code, output_sha256, created_at, finished_at, installURL?}`. Job polling could never succeed. | **Fixed** — `CloudJob` matches the row, tolerates unknown states |
| 3 | **High** | `POST /api/sign` requires an `Idempotency-Key` header; the client never sent one, so the request was rejected before a job existed. | **Fixed** — caller-supplied key, so a retry collapses onto the original job |
| 4 | **High** | The client sent its bearer token twice, once as `x-api-key`. The service ignores that header and does **not** redact it (`app.ts` redacts `authorization` only), so the credential was written to the service's access log. | **Fixed** — one `Authorization` header; regression test asserts `x-api-key` is absent |
| 5 | **High** | `GET /api/jobs/{id}` and `GET /api/queue` had no response schema in `openapi.json` — the shapes the client depends on were documented in prose only, which is how #1 and #2 survived. | **Fixed** — `JobView` and `QueueCounts` schemas; the routes return parsed values |
| 6 | **High** | A response that failed validation was reported as `400 Invalid request` — the client was blamed for a server contract violation, and a 4xx is not retried by anything. | **Fixed** — response validation raises `500` and logs only the schema name |
| 7 | **Medium** | `POST /api/sign` and `GET /api/jobs/:id` set no timeout; `URLSession.shared`'s 60-second default applied to a call that may need longer, and a stalled connection had no resource bound. | **Fixed** — explicit request timeouts; uploads use a session with a 1-hour resource timeout and `waitsForConnectivity` |
| 8 | **Medium** | All non-2xx became an `NSError` carrying the raw body, so 401, 409 and 429 were indistinguishable and nothing could decide whether to retry. | **Fixed** — `CloudServiceError` classification, `requestId` preserved, retry eligibility derived from the kind |
| 9 | **Medium** | An upload was accepted whatever the service reported: no check that the stored byte count matched the archive. A truncated transfer would have been queued for signing. | **Fixed** — size and echoed kind are compared; mismatch throws |
| 10 | **Medium** | Job status polling had no retry at all, so one dropped connection ended the poll. | **Fixed** — bounded exponential backoff with ±25% jitter, **read-only** (the submission path never retries) |
| 11 | **Medium** | `PremiumManager` sends `X-API-Key` on a request made through `URLSession.shared`, which follows redirects. A cross-host redirect would forward the header. | **Documented, not changed** — fixing it needs a session delegate that pins the host, which is a separate change with its own tests |
| 12 | **Low** | The iOS client's `apiKey` is labelled as an API key, but the service verifies an RS256 JWT from a configured identity provider and does not mint tokens. | **Documented** — the stored value is the bearer token; 401/403 now say what is required |

## What is deliberately not implemented

- **No iOS signing client beyond transport.** `signRemotely` throws `privateKeyUploadDisabled`:
  uploading a p12 and its password needs a consent surface that does not exist. So #1–#10 fix a
  path that is reachable through `upload` and `submitSignJob` but not exposed as a feature.
- **No download verification on the client.** `output_sha256` is now in the contract and decoded,
  but nothing downloads a result yet, so no verification is claimed.
- **No OTA capability handling on the client.** `installURL` is decoded and never logged or
  persisted; opening it is the user's action.
- **No new service, queue, or token-minting endpoint.** The service has no login; inventing one
  would be a new authentication system the brief forbids.
- **No change to `server/`.** Its 167 tests pass as they are; no defect was found in it that
  justified touching it in this pass.

## Running the suites (the commands these results came from)

```bash
# cloud-signing: 14 tests
cd cloud-signing && npm ci && npm run build && npm test
cd cloud-signing && npm run contracts && git diff --exit-code -- openapi.json

# premium API: 167 tests
python3 -m venv /tmp/svenv && /tmp/svenv/bin/pip install -r server/requirements.txt pytest cryptography
(cd server && /tmp/svenv/bin/python -m pytest tests/ -q)

# the iOS-side contract check (no Swift toolchain needed)
python3 tools/test_cloud_signing_contract.py
```

The iOS client itself is compiled by CI, not by these commands.
