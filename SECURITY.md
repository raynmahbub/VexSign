# Security Policy

## Reporting a vulnerability

Do not open a public issue for security vulnerabilities. Report security concerns privately to the maintainers through the repository's private security reporting channel when available, or contact the project owner directly.

Include:

- A clear description of the issue and impact.
- Reproduction steps or proof of concept.
- Affected versions, commit, or configuration.
- Any suggested mitigation.

## Security practices

- Secrets, credentials, private keys, and tokens must not be committed.
- Security-sensitive changes should include validation or tests where practical.
- Logging must avoid exposing secrets, personal data, or raw sensitive payloads.
- Dependency and workflow changes should be reviewed for supply-chain risk.
