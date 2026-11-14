# UX and accessibility review

This is an incremental, source-based review, not an accessibility certification.
Simulator, VoiceOver and physical-device observations remain pending.

## Home — first pass

Reviewed `VexHomeDashboard.swift`, `VexHomeComponents.swift` and the alternative
Home presentation in `HomeView.swift`.

| Area | Source finding | Change / remaining check |
| --- | --- | --- |
| Updates summary | Zero matches was presented as repositories being up to date, although the count alone cannot establish refresh or network success. | Says no updates are shown; verify VoiceOver and empty/offline states. |
| Direct URL download | The manager returns an untracked placeholder for blocked requests, but both Home presentations always said the download started and cleared the input. | Keep input when untracked; for a tracked row, direct the user to its status rather than claim transfer progress. Test blocked, queued, existing/paused and successful cases on-device. |
| Onboarding | A source was presented as one of three steps to sign, although a locally imported IPA does not require a source. | Mark it optional; the checklist still counts all three workspace options, not signing readiness. |
| Certificate label | A non-expired selected certificate was labeled ready without proving profile or signing compatibility. | Label it selected; expiration/revocation warnings are retained. |
| Large text | Metrics, certificate caption and update details competed for horizontal space; URL field had a fixed height in the alternative presentation. | Stack metrics and the hero caption at accessibility sizes; allow the URL field to grow. Check AX sizes, localization, Bold Text and both presentations. |
| URL action | The icon-only action did not reserve a 44-point target, and the input hint was on its container. | Add a 44-point target and put the hint on the field. Verify touch and VoiceOver focus. |
| Recent apps | Cards open Library rather than a specific app. | Add a VoiceOver hint; verify focus order and consider clearer navigation in a later design pass. |

The remaining screens have **not** been audited in this pass. Next: Library
selection and destructive actions, then signing/preflight and installation status.
Do not infer accessibility or device readiness from a source review.
