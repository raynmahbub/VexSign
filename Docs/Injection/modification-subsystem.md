# Tweak injection and IPA modification subsystem

This document describes the implemented structural subsystem. It is **not** a
claim of runtime tweak compatibility: only an authorized real-device run can
establish that. See [authorized device acceptance](authorized-device-acceptance.md).

## Scope and authorization

The modification workspace operates only on apps already in VexSign's library —
imports the user made, or signed outputs the user owns. It does not enumerate or
modify Apple system apps, does not execute imported binaries or package scripts,
and does not bypass code signing, DRM, entitlements or platform security. A
structured plan carries explicit include/exclude rules; a missing, malformed or
non-matching rule selects nothing. The signing engine re-checks the target gate
before it places any payload.

## Import and inspection

* `.deb`: `ar` envelope (`debian-binary`, exactly one `control.tar*`, one
  `data.tar*`) plus strict TAR expansion. Control metadata (`Package`, `Name`,
  `Version`, `Architecture`, `Maintainer`, `Description`, `Depends`,
  `Pre-Depends`, `Conflicts`, `Breaks`, `Provides`) is parsed without installing
  anything. Maintainer scripts are reported as ignored, never run.
* TAR payload compression: none, gzip, bzip2, xz, lzma and zstd through the
  existing `Decompression` service.
* Path safety: absolute paths, `..` traversal, links, devices, duplicate
  normalized names, depth overrun, entry-count and expanded-byte limits are
  rejected before writing. Extraction happens in a private temporary directory
  removed on success and failure.
* Inventory: dylibs, frameworks, resource bundles, install paths, filter plists
  (`Bundles` / `Executables`) and layout (rootful / rootless / roothide / mixed /
  unknown). A malformed filter is a finding that refuses injection rather than a
  reason to inject everywhere.
* Dynamic libraries and frameworks are inspected with the existing
  `MachOInspector`. Thin and universal Mach-O files are read bounds-first;
  malformed commands, wrong platform, encryption, missing arm64 slice and
  non-sandbox absolute load paths are reported.

## Decisions and plan

`InjectionPlanner` combines package inspection, dependency resolution, filter
evaluation and binary findings into a deterministic `InjectionPlan`. Outcomes are
`compatible`, `incompatible`, `unsupported`, `missingDependency`,
`conflictingModification`, `requiresAdditionalValidation` and `invalidPackage`.
Only `compatible` with at least one safe step can be applied.

Dependency resolution covers `Depends` / `Pre-Depends`, `Conflicts` / `Breaks`,
provided-package aliases, cycles, file collisions, required hook runtimes and
blocking versus advisory findings. Duplicate payload names are conflicts: the
legacy auto-rename path was replaced by an explicit refusal.

The plan preview lists place payload, add load command, redirect hook runtime,
re-sign nested code and verify signature steps with their target identifiers.
It is a preview, not a success state.

## Supported modification mechanisms

* Payloads: `.dylib`, `.framework`, `.bundle`, `.appex`, `.deb`.
* Path styles: `@executable_path`, `@rpath`; root or `Frameworks/` install folder.
* Native load-command mutation remains the pinned Zsign engine — the only writer
  of user app binaries. The Swift `MachOLoadCommandInjector` is a bounds-checked
  planner/applier used to prove in-place layout feasibility and in deterministic
  tests; it is **not** a second production mutation mechanism.
* Swift-side admission accepts verified 64-bit little-endian arm64 / arm64e thin
  and universal files with well-formed commands, safe slack before the first
  section and a valid code-signature command layout. Other architectures, fat
  layouts with out-of-bounds slices, malformed command chains and insufficient
  slack are refused with `unsupported` / `invalidPackage` outcomes.
* Existing absolute Substrate/Substitute/ElleKit load paths are redirected to
  the bundled ElleKit copy; a required runtime that is absent refuses the run.
* App extensions are placed in `PlugIns/`, have their bundle identifier rewritten
  under the host identifier, and are signed as nested code by the existing
  pipeline. The target gate and binary admission cover nested targets too.
* No jailbreak, exploit, code-signing bypass, DRM circumvention, arbitrary script
  execution or unrelated-bundle modification is implemented.

## Signing, verification and rollback

Modification happens exclusively in the existing signing pipeline's temporary
working copy. The original imported IPA is never overwritten. The pipeline then
signs with the native engine, runs the existing independent signature and
resource-seal verifier, registers the output only when verification accepts it,
and settles its copies through `CleanupManager`. The modification workspace
receives the verifier's own report and never marks an output installable on its
own. A Swift-side read-back re-checks that the expected load command exists after
the engine reports success; stale signature commands are not treated as valid.

Profiles are JSON files of `{tweak reference, version reference, enabled, path}`
entries. They contain no paths to binaries, secrets or archive bytes. References
to removed tweaks or replaced versions are pruned rather than silently reused.

Cancellation marks the operation report `cancelled`, drops the request ID so a
late completion is ignored, and leaves cleanup to the signing owner. A failed
plan records its blocking findings and failed step; no partial output is
presented as installable. Recovery is to keep the untouched original import and
re-run a reviewed plan after resolving the recorded finding — there is no
in-place patching of an already signed output.

## Screens

`TweaksView → Modify App with Tweaks` opens the service-backed workspace: package
import and inspection, tweak-library selection, authorized application choice,
plan preview, apply-and-sign, operation report, independent verification report
and saved profiles. All rows come from imported artifacts, stored profiles or
service results; no progress or success value is simulated.
