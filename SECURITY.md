# Security policy

## Supported versions

Security fixes land on `main` and in the latest published release. Older
releases are not maintained. Check the [releases page](https://github.com/raynmahbub/VexSign/releases)
for the current version.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Include the affected version or commit, the impact, and the smallest
   reproduction you can share.

Please avoid attaching real certificates, provisioning profiles, Apple ID
credentials or pairing files. Redact bundle identifiers and tokens where
possible. We will acknowledge the report, investigate, and coordinate a fix and
disclosure with you.

See the [VexSign threat model](Documentation/Security/THREAT_MODEL.md) for an overview of assets, trust boundaries, data flows, and remaining limitations. It is not a security audit or guarantee.

## Scope

In scope:

- signing, archive-extraction and install pipelines;
- certificate, profile and secret storage;
- the local HTTPS install server and Web Manager authentication;
- repository/source parsing and remote content handling;
- privilege boundaries between the app, extensions and companion targets.

Out of scope:

- issues that require a jailbroken device or an already-compromised OS;
- Apple platform vulnerabilities (report those to Apple);
- social engineering or physical access to an unlocked device;
- third-party repositories' content, unless VexSign handles it unsafely.

## Handling secrets

VexSign is designed so signing identities stay on device. When reporting,
never include a `.p12`, `.mobileprovision`, private key, pairing file, session
cookie or full request containing an authorization header. A redacted excerpt
is enough to explain most issues.
