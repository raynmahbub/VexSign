#!/usr/bin/env python3
"""Fail when the app's two SwiftPM pin files drift apart or stop covering the graph.

`make`/Release build the app and CI builds/tests it through the same workspace, but
Xcode keeps a resolved file in two places:

    VexSign.xcworkspace/xcshareddata/swiftpm/Package.resolved
    VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

When those disagree, the artifact you ship is compiled against a different
dependency graph than the one CI tested. This gate compares them pin-by-pin
(format/originHash differences are ignored — Xcode rewrites those on resolve) and
checks that the pins actually satisfy the declared requirements:

  * every XCRemoteSwiftPackageReference in project.pbxproj,
  * every remote `.package(url:)` in the local manifests the app links
    (NativeSigning, SideSign, Vendor/Zsign).

The app pin files hold only versioned, immutable pins — the contract
`NativeSigning/prepare_combined_smoke.py` relies on when it stages the constrained
graph. SideSign's four branch-based dependencies are recorded separately in
`SideSign/Package.resolved` (the vendored pin record); this gate checks that those
branch requirements are covered there and that the shared SDK pins agree.

Offline and dependency-free; part of `make verify` and the CI quick gate.

Usage:
    python3 tools/check-package-graph.py            # check
    python3 tools/check-package-graph.py --list     # print the shared pin set
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVED = [
    Path("VexSign.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
    Path("VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
]
SIDESIGN_RESOLVED = Path("SideSign/Package.resolved")
PBX = Path("VexSign.xcodeproj/project.pbxproj")
LOCAL_MANIFESTS = [
    Path("NativeSigning/Package.swift"),
    Path("SideSign/Package.swift"),
    Path("Vendor/Zsign/Package.swift"),
]

VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$")
REVISION = re.compile(r"^[0-9a-f]{40}$")


def version_key(text: str) -> tuple:
    match = VERSION.match(text)
    if not match:
        raise ValueError(f"not a version: {text!r}")
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    # A prerelease sorts before its release; compare identifiers piecewise.
    pre = match.group(4)
    if pre is None:
        return (major, minor, patch, 1, ())
    parts = []
    for piece in pre.split("."):
        parts.append((0, int(piece)) if piece.isdigit() else (1, piece))
    return (major, minor, patch, 0, tuple(parts))


def identity_for(url: str) -> str:
    name = url.rstrip("/").rsplit("/", 1)[-1]
    if name.endswith(".git"):
        name = name[:-4]
    return name.lower()


def load_pins(path: Path) -> dict[str, dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    pins = {}
    for pin in data.get("pins", []):
        identity = pin["identity"]
        if identity in pins:
            raise ValueError(f"{path.name}: duplicate pin {identity}")
        state = pin.get("state", {})
        if not REVISION.match(state.get("revision", "")):
            raise ValueError(f"{path.name}: {identity} has no valid revision")
        if "version" in state:
            version_key(state["version"])
        elif "branch" not in state:
            raise ValueError(f"{path.name}: {identity} has neither version nor branch")
        pins[identity] = pin
    return pins


def satisfies(pin: dict, requirement: dict) -> bool:
    state = pin["state"]
    kind = requirement["kind"]
    if kind == "branch":
        return state.get("branch") == requirement["branch"]
    if "version" not in state:
        return False
    actual = version_key(state["version"])
    if kind == "exact":
        return actual == version_key(requirement["version"])
    if kind == "from":
        return actual >= version_key(requirement["version"])
    if kind == "range":
        return version_key(requirement["lower"]) <= actual < version_key(requirement["upper"])
    if kind == "upToNextMajor":
        low = version_key(requirement["version"])
        return low <= actual < (low[0] + 1, 0, 0, 1, ())
    if kind == "upToNextMinor":
        low = version_key(requirement["version"])
        return low <= actual < (low[0], low[1] + 1, 0, 1, ())
    raise ValueError(f"unknown requirement kind: {kind}")


def pbx_requirements(text: str) -> list[tuple[str, dict]]:
    out = []
    block = re.compile(
        r'XCRemoteSwiftPackageReference "([^"]+)" \*/ = \{(.*?)\n\t\t\};', re.S
    )
    for match in block.finditer(text):
        body = match.group(2)
        url = re.search(r'repositoryURL = "([^"]+)"', body)
        kind = re.search(r"kind = (\w+);", body)
        if not url or not kind:
            raise ValueError(f"unparseable package reference {match.group(1)}")
        kind = kind.group(1)
        if kind == "exactVersion":
            version = re.search(r"version = ([^;]+);", body).group(1)
            req = {"kind": "exact", "version": version}
        elif kind in ("upToNextMajorVersion", "upToNextMinorVersion"):
            version = re.search(r"minimumVersion = ([^;]+);", body).group(1)
            req = {"kind": kind.removesuffix("Version"), "version": version}
        elif kind == "branch":
            req = {"kind": "branch", "branch": re.search(r"branch = ([^;]+);", body).group(1)}
        else:
            raise ValueError(f"unsupported requirement kind {kind} for {match.group(1)}")
        out.append((identity_for(url.group(1)), req))
    return out


MANIFEST_DEP = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?url:\s*"([^"]+)"\s*,(.*?)\)\s*[,.\]]', re.S)


def manifest_requirements(text: str) -> list[tuple[str, dict]]:
    out = []
    for match in MANIFEST_DEP.finditer(text):
        url, rest = match.group(1), match.group(2)
        exact = re.search(r'exact:\s*"([^"]+)"', rest) or re.search(r'\.exact\(\s*"([^"]+)"', rest)
        from_ = re.search(r'from:\s*"([^"]+)"', rest)
        range_ = re.search(r'"([^"]+)"\s*\.\.<\s*"([^"]+)"', rest)
        branch = re.search(r'branch:\s*"([^"]+)"', rest)
        next_major = re.search(r'\.upToNextMajor\(\s*from:\s*"([^"]+)"', rest)
        next_minor = re.search(r'\.upToNextMinor\(\s*from:\s*"([^"]+)"', rest)
        if exact:
            req = {"kind": "exact", "version": exact.group(1)}
        elif range_:
            req = {"kind": "range", "lower": range_.group(1), "upper": range_.group(2)}
        elif next_major:
            req = {"kind": "upToNextMajor", "version": next_major.group(1)}
        elif next_minor:
            req = {"kind": "upToNextMinor", "version": next_minor.group(1)}
        elif from_:
            req = {"kind": "from", "version": from_.group(1)}
        elif branch:
            req = {"kind": "branch", "branch": branch.group(1)}
        else:
            raise ValueError(f"unparseable .package(url: {url}) requirement: {rest.strip()[:80]}")
        out.append((identity_for(url), req))
    return out


def check(root: Path = ROOT) -> list[str]:
    problems = []
    resolved = [root / path for path in RESOLVED]
    sidesign = root / SIDESIGN_RESOLVED
    pbx = root / PBX
    manifests = [root / path for path in LOCAL_MANIFESTS]

    pin_sets = []
    for path in resolved:
        try:
            pin_sets.append(load_pins(path))
        except (OSError, ValueError, KeyError) as error:
            problems.append(f"{path.relative_to(root)}: {error}")
    if len(pin_sets) != len(resolved):
        return problems

    left, right = pin_sets
    for identity in sorted(set(left) | set(right)):
        a, b = left.get(identity), right.get(identity)
        if a is None:
            problems.append(f"{identity}: pinned only in the project resolved file")
        elif b is None:
            problems.append(f"{identity}: pinned only in the workspace resolved file")
        elif a["state"] != b["state"] or a["location"] != b["location"]:
            problems.append(
                f"{identity}: workspace pins {a['state'].get('version', a['state'].get('branch'))} "
                f"but project pins {b['state'].get('version', b['state'].get('branch'))}"
            )
    # The combined-host preparation stages only versioned immutable app pins.
    for identity, pin in left.items():
        if set(pin["state"]) != {"version", "revision"}:
            problems.append(f"{identity}: app pin must be versioned and immutable (combined-host contract)")
    if problems:
        return problems

    requirements = []
    try:
        requirements += pbx_requirements(pbx.read_text(encoding="utf-8"))
    except (OSError, ValueError, AttributeError) as error:
        problems.append(f"project.pbxproj: {error}")
    for manifest in manifests:
        try:
            requirements += manifest_requirements(manifest.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            problems.append(f"{manifest.relative_to(root)}: {error}")

    try:
        sidesign_pins = load_pins(sidesign)
    except (OSError, ValueError, KeyError) as error:
        sidesign_pins = {}
        problems.append(f"SideSign/Package.resolved: {error}")

    for identity, requirement in requirements:
        if requirement["kind"] == "branch":
            # Branch dependencies live in the vendored SideSign pin record, not
            # the versioned app graph.
            pin = sidesign_pins.get(identity)
            if pin is None:
                problems.append(f"{identity}: branch dependency missing from SideSign/Package.resolved")
            elif not satisfies(pin, requirement):
                problems.append(f"{identity}: SideSign pin does not satisfy {requirement}")
            continue
        pin = left.get(identity)
        if pin is None:
            problems.append(f"{identity}: required ({requirement}) but not pinned")
        elif not satisfies(pin, requirement):
            got = pin["state"].get("version", pin["state"].get("branch"))
            problems.append(f"{identity}: pinned {got} does not satisfy {requirement}")

    # Shared SDK pins must agree between the app graph and the SideSign record.
    for identity in ("swift-crypto", "swift-asn1", "openssl"):
        a, b = left.get(identity), sidesign_pins.get(identity)
        if a is not None and b is not None and a["state"] != b["state"]:
            problems.append(f"{identity}: app and SideSign resolved files disagree on the shared SDK pin")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true", help="print the shared pin set")
    arguments = parser.parse_args()

    if arguments.list:
        pins = load_pins(ROOT / RESOLVED[0])
        for identity in sorted(pins):
            state = pins[identity]["state"]
            print(f"{identity:36} {state.get('version', state.get('branch'))}")
        print(f"{len(pins)} pins")
        return 0

    problems = check()
    if problems:
        print(f"❌ package graph drift ({len(problems)} problem(s)):")
        for problem in problems:
            print(f"  {problem}")
        print("Resolve once on macOS (make bootstrap) and copy the resulting pins to both files.")
        return 1
    print(f"✅ {len(load_pins(ROOT / RESOLVED[0]))} pins agree across workspace and project and satisfy every declared requirement")
    return 0


if __name__ == "__main__":
    sys.exit(main())
