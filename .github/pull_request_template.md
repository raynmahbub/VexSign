<!--
Thanks for the contribution. Keep the PR focused and fill in the sections
that apply; delete the rest. See CONTRIBUTING.md for setup, validation and
licensing rules, and SECURITY.md to report vulnerabilities privately.
-->

## Summary

<!-- What changed and why. Link the issue or discussion when there is one. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / internal cleanup
- [ ] Documentation
- [ ] CI / tooling
- [ ] Dependency or vendored update

## Validation

- [ ] `make verify` passes locally
- [ ] `make test` (or targeted tests) covers the behavior change
- [ ] New user-facing text added to `Localizable.xcstrings` (`python3 tools/sync-strings.py --write`) when applicable
- [ ] Component checks run when relevant: Platform check, Server tests, Ecosystem contracts
- [ ] `git diff --check` is clean

## Notes for reviewers

<!-- Design decisions, screenshots for UI changes, device tests still needed,
risk areas, follow-ups. Note anything you could not test (for example code
that needs Xcode or a physical device). -->

## Checklist

- [ ] Change is focused; unrelated refactors are split out
- [ ] Regression tests added or updated for behavior changes
- [ ] Documentation updated for user- or contributor-visible changes
- [ ] No private keys, certificates, provisioning profiles, tokens, UDIDs, or local environment files are included
- [ ] Third-party code keeps its license and attribution notices
