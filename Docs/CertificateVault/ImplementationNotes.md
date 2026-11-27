# Certificate vault implementation notes

## Scope and ownership

`CertificateVault` is the single actor that owns vault-managed signing identities,
provisioning profiles, and their association verdicts. It is reached from the
Certificate Vault sheet in the Certificates screen.

- Private-key material is added to the iOS Keychain with a content-derived label,
  `WhenUnlockedThisDeviceOnly` accessibility, and a sign/verify proof. No private
  key, PKCS#12 payload, or password is written to the JSON inventory, logs,
  UserDefaults, or a view model.
- The inventory under Application Support holds public metadata only. An
  unreadable inventory blocks writes until the user confirms recovery; the old
  file is moved aside instead of being silently replaced.
- PKCS#12 bytes are read through a security-scoped reader with a bounded size.
  There is no temporary private-key file, so cancellation and failure leave no
  key material on disk.
- Provisioning profiles are parsed by the existing authenticated CMS verifier.
  Parse success, expiry, and missing metadata are separate states.
- Compatibility outcomes are explicit: Compatible, Incompatible, Expired,
  Invalid, Unsupported, Incomplete, and Requires additional validation.
- Signing readiness consumes the existing read-only IPA inspection sidecar. It
  does not sign, install, or describe structural signature evidence as
  cryptographically verified.

The older file-backed certificate import remains the compatibility path for the
existing signing engine, which still consumes a staged `.p12` and its password.
This change does not implement signing.

## Reference projects

Public sources were reviewed for behaviour only: `claration/feather` (active
Feather repository), `murk-sus/SayoSign`, `Nyasami/Ksign`,
`Fanistic/RyukSign`, plus published descriptions of NexStore certificates and
Odysseus-style IPA signing. Their approaches to presenting certificate metadata,
profile fields, expiry, and revocation informed the outcome vocabulary. No
source code, signing engine, or architecture was copied; no new dependency was
added. GPL-licensed projects were not vendored, so no notice is required in this
repository.

## Verification performed here

- `make verify`: 80 repository gates passed.
- Swift files parsed with a tree-sitter Swift grammar; no syntax-error nodes.
- Deterministic XCTest coverage is in
  `VexSignTests/UnitTests/CertificateVault/CertificateVaultTests.swift`.

Not performed in this environment: Xcode build, XCTest execution, macOS CI,
physical-device signing, Keychain behaviour on a real device, and validation
against genuine Apple-issued certificates or provisioning profiles.
