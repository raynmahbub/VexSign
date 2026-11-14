#!/usr/bin/env python3
"""Read-only preservation audit against the migration's original Git revision.

Checks the *actual* original blobs, not just the map's asserted hashes. This
requires the recorded base revision in the local Git object database; it never
fetches, stages, changes baselines, checks out a branch or writes source files.
Optional tree-sitter parsing compares grammar findings, not Swift type checking.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import posixpath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[4]
MAP = ROOT / "VexSign/Documentation/Architecture/feature-layout-migration-map.json"
PRESERVATION_REPORT = "VexSign/Documentation/Architecture/feature-migration-preservation.json"
ROOT_ALIASES = {
    "icon.png": "VexSign/Resources/Assets/icon.png",
    "app-repo.json": "VexSign/Resources/Templates/app-repo.json",
    "repos.json": "VexSign/Resources/Templates/repos.json",
    "license_plist.yml": "VexSign/Configuration/Signing/license_plist.yml",
    "render.yaml": "VexSign/Services/WebManager/Configuration/render.yaml",
}
URL = re.compile(r"https?://[^\s\"'<>`\)\]]+")
# These are deliberately incomplete concatenation sentinels in the original
# negative URL-rewrite test, not public resource addresses. No real URL is exempt.
SYNTHETIC_URL_PREFIXES = {
    "https://github.com/raynmahbub/",
    "https://raw.githubusercontent.com/raynmahbub/",
}
# Preserve the original migration hashes. Integrating main must also preserve
# its already-reviewed dependency update, not revert it to make an audit pass.
# Only this exact original -> upstream lock pair is admitted; no mutable map
# baseline, arbitrary lock regeneration, or URL-domain exemption is allowed.
REVIEWED_MAIN_DEPENDENCY_LOCK = {
    "path": "Services/CloudSigning/cloud-signing/package-lock.json",
    "revision": "725a2769be00ad60542102f472bbb879c8136f86",
    "sha256Before": "2da2bc3b6488837c338b993bc68796e4dbf003e367f8cad2f7364d88fef4c92a",
    "sha256After": "e6931af4c320d691770bbe7258a8167e696a372bef11d54eaa4054e49899f47a",
}


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def text(value: bytes) -> str | None:
    if b"\0" in value:
        return None
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError:
        return None


def original_blobs(revision: str) -> dict[str, tuple[str, bytes]]:
    listing = subprocess.check_output(["git", "ls-tree", "-r", "-z", revision], cwd=ROOT)
    objects: list[tuple[str, str, str]] = []
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        if kind != "blob":
            raise ValueError(f"Unaccounted Git {kind}: {path.decode()}")
        objects.append((path.decode(), mode, oid))
    result = subprocess.run(["git", "cat-file", "--batch"], cwd=ROOT,
        input="".join(oid + "\n" for _, _, oid in objects).encode(), capture_output=True, check=True)
    cursor = 0
    blobs: dict[str, tuple[str, bytes]] = {}
    for path, mode, _ in objects:
        end = result.stdout.index(b"\n", cursor)
        size = int(result.stdout[cursor:end].split()[-1])
        value = result.stdout[end + 1:end + 1 + size]
        cursor = end + size + 2
        blobs[path] = (mode, value)
    return blobs


def current_paths() -> list[str]:
    listed = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    return sorted({path.decode() for path in listed.split(b"\0") if path and
        ((ROOT / path.decode()).is_file() or (ROOT / path.decode()).is_symlink())})


def working_blob(path: Path) -> bytes:
    return path.readlink().as_posix().encode() if path.is_symlink() else path.read_bytes()


def is_license(path: str) -> bool:
    name = Path(path).name.lower()
    return any(token in name for token in ("license", "copying", "copyright", "authors")) and Path(name).suffix in ("", ".txt", ".md")


def relocations(mapping: dict) -> dict[str, str]:
    paths = dict(mapping.get("directoryMappings", {}))
    paths.update((entry["old"], entry["new"]) for entry in mapping["fileMappings"])
    return dict(sorted(((old, new) for old, new in paths.items() if old != new), key=lambda item: -len(item[0])))


def relocate_path(value, paths: dict[str, str]):
    """Relocate path-valued scalars once, preserving all non-path values/URLs."""
    if isinstance(value, list):
        return [relocate_path(item, paths) for item in value]
    if isinstance(value, dict):
        return {key: relocate_path(item, paths) for key, item in value.items()}
    if not isinstance(value, str):
        return value
    for prefix in ("$(PROJECT_DIR)/", "$(SRCROOT)/", "${PROJECT_DIR}/", "${SRCROOT}/"):
        if value.startswith(prefix):
            return prefix + relocate_path(value[len(prefix):], paths)
    for old, new in paths.items():
        if value == old or value.startswith(old + "/"):
            return new + value[len(old):]
    return value


def relocate_references(content: str, paths: dict[str, str]) -> str:
    """Allow only explicit repository-path edits in attribution indexes/scripts.

    Single directory words (e.g. App) and paths inside public URLs are NOT prose
    rewrites. A single substitution prevents a destination being moved twice.
    """
    candidates = sorted((old for old in paths if "/" in old), key=len, reverse=True)
    if not candidates:
        return content
    pattern = re.compile(r"(?<![\w./-])(?:" + "|".join(re.escape(old) for old in candidates) + r")(?![\w.-])")
    return pattern.sub(lambda match: paths[match.group()], content)


def parse_openstep(source: str) -> dict:
    """Small strict reader for the project's OpenStep dictionaries/arrays.

    Comments and quoted strings are lexed separately: shell-script braces,
    URL slashes and comment-like text inside a string cannot change structure.
    It fails closed on unsupported/malformed input or duplicate dictionary keys.
    This reads project metadata; it is NOT an Xcode build-setting evaluator.
    """
    tokens: list[tuple[str, str]] = []
    index = 0
    punctuation = "{}()=;,"
    while index < len(source):
        if source[index].isspace():
            index += 1
        elif source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end == -1 else end + 1
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end == -1:
                raise ValueError("Unterminated OpenStep comment")
            index = end + 2
        elif source[index] == '"':
            start = index
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            tokens.append(("atom", json.loads(source[start:index])))
        elif source[index] in punctuation:
            tokens.append((source[index], source[index]))
            index += 1
        else:
            start = index
            while index < len(source) and not source[index].isspace() and source[index] not in punctuation + '"':
                if source.startswith(("//", "/*"), index):
                    break
                index += 1
            if index == start:
                raise ValueError("Unsupported OpenStep token")
            tokens.append(("atom", source[start:index]))
    cursor = 0

    def take(kind: str) -> str:
        nonlocal cursor
        if cursor >= len(tokens) or tokens[cursor][0] != kind:
            raise ValueError(f"Expected OpenStep {kind} at token {cursor}")
        value = tokens[cursor][1]
        cursor += 1
        return value

    def value():
        if cursor >= len(tokens):
            raise ValueError("Unexpected end of OpenStep input")
        kind = tokens[cursor][0]
        if kind == "{":
            take("{")
            result = {}
            while cursor < len(tokens) and tokens[cursor][0] != "}":
                key = take("atom")
                if key in result:
                    raise ValueError(f"Duplicate OpenStep key: {key}")
                take("=")
                result[key] = value()
                take(";")
            take("}")
            return result
        if kind == "(":
            take("(")
            items = []
            while cursor < len(tokens) and tokens[cursor][0] != ")":
                items.append(value())
                if cursor < len(tokens) and tokens[cursor][0] == ",":
                    take(",")
                elif cursor >= len(tokens) or tokens[cursor][0] != ")":
                    raise ValueError("Missing OpenStep array separator")
            take(")")
            return items
        return take("atom")

    result = value()
    if cursor != len(tokens) or not isinstance(result, dict):
        raise ValueError("OpenStep input is not one complete dictionary")
    return result


def reference_path(objects: dict, identifier: str, visiting: tuple[str, ...] = ()) -> str:
    if identifier in visiting:
        raise ValueError("Cyclic Xcode file reference")
    item = objects[identifier]
    tree = item.get("sourceTree", "<group>")
    if tree not in ("<group>", "SOURCE_ROOT"):
        raise ValueError(f"Unsupported xcconfig sourceTree: {tree}")
    parents = [key for key, parent in objects.items() if identifier in parent.get("children", [])]
    if len(parents) > 1:
        raise ValueError("Ambiguous Xcode file reference")
    parent = reference_path(objects, parents[0], visiting + (identifier,)) if parents and tree == "<group>" else ""
    return posixpath.normpath(posixpath.join(parent, item.get("path", "")))


def xcconfig_settings(path: str, blobs: dict[str, bytes], visiting: tuple[str, ...] = ()) -> dict:
    """Read the migration's scalar assignments/includes; reject other syntax."""
    if path in visiting:
        raise ValueError("Cyclic xcconfig include")
    result = {}
    for line in blobs[path].decode().splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        include = re.fullmatch(r'#include\s+"([^"\n]+)"', line)
        if include:
            included = posixpath.normpath(posixpath.join(posixpath.dirname(path), include[1]))
            result.update(xcconfig_settings(included, blobs, visiting + (path,)))
            continue
        setting = re.fullmatch(r"([A-Z][A-Z0-9_]*)\s*=\s*(.+)", line)
        if not setting:
            raise ValueError(f"Unsupported xcconfig expression in {path}: {line}")
        raw = setting[2].strip()
        result[setting[1]] = json.loads(raw) if raw.startswith('"') else raw
    return result


def project_preservation(before: bytes, after: bytes, paths: dict[str, str], blobs: dict[str, bytes]) -> dict:
    base = parse_openstep(before.decode())
    now = parse_openstep(after.decode())
    previous, current = base["objects"], now["objects"]
    failures = []
    if {key: value for key, value in base.items() if key != "objects"} != {key: value for key, value in now.items() if key != "objects"}:
        failures.append("Xcode root identity/object format changed")
    missing = sorted(set(previous) - set(current))
    if missing:
        failures.append("Original Xcode object IDs removed: " + ", ".join(missing))

    def objects_of(objects: dict, kinds: set[str]) -> dict:
        return {key: item for key, item in objects.items() if item.get("isa") in kinds}

    relocated_kinds = {"PBXNativeTarget", "PBXGroup", "PBXFileSystemSynchronizedRootGroup",
        "PBXFileSystemSynchronizedBuildFileExceptionSet", "XCBuildConfiguration",
        "XCLocalSwiftPackageReference", "XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency", "PBXShellScriptBuildPhase"}
    unchanged = objects_of(previous, {item["isa"] for item in previous.values()} - relocated_kinds)
    for key, item in unchanged.items():
        if item != current.get(key):
            failures.append(f"Xcode build/product/dependency object changed: {key}")
    additional = {key: current[key] for key in set(current) - set(previous)}
    additional_groups = {key for key, item in additional.items() if item.get("isa") == "PBXGroup" and item.get("path") == "VexSign/Configuration/Build"}
    for key, item in additional.items():
        if key not in additional_groups and not (item.get("isa") == "PBXFileReference" and str(item.get("path", "")).endswith(".xcconfig")):
            failures.append(f"Unreviewed additional Xcode object: {key}")
    for key, item in objects_of(previous, {"PBXGroup"}).items():
        actual = dict(current.get(key, {}))
        actual["children"] = [child for child in actual.get("children", []) if child not in additional_groups]
        expected = dict(item)
        expected.setdefault("children", [])
        if expected != actual:
            failures.append(f"Xcode original group changed beyond xcconfig references: {key}")
    targets = objects_of(previous, {"PBXNativeTarget"})
    if targets != objects_of(current, {"PBXNativeTarget"}):
        failures.append("Xcode target identities/products/configuration lists/dependencies changed")
    packages = objects_of(previous, {"XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency"})
    if relocate_path(packages, paths) != objects_of(current, {"XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency"}):
        failures.append("Xcode package identity/requirement/product changed beyond path relocation")
    configurations = objects_of(previous, {"XCBuildConfiguration"})
    current_configurations = objects_of(current, {"XCBuildConfiguration"})
    if configurations.keys() != current_configurations.keys():
        failures.append("Xcode build configuration identities changed")
    checked_settings = []
    for key, config in configurations.items():
        if key not in current_configurations:
            continue
        actual = current_configurations[key]
        if config.get("baseConfigurationReference"):
            raise ValueError("Original base xcconfig needs an explicit audit before comparison")
        effective = {}
        if actual.get("baseConfigurationReference"):
            path = reference_path(current, actual["baseConfigurationReference"])
            effective.update(xcconfig_settings(path, blobs))
        effective.update(actual["buildSettings"])
        expected = relocate_path(config["buildSettings"], paths)
        changed = sorted(name for name in set(expected) | set(effective) if expected.get(name) != effective.get(name))
        if changed:
            failures.append(f"Xcode build-setting values changed in {key}: " + ", ".join(changed))
        if {k: v for k, v in config.items() if k not in ("buildSettings", "baseConfigurationReference")} != {k: v for k, v in actual.items() if k not in ("buildSettings", "baseConfigurationReference")}:
            failures.append(f"Xcode configuration metadata changed: {key}")
        checked_settings.append({"id": key, "name": config["name"], "settingCount": len(expected), "changedSettingKeys": changed})

    groups = objects_of(previous, {"PBXFileSystemSynchronizedRootGroup"})
    resource_type_repairs = []
    for key, group in groups.items():
        new_group = current.get(key, {})
        if new_group.get("path") != relocate_path(group["path"], paths) or group.get("exceptions", []) != new_group.get("exceptions", []):
            failures.append(f"Xcode synchronized group identity/path changed unexpectedly: {key}")
        expected_types = {}
        for relative, file_type in group.get("explicitFileTypes", {}).items():
            destination = relocate_path(posixpath.join(group["path"], relative), paths)
            expected_types[posixpath.relpath(destination, new_group["path"])] = file_type
        if key == "3379C1BB2DA869A1004372DA":
            # The Debian AR payload must be copied for TweakHandler, not fed to
            # ld as a Mach-O static library. No asset bytes or target changes.
            expected_types["Resources/ellekit.deb"] = "file"
            resource_type_repairs.append({"group": key, "path": "Resources/ellekit.deb", "fileType": "file"})
        if expected_types != new_group.get("explicitFileTypes", {}):
            failures.append(f"Xcode resource file type changed beyond the reviewed Debian payload repair: {key}")
        if {k: v for k, v in group.items() if k not in ("path", "exceptions", "explicitFileTypes")} != {k: v for k, v in new_group.items() if k not in ("path", "exceptions", "explicitFileTypes")}:
            failures.append(f"Xcode synchronized group metadata changed unexpectedly: {key}")
        for exception in group.get("exceptions", []):
            old = previous[exception]
            new = current.get(exception, {})
            expected = []
            for relative in old["membershipExceptions"]:
                destination = relocate_path(posixpath.join(group["path"], relative), paths)
                member = posixpath.relpath(destination, new_group["path"])
                # Plists/entitlements moved outside synchronized app roots are
                # build inputs now, not accidental bundled source members.
                if member != ".." and not member.startswith("../"):
                    expected.append(member)
            if expected != new.get("membershipExceptions") or old["target"] != new.get("target"):
                failures.append(f"Xcode target-relative membership changed: {exception}")
    phases = objects_of(previous, {"PBXShellScriptBuildPhase"})
    for key, phase in phases.items():
        expected = relocate_path(phase, paths)
        if "shellScript" in expected:
            script = phase["shellScript"]
            rooted_paths = {prefix + old: prefix + new for prefix in ("${SRCROOT}/", "$(SRCROOT)/", "${PROJECT_DIR}/", "$(PROJECT_DIR)/")
                for old, new in paths.items() if prefix + old in script}
            expected["shellScript"] = relocate_references(script, {**paths, **rooted_paths})
        if expected != current.get(key):
            failures.append(f"Xcode shell-script phase changed beyond path relocation: {key}")
    return {
        "originalObjectIDs": len(previous), "currentObjectIDs": len(current),
        "missingOriginalObjectIDs": missing, "additionalObjectIDs": sorted(set(current) - set(previous)),
        "targets": [{"id": key, "name": item["name"], "productName": item["productName"], "productType": item["productType"]} for key, item in targets.items()],
        "configurations": checked_settings,
        "packageReferencesAndProducts": len(packages), "synchronizedGroups": len(groups),
        "reviewedResourceTypeRepairs": resource_type_repairs,
        "unchangedBuildProductAndDependencyObjects": len(unchanged),
        "failures": failures,
        "limitation": "Declared setting values, includes and metadata only; not Xcode expansion, compilation or bundle placement.",
    }


def protected_input(path: str) -> bool:
    return (Path(path).suffix in (".entitlements", ".plist", ".xcprivacy")
        or Path(path).name in ("Package.swift", "Package.resolved", "inputs.lock.json", "package-lock.json", "openapi.json", "FilePickerFix.m", "FileManager+documents.swift")
        or ".xcdatamodeld/" in path)


def reviewed_security_linkage(old: str, before: bytes, after: bytes) -> bool:
    """Only one reviewed public-framework link may differ from a protected input.

    This is a byte-exact transformation, not a mutable hash baseline or a blanket
    vendor exception. No pins, dependencies, targets, flags, or license text change.
    """
    marker = b'\t\t\t\t.linkedFramework("OpenSSL"),\n'
    addition = b'                .linkedFramework("Security"),\n'
    return (old == "Packages/Vendor/Zsign/Package.swift" and before.count(marker) == 1
        and after == before.replace(marker, marker + addition, 1))


def reviewed_flat_package_sources(old: str, before: bytes, after: bytes) -> bool:
    """Only make the unchanged single module's relocated source root explicit.

    Byte-exact transformation: no product/target/module name, dependency, pin,
    platform, flag, or other manifest content can change under this exception.
    Original source-file hashes and destinations are audited independently.
    """
    marker = b'.target(\n            name: "AltSourceKit"),'
    replacement = b'.target(\n            name: "AltSourceKit",\n            path: "Sources"),'
    return (old == "Packages/AltSourceKit/Package.swift" and before.count(marker) == 1
        and after == before.replace(marker, replacement, 1))


def reviewed_main_dependency_lock(old: str, before: bytes, after: bytes) -> bool:
    """Admit only the exact lock already published on the integrated main revision.

    The ordinary original-hash check still runs independently. Changed registry
    URLs are accounted for only when both complete blobs match this reviewed pair.
    """
    return (old == REVIEWED_MAIN_DEPENDENCY_LOCK["path"]
        and digest(before) == REVIEWED_MAIN_DEPENDENCY_LOCK["sha256Before"]
        and digest(after) == REVIEWED_MAIN_DEPENDENCY_LOCK["sha256After"])


def bridging_header_preservation(old: str, new: str, before: bytes, after: bytes,
                                 paths: dict[str, str], originals: dict) -> dict:
    includes = []
    def replace(match):
        relative = match[2]
        target = posixpath.normpath(posixpath.join(posixpath.dirname(old), relative))
        if target not in originals:
            candidates = [path for path in originals if Path(path).name == relative]
            if len(candidates) != 1:
                raise ValueError(f"Ambiguous original bridging-header include: {relative}")
            target = candidates[0]
        destination = relocate_path(target, paths)
        includes.append({"original": target, "destination": destination})
        return match[1] + posixpath.relpath(destination, posixpath.dirname(new)) + match[3]
    expected = re.sub(r'(#(?:include|import)\s+")([^"\n]+)(")', replace, before.decode())
    return {"path": new, "includes": includes, "onlyIncludePathsChanged": expected.encode() == after}


def parse_findings(value: bytes, parser) -> list[dict]:
    queue = [parser.parse(value).root_node]
    lines = value.decode("utf-8", "replace").splitlines()
    found = []
    while queue:
        node = queue.pop()
        if node.type == "ERROR" or node.is_missing:
            fragment = value[node.start_byte:node.end_byte].decode("utf-8", "replace")
            # A missing grammar token has no bytes; retain the whole source line
            # so an equal total cannot hide an unrelated new syntax finding.
            context = fragment or (lines[node.start_point.row] if node.start_point.row < len(lines) else "<end of file>")
            signature = node.type + ":" + re.sub(r"\s+", " ", context).strip()
            found.append({"line": node.start_point.row + 1, "kind": node.type, "signature": signature})
        queue.extend(node.children)
    return sorted(found, key=lambda finding: (finding["line"], finding["kind"]))


def audit(parse_swift: bool = False) -> dict:
    mapping = json.loads(MAP.read_text())
    originals = original_blobs(mapping["baseCommit"])
    entries = mapping["fileMappings"]
    failures: list[str] = []
    destinations = [entry["new"] for entry in entries]
    if len(destinations) != len(set(destinations)):
        failures.append("Original mappings do not have unique destinations")
    if len(entries) != len(originals) or set(originals) != {entry["old"] for entry in entries}:
        failures.append("Migration map does not equal the original Git inventory exactly once")
    current = current_paths()
    added = sorted(set(current) - set(destinations))
    if added != sorted(mapping.get("addedFiles", [])):
        failures.append("addedFiles inventory differs from the actual non-ignored working tree")
    urls_before: set[str] = set()
    urls_now: set[str] = set()
    rewritten, identical, binary, licenses, resources = [], [], [], [], []
    paths = relocations(mapping)
    attribution_indexes, protected, metadata, headers = [], [], [], []
    superseded_dependency_urls: set[str] = set()
    blobs_now = {path: working_blob(ROOT / path) for path in current}
    for path, value in blobs_now.items():
        # An old evidence report must not manufacture preservation of a URL
        # removed from the actual repository sources/documentation.
        content = text(value)
        if content is not None and path != PRESERVATION_REPORT:
            urls_now.update(URL.findall(content))
    for entry in entries:
        old, new = entry["old"], entry["new"]
        if old not in originals:
            failures.append(f"Map names an unknown original: {old}")
            continue
        mode, before = originals[old]
        if digest(before) != entry["sha256Before"]:
            failures.append(f"Incorrect original SHA256: {old}")
        if new not in blobs_now:
            failures.append(f"Missing destination: {old} -> {new}")
            continue
        after = blobs_now[new]
        (identical if before == after else rewritten).append(new)
        if mode == "120000":
            if not (ROOT / new).is_symlink() or (ROOT / new).readlink().as_posix().encode() != before:
                failures.append(f"Symlink changed: {old}")
        elif (ROOT / new).is_symlink():
            failures.append(f"Regular file replaced by symlink: {old}")
        elif bool(int(mode, 8) & 0o111) != bool((ROOT / new).stat().st_mode & 0o111):
            failures.append(f"Executable mode changed: {old}")
        content = text(before)
        if content is None:
            binary.append(new)
            if before != after:
                failures.append(f"Binary bytes changed: {old}")
        else:
            urls_before.update(URL.findall(content))
        if is_license(old):
            licenses.append({"path": new, "identical": before == after, "sha256": digest(before)})
            if before != after:
                failures.append(f"License/attribution bytes changed: {old}")
        if "notice" in Path(old).name.lower() or Path(old).name == "license_plist.yml":
            path_only = content is not None and relocate_references(content, paths).encode() == after
            attribution_indexes.append({"original": old, "path": new, "onlyRepositoryPathsChanged": path_only})
            if not path_only:
                failures.append(f"Attribution/index content changed beyond repository paths: {old}")
        if protected_input(old):
            reviewed = reviewed_security_linkage(old, before, after)
            flat_sources = reviewed_flat_package_sources(old, before, after)
            main_lock = reviewed_main_dependency_lock(old, before, after)
            evidence = {"path": new, "identical": before == after, "sha256Before": digest(before), "sha256After": digest(after)}
            if reviewed:
                evidence["reviewedChange"] = "Public Security framework linkage only; upstream package/pins unchanged"
            if flat_sources:
                evidence["reviewedChange"] = "Explicit flattened Sources path only; module/product/dependencies unchanged"
            if main_lock:
                evidence["reviewedChange"] = "Exact incoming main dependency lock; original migration hash retained"
                evidence["sourceRevision"] = REVIEWED_MAIN_DEPENDENCY_LOCK["revision"]
                evidence["sourcePath"] = old
                superseded_dependency_urls.update(set(URL.findall(before.decode())) - set(URL.findall(after.decode())))
            protected.append(evidence)
            if before != after and not (reviewed or flat_sources or main_lock):
                failures.append(f"Protected input bytes changed: {old}")
        if old == "Packages/Vendor/manifest.json":
            path_only = relocate_path(json.loads(before), paths) == json.loads(after)
            metadata.append({"path": new, "onlyRepositoryPathsChanged": path_only})
            if not path_only:
                failures.append("Vendored pins/attribution metadata changed beyond repository paths")
        if old.endswith("VexSign-Bridging-Header.h"):
            header = bridging_header_preservation(old, new, before, after, paths, originals)
            headers.append(header)
            if not header["onlyIncludePathsChanged"]:
                failures.append("Bridging-header content changed beyond relocated include paths")
            for include in header["includes"]:
                if blobs_now.get(include["destination"]) != originals[include["original"]][1]:
                    failures.append("Bridging-header input changed: " + include["original"])
        if old.startswith("App/iOS/VexSign/Resources/"):
            resources.append({"path": new, "identical": before == after})
    aliases = []
    for alias, canonical in ROOT_ALIASES.items():
        equal = alias in blobs_now and canonical in blobs_now and blobs_now[alias] == blobs_now[canonical]
        aliases.append({"alias": alias, "canonical": canonical, "identical": equal})
        if not equal:
            failures.append("Published root alias differs from its canonical owner: " + alias)
    project_path = "VexSign.xcodeproj/project.pbxproj"
    project = project_preservation(originals[project_path][1], blobs_now[project_path], paths, blobs_now)
    failures.extend(project["failures"])
    if sorted(rewritten) != sorted(mapping.get("rewrittenFiles", [])):
        failures.append("rewrittenFiles inventory differs from the actual original-blob comparison")
    missing_urls = sorted(urls_before - urls_now - SYNTHETIC_URL_PREFIXES - superseded_dependency_urls)
    failures.extend(f"Original URL removed: {url}" for url in missing_urls)
    result = {
        "baseCommit": mapping["baseCommit"], "branch": mapping["branch"],
        "originalFiles": len(originals), "mappedFiles": len(entries),
        "relocatedFiles": sum(entry["old"] != entry["new"] for entry in entries),
        "byteIdenticalOriginals": len(identical), "rewrittenTextOriginals": len(rewritten),
        "addedFiles": len(added), "binaryFilesPreserved": len(binary),
        "licenseAndAttributionFilesPreserved": len(licenses),
        "licenseTexts": licenses, "attributionIndexes": attribution_indexes,
        "protectedInputs": protected, "pathRelocatedMetadata": metadata,
        "bridgingHeaders": headers, "rootCompatibilityAliases": aliases,
        "xcodeProjectComparison": project,
        "originalAppResources": resources,
        "missingOriginalURLs": missing_urls,
        "syntheticURLPrefixExclusions": sorted(SYNTHETIC_URL_PREFIXES),
        "supersededMainDependencyURLs": sorted(superseded_dependency_urls),
        "failures": failures,
        "limitations": ["Byte/path/grammar checks are not Swift type checking, Xcode builds, XCTest, simulator or device acceptance."],
    }
    if parse_swift:
        from tree_sitter import Language, Parser
        import tree_sitter_swift
        parser = Parser(Language(tree_sitter_swift.language()))
        base_flags, current_flags = {}, {}
        for entry in entries:
            if entry["old"].endswith(".swift"):
                findings = parse_findings(originals[entry["old"]][1], parser)
                if findings:
                    base_flags[entry["old"]] = findings
        for path, value in blobs_now.items():
            if path.endswith(".swift"):
                findings = parse_findings(value, parser)
                if findings:
                    current_flags[path] = findings
        base_counter = Counter(finding["signature"] for findings in base_flags.values() for finding in findings)
        current_counter = Counter(finding["signature"] for findings in current_flags.values() for finding in findings)
        introduced = list((current_counter - base_counter).elements())
        result["swiftGrammarComparison"] = {
            "baseFiles": sum(path.endswith(".swift") for path in originals),
            "currentFiles": sum(path.endswith(".swift") for path in blobs_now),
            "baseFindings": sum(base_counter.values()), "currentFindings": sum(current_counter.values()),
            "newFindingSignatures": introduced,
            "baseFlaggedFiles": base_flags, "currentFlaggedFiles": current_flags,
        }
        failures.extend("New Swift grammar finding: " + signature for signature in introduced)
    return result


def main() -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--parse-swift", action="store_true", help="requires tree-sitter and tree-sitter-swift; NOT swiftc")
    arguments.add_argument("--report", type=Path, help="write a JSON evidence report (never changes a baseline)")
    options = arguments.parse_args()
    try:
        result = audit(options.parse_swift)
    except (ValueError, OSError, KeyError, ImportError, subprocess.CalledProcessError) as error:
        print(f"Preservation audit could not complete: {error}", file=sys.stderr)
        return 1
    if options.report:
        options.report.parent.mkdir(parents=True, exist_ok=True)
        options.report.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Originals: {result['originalFiles']}; mapped: {result['mappedFiles']}; relocated: {result['relocatedFiles']}")
    print(f"Identical: {result['byteIdenticalOriginals']}; rewritten text: {result['rewrittenTextOriginals']}; added: {result['addedFiles']}")
    print(f"Binary preserved: {result['binaryFilesPreserved']}; license/attribution preserved: {result['licenseAndAttributionFilesPreserved']}")
    print(f"Protected inputs: {len(result['protectedInputs'])}; path-only attribution indexes: {len(result['attributionIndexes'])}")
    project = result["xcodeProjectComparison"]
    print(f"Xcode metadata: {len(project['targets'])} targets; {project['originalObjectIDs']} original IDs audited; {len(project['configurations'])} declared setting sets compared")
    for failure in result["failures"]:
        print("FAIL: " + failure)
    if "swiftGrammarComparison" in result:
        grammar = result["swiftGrammarComparison"]
        print(f"Grammar only: {grammar['baseFindings']} -> {grammar['currentFindings']} findings; new signatures: {len(grammar['newFindingSignatures'])}")
    print("FAIL" if result["failures"] else "PASS (portable preservation only)")
    return 1 if result["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
