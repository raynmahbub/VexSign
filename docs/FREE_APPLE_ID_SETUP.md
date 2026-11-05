# Free Apple ID Signing Setup Guide

This guide walks you through setting up and using VexSign's **Free Apple ID signing** feature, which allows you to sign and install apps using a free Apple Developer account (3 apps, 7-day expiry).

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Anisette Provider Setup](#anisette-provider-setup)
3. [Free Apple ID Configuration](#free-apple-id-configuration)
4. [Provisioning an App](#provisioning-an-app)
5. [Installing via TrollStore](#installing-via-trollstore)
6. [Certificate Status Checking](#certificate-status-checking)
7. [Auto-Renewal](#auto-renewal)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **iOS Device**: iPhone/iPad running iOS 16.0 or later
- **VexSign App**: Built from the `arena/a28af82e-vexsign` branch
- **Apple ID**: A valid Apple ID (free tier works)
- **Anisette Provider**: An HTTPS endpoint returning Apple authentication headers (see below)
- **Paired Device**: Your iOS device paired with a Mac (for device UDID retrieval)
- **TrollStore** (optional): For permanent installation on iOS 14.0–16.6.1

---

## Anisette Provider Setup

### What is an Anisette Provider?

Free Apple ID signing requires an **Anisette Provider** - an HTTPS server that returns 10 specific Apple headers used for authenticating with Apple's services (GSX, Albert, etc.). VexSign cannot include a default provider due to Apple's terms of service.

### Required Headers

Your endpoint must return these 10 headers as JSON:

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

### Quick Deploy Options

#### Option 1: Use the Included Reference Server

VexSign includes a reference Anisette server implementation:

```bash
cd AnisetteServer
swift build -c release
./.build/release/AnisetteServer
```

The server runs on `http://localhost:8080/anisette` by default.
Set `PORT` environment variable to change the port.

**For production**: Deploy behind HTTPS with a valid TLS certificate (Let's Encrypt recommended).

#### Option 2: Community Providers

Several community-run Anisette providers exist. **Use at your own risk** - these are third-party services:

- Check VexSign Discord/Telegram for current recommendations
- Ensure the provider uses HTTPS
- Test the endpoint before configuring in VexSign

#### Option 3: Self-Hosted (Recommended)

Deploy your own instance for maximum privacy and reliability:

```dockerfile
# Dockerfile
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

**Production checklist**:
- [ ] Valid TLS certificate (Let's Encrypt)
- [ ] Rate limiting (e.g., 10 req/min per IP)
- [ ] Persistent Device ID (store UUID on disk)
- [ ] Monitoring/logging
- [ ] Firewall rules (restrict to your IPs if possible)

---

## Free Apple ID Configuration

### 1. Open Signing Methods

1. Open VexSign
2. Go to **Settings** → **Signing Methods**
3. Tap **Free Apple ID**

### 2. Configure Anisette Provider

1. Tap **Anisette Provider**
2. Enter your HTTPS endpoint URL (e.g., `https://your-server.com/anisette`)
3. Tap **Test** - VexSign will verify the endpoint returns valid headers
4. If test passes, tap **Save**

### 3. Sign In with Apple ID

1. Back in **Free Apple ID** section, tap **Sign In**
2. Enter your Apple ID and password
3. Complete 2FA (enter the 6-digit code from your trusted device)
4. Select your **Team** (Free tier will show as "Free")

### 4. Verify Setup

- You should see "Signed In" status with your team identifier
- The **3-app limit** indicator shows current usage (e.g., "0/3 apps used")
- **Anisette Provider** shows your configured endpoint

---

## Provisioning an App

### 1. Import or Download an App

- **Import**: Use the **Library** tab → **+** → Import .ipa
- **Download**: Use **App Store** tab to download from a source

### 2. Start Provisioning

1. Go to **Settings** → **Signing Methods** → **Free Apple ID**
2. Tap **Provision App** (or **Provision & Sign**)
3. The **5-step wizard** will guide you:

#### Step 1: Select App
- Choose an app from your library (imported or signed)
- The app's bundle identifier will be registered with Apple

#### Step 2: Select Device
- **Automatic**: If your device is paired via USB, it will appear in the list
- **Manual**: Enter the UDID manually (40 hex chars or 8-16-16-16-16 format)
- Find UDID in: Settings → General → About → UDID

#### Step 3: Review
- Verify app name, bundle ID, device name, and UDID
- Check the certificate that will be created

#### Step 4: Provisioning
- VexSign will:
  1. Register the device with Apple (if new)
  2. Register the App ID (bundle identifier)
  3. Create a development certificate
  4. Create a provisioning profile
- Progress is shown live with stage indicators

#### Step 5: Complete
- The app is now signed and ready for installation
- Tap **Install** to install via your preferred method
- Tap **Export .ipa** to save the signed IPA

---

## Installing via TrollStore

If you have **TrollStore** installed (iOS 14.0–16.6.1):

1. After provisioning, go to **Settings** → **Signing Methods** → **TrollStore**
2. Tap **Install App via TrollStore**
3. Select the signed app from the list
4. Tap **Install** - opens TrollStore via URL scheme
5. For bulk refresh: Tap **Refresh All (TrollStore)**

**Note**: TrollStore provides permanent installation (no 7-day expiry).

---

## Certificate Status Checking

### OCSP/CRL Status

1. Go to **Settings** → **Signing Methods** → **Diagnostics**
2. Tap **Certificate Revocation Status (OCSP/CRL)**
3. Select a signing identity from the list
4. Tap **Request Consent & Check** - explicit consent required
5. View results:
   - **Valid** (green): Certificate is good
   - **Revoked** (red): Certificate revoked by Apple
   - **Expired** (orange): Certificate expired
   - **Unknown** (gray): Could not determine status
   - **OCSP Unavailable** (orange): Apple's OCSP responder down
   - **CRL Unavailable** (orange): CRL distribution point unreachable

**Important**: Only **positive cached OCSP responses** count as valid. Missing/unknown status never counts as valid.

---

## Auto-Renewal

Free Apple ID profiles expire after **7 days**. VexSign can automatically renew them:

### Enable Background Automation

1. Go to **Settings** → **Automation**
2. Enable **Background Automation**
3. Choose policy:
   - **Notify Only**: Checks for updates, notifies you
   - **Sign & Queue**: Automatically signs and queues installs

### How Auto-Renewal Works

When enabled, the daily background task:
1. Checks for expiring free Apple ID profiles (within 2 days)
2. For each expiring profile:
   - Re-runs provisioning (device, App ID, certificate, profile)
   - Re-signs the app with the new profile
   - Queues the signed IPA for installation
3. Runs cleanup of old files
4. Sends a summary notification

### Manual Renewal

You can also trigger renewal manually:
1. Go to **Settings** → **Signing Methods** → **Free Apple ID**
2. Tap **Provision App** → Select the app → **Renew**

---

## Troubleshooting

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| **"Anisette Provider Error"** | Provider down or invalid response | Test provider in settings; check server logs |
| **"Authentication Failed"** | Wrong credentials or 2FA issue | Verify Apple ID/password; check 2FA; check Apple System Status |
| **"Unsupported Team"** | Enterprise/education team selected | Select a Free or Individual team |
| **"Provisioning Quota Exceeded"** | 3-app limit reached | Revoke unused apps in Apple Developer portal |
| **"Device Not Registered"** | UDID not in Apple portal | Re-run provisioning to register device |
| **"Certificate Limit Reached"** | Too many dev certificates | Revoke old certificates in Apple Developer portal |
| **"Profile Limit Reached"** | Too many provisioning profiles | Delete unused profiles in Apple Developer portal |
| **"Entitlements Not Supported"** | App uses push/iCloud/App Groups | Remove unsupported entitlements or use paid cert |
| **"Certificate Expired"** | Cert/profile expired | Re-run provisioning |
| **"TrollStore Installation Failed"** | TrollStore not installed or IPA invalid | Install TrollStore; ensure IPA is properly signed |
| **"Device Pairing Required"** | No pairing file | Import pairing file in Settings → Installation |
| **"HTTPS Installation Error"** | Server cert not trusted | Install Root CA profile, enable Full Trust |
| **"Network Error"** | Device/computer not on same network | Check Wi-Fi; try USB pairing |
| **"Keychain Error"** | Keychain access denied | Unlock device; restart app; check iOS Settings → Face ID & Passcode |

### Debugging Tips

1. **Check Activity Log**: Settings → Activity → View detailed logs
2. **Enable Debug Logging**: Settings → Advanced → Debug Logging
3. **Export Diagnostic Bundle**: Settings → Advanced → Export Diagnostics
4. **Test Anisette Endpoint**: `curl https://your-server.com/anisette`
5. **Verify Pairing File**: Settings → Installation → Pairing File status

### Getting Help

- **GitHub Issues**: Report bugs at https://github.com/raynmahbub/VexSign/issues
- **Discord**: Join the VexSign community for real-time help
- **Documentation**: Check `/docs` folder for more guides

---

## Security Notes

- **Never share** your Apple ID password or Anisette provider URL publicly
- **Use HTTPS only** for Anisette provider in production
- **Revoke access** when done: Settings → Signing Methods → Free Apple ID → Sign Out
- **Monitor usage**: Check the 3-app limit indicator regularly
- **Audit logs**: Review Activity Log for unexpected operations

---

## Limitations

| Limitation | Details |
|------------|---------|
| **3 Apps** | Free tier limited to 3 active apps |
| **7 Days** | Profiles expire after 7 days (auto-renewal available) |
| **No Push/iCloud** | Free certs don't support push notifications, iCloud, App Groups |
| **Development Only** | Cannot create distribution/App Store profiles |
| **iOS 16+** | Requires iOS 16.0 or later |
| **No Wildcards** | Each bundle ID must be registered individually |

---

## Advanced: Custom Anisette Provider

If you want to run your own Anisette provider with custom hardware IDs:

1. Modify `AnisetteServer/main.swift` to use your device's actual IDs
2. Generate persistent IDs on first run and store them
3. Deploy to a stable server with HTTPS

See `AnisetteServer/README.md` for deployment details.

---

*Last updated: 2024. See [CHANGELOG.md](../CHANGELOG.md) for version history.*