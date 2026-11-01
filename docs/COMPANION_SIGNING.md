# SideStore + LiveContainer companion workflow

Open **Settings → Device Tools → SideStore & LiveContainer**, or search Settings
for “Apple account”. This is an external-app workflow, not native Apple-account
signing or an embedded guest runtime.

1. Install SideStore using its official instructions. Complete Apple-account login,
   2FA, pairing/VPN setup and supported renewal automation **in SideStore**.
2. Enter a trusted, reachable HTTPS IPA URL for LiveContainer and send it to
   SideStore. Review and finish the operation there. Only SideStore-managed apps
   can be renewed by SideStore; VexSign does not silently transfer app ownership.
3. Open a Library app’s details (or long-press its row) → **SideStore & LiveContainer** → **Prepare library IPA for sharing**,
   then use **Share IPA to companion app**. App-specific biometric locks are checked
   before opening this action. The stored bundle is exported as-is, without re-signing
   or uploading. Alternatively, select a guest IPA through the file picker. If the system
   does not offer it, save to Files and import from LiveContainer instead.
4. Follow LiveContainer's instructions for its signing mode and JIT requirements.

## Boundaries and privacy

- VexSign receives no Apple passwords, 2FA codes, account sessions, certificates or
  pairing secrets from these apps. No private export/callback endpoints are used.
- SideStore receives the full hosted IPA URL, including query tokens, only after
  explicit confirmation. Only HTTPS URLs without embedded credentials are accepted.
- Opening a URL handler is not proof of app identity, account status, successful
  installation, guest launch or renewal. No completion callback is claimed.
- Sharing stages a copy of the selected `.ipa` in the OS temporary directory.
  Replacing a staged IPA removes the previous copy; the OS may purge remaining
  temporary files. IPA contents are not validated by this handoff: the receiving
  app must perform its own validation. No source archive protections are disabled.
- VexSign's certificate-based automation remains independent. There is no silent
  cross-app scheduler, unified account store or shared guest library.
- The automation history store is intentionally a process-wide owner of one
  persisted history (manual and background writers); its singleton baseline entry
  documents that exception to avoid conflicting writers.

## Protocol references checked during implementation

- SideStore: `SideStore/DeepLinks/URLHandler.swift` on `develop` handles
  `sidestore://install?url=<encoded URL>`; `AltStore/Info.plist` declares `sidestore`.
- LiveContainer: `LiveContainer/Info.plist` on `main` declares `livecontainer`.
- Only protocol facts were used; no third-party implementation code was copied.
  Native auth/runtime integration remains outside the scope described in
  [REFERENCE_COMPARISON.md](REFERENCE_COMPARISON.md).

## Deferred device checks

Verify app detection, open failure reporting, URL encoding (especially query
strings), SideStore install handoff, file-provider security scope, large-IPA
sharing and the Files fallback. Confirm no account credentials appear in VexSign.
Do not mark refresh/install successful based only on returning to VexSign.

## Prepared-file summary

The sharing screen displays staged file size and can calculate a streaming SHA-256
fingerprint on demand, off the UI thread. Compare it with a value from a trusted
publisher if available. A fingerprint alone establishes neither authenticity nor
signing/guest compatibility. Fingerprints are cleared when the staged file changes.
The system share sheet may offer SideStore for installation or LiveContainer for
guest import; availability is controlled by iOS and the receiving app versions.

## Setup diagnostics

Open **Companion Setup Diagnostics** from the workflow hub, Setup Health or
Settings search. Local checks show URL-handler presence and VexSign's pairing-file
presence, with a refresh timestamp. Login/2FA, SideStore renewal, VPN connectivity,
and LiveContainer signing/JIT remain explicitly unverified. Detection never grants
an overall ready/success status or imports any companion secrets.

## Optional publisher-hash comparison

Enter a publisher SHA-256 for the staged IPA to require a match before using the
local share action. Malformed hashes, an uncomputed fingerprint or a mismatch
block that action while the expected hash is set. New staging resets both values.
The expected value must come from a trusted channel: comparing two untrusted
values is not publisher authentication. Hosted-URL handoffs are separate and are
not downloaded or hash-checked by this screen. The receiving app still validates
archives and signatures; no validation is bypassed.

## Cancelling file staging

Local file preparation copies in 1 MiB chunks. **Cancel file preparation** cancels
that copy task, checks cancellation between chunks, and removes partial output.
The original and any previously staged IPA are left unchanged. Security-scoped
file access stays active until cleanup finishes. Library archiving has no cancel
button: its compression backend does not yet support safe interruption.
