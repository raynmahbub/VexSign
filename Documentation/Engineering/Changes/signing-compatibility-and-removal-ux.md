# Signing compatibility, install confirmation and removal UX

This note describes the behaviour after the "signing compatibility, installation reliability and
consistent swipe-to-remove" work. Where an older note in this folder disagrees, this one is current;
the older passages carry a "Superseded" marker pointing here.

**Verification status.** The source-level gates (`quick_check`, the `Tools/` gates, the Python
policy tests, the string catalogue) pass. Nothing described here has been compiled, run under
XCTest, or exercised on a device at the time of writing.

## Sign Anyway

Preflight issues fall into two groups.

| Group | Codes | What the user sees |
| --- | --- | --- |
| Mandatory | `certificateMissing`, `certificateExpired`, `certificateRevoked`, `profileExpired`, `appIdentifierMismatch`, `extensionNotCovered`, `entitlementNotGranted` | "Cannot be signed", with the reason. No override. |
| Overridable | `teamMismatch`, `certificateNotInProfile`, `deviceNotProvisioned`, `signerMismatch`, `storageInsufficient`, `general` | The issue, and **Sign Anyway**. |

A mandatory failure produces an app iOS will not install, so signing it only creates a Library entry
that fails later with a less useful message. `FR.signPackageFile` returns a refusal before any task
record exists. The override flag callers pass is `checks.canSignAnyway`.

App identifiers are compared by one matcher, `ProfileApplicationIdentifierMatcher`. A wildcard needs
its whole stem plus at least one more character; a bare `*` without a prefix matches nothing.

## Extension profiles

A certificate has one main profile. An app extension with an explicit App ID of its own is not
covered by an explicit main profile. Additional profiles can be added per certificate under
Settings → Certificates → the certificate → **Extension Profiles**; they are stored in
`ExtensionProfiles/` inside the certificate's folder.

Which profile a nested bundle is signed with (`AdditionalProfiles.assignments`):

1. An additional profile whose App ID names the bundle exactly.
2. Otherwise the main profile, if it covers the bundle.
3. Otherwise the first additional wildcard profile that covers it.

The engine (`Packages/Vendor/Zsign`, `zsignWithNestedProvisions`) signs that bundle with the entitlements of
its own profile and writes the profile into the bundle before the bundle is sealed. With no
additional profiles the engine behaves exactly as before.

A profile is refused at import when it is unreadable, expired, from another team, a duplicate, or
names certificates that do not include this one. The last check is repeated at signing time, per
profile, so a mismatch names the extension instead of ending in a bare "Signing failed".

Preflight, the certificate picker, compatibility-mode removal and the post-sign verifier treat an
extension as covered when one of these profiles covers it.

### How other signers handle this

Read from source at the commits named; none of these was run.

| Project | Commit | What it does with nested bundles |
| --- | --- | --- |
| zsign (`zhlynn/zsign`) | `9299685` | Accepts several profiles. For each bundle it picks the profile whose App ID ends with the bundle identifier, writes it into that bundle before `CodeResources` is generated, and signs with that profile's entitlements. |
| AltSign (`rileytestut/AltSign`) | `1c44cfd` | One profile per bundle, matched by exact bundle identifier. Writes `embedded.mobileprovision` into the app and into each `PlugIns` extension and signs each with its own profile's entitlements. A bundle without a profile is an error (`ALTErrorMissingProvisioningProfile`). |
| AltSign, SideStore fork (`SideStore/AltSign`) | `35b68f1` | Same rule, ported to Swift (`ALTSigner.swift`). |
| Feather (`khcrysalis/Feather`) | `31ab6de` | One profile for the whole app through its vendored zsign, which has no multi-profile path. Extensions are handled by removal options. |
| KSign (`Nyasami/Ksign`) | `c14dedc` | Same as Feather: one profile, vendored zsign without a multi-profile path. |

What VexSign takes from them:

- From zsign and AltSign: the profile is written into the nested bundle *before* it is sealed, and
  the bundle is signed with the entitlements of its own profile, not the main app's.
- From AltSign: an exact bundle-identifier match decides which profile belongs to which bundle.
  zsign's suffix match would let a profile for `…app.widget` also claim `…other.app.widget`.
- Unlike AltSign, a bundle without a profile of its own is not an error by itself: a wildcard main
  profile legitimately covers it. Whether anything is left uncovered is decided by preflight, which
  refuses before signing starts.
- Feather and KSign confirm that the single-profile behaviour VexSign had is the norm for
  zsign-based signers, and that extension removal is their only answer to an explicit main profile.
  VexSign keeps that option (compatibility mode) alongside the new one.

## Install confirmation

Over-the-air installs keep watching the device after the install is handed to iOS, and end as
confirmed only when the expected version is observed. A different version, an absent app or a
timeout is never reported as success. Receipts state transport, hand-off, confirmation and
verification source separately. Retrying is refused when the signed copy is gone or the same copy is
already installing.

## Removing things

Destructive swipes never fire on a full swipe. What happens after the tap depends on what is removed:

| Item | Confirmation | Undo |
| --- | --- | --- |
| Task Center history row | no | yes, 6 s |
| Plain file (Downloads, Files tab, IPA Explorer recents) | no | yes, 6 s |
| Source | no | yes, 6 s (not for premium sources) |
| Tweak | as before (bulk asks) | yes, 6 s |
| Certificate | always | yes, 6 s |
| Library app or certificate folder via the Files tab | always | no |
| Extension profile | always | no |

Undo for files, tweaks and certificates works by moving the files aside (`RecoverableFileRemoval`)
rather than erasing them. The countdown belongs to the removal, not to the screen showing the
banner: when it ends the held files are erased even if the user has navigated away, and anything
left from an earlier session is erased at launch. A certificate is really deleted during the offer
— row, Keychain password, revocation snapshot — so nothing can sign with it; its password is held in
memory only, and undoing restores the row, its position, and the link from apps signed with it.
