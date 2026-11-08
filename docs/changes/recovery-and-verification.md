# Recovery, resource ownership and installation verification

## Verification stall

Native installation-proxy completion arrives only after its device command
returns without error. It is now accepted directly as device evidence. A second,
sandbox-filtered LaunchServices lookup is not required and cannot hold this
success at Verifying for ten minutes. Native command errors still fail.

For OTA, a progress counter, payload transfer and signing success remain
insufficient evidence. After verification begins, an unavailable/unknown lookup
has a 30-second bound (or a shorter configured confirmation limit). Failure to
observe installation releases the modal automatically, retains the task report,
and leaves a Needs review queue pill. It does **not** assert installation failed
or succeeded, advance another queued install, or silently retry through pairing.
Positive evidence received within the window still completes normally. A known
negative reading retains the separate full confirmation limit for slow devices.
The physical device's API visibility still needs user testing.

## Restart recovery

The protected journal now persists active attempts as well as finished history.
On a cold launch, unfinished attempts become terminal Interrupted records with
the last stage retained. Completed records and stored signed artifacts are not
restarted or deleted by recovery. No retry handler survives relaunch. The user
must check Signed Apps/device state and explicitly choose another operation.
Clearing history keeps the active journal intact.

## Per-copy ownership

One process-wide, NSLock-protected registry issues exclusive UUID/type leases for
signing/re-signing, installation packaging, installation, export, cloning and
managed deletion. Different stored copies can proceed independently. Workers
retain leases until they actually exit, even after their owner cancels. Deletion
admission is checked for the entire selected batch before filesystem mutations.

The singleton/concurrency policy additions are deliberate: a single registry is
necessary for callers on both actor-isolated and synchronous storage paths;
mutable ownership is protected by NSLock, and lease finalizers call only its
locked release method. SigningService accepts registry injection for tests.
This is not a cross-process lock or a restriction on user-directed external
filesystem edits. Existing native signing serialization remains in place.

## Disk capacity

Signing and installation/export packaging estimate working copies from logical
bundle sizes with a safety margin. Cloning preflights its own copy. Archive safety
inspection checks validated expanded bytes before extraction; original ZIP path,
size, checksum and symlink checks remain enabled. Estimates saturate on overflow.
Unknown capacity is best-effort, not a reservation or a security bypass: actual
write failures still propagate and existing owned-workspace cleanup runs.

## Stop semantics

The active install card says Stop Monitoring, with a hint and report explaining
that an installation already accepted by iOS may continue. It stops VexSign work
where cancellable and moves the queue on; it never claims to cancel installd.
Signing cancellation retains its existing acknowledgement/cleanup behavior.

## Migration and artifact validation

Native tests inject permission/locked-storage-like and out-of-space failures
before credential moves, test a blocked destination, resume partial migration,
and retain collision coverage. Partial certificate migrations resolve each UUID
from the private location if already moved. These are fault-injection tests, not
physical locked-device results.

Every successful IPA artifact includes BUILD.json and SHA256SUMS. Provenance
creation opens the exact IPA, verifies its embedded source SHA against checkout,
and hashes its actual bytes. Locally extracted artifacts can be checked with
`shasum -a 256 -c SHA256SUMS` on macOS or `sha256sum -c SHA256SUMS` on Linux.
These checks identify corruption/build mismatch; they are not a signing identity
or a substitute for normal signature verification.

## Validation and pending device checks

Nine added native tests cover restart isolation, lease ownership/lifetime, disk
estimates, bounded evidence, and migration failures. Four new portable provenance
tests plus four additional wiring checks run in make verify and CI. Swift grammar
and portable checks pass; latest Apple compilation/XCTest and device acceptance
remain pending. The previous CI extra-progress-argument compile failure is fixed
by adding the missing defaulted begin(progress:) parameter.

Test the exact latest IPA: native success/rejection, OTA with visible and filtered
status, reinstall/update, large IPA/low disk, stop during native/OTA work, restart
during signing/installing, competing actions on one copy, unrelated parallel
copies, and legacy credential migration after unlock. Keep PR #133 unmerged until
latest Apple checks pass; collect device reports without passwords/keys/records.
