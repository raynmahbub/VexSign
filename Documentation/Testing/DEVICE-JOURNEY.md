# Device journey: bootstrap to diagnostic export

This is an ordered implementation and acceptance checklist, not a claim that the
current build passed on a device. Never mark a step accepted from source checks
alone. Record app version/commit, iOS version, delivery route, expected outcome,
actual outcome and a sanitized diagnostic bundle for each device attempt.

## 1. First install without a computer

VexSign cannot bootstrap its own first install on a stock iPhone. An unsigned
release IPA is an input to a signer, not something Safari can install directly.

1. Obtain an eligible **already-signed VexSign build** from a distributor you trust,
   or use an installer that is already working on the device. Some installers need
   a computer for their own initial setup; do not describe those as computer-free
   bootstrap routes.
2. For OTA delivery, the distributor must host the signed IPA and valid manifest
   over reachable HTTPS. Its identity/profile must authorize the target device
   and distribution method. A paid certificate alone is not sufficient.
3. Follow iOS prompts appropriate to that distribution. Never install an unknown
   root certificate or device-management profile just to bypass an error.
4. Launch VexSign. Only now can its onboarding and account setup run.

If no authorized distribution route exists, stop and explain that limitation;
there is no universal no-computer installation bypass. Availability of any specific
public distributor is not verified here.

## 2. Choose identity setup

Onboarding exposes **Choose Signing Method**, using the same screen as Settings.

- **Paid Certificate:** import the PKCS#12 identity (.p12), its password and the
  compatible provisioning profile (.mobileprovision). Importing is not proof of
  validity: check expiration, revocation, device scope and entitlements at preflight.
- **Free Apple ID:** review backend readiness, configured Anisette provider,
  sign-in/2FA/team selection and provisioning status. Account setup contacts external
  services. In-process account signing remains gated; provisioning can export an
  identity/profile into the certificate store for the imported-certificate engine.
- **Current routing caveat:** the Free Apple ID selector currently selects the
  containerized delivery preference. That requires the embedded runtime and is
  not equivalent to installing a separately provisioned app onto SpringBoard.
  Separating identity selection from delivery routing needs its own tested change.

Acceptance still required: fresh setup with no certificates, wrong P12 password,
missing/incompatible profile, expired/revoked identity, cancelled sign-in, failed
2FA, unavailable provider and repeated attempts without leaked credentials.

## 3. Obtain an IPA

- Files: import a local IPA through onboarding or the existing Library/Files route.
- Repository: add a trusted source, browse its catalog and download an IPA.
- Treat every archive as untrusted. Reject unsafe extraction paths and malformed
  archives. Cancellation must clean staging without deleting committed imports.

Acceptance still required: valid and malformed archives, interrupted downloads,
offline operation, insufficient space, retry and duplicate import handling.

## 4. Sign

Use the imported identity/profile or the account-provisioned pair through the
existing signing engine. Preserve explicit preflight failures; do not fall back to
another identity or silently remove entitlements to make the UI appear successful.

Acceptance still required for **both identity origins**: native engine execution,
independent output signature/profile validation, nested frameworks/extensions,
entitlement mismatch, cancellation, storage failure and independent batch results.
A selected method or successful account sign-in is not signing evidence.

## 5. Install

Select the delivery route separately from the signing identity:

- Local HTTPS/OTA: requires reachable hosting and the documented local TLS setup.
- Paired device installation: requires supported pairing/device communication;
  initial pairing may require a computer.
- Embedded container: imports a guest; not a standalone iOS installation.

Record submission separately from confirmed installation. Confirm launch and
bundle/version on the target device before reporting end-to-end success.

## 6. Collect and export diagnostics

Open **Diagnostics Center → Export Diagnostic Bundle**. The bundle includes the
bounded signing console (`logs.txt`) and retained redacted disk history
(`activity.txt`), including direct subsystem events. Disk history is rotated, not
an unlimited audit trail. Review every export before sharing it.

Do not log passwords, private keys, P12 bytes, provisioning payloads, session
cookies, 2FA codes or pairing records. Redaction is defense in depth, not permission
to collect secrets. Log outcomes and stable non-secret reason codes instead.

Remaining instrumentation work: inventory import/download/account/certificate/
signing/install actions, assign correlation IDs, and test exactly one terminal
success/failure/cancellation outcome for each started operation. Current logs do
not prove every action is covered. Retention and clear-history behavior must stay
bounded and user-controlled.

## Implementation order and evidence

| Stage | Current change / next gate |
| --- | --- |
| Bootstrap guidance | Documented here; eligible signed distribution still requires verification |
| Setup navigation | Onboarding links to existing method configuration and diagnostics |
| Certificate import access | Manage Certificates remains reachable with zero identities |
| Diagnostic completeness | Export now includes retained disk events, waiting for queued writes |
| Identity vs. delivery separation | Pending targeted routing design and regression tests |
| Import/download/sign/install fixes | Pending workflow-by-workflow reproduction and implementation review |
| Native acceptance | Requires macOS/Xcode compilation, simulator tests and physical-device evidence |
