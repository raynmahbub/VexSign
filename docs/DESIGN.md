# Design

VexSign should feel calm, native and trustworthy. The interface is dense with
capabilities but never noisy: one clear next action, readable surfaces, and
system behaviour everywhere.

## Principles

1. **Native first.** Use system navigation, controls, materials, Dynamic Type
   and accessibility semantics before inventing a substitute.
2. **Content over chrome.** Cards exist to group an action or a fact, not to
   decorate empty space.
3. **One accent, used with intent.** The user's tint marks selection and
   primary actions; semantic colours (orange/red/green) are reserved for state.
4. **Opaque where it matters.** Logs, forms and app data sit on opaque surfaces.
   Glass is for navigation and compact actions.
5. **Motion explains, never delays.** Transitions are short, interruptible and
   disabled by Reduce Motion.

## Tokens

The single source of truth is `VexSign/Extensions/Theme.swift`.

### Surfaces

| Token | Use |
| --- | --- |
| `Theme.background` | Screen background. |
| `Theme.card` | Cards, grouped rows and sheets. |
| `Theme.cardElevated` | Raised cards where the theme supports it. |
| `Theme.separator` | Hairlines and card borders. |
| `Theme.quaternary` | Inputs and quiet fills. |

### Accent

| Token | Use |
| --- | --- |
| `Theme.tint` | Primary actions, selection, progress. |
| `Theme.tintDeep` | Gradient end and text on light fills. |
| `Theme.tintSoft` | Selected backgrounds and badges. |
| `Theme.websiteAccent*` | The original VexSign brand accents used in the hero. |

### Metrics

| Token | Value |
| --- | --- |
| `Theme.Radius.card` | 18 |
| `Theme.Radius.cardWide` | 22 |
| `Theme.Radius.rail` | 20 |
| `Theme.Radius.hero` | 30 |
| `Theme.Radius.large` | 28 (12 on older iOS) |
| `Theme.Spacing.cardPadding` | 16 |
| `Theme.Spacing.section` | 24 |
| `Theme.Spacing.row` | Platform row rhythm |

Do not introduce one-off corner radii or spacing values in a feature view.
Extend the token file when a new role is genuinely needed.

## Typography

- The environment applies the user's font family and scale through
  `VexWorkspaceTypography`.
- Prefer semantic styles: `.largeTitle`, `.title2`, `.headline`, `.subheadline`,
  `.caption`. Fixed point sizes are reserved for the brand mark and compact
  badges.
- Use `.monospacedDigit()` for counts, versions, sizes and progress.
- Never force a font on dense technical content; logs and binary metadata may
  opt into monospaced styles locally.

## Layout

- Screen padding: 18–20pt horizontal; section spacing: 22–24pt.
- Touch targets are at least 44×44pt.
- Cards use `RoundedRectangle(cornerRadius:style: .continuous)`.
- A section has one title, an optional one-line detail, and content. Avoid
  stacking more than three levels of cards.
- Prefer `LazyVGrid` with flexible columns and `ScrollView(.horizontal)` rails
  for repeated small items.

## Components

The Home refresh introduces reusable pieces in
`VexSign/DesignSystem/`:

| Component | Role |
| --- | --- |
| `VexHomeDashboard` | Content-first Home composition. |
| `VexHomeSurface` | Opaque card with a contrast-aware hairline. |
| `VexHomeMark` | Compact VexSign brand mark. |
| `VexSectionTitle` | Section heading with optional supporting line. |
| `VexHeroAction` | Filled/outlined action on the gradient hero. |
| `VexQuickAction` | Two-column navigation tile. |
| `VexSetupRow` | Getting-started checklist row. |
| `VexStatusCard` | Active task, attention or update summary. |
| `VexToolRow` | Workspace tool row with icon and optional chevron. |

Use these before adding another card style. They are deliberately plain SwiftUI
and work on iOS 16 and later.

## Home hierarchy

1. **Greeting and Task Center** — orientation and a way back to work.
2. **Hero** — certificate readiness and the two primary actions.
3. **Metrics** — Library, Certificates, Repositories.
4. **Get started** — only while fewer than three setup steps are complete.
5. **Quick actions** — Import, Quick Sign, Library, Discover.
6. **In your workspace** — only when there is an active task, attention item or
   update.
7. **Recently added** — real app icons, no placeholder art.
8. **Workspace tools** — certificates, repositories, companion apps, URL import.

Sections that have nothing to say disappear. An empty dashboard should feel
short, not broken.

## Colour and appearance

Themes: System, Midnight Violet, Graphite, Paper, OLED, Luna and Flare. Each
theme supplies its own background, card and separator values; the user's accent
is layered on top. Semantic state colours stay constant across themes.

- Never hard-code `Color.black` or `Color.white` for body text.
- White text is only used on the brand gradient hero, which is checked in every
  appearance.
- Increase Contrast adds a stronger card border; Reduce Transparency removes
  glass effects.

## Motion

- Standard press feedback comes from `VexSignFlareButtonStyle`.
- Use `easeInOut(duration: 0.18–0.28)` for state changes.
- Do not animate layout in response to scrolling.
- Respect `accessibilityReduceMotion` and the app's animation preference.
- Avoid symbol effects and spring APIs that are newer than the deployment
  target unless guarded by availability.

## Accessibility

- Every icon-only control has an accessibility label.
- Cards that act as one control are a single button, not a pile of labels.
- Progress is announced through the task's title and phase, not colour alone.
- Text supports Dynamic Type; test at AX3 and with Bold Text.
- VoiceOver order follows the visual order: header, hero, metrics, actions,
  status, recents, tools.
- The dashboard remains usable with Reduce Transparency and Increase Contrast.

## Copy

- Sentence case for labels; no terminal punctuation on buttons.
- Prefer verbs: “Import IPA”, “Quick sign”, “Add repository”.
- Be specific about state: “Expires in 12 days”, not “Warning”.
- Do not promise capabilities that are experimental. Link to the limitation.
- Add every new literal to `Localizable.xcstrings` via
  `python3 tools/sync-strings.py --write`.

## Review checklist

- [ ] Uses `Theme` tokens, not new raw colours or radii.
- [ ] Works at AX3 and with Bold Text.
- [ ] Has 44pt targets and labels for icon-only actions.
- [ ] Empty, loading, error and success states are all designed.
- [ ] Reduce Motion and Reduce Transparency are respected.
- [ ] New strings are in the catalogue.
- [ ] `make verify` passes.
