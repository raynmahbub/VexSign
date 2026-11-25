# Installing VexSign without a computer

This guide describes **routes**, not a promise that every iPhone can install VexSign
without a computer. A route is only usable when its device requirements are met, and
only an observation on that device can confirm a result. VexSign does not bundle,
rebrand or redistribute any external installer.

## Choose a route by device compatibility

| Route | Device requirements | What VexSign provides | What must be observed on the device |
| --- | --- | --- | --- |
| **On-device bootstrap (external installer)** | A recent iOS release, the installer's own minimum version, Developer Mode, and the local-network/VPN setup the installer requires. Check the installer's published requirements before starting. | An unchanged release IPA, its source commit and its SHA-256. The [acceptance harness](../../Tools/Audit/device-acceptance.py) records the result against that exact file. | That the installer accepted the unmodified IPA, that VexSign launched, and that the installed bundle identifier and version match the artifact. These are pending until a human records them. |
| **Companion-paired installation** | A pairing file and a reachable companion on the same network. Available on older iOS releases where the bootstrap route is not supported. | A checked IPA handed to the paired transport, install queue state and installation evidence. | Device acceptance of the install and the installed version. A queued package is not an installed app. |
| **Over-the-air manifest** | A browser-visible HTTPS manifest host; the device must trust the host. | A generated manifest and signed package. | iOS does not report the final result to the app; confirm on the Home Screen. |
| **Guest container / host workflow** | A compatible host and guest runtime on this device. | An exported, checked IPA for the receiving app to import. | Guest compatibility, signing mode, JIT and execution. Import into a container is a separate action from installing a standalone app. |
| **TrollStore** | A device and iOS version supported by TrollStore, with TrollStore already installed. | Detection of this app's own install origin and an export for the external installer. | The external installer's own acceptance. A URL scheme probe cannot prove TrollStore is installed. |

The paired AFC / `installd` route is present in code but stays blocked until the
same-device inventory bridge and exact installed-version read-back are accepted.
A readable pairing file, an active VPN or a successful identity query does not
unlock it; the Feature Status screen reports it as needing device validation.

An **identity** is not a route. An Apple Account, an imported `.p12`/profile pair and a
managed certificate each describe who signs the code; none of them selects where the
package runs. In particular, signing in with an Apple Account does not select the guest
container route. The delivery method stays as the user last chose it until the user
explicitly changes it.

The two selections live in separate screens:

1. **Settings → Signing Methods** chooses the signing identity: imported `.p12` +
   profile or Apple Account. It does not write any installation preference.
2. **Settings → Installation** chooses the installation method: **Direct** (using the
   server or paired transport selected there) or **Embedded container**. The screen
   shows the current device readiness for the selected method. An unavailable
   container fails closed; it is never replaced with a direct install behind the
   user's back.

## Validate the bootstrap route before recommending it

The first proof is the installation of VexSign itself, using the unchanged build:

1. Build the release artifact (`make`) and record its commit and SHA-256. Do not alter,
   rebrand or repackage the IPA before handing it to the external installer.
2. On a device that meets the installer's published requirements, enable Developer Mode
   and complete the installer's on-device pairing/network setup yourself.
3. Initialise a pending acceptance report for **that** file:

   ```bash
   python3 Tools/Audit/device-acceptance.py init \
     --ipa packages/VexSign-<version>.ipa \
     --report device-acceptance.local.json \
     --include-computer-free-bootstrap
   ```

4. Run the external installer with its `--ipa` argument and the same file. Record what
   the device actually showed in the two bootstrap cases and in the ordinary launch case;
   never mark a check as passed from a log line or a queued state alone.
5. Check the report against the same IPA:

   ```bash
   python3 Tools/Audit/device-acceptance.py check \
     --ipa packages/VexSign-<version>.ipa \
     --report device-acceptance.local.json
   ```

A different IPA, a different commit or a partially filled report fails the check. A
passed report is a human attestation for that artifact and device, not independent
device verification, and it says nothing about other devices or iOS versions. The
report file is local-only and is not committed.

## After installation: one complete account cycle

The next proof is a single cycle with one identity: provision or renew a profile,
import the exact identity it produced, re-sign the retained library copy, install it
through a route that is actually available, and verify the result on the device. Each
stage is recorded with a correlation ID; a cancelled or blocked stage ends the cycle
rather than reporting a success for later stages. See
[account refresh](account-refresh.md) for the order and the evidence each stage needs.

## Diagnostics

If a route fails, export diagnostics from Settings → Diagnostics. The bundle contains
operation outcomes (stage, status and sanitized reason), not credentials, file contents,
account identifiers or private paths. Operation outcomes describe what VexSign did;
they never claim a device accepted an install unless device evidence was recorded.
