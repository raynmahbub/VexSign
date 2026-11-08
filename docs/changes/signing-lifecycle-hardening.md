# Signing lifecycle hardening

## Changes

- SigningView assigns an explicit request ID. Stop cancels that request only, rather than cancelling unrelated automation or batch runs.
- Delayed log presentation checks the run identity so an old presentation timer cannot open logs over a later retry.
- SigningService owns each source library UUID until its terminal event arrives, rejecting a second request for the same source even with a new request ID. Different library apps can still run independently.
- The adapter rejects duplicate admission before touching shared log/Live Activity state.
- Cancellation is checked before starting work, before copying, after the signing engine returns, and before registration. The synchronous native engine is not forcibly interrupted; Stop remains cooperative.
- Only the service emits terminal events. Work cannot accidentally emit a second success/failure/cancellation.
- Ownership is released before terminal callbacks, allowing immediate synchronous retry.
- Registration throws for a missing output bundle, resolves the committed Core Data object by permanent object ID, and preserves the saved bundle if object resolution fails. No cancellation check after commit misreports a committed app as cancelled.

## Regression tests added

SigningServiceTests:
- Same app with different request IDs is rejected until cleanup finishes.
- Terminal callback can immediately restart the same request.
- Cancelling one request leaves another app running.
- Work cannot emit an extra terminal event.

## Validation

Passed in the Linux workspace: project structure, whitespace/diff, concurrency-discipline, error-discipline, and package configuration checks. XCTest and native signing were not run: macOS/Xcode and device certificates are required.

## Required on-device acceptance

1. Missing/expired certificate and blocking preflight: no unexpected success or registration.
2. Normal sign and modify-only: expected output opens in Library with correct metadata.
3. Stop during copy, modification, engine signing, and verification: temporary work is cleaned and unrelated jobs continue. A Stop after database commit may correctly report success.
4. Immediately retry after cancellation or failure; repeat with automatic logs enabled.
5. Attempt two requests for the same source from UI/automation; only one is admitted.
6. Enable automatic installation and cleanup: output remains available to the installer; confirm installation, cancellation, and actionable failure separately from signing success.
7. Exercise export, batch processing, background/foreground transitions, low storage, and untrusted/revoked profiles.

This is targeted lifecycle hardening, not a guarantee that every certificate, third-party binary, network, or iOS installation method succeeds.
