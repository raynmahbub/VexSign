# Web Manager: routes, authentication and what each endpoint exposes

The Web Manager is the one part of VexSign that listens on a socket. It is
turned on from **Settings → Web Manager**, runs only while the app is
foregrounded, and serves three things on the same port:

- a small browser UI for uploading files and installing what is already on the
  device;
- a WebDAV share over the same library, for Finder and other clients;
- a JSON automation API (`/api/…`) for scripts and shortcuts.

This page is the contract: which routes exist, what authenticates them, and
what they will refuse to reveal. It is written from
`VexSign/App/iOS/Infrastructure/Networking/WebManager/`, which is the source of
truth when they disagree.

## Authentication

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
server from the user's browser. See the DNS-rebinding row in
[THREAT_MODEL](../Security/THREAT_MODEL.md).

## JSON API

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

## WebDAV

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

## Deliberate decisions

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

## Where the tests are — and what is missing

The pure pieces are covered, and each is worth reading before changing the
behaviour:

- `Tests/UnitTests/Application/WebManagerAccessTests.swift` — Host/Origin
  checks, token extraction and constant-time comparison, hidden-app visibility.
- `Tests/UnitTests/Application/WebManagerFilenamePolicyTests.swift` —
  traversal and header-injection rules for names.
- `Tests/UnitTests/Application/WebDAVTransferPolicyTests.swift` — containment.
- `VexSign/Tools/Validation/security-validation/test_webmanager_wiring.py` — a
  text gate that the middleware is installed in the expected order.

The server itself (`WebManagerServer.swift`, `+HTTP`, `+API`, `+WebDAV`) has no
request-level test: nothing boots it and asserts a response. That is the largest
untested surface in the app, and the table above is the checklist for fixing it.
