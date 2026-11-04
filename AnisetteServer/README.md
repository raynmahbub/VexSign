# Anisette Server for VexSign

A minimal HTTP server that provides Apple Anisette headers for VexSign's Free Apple ID signing flow.

## Overview

VexSign's Free Apple ID signing requires an "Anisette Provider" - an HTTPS endpoint that returns 10 specific Apple headers as JSON. These headers are used to authenticate with Apple's services (GSX, Albert, etc.) when creating development certificates and provisioning profiles.

This server implements that endpoint.

## Required Headers

The endpoint must return these 10 headers as a JSON object:

| Header | Description |
|--------|-------------|
| `X-Apple-I-MD` | Machine ID hash |
| `X-Apple-I-MD-M` | Machine ID hash (variant) |
| `X-Apple-I-MD-RINFO` | Machine info timestamp |
| `X-Apple-I-MD-LU` | Last updated timestamp |
| `X-Apple-I-SRL-NO` | Serial number |
| `X-Apple-I-Client-Time` | ISO8601 client time |
| `X-Apple-I-Timezone` | IANA timezone identifier |
| `X-Apple-Locale` | Locale identifier |
| `X-Apple-Device-ID` | Device UUID |
| `X-Mme-Device-Id` | Device UUID (duplicate) |

## Quick Start

### Build and Run

```bash
cd AnisetteServer
swift build -c release
./.build/release/AnisetteServer
```

The server starts on port 8080 by default. Set the `PORT` environment variable to change it.

### Test the Endpoint

```bash
curl http://localhost:8080/anisette
```

Expected response:
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

## Configuration in VexSign

1. Open VexSign Settings → Signing Methods → Free Apple ID
2. Tap "Anisette Provider"
3. Enter your server URL (e.g., `https://your-server.com/anisette`)
4. Tap "Test" to verify the endpoint works
5. The server must use HTTPS for production use

## Production Deployment

### Requirements

- **HTTPS**: Apple requires HTTPS for production use. The server must have a valid TLS certificate.
- **Persistent Device ID**: The `X-Apple-Device-ID` should be consistent across restarts. Store it in a file.
- **Rate Limiting**: Add rate limiting to prevent abuse.
- **Authentication**: Consider adding API key authentication for the endpoint.

### Docker Deployment

```dockerfile
FROM swift:5.9-jammy

WORKDIR /app
COPY . .
RUN swift build -c release

EXPOSE 8080
CMD ["./.build/release/AnisetteServer"]
```

```bash
docker build -t anisette-server .
docker run -d -p 8080:8080 -e PORT=8080 anisette-server
```

### Systemd Service (Linux)

```ini
[Unit]
Description=Anisette Server for VexSign
After=network.target

[Service]
Type=simple
User=anisette
WorkingDirectory=/opt/anisette-server
ExecStart=/opt/anisette-server/.build/release/AnisetteServer
Restart=always
RestartSec=10
Environment=PORT=8080

[Install]
WantedBy=multi-user.target
```

## Security Considerations

⚠️ **Important**: This is a reference implementation. For production use:

1. **Use HTTPS only** - Never expose this over HTTP in production
2. **Implement authentication** - Add API key or token verification
3. **Rate limit** - Prevent abuse with per-IP rate limiting
3. **Log access** - Monitor for unusual activity
4. **Keep headers fresh** - The `X-Apple-I-Client-Time` must be current (within a few minutes)
5. **Persistent Device ID** - Use a stable UUID stored on disk, not generated on each startup

## How It Works

When VexSign performs Free Apple ID signing:
1. User enters Apple ID + password
2. VexSign calls the Anisette Provider endpoint
3. Provider returns the 10 headers
4. VexSign includes these headers in requests to Apple's authentication services
5. Apple validates the headers and proceeds with authentication

The headers simulate a real Apple device's characteristics, allowing the authentication to succeed.

## Troubleshooting

### "Invalid Anisette Headers" error
- Ensure all 10 headers are present
- Check that `X-Apple-I-Client-Time` is current (within 5 minutes)
- Verify `X-Apple-Device-ID` is a valid UUID format

### Connection refused
- Ensure the server is running
- Check firewall rules
- Verify the correct port is used

### HTTPS certificate errors
- Use a valid TLS certificate (Let's Encrypt or similar)
- Self-signed certificates will not work with VexSign's transport

## License

This is part of the VexSign project. See the main repository for license details.