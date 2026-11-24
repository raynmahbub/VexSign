# Security

See [SECURITY.md](../../SECURITY.md) for vulnerability reporting.

Security-sensitive code lives primarily in `VexSign/Security/`, `VexSign/Storage/Keychain/`, and related validation paths. Changes should preserve secret redaction, safe archive handling, and validated network/download behavior.
