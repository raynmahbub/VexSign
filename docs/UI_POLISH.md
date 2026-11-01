# Vex Glass — implementation checklist

The design direction is an action-first native signing workspace: neutral opaque
content, restrained accent color, semantic status colors and glass only where it
helps navigation. This checklist tracks code implementation, **not a declaration
that device testing or visual acceptance has passed**.

## 1. Shared identity and surface system — implemented

- Theme surface functions and shared 4/8/12/16/24/32 spacing scale.
- Opaque content cards with increased-contrast borders.
- Theme backgrounds/card colors injected into NimbleViews lists and forms.
- Supported iOS 26 glass action style falls back for Reduce Transparency and
  Increased Contrast; older systems use bordered actions.
- Removed the restart-based private Liquid Glass experiment from Appearance.

## 2. Themes — implemented

- System: respects the existing interface-style choice.
- Midnight Violet and Graphite: restrained dark palettes.
- Paper: warm light presentation.
- OLED: black background and elevated dark cards.
- Luna and Flare: retained raw values and existing Home layout for compatibility.
- Swatch previews and selected-state accessibility in Appearance.
- Existing custom accents are preserved. Preset accent defaults apply when no
  custom tint is stored, rather than silently overwriting a user's color choice.

## 3. Home — implemented

- New dashboard for System/new presets, with semantic typography.
- Import and Sign actions, Setup Health, current task and relevant updates.
- Recent library entries omit hidden and currently locked apps; task summaries
  use kind/stage rather than potentially sensitive app titles.
- No empty metric chart/counter panels. Tools and URL download remain accessible.
- Recently added items open Library; they do not bypass its authentication flow.

## 4. Library — implemented

- Compact list default; optional adaptive row cards and a separate icon-grid layout.
  All presentations share the existing app-cell detail entry and context actions.
- Editing uses list layout so selection and manual reordering stay available.
- Smaller app icons, two-line names and version/stored-copy subtitles; bundle IDs
  remain in app details rather than crowding every row.
- All / Signed / Imported / Needs Attention scopes.
- Attention uses revoked/expired/soon-expiring signed identities or available
  updates. Unknown status and unsigned imports are not reported as failures.
- Search/scope-aware empty state, clear-filter action and export in selection bar.
- Device installation evidence remains separate from stored signed-copy labels.

## 5. Settings — implemented

- Setup → Signing/Installation → Sources/Updates → Automation → Appearance →
  Security → Storage → Companions → Advanced → About/Support.
- Search and every existing destination preserved.
- Smaller shared section headings; About and donation content moved to the end.
- Companion apps/devices have their own section rather than implying that the
  app includes LiveContainer's runtime.

## 6. Typography — implemented

- System font remains the default. Existing optional font preferences persist.
- Inherited body font now scales with Dynamic Type plus the user's size setting.
- New dashboard/signing components use semantic text styles, not fixed pixel sizes.
- Technical identifiers, logs and fingerprints keep dedicated monospaced styling.
- Legacy themed Home layouts retain their styling as an explicit compatibility choice.

## 7. Signing — implemented

- Safe-area action panel replaces the private variable-blur overlay and spacer.
- Real SigningService stage callback shown, with an indeterminate spinner rather
  than implying a time percentage from stage milestone estimates.
- Stop, logs and retry/start actions remain accessible; inline failure stays visible.
- Existing preflight, post-sign cleanup and automatic-install preferences preserved.
- Signing completion is not presented as installation completion.

## 8. Companions — implemented

- Roles explained in a compact disclosure: VexSign prepares, SideStore manages
  its account/install/renewal, LiveContainer imports/runs compatible guests.
- Handoff, local detection and confirmed success remain distinct.
- See COMPANION_SIGNING.md for protocol, privacy and lifecycle details.

## 9. Interaction and accessibility — implementation pass complete

- Shared card/spacing tokens, action labels and 44-point signing/selection controls.
- Root Reduce Motion transaction policy, alongside existing press-style safeguards.
- Reduced-transparency and contrast fallback for the new glass navigation action.
- Destructive operations retain confirmation; reversible filter changes need none.
- Existing secure log redaction and selectable detailed errors remain in place.

## Validation still required

- macOS/Xcode compilation and execution of DesignSystemTests and the existing suite.
- iOS 16 fallback and iOS 26 glass navigation on physical devices.
- Every preset in light/dark transitions, custom tint, and restored legacy preferences.
- Accessibility text sizes (including selection bar, cards, forms and long app names),
  VoiceOver, Reduce Motion, Reduce Transparency and Increased Contrast.
- iPhone landscape, iPad multiwindow and adaptive-card selection/reordering.
- Real signing/stop/retry/log flows and post-sign installation confirmation.
- SideStore/LiveContainer handoffs and return-to-app behavior.

Linux `make verify` checks structure, localization and architectural gates. A
supplementary tree-sitter parse checks Swift syntax but cannot type-check SwiftUI
or replace Xcode or screenshots from real devices.

## Follow-up: adaptive action groups

- Home actions, signing controls and Library selection use one measured action
  layout. Equal-width columns stack before labels need horizontal compression;
  accessibility text sizes always stack. Horizontal ordering respects RTL.
- Library keeps Sign/Install and Export prominent, with Sign & Install and
  explicitly labelled Delete under More. Delete still opens confirmation.
- Entering Library selection dismisses the keyboard; selection count is visible.
- Settings now uses the same glass-action modifier as Home, including Increased
  Contrast and Reduce Transparency fallbacks.
- Added sizing-decision boundary tests. Actual SwiftUI measurement, long translated
  labels, RTL placement and screen-height behavior still require device validation.

## Completion follow-up: Library, appearance and signing outcomes

- Library now has three persisted layouts: compact list, adaptive row cards and
  icon grid. Icon tiles reuse the same cell's authenticated detail entry, sheets
  and context actions. Selection still switches to a list. Badges stack inside
  tiles instead of competing with long app names.
- Single-cell Library deletion (swipe or context menu), as well as bulk deletion,
  requires confirmation and explains that deleting a stored copy is not uninstalling.
- Appearance includes a live card preview, a theme-accent reset, and a confirmed
  workspace reset for theme/interface style, font, scale, accent and press feedback.
  Other appearance preferences and all signing/data settings are preserved.
- Custom accent changes are observed at the root so SwiftUI and UIKit tint refresh
  together. Home's time-of-day greeting uses the device calendar and local time.
- Manual signing shows an explicit completion screen with Done and Logs. Cleanup
  is deferred until Done (or parent removal), with a one-shot action to avoid
  duplicate deletion. Logs can be reopened without completing this manual flow.
- Automatic-install behavior remains unchanged: immediate handoff, or handoff on
  closing an already-open console. It does not pause for the manual success screen
  and does not claim installation success.
- Signing failures display the full redacted, selectable error in scrollable content,
  with retry and logs; cancellation remains distinct from failure. More options are
  disabled during a signing run, and interactive dismissal is blocked during signing
  and the manual completion step.

Latest lightweight validation: `make verify` passed (396 Swift files scanned;
2,717 localization keys), `git diff --check` passed, and supplementary tree-sitter
parsing passed for 43 changed/new Swift files. No Xcode compiler, XCTest execution,
visual preview or device validation was available; the validation checklist above
still applies, including cleanup timing, console presentation and auto-install.

## Nine-area audit follow-up

- Signing now includes an expandable Prepare / Customize / Sign / Verify / Install
  overview fed by the service's real stage callbacks. Only reached stages can be
  marked complete; skipped stages stay “Not run”. Failure and cancellation retain
  their own statuses. Installation always remains a separate step in this view.
- Added regression test cases for stage mapping, skipped stages, failure/cancellation
  and the invariant that signing success cannot imply installation success.
- Shared section counters no longer apply glass to content headers. They use opaque
  semantic fills and monospaced numeric text; header icons use a Dynamic Type text
  style. Native glass remains reserved for supported navigation/actions.
- Updated the Library checklist above to include the completed icon-grid option.

Audit checks: `make verify` and `git diff --check` passed; supplementary syntax parsing
passed for 44 changed/new Swift files. The localization catalogue has 2,723 keys.
Xcode compilation, XCTest execution and device/accessibility validation remain pending.

## Specification follow-through: quiet Home and result actions

- Nonlegacy Home now uses a plain theme background, rather than drawing the legacy
  decorative grid beneath the new dashboard. Existing Luna/Flare layouts are retained.
- Home shows a relevant Needs Attention summary from the same expiry/revocation/update
  rules as Library. Hidden and session-locked entries are excluded. The action opens
  Library for review. Recent entries remain honestly labelled “Recently added”, not
  “Recently used”, since no usage history is recorded.
- Home task summaries use stage text and an indeterminate indicator: shared task
  milestone fractions are not presented as measured work percentages.
- Manual signing results now offer Install, Share IPA and View in Library (the latter
  two under More), with Done and logs still available. Each result action runs the
  one-shot cleanup/completion path. An explicit consuming/keep action protects the
  signed bundle from post-sign deletion; Done alone applies normal cleanup settings.
- Automatic installation is unchanged. Completion colors are green for confirmed
  signing-stage success, red for failure and neutral for unknown/separate install state.
- Added pure completion-policy regression tests, including bundle retention for
  install/export/Library and the automatic-install preference.

Validation: lightweight verification and diff checks passed; supplemental parsing
passed for all 46 changed/new Swift files, including the final background adjustment.
Xcode builds, executable tests and visual/device acceptance remain outstanding.

## Confidence and recovery recommendations

- Start Signing opens a Ready to Sign review: effective bundle ID, changed identity,
  extension removal, injection count, signing certificate and actual preflight issues.
  Review Certificate and Options returns to the editable signing form; the certificate
  row has a Choose Certificate destination even when nothing is selected. Existing
  blocking overrides require an explicit confirmation. Review acceptance starts the
  pipeline only after the review sheet dismisses.
- App details begin with separate stored-copy, device-installation and bundle-expiry
  facts, plus the latest signing task when its subject UUID matches this exact entry.
  No task is guessed from app name. Existing signature/certificate details remain.
- Repeat signing from app details now reviews the effective saved options, expiry,
  missing saved-certificate fallback and actual preflight issues before running. It
  disables duplicate submissions while running and explains source replacement and
  cleanup behavior. Source-content fingerprinting is **not** implemented: the review
  explicitly says changes cannot be detected. Other existing repeat-sign entry points
  still retain their original behavior.
- Task Details includes a privacy-minimized Copy Redacted Report with kind, outcome,
  timestamps, failure stage and recovery guidance. Rather than guessing at redaction
  of arbitrary free text, the export omits app names, subject IDs, URLs, file paths and
  raw errors entirely. Local error details use existing secret redaction and selection.
  Receipts do not claim that a retained copy or installed app still exists.
- Home/Library manual Files imports offer Keep Both / Use Existing for an accessible
  imported entry with the same nonempty bundle ID and version. This is metadata
  matching, not byte identity. Use Existing deletes only the newly imported copy;
  the existing copy is never automatically re-signed by this choice. Quick Sign uses
  the explicitly chosen copy in the normal signing screen. Automated and background
  imports are unchanged. If no safe presenter is available, the new copy is retained.
  Concurrent manual prompts are queued. Existing hidden/locked entries are excluded.
- VoiceOver announcements are queued only when the high-level signing step changes,
  not on progress ticks. Task search dismisses its keyboard on scrolling. Library
  selection supports Escape and Command-A; review supports Escape to return to options.
- Added tests for metadata matching and receipt privacy. All tests still require Xcode
  execution; real VoiceOver/keyboard behavior and duplicate-choice lifecycle need
  device validation, including concurrent imports and app backgrounding.
