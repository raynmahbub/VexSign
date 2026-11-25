# ADR 0001 — Adopt the production architecture

- **Status:** Accepted
- **Date:** 2026-11-24
- **Scope:** repository root, app layers, test roots and boundary enforcement

## Context

VexSign had already moved from a flat tree to a feature-oriented layout, but the written
blueprints disagreed with each other and with the repository in three places:

- some diagrams named `VexSignTests/` as a folder while the Xcode target
  `VexSignTests` uses `Tests/` as its source root;
- UI automation was described as "to be added" although the `VexSignUITests` target
  already exists with a sibling `UITests/` root;
- the architecture README listed `UITests` under `Tests/` and stale `Configuration/`
  names.

Repeated redesign was costing more than the remaining drift. The repository needed one
ratified map, one set of allowed dependency edges, and tests that make the map durable.

## Decision

1. **Keep the root tree** at `VexSign`, `Packages`, `Tests`, `UITests`, `Tools`,
   `Configuration`, `Platform`, `Services`, `Documentation`, plus the Xcode project
   and workspace. No new root folders; no `Core/`, `Infrastructure/`, `Sources/` or
   second app source root.
2. **Keep `VexSign/` as the single iOS app source root** with the ten layers
   `App`, `Features`, `DesignSystem`, `Shared`, `Services`, `Security`, `Storage`,
   `Networking`, `System`, `Resources`.
3. **Keep `Tests/`** as the source root of the `VexSignTests` target. The folder name
   is not changed to match the target name; doing so would move a synchronized root.
4. **Keep `UITests/`** as the source root of the real `VexSignUITests` target. It stays
   a sibling of `Tests/`; `Tests/UI/`, `VexSignTests/UITests/` and a root
   `VexSignUITests/` folder are rejected.
5. **Keep root `Services/`** for the separately deployable `Cloud`, `WebManager` and
   `Integrations` backends. `VexSign/Services/` remains the app workflow layer.
6. **Keep the six real packages** and add a package only when an independently
   testable module is introduced.
7. **Keep the curated root files**, including the five byte-identical compatibility
   aliases. Add `.gitattributes` so line endings and binary assets agree with
   `.editorconfig`.
8. **Enforce boundaries in the existing validation suite** rather than adding a new
   CI system. Every structural rule in this ADR has an assertion in
   `Tools/Validation/architecture-rules/`.

## Alternatives rejected

| Alternative | Why rejected |
| --- | --- |
| Rename `Tests/` → `VexSignTests/` | A source move for a naming preference; breaks the synchronized root, CI filters and layout guard for no behavioural gain. |
| Move UI tests into `VexSignTests/UITests/` | A nested synchronized root was already tried and failed. |
| Add `Platform/iOS/` | The iOS target *is* `VexSign/`; the folder would be empty or duplicate a target root. |
| Rename root `Services/` → `Backend/` | Clearer wording, but a wide mechanical change across CI, Makefile, docs, Dependabot and render config; deferred until there is a functional reason. |
| Split `ci.yml` into ten workflow files | Release checks name specific jobs in one run; splitting adds concurrency and provenance complexity without stronger gates. |
| Create a package per feature | Violates the "no empty modules" rule and slows the build graph. |
| Add `Core/` or `Infrastructure/` | Generic buckets that compete with `Shared`, `Services` and `System`. |

## Consequences

- Folder-level work stops. New code must fit an existing boundary, or the ADR, README,
  root map and guard are updated in the same commit.
- `Features` depend only on `Shared/Models` and `Shared/Protocols`; concrete services
  are injected by `AppContainer`.
- `Security` decides, `Storage` persists, `Networking` transports and `System` adapts
  the OS. None of them may absorb another's responsibility.
- Portable gates run on every change. Native build, simulator tests and physical-device
  evidence remain separate, explicitly reported signals; a skipped device job is never
  described as passing.
