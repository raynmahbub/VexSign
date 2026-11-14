#!/usr/bin/env python3
"""Structural validation of VexSign.xcodeproj/project.pbxproj.

There is no Xcode here, so this checks what can be checked without it:
  1. every 24-hex object id referenced is also defined
  2. every new target has 4 build configurations, a product reference and a
     file-system-synchronized group whose folder exists on disk
  3. each membership-exception file exists relative to its own synchronized
     root group, and build-setting plist/entitlement/header paths exist
  4. the iOS app embeds the watch app, and the watch app embeds its widget
  5. every target's SDKROOT / deployment target look sane for its platform
  6. no embedded iOS extension asks for a newer iOS than the app that embeds it
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PBX = ROOT / "VexSign.xcodeproj" / "project.pbxproj"
text = PBX.read_text()

ID_RE = re.compile(r"\b([0-9A-F]{24})\b")
# Objects are defined either multi-line ("ID /* c */ = {") or on one line
# ("ID /* c */ = {isa = PBXBuildFile; …};").
OBJECT_RE = re.compile(r"^\t\t([0-9A-F]{24})(?: /\*.*?\*/)? = \{", re.MULTILINE)

problems: list[str] = []
notes: list[str] = []

# 1. defined ids
defined = {m.group(1) for m in OBJECT_RE.finditer(text)}
referenced = set(ID_RE.findall(text))
missing = sorted(referenced - defined)
if missing:
    problems.append(f"referenced but never defined: {', '.join(missing[:10])}")

# helpers to pull one object's body
def body(object_id: str) -> str:
    """Object body, for both the multi-line and the single-line pbxproj forms."""
    multi = re.compile(rf"^\t\t{object_id} [^\n]*= \{{$(.*?)^\t\t\}};$", re.MULTILINE | re.DOTALL)
    match = multi.search(text)
    if match:
        return match.group(1)

    single = re.compile(rf"^\t\t{object_id}(?: /\* .*? \*/)? = \{{(.*)\}};$", re.MULTILINE)
    match = single.search(text)
    if match:
        return match.group(1)

    raise KeyError(object_id)


def ids_in(chunk: str) -> list[str]:
    return ID_RE.findall(chunk)


# 2/4/5. target checks
targets = {}
for match in re.finditer(r"^\t\t([0-9A-F]{24}) /\* (\w+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;", text, re.MULTILINE):
    targets[match.group(2)] = match.group(1)

expected = {
    "VexSignWidgetExtensionExtension": ("iphoneos", "IPHONEOS_DEPLOYMENT_TARGET", "com.vexsign.app.widget"),
    "VexSignTV": ("appletvos", "TVOS_DEPLOYMENT_TARGET", "com.vexsign.app.tv"),
    "VexSignVision": ("xros", "XROS_DEPLOYMENT_TARGET", "com.vexsign.app.vision"),
    "VexSignWatch": ("watchos", "WATCHOS_DEPLOYMENT_TARGET", "com.vexsign.app.watch"),
    "VexSignWatchWidgets": ("watchos", "WATCHOS_DEPLOYMENT_TARGET", "com.vexsign.app.watch.widgets"),
}

for name, target_id in targets.items():
    target_body = body(target_id)

    config_list_id = re.search(r"buildConfigurationList = ([0-9A-F]{24})", target_body)
    if not config_list_id:
        problems.append(f"{name}: no buildConfigurationList")
        continue
    config_list = body(config_list_id.group(1))
    config_ids = ids_in(config_list)
    names = []
    for config_id in config_ids:
        chunk = body(config_id)
        found = re.search(r'name = "?([^";\n]+)"?;', chunk)
        names.append(found.group(1) if found else "?")
    if sorted(names) != sorted(["Debug", "Debug-distribution", "Release", "Release-distribution"]):
        problems.append(f"{name}: configurations are {names}")

    if name in expected:
        sdkroot, deployment_key, bundle = expected[name]
        for config_id in config_ids:
            chunk = body(config_id)
            if f"SDKROOT = {sdkroot};" not in chunk:
                problems.append(f"{name}: missing SDKROOT = {sdkroot}")
            if deployment_key not in chunk:
                problems.append(f"{name}: missing {deployment_key}")
            if f"PRODUCT_BUNDLE_IDENTIFIER = {bundle};" not in chunk:
                problems.append(f"{name}: wrong PRODUCT_BUNDLE_IDENTIFIER")

    group_ids = re.findall(r"fileSystemSynchronizedGroups = \(\n(.*?)\n\t\t\t\);", target_body, re.DOTALL)
    for chunk in group_ids:
        for group_id in ids_in(chunk):
            group_body = body(group_id)
            path = re.search(r"path = ([^;]+);", group_body)
            if path and not (ROOT / path.group(1).strip()).is_dir():
                problems.append(f"{name}: synchronized group folder {path.group(1)} does not exist")

    product_id = re.search(r"productReference = ([0-9A-F]{24})", target_body)
    if not product_id:
        problems.append(f"{name}: no productReference")

# 3. Xcode path settings and membership exceptions point at real files.
# Exception paths are relative to the synchronized root group that owns them;
# after the clean-root migration, checking them against three globally guessed
# app roots would hide a broken target membership.
root_groups = re.findall(
    r"^\t\t([0-9A-F]{24})[^\n]*= \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;",
    text,
    re.MULTILINE,
)
if not root_groups:
    problems.append("no PBXFileSystemSynchronizedRootGroup objects found")
for group_id in root_groups:
    group_body = body(group_id)
    group_path = re.search(r"path = ([^;]+);", group_body)
    if not group_path:
        problems.append(f"synchronized root group {group_id[:8]}… has no path")
        continue
    group_dir = Path(group_path.group(1).strip().strip('"'))
    if not (ROOT / group_dir).is_dir():
        problems.append(f"synchronized root group {group_id[:8]}…: {group_dir} does not exist")
    exceptions = re.search(r"exceptions = \((.*?)\);", group_body, re.DOTALL)
    for exception_id in ids_in(exceptions.group(1)) if exceptions else []:
        try:
            exception_body = body(exception_id)
        except KeyError:
            problems.append(f"synchronized root group {group_id[:8]}… references undefined exception {exception_id}")
            continue
        members = re.search(r"membershipExceptions = \((.*?)\);", exception_body, re.DOTALL)
        if not members:
            problems.append(f"exception set {exception_id[:8]}… has no membershipExceptions")
            continue
        for line in members.group(1).splitlines():
            relative = line.strip().rstrip(",").strip('"')
            if not relative or relative.startswith(("(", ")", "/*")):
                continue
            if not (ROOT / group_dir / relative).exists():
                problems.append(
                    f"membership exception in {group_dir}: {relative} does not exist "
                    f"(exception set {exception_id[:8]}…)"
                )

for key in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS", "SWIFT_OBJC_BRIDGING_HEADER"):
    for match in re.finditer(rf"^\s*{key} = \"?([^\";\n]+)\"?;", text, re.MULTILINE):
        relative = match.group(1).strip().strip('"')
        if relative.startswith("$("):
            continue
        if not (ROOT / relative).exists():
            problems.append(f"{key}: {relative} does not exist")

for pattern in (r"\$\(SRCROOT\)/([^\"\s;\\]+)", r"\$\{SRCROOT\}/([^\"\s;\\]+)"):
    for match in re.finditer(pattern, text):
        relative = match.group(1).strip().strip('"')
        if not (ROOT / relative).exists():
            problems.append(f"SRCROOT reference: {relative} does not exist")

# 4. embedding
vexsign_body = body(targets["VexSign"])
watch_product = re.search(r"productReference = ([0-9A-F]{24})", body(targets["VexSignWatch"])).group(1)
widgets_product = re.search(r"productReference = ([0-9A-F]{24})", body(targets["VexSignWatchWidgets"])).group(1)

def embeds(target_body: str, phase_name: str, product_id: str, label: str) -> None:
    """phase -> build file -> product reference."""
    match = re.search(rf"([0-9A-F]{{24}}) /\* {re.escape(phase_name)} \*/", target_body)
    if not match:
        problems.append(f"{label}: no '{phase_name}' build phase")
        return
    phase_body = body(match.group(1))
    build_files = ids_in(phase_body)
    for build_file in build_files:
        if product_id in body(build_file):
            return
    problems.append(f"{label}: '{phase_name}' never embeds the expected product")


embeds(vexsign_body, "Embed Watch Content", watch_product, "VexSign")
embeds(body(targets["VexSignWatch"]), "Embed Foundation Extensions", widgets_product, "VexSignWatch")

dependency_targets = [body(dep) for dep in ids_in(re.search(r"dependencies = \((.*?)\n\t\t\t\);", vexsign_body, re.DOTALL).group(1))]
if not any(targets["VexSignWatch"] in chunk for chunk in dependency_targets):
    problems.append("VexSign has no target dependency on VexSignWatch")

# 6. extension minimum iOS must not exceed the host app's
#
# An appex whose MinimumOSVersion is higher than the embedding app's is
# invalid (ITMS-90362), and a signer that validates nested bundles can reject
# the IPA before it is ever installed. The widget target sat at 26.0 while the
# app was 16.0, which is exactly this mismatch.
def deployment_target(target: str, key: str) -> set[str]:
    values = set()
    target_body = body(targets[target])
    for config_id in ids_in(body(re.search(r"buildConfigurationList = ([0-9A-F]{24})", target_body).group(1))):
        found = re.search(rf"{key} = ([0-9.]+);", body(config_id))
        if found:
            values.add(found.group(1))
    return values


def _version(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


host_targets = deployment_target("VexSign", "IPHONEOS_DEPLOYMENT_TARGET")
extension_targets = deployment_target("VexSignWidgetExtensionExtension", "IPHONEOS_DEPLOYMENT_TARGET")
if host_targets and extension_targets and _version(max(extension_targets)) > _version(min(host_targets)):
    problems.append(
        "VexSignWidgetExtensionExtension: IPHONEOS_DEPLOYMENT_TARGET "
        f"{sorted(extension_targets)} is newer than VexSign's {sorted(host_targets)}; "
        "an embedded extension cannot require a newer iOS than its host app"
    )

print(f"targets found: {', '.join(sorted(targets))}")
print(f"object ids defined: {len(defined)}")
for note in notes:
    print("note:", note)
if problems:
    print("\nPROBLEMS:")
    for problem in problems:
        print(" -", problem)
    sys.exit(1)
print("\npbxproj structure OK")
