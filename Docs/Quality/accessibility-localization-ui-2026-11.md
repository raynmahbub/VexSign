# Accessibility, Localization and UI Quality — 2026-11

This is the working evidence for the current quality pass. It separates what the
repository gates actually checked from what needs Xcode, a simulator, or a
physical iPhone. Nothing in this document claims that a simulator test ran, that
VoiceOver was heard, or that Instruments recorded a trace in this environment.

## Scope audited

| Surface | Finding | Change |
| --- | --- | --- |
| Library / Sources / Downloads / Certificates / Updates toolbar and icons | 24 icon-only controls had no spoken name (`accessibility-icon-button-baseline.json`) | Added localized labels to every actionable icon; marked purely decorative chevrons hidden. Baseline is now zero. |
| Feature Status overview | Counters were `@State`-hidden from VoiceOver; the whole row announced the numbers only | Combined counters expose one localized `%lld implemented, %lld need device validation` label; icon decoration hidden; pipeline labels use semantic caption font and a minimum width instead of a fixed 62 pt clip. |
| Home flare tiles | Fixed 104 pt height clips at large text; label built with string interpolation | `minHeight` + vertical `fixedSize`; localized `%@ %@` label. |
| Diagnostics / Troubleshooting | No stable identifiers; URL of local records was not testable; troubleshooting link used an unlocalized `Label` | Six new `A11y.Diagnostics` identifiers, localized link/screen title, contract and XCUITest coverage. |
| Home update card | English-only branch for `1 Update Available` | String Catalog plural variants handle all locale-specific plural rules. |
| New localized UI strings | 64 user-facing strings lacked catalogue keys | Added through `sync-strings.py --write`; countable strings given `one`/`other` variants; gate passes. |

Major screens reached by navigation (Home, Library, Tasks, Settings, Signing
Methods, Installation, Notification Types, Diagnostics, Troubleshooting) already
used `A11y` identifiers and localized `NBList`/`NBSection` components. The fixes
above target concrete defects rather than replacing that design system.

## Accessibility details

- `VexMinimumTapTarget` (`.vexsignMinimumTapTarget()`) gives compact icon
  buttons a 44 × 44 pt hit region without changing their visual size. It is
  applied to favorite/auto-update and download controls; decorative images must
  not use it.
- Every changed icon-only control now has a localized accessibility label and,
  where state changes, a state-dependent verb ("Select"/"Deselect", "Enable"/
  "Disable", "Pause"/"Resume"). Buttons keep their native button trait.
- The troubleshooting screen uses native `List`, `Section`, `Menu`, `TextField`,
  `Toggle`, `DatePicker` and `Button`, so VoiceOver traits, states and rotor
  navigation come from UIKit rather than custom controls.
- Accessibility labels pass through `String.localized` / `.localized`, so they
  are localized with the rest of the interface. No language is machine-added.
- Light/dark appearance, Bold Text, Increase Contrast and Reduce Motion need
  on-device or Xcode verification. The existing `VexWorkspaceAccessibility`
  reduce-motion transaction and `VexToolbarActionStyle` contrast handling were
  reused; a new UI test relaunches the app in dark appearance and walks to
  Diagnostics.

## Localization

- `Localizable.xcstrings` remains the single catalogue: `sourceLanguage = en`,
  5,369 keys. Twelve locales already carry partial reviewed translations;
  no thirteenth locale or machine-translated content was added. New keys were added with format
  specifiers intact; `sync-strings.py --check` and `test_sync_strings.py` pass.
- New counts use `%lld` with String Catalog plural variants rather than English
  conditionals. Dates use `DatePicker` and `formatted(date:time:)`, which follow
  the user's locale.
- RTL is a **manual** acceptance item: launch with `-AppleLanguages (ar)` in
  Xcode (or an RTL pseudolocale) and confirm mirrored navigation, no clipped
  labels, and unchanged control order. No Arabic content was fabricated.

## Responsive layout

- Flare tiles now grow vertically with Dynamic Type instead of clipping at
  104 pt.
- Feature Status pipeline labels use a minimum width with wrapping; the old
  fixed 62 pt width clipped translated text and large type.
- No new device-specific geometry was introduced; existing adaptable `NBList`
  and SwiftUI stack layouts are retained for iPad and both orientations.

## Performance (evidence-based)

- The only local performance change is the removal of unconditional fixed-height
  clipping and redundant English string branching; it has no benchmark claim.
- The troubleshooting view recalculates its filter from an already bounded,
  in-memory journal (250 events / 512 KB). It adds no polling, no new timer and
  no main-thread file reads.
- Earlier diagnostics work added `OSSignposter` intervals around export and
  correlation. **No Instruments measurement was taken here.** Any animation,
  scroll or launch performance baseline remains a device task. Snapshot testing
  was deliberately not added: there is no snapshot dependency or recorded
  baseline, and XCUITest screenshots already provide failure evidence.

## Tests and gates

Executed in this environment (portable checks only):

```
python3 Tools/Validation/repository-validation/test_icon_button_labels.py  # 11 OK, 0 unlabelled sites
python3 Tools/Validation/repository-validation/test_accessibility_baseline.py  # 4 OK, 80 fixed-size sites
python3 Tools/Validation/repository-validation/sync-strings.py --check  # 928 files / 4728 literals / 5369 keys, OK
python3 Tools/Validation/repository-validation/test_sync_strings.py  # 25 OK
python3 Tools/Audit/test_quality_engineering_contracts.py  # 16 OK
python3 Tools/Audit/test_simulator_selection.py  # 4 OK
make verify  # 87 gate(s) passed
make docs-check  # OK
```

Not executed here (no Xcode, Swift compiler, simulator or iPhone in this
sandbox): `xcodebuild`, `VexSignTests`, `VexSignUITests`, accessibility audit,
Instruments, physical-device flows. CI remains the place where those results
must be read from xcresult artifacts. UI tests added:

- `AccessibilityWorkflowUITests`: identifier-driven navigation to Diagnostics
  and Troubleshooting, filter/exposure checks, tab-bar labels, dark-appearance
  relaunch, and Apple's accessibility audit (report-only by default, strict when
  the dispatch input `strict_a11y_audit` is set).
- `A11y.Diagnostics.*` contract tests in `VexSignTests/UnitTests` and mirrored
  `UIID` constants keep production and UI test identifiers in sync.

## GitHub Actions

`ci.yml` is edited, not duplicated:

- `workflow_dispatch.simulator_runtime` lets a reviewer request the oldest
  supported runtime (for example `17.0`) via `select_simulator.py --min-runtime`;
  normal runs keep the newest available runtime.
- `workflow_dispatch.strict_a11y_audit` promotes real accessibility audit
  findings to failures; the default stays report-only until a device baseline
  is reviewed.
- The UI job prints its selected simulator/runtime and audit mode into the run
  summary, next to its existing xcresult, screenshot and quality-report uploads.
- The quick job runs the new quality-engineering contract test, so source and
  catalogue drift fails before paid macOS jobs start.

## Real iPhone acceptance checklist (manual — not performed here)

Install a development-signed build on a physical iPhone and record results with
screenshots in the feature-acceptance report. A simulator pass is not a substitute.

1. VoiceOver: sweep Home → Library → Tasks → Settings → Signing Methods →
   Installation → Diagnostics → Troubleshooting. Every control announces a
   meaningful name, current state and role; no element announces only an SF
   Symbol name; reading order follows visual order.
2. Dynamic Type at the largest accessibility size: flare tiles, Feature Status
   counters/pipelines, filters and toolbar icons wrap without clipping or
   overlap; hit regions remain tappable.
3. Bold Text and Increase Contrast: status colors are not the only signal
   (icon + text remain); labels and borders stay legible in light and dark.
4. Reduce Motion: screen transitions and progress changes do not animate.
5. RTL: launch with an RTL locale; verify mirrored rows, chevrons and readable
   text. Report any clipped translated label rather than translating by machine.
6. Diagnostics: open Troubleshooting, choose a category, filter by operation,
   export a filtered bundle, and review the share sheet before sharing. Verify
   no free-form log text is included.
7. Core workflows: import an IPA, sign with an imported certificate, queue an
   install, and verify the result in iOS Settings. These outcomes cannot be
   asserted by XCUITest and must be recorded manually.
8. Performance: launch, scroll Library/Tasks, and export diagnostics while
   recording an Instruments Time Profiler trace; attach the trace and note the
   device, iOS version and build.
