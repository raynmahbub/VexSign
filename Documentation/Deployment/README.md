# Deployment

Deployment artifacts and procedures are service-specific:

- iOS app builds are produced through Xcode/`make` targets.
- `Services/WebManager/` contains the self-hosted web manager service.
- `Services/Cloud/` contains cloud service code and configuration.

Use release and service documentation before changing deployment behavior.

Client installation is covered by [Installing VexSign without a computer](computer-free-installation.md):
route compatibility by device, the acceptance evidence required before recommending a
bootstrap route, and the order of a complete account refresh cycle.

[Per-feature acceptance](feature-acceptance.md) explains how to run native tests on a
simulator or connected device and bind one observation per registered feature to an
exact IPA. It is evidence collection, not a simulated device pass.

The complete GitHub Actions pipeline, including the release gate and the self-hosted
iPhone runner, is described in [Automated QA](../CI/automated-qa.md).
