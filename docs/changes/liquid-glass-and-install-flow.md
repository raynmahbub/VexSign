# Liquid Glass branding and install completion

- Liquid Glass is the primary app icon and default in-app brand. Successful selections also update in-app branding. Existing alternate icons remain available.
- The launch storyboard and distributed/repository images use the new default artwork. iOS caches launch screens; these static resources cannot follow a runtime icon preference.
- Download confirmation now has a bounded positive-progress phase. A new app proven absent before installation can finish immediately when the device reports it installed, even if the progress counter stays nonzero. An existing app or unknown baseline alone never proves a new installation.
- Queue callbacks from retired installers are ignored, preventing late Skip/Retry callbacks from affecting the next job. Confirmed success retains the existing brief success feedback and automatic dismissal.

## Device acceptance

1. Sign with Install After Signing off: signing closes; no install claim is made.
2. Sign with Install After Signing on: approve iOS installation; card closes after device confirmation.
3. Test first install, update, cancelled prompt, rejected signature, export, batch, and Skip/Retry races. Failure must remain actionable, not masquerade as success.
4. Select an icon in Settings → App Icon; verify Home Screen, Settings, About, and featured branding. Relaunch and verify persistence.

Regression XCTest cases cover stuck nonzero counters and newly appearing apps. Run the iOS test target on macOS/Xcode; this Linux workspace has no Apple SDK or Swift toolchain.
