#!/usr/bin/env python3
"""Check that the Xcode project's folder-synchronized groups are wired safely.

The app targets use `PBXFileSystemSynchronizedRootGroup`, so *where a folder sits
on disk* decides what a target compiles and bundles. That makes a source move a
project-wiring change, and the failure mode is quiet:

  * a nested synchronized root group (one root group whose path contains
    another's) is a shape Xcode does not produce, and the project stops
    resolving package products for the affected targets;
  * a resource moved out of a target's synchronized root silently stops being
    bundled, which shows up as an app with unlocalized keys, no launch screen,
    a missing privacy manifest, or a missing runtime payload.

Both of those shipped through a repository relocation because every other gate
still passed. This gate reads the project text and asserts the properties that
the relocation broke, so the next move fails here instead of on a device.

Exit status is 0 when every check passes, 1 otherwise.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "VexSign.xcodeproj/project.pbxproj"
# Nesting is a hard failure: a recorded baseline would let the next regression
# be silenced instead of fixed.

# Resources the built app must contain. Each is (path relative to the sync root,
# why it has to be in the bundle). The bundle is only as complete as the folder
# the target synchronizes, so each of these has to live under the iOS sync root.
# Source roots that hold first-party Swift. Every one of them must be reachable
# from some target's synchronized root, or the code is never compiled.
SOURCE_ROOTS = ("App", "Platform", "Shared", "Storage", "Networking", "Apple",
                "DesignSystem", "VexSign/Services", "Tests")

BUNDLED_RESOURCES = (
    ("Resources/Localizations/Localizable.xcstrings",
     "iOS falls back to raw keys when the catalogue is not bundled"),
    ("Resources/Launch Screen.storyboard",
     "INFOPLIST_KEY_UILaunchStoryboardName names a storyboard that must ship"),
    ("Resources/PrivacyInfo.xcprivacy",
     "the privacy manifest is a submission requirement"),
    ("Resources/ellekit.deb",
     "TweakHandler loads it from the bundle and ci.yml byte-compares it"),
    ("Resources/Settings.bundle",
     "the app's settings pane is a bundled bundle"),
)


def objects(text):
    """id -> (comment, body) for every `id /* comment */ = { ... };` object."""
    found = {}
    for match in re.finditer(r"\n\t\t([0-9A-F]{24}) /\* ([^*\n]+?) \*/ = \{", text):
        start = text.index("{", match.start())
        depth = 0
        for index in range(start, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    found[match.group(1)] = (match.group(2).strip(), text[start:index + 1])
                    break
    return found


def sync_roots(text):
    """Synchronized root groups as (id, display name, on-disk path)."""
    roots = []
    for oid, (name, body) in objects(text).items():
        if "isa = PBXFileSystemSynchronizedRootGroup;" not in body:
            continue
        path = re.search(r"path = ([^;]+);", body)
        roots.append((oid, name, path.group(1) if path else None))
    return roots


def target_groups(text):
    """Native target name -> the synchronized group ids it compiles."""
    out = {}
    for oid, (name, body) in objects(text).items():
        if "isa = PBXNativeTarget;" not in body:
            continue
        # Brace-match the list: an exception-set id inside a nested object would
        # truncate a non-greedy match at the first `);` in the body.
        start = body.find("fileSystemSynchronizedGroups = (")
        if start < 0:
            out[name] = []
            continue
        depth, end = 0, len(body)
        for index in range(start, len(body)):
            if body[index] == "(":
                depth += 1
            elif body[index] == ")":
                depth -= 1
                if depth == 0:
                    end = index
                    break
        listed = body[body.index("(", start) + 1:end]
        # Each entry is `ID /* Name */`; keep the id and drop the display name.
        out[name] = [x.split("/*")[0].strip() for x in listed.split(",") if x.strip()]
    return out


def nested_roots(roots):
    """Pairs where one synchronized root's path contains another's."""
    paths = [(oid, name, path) for oid, name, path in roots if path]
    pairs = []
    for _, outer_name, outer in paths:
        for _, inner_name, inner in paths:
            if outer != inner and inner.startswith(outer.rstrip("/") + "/"):
                pairs.append((outer_name, outer, inner_name, inner))
    return pairs


def orphaned_sources(root, roots):
    """First-party Swift that no synchronized root can reach, so nothing compiles it.

    A synchronized root compiles the folder it names and nothing else, so a source
    tree outside every root is dead weight: the build either ignores it or fails
    with a missing symbol, and no other gate notices.
    """
    reachable = [path.rstrip("/") for _, _, path in roots if path]
    orphans = []
    for name in SOURCE_ROOTS:
        base = root / name
        if not base.is_dir():
            orphans.append(f"{name}: root is missing")
            continue
        for path in sorted(base.rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            if not any(relative == r or relative.startswith(r + "/") for r in reachable):
                orphans.append(relative)
    return orphans


def unbundled(root, roots, targets):
    """Resources that no app target's synchronized root can reach."""
    ios = targets.get("VexSign") or []
    reachable = []
    for oid, _, path in roots:
        if oid in ios and path:
            reachable.append(path.rstrip("/"))
    missing = []
    for relative, why in BUNDLED_RESOURCES:
        if not any((root / base / relative).exists() for base in reachable):
            missing.append(f"{relative}: not under any VexSign sync root ({why})")
    return missing


def problems(root=ROOT, project=PROJECT):
    """Every wiring problem, as printable lines."""
    if not project.exists():
        return [f"{project.relative_to(root)}: missing"]
    text = project.read_text(encoding="utf-8")
    roots = sync_roots(text)
    targets = target_groups(text)
    found = []

    unreferenced = sorted({oid for oid, _, _ in roots}
                          - {oid for ids in targets.values() for oid in ids})
    if unreferenced:
        found.append(f"{len(unreferenced)} synchronized root(s) belong to no target: "
                     f"{', '.join(unreferenced)}")

    nesting = nested_roots(roots)

    for outer_name, outer, inner_name, inner in nesting:
        found.append(f'nested synchronized roots: "{outer_name}" ({outer}) contains '
                     f'"{inner_name}" ({inner}); a nested root is claimed by more than one '
                     "target, so the builds fail with \"Unable to find module dependency\" "
                     "and iOS also reports \"Multiple commands produce "
                     ".../PrivacyInfo.xcprivacy\". Move the folder out so it is a sibling "
                     "of the outer root.")

    for name, ids in targets.items():
        if not ids:
            found.append(f'target "{name}" synchronizes no folder, so it compiles nothing')

    found.extend(unbundled(root, roots, targets))
    orphans = orphaned_sources(root, roots)
    if orphans:
        found.append(f"{len(orphans)} first-party source file(s) sit outside every "
                     "synchronized root, so no target compiles them (e.g. "
                     f"{orphans[0]}); move them under a root or add a root that names them")
    return found


if __name__ == "__main__":
    failures = problems()
    if failures:
        print("\n".join(failures))
        sys.exit(1)
    print("Xcode project wiring: OK (one synchronized root per target, no nesting)")
