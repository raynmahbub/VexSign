# Free Apple ID Signing Setup Guide

This guide describes VexSign's **experimental Free Apple ID provisioning and certificate-import handoff**. Imported-certificate signing remains the supported path; native account signing has not completed production CMS or physical-device acceptance.

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

- **iOS Device**: iPhone/iPad running iOS 17.0 or later
- **VexSign App**: A [release](https://github.com/raynmahbub/VexSign/releases) build or your own build of the current branch
- **Apple ID**: A valid Apple ID (free tier works)
- **Anisette Provider**: An HTTPS endpoint returning Apple authentication headers (see below)
- **Paired Device**: Your iOS device paired with a Mac (for device UDID retrieval)
- **TrollStore** (optional): For permanent installation on iOS 14.0–16.6.1

> **Native account signing is not integrated or device-accepted yet.** The code
> can validate and export a receipt-bound profile and, after separate explicit
> consent, import its identity into the ordinary certificate store. However,
> profile creation is still gated on a production CMS verifier that shipping
> builds do not select. Treat the steps below as an experimental developer flow,
> not a working end-to-end path. [Free Apple ID handoff](NATIVE_SIGNING_HANDOFF.md)
> records the implemented seam and remaining acceptance gates. Signing with an
> imported `.p12` + `.mobileprovision` is the supported path.

---

## Anisette Provider Setup

### What is an Anisette Provider?

Free Apple ID signing requires an **Anisette Provider** - an HTTPS server that returns 11 specific Apple header fields used for authenticating with Apple's services (GSX, Albert, etc.). VexSign cannot include a default provider due to Apple's terms of service.

### Required Headers

Your endpoint must return these 11 fields as one flat JSON object:

| Header | Description |
|--------|-------------|
| `X-Apple-I-MD` | Machine ID hash |
| `X-Apple-I-MD-M` | Machine ID hash (variant) |
| `X-Apple-I-MD-RINFO` | Routing info |
| `X-Apple-I-MD-LU` | Last updated timestamp |
| `X-Apple-I-SRL-NO` | Serial number |
| `X-MMe-Client-Info` | Client information |
| `User-Agent` | Client user agent |
| `X-Apple-I-Client-Time` | ISO8601 client time |
| `X-Apple-I-Timezone` | IANA timezone identifier |
| `X-Apple-Locale` | Locale identifier |
| `X-Mme-Device-Id` | Device UUID |

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

#### Step 5: Experimental certificate import
- Review the separate private-key export consent.
- Tap **Import Certificate & Profile** to validate the fresh profile and import
  the pair into **Certificates**. This does not sign or install the selected app.
- If import succeeds, select that certificate explicitly in the existing signing
  flow. Production CMS gating and device acceptance still apply.

---

## Installing via TrollStore

TrollStore is a separate app that perma-signs IPAs on the iOS versions the
CoreTrust bug covers (roughly 14.0–16.6.1 and 17.0). VexSign never installs it.

1. Sign an app first — TrollStore installs a **signed** IPA.
2. Go to **Settings** → **Signing Methods** → **TrollStore**.
3. Tap **Send a Signed IPA to TrollStore**, pick the signed IPA and tap
   **Open <file> in TrollStore**.

How the hand-off works: TrollStore registers **no URL scheme of its own**. Since
1.3 it replaces Apple's `apple-magnifier` scheme, so VexSign opens
`apple-magnifier://install?url=<IPA URL>` (see TrollStore's
`TSSceneDelegate.m`). TrollStore then downloads/consumes that IPA and installs
it itself.

Limits worth knowing:

- **VexSign cannot confirm the result.** iOS reports only that the URL opened;
  on a device without TrollStore — or with TrollStore's *URL Scheme* setting
  off — the same URL opens the Magnifier app instead.
- **"Detected" means this copy of VexSign was installed by TrollStore**, which
  is the only positive signal an app can read (TrollStore's `_TrollStore`
  marker next to the bundle). A normal install cannot see it, so a *not
  detected* verdict does not prove TrollStore is missing. Use **Share Signed
  IPA Instead** and open the file from TrollStore in that case.
- **No refresh command.** TrollStore does not accept a URL command to refresh
  app registrations; use **Refresh All App Registrations** inside TrollStore.

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

Free Apple ID profiles normally expire after **7 days**. Unattended native
renewal is **not implemented**. Background discovery can identify locally
recorded profiles that are nearing expiry, but it does not mint mutation consent,
create profiles, export keys, sign apps or queue installations.

To renew during an accepted developer test, repeat the explicit provisioning and
certificate-import flow, then sign again through the ordinary certificate flow.
Do not interpret an expiry notification as a completed renewal.

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
| **7 Days** | Profiles normally expire after 7 days; unattended native renewal is not implemented |
| **No Push/iCloud** | Free certs don't support push notifications, iCloud, App Groups |
| **Development Only** | Cannot create distribution/App Store profiles |
| **iOS 17+** | Requires iOS 17.0 or later |
| **No Wildcards** | Each bundle ID must be registered individually |

---

## Advanced: Custom Anisette Provider

Free Apple ID signing needs a **real** Anisette provider — a service that derives
valid machine headers from a provisioned identity. The bundled
[`AnisetteServer`](../AnisetteServer/README.md) is only a **protocol mock**: it
returns fabricated header values so the wire format can be tested locally, and
Apple will reject them. It cannot authenticate or provision.

To use your own provider, deploy a genuine Anisette implementation (for example an
anisette-v3 compatible service) behind HTTPS and enter its endpoint in
**Settings → Signing Methods → Free Apple ID → Anisette Provider**. See
[`AnisetteServer/README.md`](../AnisetteServer/README.md) for the expected response
shape and the mock's limits.

---

See [CHANGELOG.md](../CHANGELOG.md) for release notes.
## Bundled community server catalogue

The provider editor now includes all 22 entries from
[SideStore's public server catalogue](https://github.com/SideStore/anisette-servers/blob/3cd273b679bbb7777e9d585e49fdfa239cf21486/servers.json),
pinned to revision `3cd273b679bbb7777e9d585e49fdfa239cf21486` and reviewed on
2026-11-06. The snapshot is `VexSign/Resources/AnisetteServers.json`; its upstream
AGPL-3.0 license is retained in `VexSign/Resources/AnisetteServers-LICENSE.txt`.
These are community-operated endpoints, not VexSign-operated or endorsed services.
No availability, privacy-policy or operator-identity verification is claimed.

Catalogue entries are **candidates**, not automatically compatible providers.
VexSign's native account backend currently accepts the bounded HTTPS JSON-header
protocol, not SideStore's full v3/WebSocket provisioning protocol. Choosing a
preset opens the editor; **Save & Verify** explicitly contacts only that endpoint
and checks its headers before replacing the configured provider. Failed checks
leave the previous provider unchanged. The HTTP-only catalogue entry remains
visible but cannot be selected. There is no background probe of every server or
automatic failover to another operator. A successful header check is not an Apple
login, account acceptance test, signing success or promise of future health.

Opening Signing Methods initializes the configured native backend without
logging in. Saving/removing a provider serializes backend replacement and clears
old UI state; operations are blocked if the displayed descriptor no longer
matches the active backend. Guest builds still cannot use the primary-app
credential store: embedded SideStore retains its own account setup. This change
does not complete or promote the VexSign-primary all-in-one architecture.
