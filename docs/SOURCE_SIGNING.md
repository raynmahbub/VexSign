# Signing a repository

VexSign's "Trusted" badge is a switch the user flips. It says what the user decided, not what the
publisher proved. A repository can now prove itself instead: sign the document once, and every
VexSign that loads it shows **Signed by …** — or refuses the refresh if the signature does not match.

This is optional and stays optional. Every unsigned repository keeps working exactly as it does
today, labelled with nothing.

## The format

Add one top-level member, `vexsign`, to `source.json`:

```json
{
  "name": "Example Repo",
  "identifier": "com.example.repo",
  "apps": [ … ],
  "vexsign": {
    "algorithm": "ed25519",
    "publicKey": "BASE64_32_BYTE_ED25519_PUBLIC_KEY",
    "signature": "BASE64_64_BYTE_SIGNATURE",
    "publisher": "Example"
  }
}
```

`publisher` is display only. `publicKey` and `signature` are standard base64 (with padding) of the
raw Ed25519 key and signature — 32 and 64 bytes.

## What is signed

The **canonical form of the document**: the `vexsign` member removed, everything else re-serialised
as JSON with sorted keys and no whitespace.

```
canonical = JSON(sorted_keys(document without "vexsign"), compact)
signature = Ed25519_sign(private_key, canonical)
```

VexSign implements exactly this in `SourceProvenanceVerifier.canonicalBytes` — Foundation's
`JSONSerialization` with `.sortedKeys`. A publisher must produce the same bytes; the sorted-keys rule
is what makes that possible without shipping a canonicalisation library.

## Producing a signature

Ed25519, no dependencies beyond OpenSSL 3:

```sh
# 1. One-time: an Ed25519 key pair (keep the private key offline).
openssl genpkey -algorithm ED25519 -out repo-signing.pem
openssl pkey -in repo-signing.pem -pubout -outform DER | tail -c 32 | base64

# 2. Every publish: canonicalise, sign, paste back.
python3 - <<'PY'
import json, sys
doc = json.load(open("source.json"))
doc.pop("vexsign", None)
open("source.canonical.json", "wb").write(
    json.dumps(doc, sort_keys=True, separators=(",", ":")).encode()
)
PY
openssl pkeyutl -sign -inkey repo-signing.pem -rawin \
    -in source.canonical.json -out source.sig

base64 -w0 < source.sig        # paste as "signature"
```

Python's `json.dumps(…, sort_keys=True, separators=(",", ":"))` matches Foundation's `.sortedKeys`
output for the value types a repository contains (strings, numbers, booleans, null, arrays,
objects). Numbers are the one sharp edge: keep them integers or plain decimals, and compare the
canonical bytes of a known document once before trusting the pipeline.

## What VexSign does with it

| Situation | Refresh | Badge |
|---|---|---|
| No `vexsign` member | Accepted, as today | none |
| Signature verifies | Accepted | **Signed by …** (teal) |
| Signature present, does not verify | **Refused** — the previous catalog stays | **Bad signature** (red) |
| Signature present, algorithm or key malformed | **Refused** | **Bad signature** (red) |

Refusing is deliberate. A source that used to be signed and now is not, or whose signature breaks,
is exactly the case this exists for; falling back to "trust it anyway" would make the signature
decorative.

## Limits, stated plainly

- A signature proves the document was produced by whoever holds the private key. It says nothing
  about whether the apps inside are safe, and it is not a review.
- The key is not pinned. Whoever controls the URL can swap the key and the signature together, so
  a signature defends against a modified document on the way to you, not against a hostile host.
  Pinning a key per repository is a possible next step; it is not in this version.
- Verification happens on every refresh, before the catalog is published. The badge is a cached
  label; only the check is authoritative.

## Also recorded here: ESign decryption keys

`AltSourceKit` ships `ASDecrypt` and `EsignSourceKey` for repositories that distribute
ESign-encrypted catalogs. Those keys are published by the repository, are not secrets VexSign holds,
and do not authenticate anything — decrypting a document says only that someone could encrypt it.
See `LICENSE` and [`SECURITY.md`](../SECURITY.md) for the distribution note.
