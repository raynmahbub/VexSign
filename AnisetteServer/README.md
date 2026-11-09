# Anisette Server (protocol mock)

A minimal macOS HTTP server that returns the **shape** of an Anisette provider
response for VexSign's Free Apple ID signing flow.

> ⚠️ **This is a mock, not a working Anisette provider.** The ten header values
> are **fabricated** (a random serial number, a UUID-derived hash, a fixed routing
> number). Apple's services will reject them, so this server **cannot**
> authenticate an Apple ID or provision certificates. It exists only to exercise
> the client/server wire format locally and to document the expected response.
>
> For actual signing, deploy a real Anisette implementation (for example an
> anisette-v3 compatible service) and configure its HTTPS endpoint in VexSign.

## Platform

macOS only. The server uses Apple's **Network** framework, which is not available
on Linux; the package therefore declares no Linux platform. Build and run with
Swift 5.9+ on macOS:

```bash
cd AnisetteServer
swift run            # or: swift build -c release && ./.build/release/AnisetteServer
```

The server listens on port `8080` by default; set `PORT` to change it.

```bash
curl http://localhost:8080/anisette
```

Example response (values are illustrative and fabricated):

```json
{
  "headers": {
    "X-Apple-I-MD": "abc123...",
    "X-Apple-I-MD-M": "def456...",
    "X-Apple-I-MD-RINFO": "1710000000",
    "X-Apple-I-MD-LU": "1710000000",
    "X-Apple-I-SRL-NO": "123456",
    "X-Apple-I-Client-Time": "2024-01-15T10:30:00.000Z",
    "X-Apple-I-Timezone": "America/New_York",
    "X-Apple-Locale": "en_US",
    "X-Apple-Device-ID": "ABCDEF12-3456-7890-ABCD-EF1234567890",
    "X-Mme-Device-Id": "ABCDEF12-3456-7890-ABCD-EF1234567890"
  }
}
```

## Required header fields

A real provider must return these ten fields as a JSON object under `headers`:

| Header | Description |
|--------|-------------|
| `X-Apple-I-MD` | Machine ID hash |
| `X-Apple-I-MD-M` | Machine ID hash (variant) |
| `X-Apple-I-MD-RINFO` | Routing info |
| `X-Apple-I-MD-LU` | Last-updated timestamp |
| `X-Apple-I-SRL-NO` | Serial number |
| `X-Apple-I-Client-Time` | ISO8601 client time |
| `X-Apple-I-Timezone` | IANA timezone identifier |
| `X-Apple-Locale` | Locale identifier |
| `X-Apple-Device-ID` | Device UUID |
| `X-Mme-Device-Id` | Device UUID (duplicate) |

VexSign's HTTPS transport requires an `https://` endpoint with no embedded
credentials, query string or fragment, and validates that exactly these fields
are present. See `NativeSigning/Authentication/HTTPSAnisetteProvider.swift`.

## Configuring a real provider in VexSign

1. Open **Settings → Signing Methods → Free Apple ID**.
2. Tap **Anisette Provider**.
3. Enter your provider's HTTPS URL (e.g. `https://your-server.com/anisette`).
4. Tap **Test** to verify the endpoint.

This mock serves plain HTTP on localhost and is intended for local protocol
testing only; it is not a production deployment and should not be exposed.

## License

Part of the VexSign project. See the repository root for license details.
