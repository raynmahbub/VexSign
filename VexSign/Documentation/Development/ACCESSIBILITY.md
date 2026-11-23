# Accessibility: Dynamic Type and VoiceOver

Accessibility is a correctness property here, not polish. The app signs and installs
software, so a control whose purpose is only conveyed by an icon is a control a VoiceOver
user cannot operate, and text that ignores the system text size is unreadable for exactly the
users who set it.

Two rules cover almost everything, and both are checkable in review.

## 1. Text scales with the system setting

Use a semantic style (`Font.TextStyle`) instead of a point size:

```swift
Text(title).font(.system(.title2, design: .monospaced, weight: .bold))   // not .system(size: 24, ...)
Text(name).font(.headline)
```

A fixed `.font(.system(size: 24))` does not respond to **Settings → Display & Brightness →
Text Size** or to Accessibility sizes. `DynamicTypeSize` and `minimumScaleFactor` do not
compensate: `minimumScaleFactor` only shrinks text that already overflowed, it never grows it.

### Where a fixed size is allowed

A fixed size is right only where the surrounding geometry is fixed too: an icon glyph or a
numeral inside a frame with an explicit width and height (a 38 pt tile, a 14 pt column, a
progress ring), or text inside a fixed-size badge. Everything else — labels, captions, body
text, buttons, list rows — uses a `Font.TextStyle`, because it is the only thing that responds
to **Settings → Accessibility → Larger Text**.

Controls in that category must carry the information in accessibility, not in geometry:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel(Text(.localized("Downloads")))
.accessibilityValue(Text(verbatim: "\(Int(progress * 100))%"))
```

The category is larger than it sounds: 145 call sites app-wide, 125 of them in the iOS tree,
concentrated in `Presentation/Features/Home`, `…/Downloads` and the app-icon screens. The count
per feature area is pinned in
[`accessibility-font-size-baseline.json`](../../Tools/Validation/repository-validation/accessibility-font-size-baseline.json)
and enforced by
[`test_accessibility_baseline.py`](../../Tools/Validation/repository-validation/test_accessibility_baseline.py),
which `make verify` runs:

- a new `.font(.system(size:))` in an area that has none, or above its recorded count, fails the
  gate — use a semantic style, or justify the size (the frame is fixed, and say why) and
  re-record it with `--update` in the same commit;
- removing one is required to count: the gate compares the tree to the baseline *exactly*, so a
  deletion without `--update` in the same commit fails — otherwise the freed budget is available
  to be spent again by the next unrelated edit.

## 2. Every control has a name

A `Button` whose label is only an `Image(systemName:)` has no text for VoiceOver, so it is
announced as "button" and nothing else. Give it a label, and keep the label a sentence a user
would recognise:

```swift
Button { viewState = .collapsed } label: {
    Image(systemName: "chevron.down")
}
.buttonStyle(.borderless)
.accessibilityLabel(Text(.localized("Collapse downloads")))
```

Conventions used in this repository:

| Control | Label |
| --- | --- |
| Chevron that hides a list | `Collapse downloads` |
| Chevron that shows more | `Expand downloads` |
| Chevron that shrinks a sheet to a pill | `Minimize downloads` |
| Play/pause toggle for a queue | `Pause all downloads` / `Resume all downloads` (switch on state) |
| Icon that opens a picker | Name the outcome (`Choose a device`), not the glyph |

For a state-dependent control, put the state in the label or `.accessibilityValue`; do not
rely on colour or on a `play.fill`/`pause.fill` swap.

## 3. Reviewing a change

- New `Image(systemName:)` inside a `Button`? Check for `.accessibilityLabel`.
- New `.font(.system(size:`? Justify it or replace it.
- New progress indicator? Give the container a label *and* a value.
- New `.sheet`, `.alert` or custom overlay? It needs a title and a dismiss action that
  VoiceOver can reach.

The font-size rule is now gated (see above); the label rules are still review items. The list of
remaining unlabelled icon buttons is the backlog for the next accessibility pass; add a label
when you touch a file rather than leaving it for a dedicated sweep.
