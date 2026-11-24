# Testing

Automated tests live under `Tests/`:

- `UnitTests/` - focused unit coverage.
- `IntegrationTests/` - cross-component and workflow integration coverage.
- `SecurityTests/` - security and policy regressions.
- `PerformanceTests/` - performance-sensitive checks.
- `Support/` - shared test fixtures and helpers.

Use `make verify` for portable checks and `make test` for Xcode simulator tests on macOS.
