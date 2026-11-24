# Updating VexSign itself

> **Honest summary.** VexSign cannot update itself from a release page without a
> signing identity that the device already trusts. What it can do is sign a
> release it downloaded and hand that copy to iOS, which replaces the bundle in
> place. Everything below is about who may replace what, and about the two remote
> update routes that stay refused.

## 1. The three routes, and which one applies

| Situation | Route | Where |
| --- | --- | --- |
| The device trusts a certificate you installed VexSign with | Sign the release in Library, then install it in place | The update sheet, [in-place update](#2-in-place-update-what-it-checks) |
| VexSign was installed by TrollStore | Export this build's IPA and open it in TrollStore | Settings → **This build** → *Save this build as an IPA* |
| VexSign was installed some other way (AltStore, SideStore, Xcode) | Use that installer | Not VexSign's to drive |

The update sheet never starts a transfer it knows iOS would refuse: it asks one
question first and shows the blocker as the next step.

## 2. In-place update: what it checks

`SelfReplacementPolicy.verdict(candidate:runningIdentifier:runningVersion:)` is
the whole rule, and it is testable without a device:

| Blocker | Meaning | What the sheet says |
| --- | --- | --- |
| `missing` | No copy of VexSign is in Library | Download the release, import it, sign it, come back |
| `notSigned` | The copy is an imported, unsigned build | Sign it with the certificate you installed VexSign with |
| `notNewer` | Same version, older, or unreadable version | iOS only replaces a bundle with a higher version |
| `differentApp` | The copy carries another bundle identifier | An in-place update has to carry VexSign's identifier |

A `nil` verdict means iOS may be handed the copy. The install is then served from
VexSign's own local HTTPS server through an `.itms-services` URL; iOS performs the
replacement and reports the result. Nothing is claimed until it does.

Two routes are refused **by design** and are not on any roadmap:

- Uploading the signing key to a third-party updater. The key never leaves the
  device.
- Driving an unverified mutation over a paired-device transport. A pairing record
  is not proof that the other end is the device it claims to be.

Both refusals are user-visible copy, not just `Reason` codes: see
`SelfReplacementBlocker.message`.

## 3. TrollStore: replace without a certificate

A TrollStore install is not signed by Apple and does not need to be. TrollStore
replaces a bundle in place when it is asked to install an IPA whose bundle
identifier matches, which makes the "sign the release first" step unnecessary on
those devices — and, before this existed, impossible to skip: the only
self-replacement route demanded a signed copy, so a TrollStore user had to sign a
release of VexSign in order to update VexSign.

`SelfPackageExporter` packages the *running* bundle with the same `AppArchiver`
the installer and Web Manager use, into `Documents/Exports/VexSign-<version>-<build>.ipa`,
and Settings → **This build** offers to share it. What that is and is not:

- It is the running build, byte-for-byte, wrapped in `Payload/`.
- It is not signed by VexSign, and packaging it proves nothing about the result:
  installing it still needs a device that trusts the copy (TrollStore, or a
  signing identity on the receiving device).
- A guest build (`VexSignEmbeddedGuest`) is not exported: it runs from the host's
  bundle, so the export would be the host under VexSign's name.

## 4. What update checks can and cannot see

- The update check compares versions with the same ordering the policy uses,
  including prereleases (`VersionOrder.precedence`).
- A build installed by a store you do not control may be updated by that store at
  any time; VexSign cannot see or prevent that, and says so rather than implying
  it manages the install.
- Renewal of *signing* certificates is a separate problem with its own page:
  [on-device-signing.md](on-device-signing.md) and
  [apple-account-limitations.md](apple-account-limitations.md).

## Related

- [bootstrap.md](bootstrap.md) — why the first installation is a different problem.
- [embedded-host.md](embedded-host.md) — the combined build, which has its own
  update path through its host.
- [ota.md](ota.md) — the `.itms-services` mechanics this page relies on.
