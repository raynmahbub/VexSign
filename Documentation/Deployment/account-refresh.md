# Manual Apple Account refresh

A free Apple Account profile expires. Refreshing it is an explicit, attended
operation: Apple may ask for authentication again, key export needs its own
consent, and a package handed to iOS is not proof that iOS installed it.

The refresh engine runs these six stages in order and stops at the first one that
fails, is cancelled, or cannot establish its evidence:

| Stage | What must be true to continue |
| --- | --- |
| Preflight | The retained app is signed; the app identifier, device, team and current certificate are all known. |
| Provision | Apple returns a profile with a later expiry for the same app, device and team. An unchanged expiry ends the run before key export. |
| Import identity | The imported certificate is the exact identity the renewed profile returned, with the same profile UUID, bundle identifier and expiry. |
| Sign | The retained library copy is re-signed with that imported identity, producing a new artifact with the same bundle identifier. |
| Install | The signed artifact is handed to the delivery route the user chose. A submitted package is not an installed app. |
| Verify | A supported exact device reading matches the bundle identifier and version. With no such reading the result is recorded as **unconfirmed**, never as a successful install. |

Changing identity mid-run is a refusal, not a fallback: a certificate that differs
from the one the installed copy used may not install over it. A blocked stage never
advances to the next one, and a cancelled run never resumes on its own.

## What the user sees

1. Open **Settings → Signing & Installation → Review Account Refresh** (or use the
   review Shortcut), choose the already signed library app and target device, and
   confirm each approval, including a single regeneration of its existing profile
   and the one-time key export. The Shortcut only opens this screen.
2. Import the resulting certificate and profile only after reviewing the key-export
   consent. The review then offers sign, or sign and install, bound to that app and
   identity. No other certificate is substituted.
3. Check the Home Screen and the installed version. If the app was handed to iOS
   over a route that reports no result, use the unconfirmed outcome in the task
   history as the honest answer rather than retrying blindly.
4. Export diagnostics from Settings → Diagnostics if a stage failed. The bundle's
   `operations.json` contains the correlation ID, stage, status and a sanitized
   reason for each outcome; it never contains account names, credentials or
   private paths. Unconfirmed verification is recorded as unconfirmed, not success.

When Apple Account is the selected signing identity, a downloaded or imported IPA
is kept in the Library and the attended provisioning review opens with that app
preselected. The review still collects every approval; no stored `.p12` is used
as a fallback. A browser upload reports that review is required rather than
opening a sheet on a device that may be locked.

An Apple Account selects **who signs**, not **where the app is delivered**. The
install route stays as selected; signing in never switches an install into a guest
container. Shortcuts may open this review, but they do not grant account approvals
or perform any stage of the refresh. Best-effort scheduled work is opt-in: it posts
a reminder when a due refresh needs authentication or approval. It never attempts
an unattended sign-in, provisioning, key export, signing or installation.
