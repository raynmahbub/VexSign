# Contributing to VexSign

## Development workflow

- Work on the active Arena/session branch named in the session context. Do not rename it or push to other branches.
- Keep changes scoped, reviewable, and aligned with the repository architecture.
- Run the relevant validation before handing off work.

## Local checks

```bash
make bootstrap
make verify
make docs-check
make test          # macOS/Xcode, simulator
make test-packages # NativeSigning / SideSign package tests
```

Use `make help` for the full target list.

## Code organization

- `VexSign/` contains the app source: app composition, features, shared code, services, storage, networking, security/system integrations, design system, and resources.
- `Packages/` contains independently maintained Swift packages and vendored dependencies.
- `Services/` contains separately deployable backend services.
- `Tests/` contains automated verification.
- `Tools/` contains scripts and validation utilities.

## Pull requests

- Describe the problem, the change, and verification performed.
- Include screenshots or recordings for user-visible UI changes.
- Do not commit secrets, credentials, or generated build artifacts unless the repository explicitly tracks them.
