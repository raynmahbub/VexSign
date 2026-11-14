# Curated data

## `revoked_certs.json`

The local revocation list the [Certificate Status Checker](../cert_inspector.py)
consults. It ships empty on purpose: this server never claims a certificate is
unrevoked, it only reports what *you* have recorded.

```json
[
  {
    "sha1": "00112233445566778899aabbccddeeff00112233",
    "sha256": "…optional…",
    "label": "Example Enterprise cert, revoked 2026-03-01",
    "reported": "2026-03-01",
    "note": "Confirmed revoked by the issuing team."
  }
]
```

Either fingerprint is enough for a match; both are accepted. Entries are read on
every request, so editing the file takes effect without a restart. Only add
entries you can stand behind — a false positive here tells someone their signing
setup is broken when it is not.
