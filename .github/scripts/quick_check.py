#!/usr/bin/env python3
"""Find build-breaking mistakes in seconds - no Xcode, no dependency build.

A full `xcodebuild` of VexSign compiles Vapor, NIO, Nuke and friends and takes
tens of minutes of macOS runner time. Most breakages that come out of merging
features from other forks are cheap to detect long before that:

  1. leftover merge-conflict markers (<<<<<<< ======= >>>>>>>)
  2. Swift syntax errors           - `swiftc -parse` on every first-party file,
                                     real compiler diagnostics, no SDK needed
  3. duplicate top-level types     - "invalid redeclaration" when two files
                                     both define `struct FooView`
  4. duplicate file names          - Xcode refuses two Foo.swift in one target
  5. broken resources              - Info.plist / entitlements / *.xcstrings /
                                     *.json / *.xcscheme that no longer parse
  6. project.pbxproj sanity        - unbalanced braces/parentheses
  7. repository layout / script syntax / build script inputs
  8. missing cross-module imports  - `swiftc -parse` does not resolve imports, so a file
                                     that calls `String.localized` without importing
                                     NimbleExtensions only breaks in a real build

Every finding is emitted as a GitHub annotation (file + line), collected in
the job summary with the offending source lines so it can be fixed right
away, and written as JSON for other tooling.

    python3 quick_check.py [--root .] [--json out.json] [--no-swiftc]

Exit status: 0 = clean, 1 = at least one error.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import unicodedata
import xml.etree.ElementTree as ET
from collections import defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path

# Swift "targets" as they exist on disk. Duplicate names/types are only a
# problem inside one module, so each directory is checked on its own.
SWIFT_MODULES: dict[str, str] = {
    "VexSign": "VexSign",
    "VexSignWidgetExtension": "VexSignWidgetExtension",
    "VexSignTV": "VexSignTV",
    "VexSignVision": "VexSignVision",
    "VexSignWatch": "VexSignWatch",
    "VexSignWatchWidgets": "VexSignWatchWidgets",
    "VexSignTests": "VexSignTests",
    "AltSourceKit": "AltSourceKit/Sources/AltSourceKit",
    "NimbleExtensions": "NimbleKit/Sources/NimbleExtensions",
    "NimbleJSON": "NimbleKit/Sources/NimbleJSON",
    "NimbleViews": "NimbleKit/Sources/NimbleViews",
}

# Parse-only coverage for the modules SWIFT_MODULES cannot describe: their
# trees contain overlay/patch copies and staged smoke sources, so the
# duplicate-type/filename checks (which are per-module) would false-positive.
# Syntax is still worth gating — a stray brace in NativeSigning once reached
# the macOS build because nothing here parsed it. Only the folders the
# NativeSigning target actually compiles are listed (see its Package.swift),
# plus the vendored SideSign target it now links.
PARSE_ONLY_MODULES: dict[str, list[str]] = {
    "NativeSigning": [
        "NativeSigning/Authentication",
        "NativeSigning/Codec",
        "NativeSigning/Identity",
        "NativeSigning/Provisioning",
        "NativeSigning/Security",
        "NativeSigning/Services",
        "NativeSigning/Signing",
    ],
    "SideSign": ["SideSign/Sources"],
}

# Symbols that are only visible when their module is imported. `-parse` cannot see this, and
# neither can tree-sitter, so it is worth a dedicated check: `.localized` missing its import
# has broken this repository's build more than once.
CROSS_MODULE_SYMBOLS: dict[str, str] = {
    "NimbleExtensions": r"(?:\.localized\(|\bNBHaptic\b)",
    "NimbleViews": (
        r"\bNB(?:Section|Grid|Button|NavigationView|ToolbarButton|ContentUnavailable|"
        r"PillView|PillItem|TitleWithSubtitleView|SheetButton|VariableBlurView|Spacing|Radius)\b"
    ),
}

# Directories that are never ours to check.
SKIP_DIRS = {".git", ".build", "Zsign", "IDeviceKitten", "Packages", "packages", "Payload", "deps",
             "_upstream_vexsign", "_VexSign", "node_modules", "DerivedData", ".swiftpm", "server", "cloud-signing"}

TEXT_EXTS = {".swift", ".m", ".mm", ".h", ".c", ".cpp", ".plist", ".entitlements", ".json", ".xcstrings", ".strings",
             ".stringsdict", ".pbxproj", ".xcscheme", ".xcworkspacedata", ".md", ".yml", ".yaml", ".xcconfig",
             ".storyboard", ".xib", ".intentdefinition", ".txt", ".sh", ".py"}

CONFLICT_RE = re.compile(r"^(<{7}|={7}|>{7}|\|{7})( |$)")
DIAG_RE = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<col>\d+): (?P<sev>error|warning|note): (?P<msg>.*)$")
DECL_RE = re.compile(
    r"^(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s+)*"                              # attributes: @MainActor @frozen @objc(Foo)
    r"(?:(?:public|internal|private|fileprivate|open|package|final|indirect|nonisolated|dynamic)\s+)*"
    r"(?P<kind>class|struct|enum|actor|protocol|typealias|macro)\s+(?P<name>[A-Za-z_]\w*)"
)
IF_RE = re.compile(r"^\s*#if\b")
ELSE_RE = re.compile(r"^\s*#(elseif|else)\b")
ENDIF_RE = re.compile(r"^\s*#endif\b")

MAX_CONTEXT_ISSUES = 25


@dataclass
class Finding:
    check: str
    severity: str  # error | warning
    message: str
    file: str | None = None
    line: int | None = None
    col: int | None = None
    context: list[str] = field(default_factory=list)


class Report:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.findings: list[Finding] = []
        self.stats: dict[str, int] = defaultdict(int)

    def add(self, finding: Finding) -> None:
        self.findings.append(finding)

    @property
    def errors(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "error"]

    @property
    def warnings(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "warning"]


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def iter_files(root: Path, exts: set[str] | None = None):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.endswith(".xcassets"))
        for name in sorted(filenames):
            path = Path(dirpath) / name
            if exts is None or path.suffix in exts:
                yield path


def rel(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def context_lines(path: Path, line: int, radius: int = 2) -> list[str]:
    lines = read_lines(path)
    if not lines or line < 1:
        return []
    start = max(1, line - radius)
    end = min(len(lines), line + radius)
    out = []
    for number in range(start, end + 1):
        marker = ">" if number == line else " "
        out.append(f"{marker}{number:5d} | {lines[number - 1].rstrip()}")
    return out


# --------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------

def layout_findings(paths: list[str]) -> list[Finding]:
    """Check project-owned path hygiene without flattening standard tool layouts."""
    findings = []
    children: dict[str, set[str]] = defaultdict(set)
    spellings: dict[str, str] = {}
    packages = {p.rsplit("/", 1)[0] for p in paths if p.endswith("/Package.swift")}
    for path in sorted(paths):
        parts = path.split("/")
        for index, name in enumerate(parts):
            prefix = "/".join(parts[:index + 1])
            if name != name.strip() or any(ord(c) < 32 for c in name):
                findings.append(Finding("repository-layout", "error",
                    "Path contains leading/trailing whitespace or control characters.", path, 1, 1))
                break
            key = unicodedata.normalize("NFC", prefix).casefold()
            previous = spellings.setdefault(key, prefix)
            if previous != prefix:
                findings.append(Finding("repository-layout", "error",
                    f"Path collides with {previous!r} on case-insensitive filesystems.", path, 1, 1))
                break
            if index:
                children["/".join(parts[:index])].add(name)
    for parent, names in sorted(children.items()):
        if len(names) != 1:
            continue
        child = next(iter(names))
        if parent + "/" + child not in children:
            continue  # A directory with a single FILE is fine.
        if parent == "Vendor" or parent.startswith("Vendor/") or any(
                p.endswith((".xcodeproj", ".xcworkspace")) for p in parent.split("/")):
            continue  # Preserve upstream/Xcode-owned hierarchies.
        if parent.endswith("/Sources") and parent.rsplit("/", 1)[0] in packages:
            continue  # SwiftPM requires Sources/<target>; it is not redundant.
        findings.append(Finding("repository-layout", "error",
            f"Redundant single-child folder chain {parent}/{child}; flatten it unless required by a tool layout.",
            parent, 1, 1))
    return findings


def check_repository_layout(root: Path, report: Report) -> list[str]:
    # Git excludes generated trees; include new files so the pre-commit command
    # sees a move before git add. Deleted paths in the index are not inspected.
    result = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                            cwd=root, capture_output=True, check=False)
    if result.returncode:
        report.add(Finding("repository-layout", "error", "Cannot inventory repository paths; run inside a Git checkout."))
        return []
    paths = sorted({os.fsdecode(p) for p in result.stdout.split(b"\0") if p and (root / os.fsdecode(p)).exists()})
    for finding in layout_findings(paths):
        report.add(finding)
    report.stats["repository_paths_checked"] = len(paths)
    return paths


def check_tool_syntax(root: Path, paths: list[str], report: Report) -> None:
    """Compile Python syntax and parse shell scripts, without running their code."""
    bash = shutil.which("bash")
    checked = 0
    for name in paths:
        path = root / name
        if name.startswith("Vendor/") or path.suffix not in {".py", ".sh"}:
            continue
        if path.is_symlink():
            continue
        checked += 1
        if path.suffix == ".py":
            try:
                compile(path.read_bytes(), name, "exec")
            except (SyntaxError, UnicodeError, ValueError) as exc:
                report.add(Finding("tool-syntax", "error", f"Python syntax: {exc}", name,
                                   getattr(exc, "lineno", 1), 1))
        elif bash:
            try:
                result = subprocess.run([bash, "-n", "--", str(path)], capture_output=True, text=True, timeout=20)
                if result.returncode:
                    report.add(Finding("tool-syntax", "error", f"Shell syntax: {result.stderr.strip()}", name, 1, 1))
            except subprocess.TimeoutExpired:
                report.add(Finding("tool-syntax", "error", "Shell syntax check timed out.", name, 1, 1))
        else:
            report.add(Finding("tool-syntax", "warning", "bash unavailable; shell syntax not checked.", name, 1, 1))
    report.stats["tool_files_checked"] = checked


def check_script_inputs(root: Path, project: Path, text: str, report: Report) -> None:
    """Validate declared source inputs, not generated output/runtime paths."""
    for block in re.finditer(r"inputPaths = \((.*?)\);", text, re.S):
        for match in re.finditer(r'"([^"\n]+)"', block.group(1)):
            value = match.group(1)
            relative = None
            for prefix in ("$(SRCROOT)/", "${SRCROOT}/", "$(PROJECT_DIR)/", "${PROJECT_DIR}/"):
                if value.startswith(prefix):
                    relative = value[len(prefix):]
                    break
            if relative is None or "$" in relative:
                continue  # Unknown runtime variables cannot be resolved offline.
            if not (root / relative).exists():
                line = text[:block.start()].count("\n") + 1
                report.add(Finding("pbxproj", "error", f"Build script source input does not exist: {value}",
                                   rel(root, project), line, 1))


def check_conflict_markers(root: Path, report: Report) -> None:
    count = 0
    for path in iter_files(root, TEXT_EXTS):
        for number, text in enumerate(read_lines(path), start=1):
            if CONFLICT_RE.match(text):
                count += 1
                report.add(Finding("conflict-markers", "error",
                                   "Unresolved merge conflict marker - finish the merge before building.",
                                   rel(root, path), number, 1, context_lines(path, number)))
                if count >= 100:
                    return
    report.stats["conflict_markers"] = count


def swift_files_for(root: Path, module_dir: str) -> list[Path]:
    base = root / module_dir
    if not base.is_dir():
        return []
    return [p for p in iter_files(base, {".swift"})]


def check_swift_syntax(root: Path, report: Report, swiftc: str | None, *, intentionally_skipped: bool = False) -> None:
    if intentionally_skipped:
        report.stats["swift_syntax_skipped"] = 1
        return
    if not swiftc:
        report.add(Finding("swift-syntax", "warning",
                           "swiftc not found - the Swift syntax check was skipped (run inside the swift container)."))
        return
    total = 0
    module_dirs: dict[str, list[str]] = {name: [d] for name, d in SWIFT_MODULES.items()}
    for name, dirs in PARSE_ONLY_MODULES.items():
        module_dirs.setdefault(name, []).extend(dirs)
    for module, dirs in module_dirs.items():
        files = [p for d in dirs for p in swift_files_for(root, d)]
        if not files:
            continue
        total += len(files)
        # One `swiftc -parse` per module. -parse stops after parsing: no type
        # checking, no imports resolved, so no SDK is needed. Batches keep the
        # command line short and isolate a crash to a few files.
        batch_size = 60
        for start in range(0, len(files), batch_size):
            batch = files[start:start + batch_size]
            cmd = [swiftc, "-parse", "-suppress-warnings", "-module-name", module] + [str(p) for p in batch]
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
            except subprocess.TimeoutExpired:
                report.add(Finding("swift-syntax", "error", f"swiftc -parse timed out for module {module}"))
                continue
            output = (proc.stderr or "") + (proc.stdout or "")
            if proc.returncode == 0 and "error:" not in output:
                continue
            seen = set()
            for text in output.splitlines():
                match = DIAG_RE.match(text)
                if not match or match["sev"] != "error":
                    continue
                path = Path(match["file"])
                key = (path.as_posix(), match["line"], match["col"], match["msg"])
                if key in seen:
                    continue
                seen.add(key)
                report.add(Finding("swift-syntax", "error", match["msg"].strip(), rel(root, path),
                                   int(match["line"]), int(match["col"]), context_lines(path, int(match["line"]))))
            if proc.returncode != 0 and not seen:
                tail = "\n".join(output.strip().splitlines()[-15:])
                report.add(Finding("swift-syntax", "error",
                                   f"swiftc -parse failed for module {module} without a file diagnostic:\n{tail}"))
    report.stats["swift_files_parsed"] = total


def check_duplicate_types(root: Path, report: Report) -> None:
    dupes = 0
    for module, module_dir in SWIFT_MODULES.items():
        decls: dict[tuple[str, str], list[tuple[Path, int, bool]]] = defaultdict(list)
        for path in swift_files_for(root, module_dir):
            depth = 0
            for number, text in enumerate(read_lines(path), start=1):
                if IF_RE.match(text):
                    depth += 1
                    continue
                if ENDIF_RE.match(text):
                    depth = max(0, depth - 1)
                    continue
                if text[:1].isspace() or not text:
                    continue  # only column-0 declarations are top level
                match = DECL_RE.match(text)
                if match:
                    decls[(match["kind"], match["name"])].append((path, number, depth > 0))
        for (kind, name), places in decls.items():
            if len(places) < 2:
                continue
            # Nested inside #if: could be mutually exclusive branches - warn only.
            conditional = any(place[2] for place in places)
            dupes += 1
            others = ", ".join(f"{rel(root, p)}:{n}" for p, n, _ in places[1:])
            first_path, first_line, _ = places[0]
            sev = "warning" if conditional else "error"
            note = " (inside #if - verify the branches are exclusive)" if conditional else ""
            report.add(Finding("duplicate-types", sev,
                               f"{kind} {name} is declared more than once in module {module}: also at {others}{note}",
                               rel(root, first_path), first_line, 1, context_lines(first_path, first_line, 1)))
    report.stats["duplicate_types"] = dupes


def check_cross_module_imports(root: Path, report: Report) -> None:
    """Flag symbols whose module is not imported in the file that uses them."""
    offenders = 0
    library_modules = {"NimbleExtensions", "NimbleViews", "AltSourceKit", "NimbleJSON"}
    for module, module_dir in SWIFT_MODULES.items():
        if module in library_modules:
            continue  # the libraries define these symbols
        for path in swift_files_for(root, module_dir):
            source = path.read_text(encoding="utf-8", errors="replace")
            imports = set(re.findall(r"^import (\w+)", source, re.M))
            # Comments are not code: strip them before matching.
            code = re.sub(r"//[^\n]*", "", source)
            for provider, pattern in CROSS_MODULE_SYMBOLS.items():
                if provider in imports:
                    continue
                match = re.search(pattern, code)
                if not match:
                    continue
                line = code[: match.start()].count("\n") + 1
                offenders += 1
                report.add(Finding(
                    "cross-module-imports", "error",
                    f"uses {match.group(0).strip()} from {provider} but does not `import {provider}`",
                    rel(root, path), line, 1, context_lines(path, line, 1)))
    report.stats["cross_module_imports"] = offenders


def check_duplicate_filenames(root: Path, report: Report) -> None:
    dupes = 0
    for module, module_dir in SWIFT_MODULES.items():
        by_name: dict[str, list[Path]] = defaultdict(list)
        for path in swift_files_for(root, module_dir):
            by_name[path.name].append(path)
        for name, paths in by_name.items():
            if len(paths) < 2:
                continue
            dupes += 1
            others = ", ".join(rel(root, p) for p in paths[1:])
            report.add(Finding("duplicate-filenames", "error",
                               f"{name} exists more than once in target {module} (Xcode: filename used twice): {others}",
                               rel(root, paths[0]), 1, 1))
    report.stats["duplicate_filenames"] = dupes


def check_resources(root: Path, report: Report) -> None:
    checked = 0
    for path in iter_files(root, {".plist", ".entitlements", ".xcstrings", ".json", ".xcscheme", ".xcworkspacedata",
                                  ".storyboard", ".xib", ".stringsdict"}):
        if path.name == "Package.resolved" or path.suffix in {".json", ".xcstrings"}:
            kind = "json"
        elif path.suffix in {".plist", ".entitlements", ".stringsdict"}:
            kind = "plist"
        else:
            kind = "xml"
        checked += 1
        try:
            data = path.read_bytes()
            if kind == "json":
                json.loads(data.decode("utf-8"))
            elif kind == "plist":
                plistlib.loads(data)
            else:
                ET.fromstring(data)
        except Exception as exc:  # noqa: BLE001 - any parse failure is the finding
            line = None
            match = re.search(r"line (\d+)", str(exc))
            if match:
                line = int(match.group(1))
            report.add(Finding("resources", "error", f"{path.suffix[1:]} does not parse: {exc}",
                               rel(root, path), line or 1, 1, context_lines(path, line) if line else []))
    report.stats["resources_checked"] = checked


def check_pbxproj(root: Path, report: Report) -> None:
    for path in iter_files(root, {".pbxproj"}):
        text = path.read_text(encoding="utf-8", errors="replace")
        check_script_inputs(root, path, text, report)
        # Strip comments and quoted strings before counting delimiters.
        stripped = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        stripped = re.sub(r'"(?:\\.|[^"\\])*"', '""', stripped)
        braces = stripped.count("{") - stripped.count("}")
        parens = stripped.count("(") - stripped.count(")")
        if braces or parens:
            report.add(Finding("pbxproj", "error",
                               f"project.pbxproj looks corrupted: unbalanced {{}} ({braces:+d}) / () ({parens:+d}). "
                               "Usually a bad merge - resolve it in a text editor or restore the file from main.",
                               rel(root, path), 1, 1))
        if "objectVersion = 77" in text and not re.search(r"isa = PBXFileSystemSynchronizedRootGroup", text):
            report.add(Finding("pbxproj", "warning",
                               "objectVersion 77 without synchronized groups - new Swift files may not be picked up.",
                               rel(root, path), 1, 1))


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

def annotate(finding: Finding) -> None:
    props = []
    if finding.file:
        props.append(f"file={finding.file}")
        if finding.line:
            props.append(f"line={finding.line}")
        if finding.col:
            props.append(f"col={finding.col}")
    props.append(f"title=quick-check/{finding.check}")
    msg = finding.message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{finding.severity} {','.join(props)}::{msg}")


def render_summary(report: Report, swiftc_version: str) -> str:
    errors, warnings = report.errors, report.warnings
    verdict = "✅ no build-breaking problems found" if not errors else f"❌ {len(errors)} error(s)"
    out = [f"## Quick check (no build) — {verdict}", ""]
    if report.stats.get("swift_syntax_skipped"):
        out.append("Swift syntax **not checked** (explicit `--no-swiftc`); native/compiler validation is separate.")
        out.append(f"Checked {report.stats.get('resources_checked', 0)} resource files.")
    else:
        out.append(f"Parsed {report.stats.get('swift_files_parsed', 0)} Swift files with `swiftc -parse` "
                   f"({swiftc_version or 'swiftc unavailable'}), checked {report.stats.get('resources_checked', 0)} resource files.")
    out.append("")
    out.append("| Check | Errors | Warnings |")
    out.append("|---|---:|---:|")
    for check in ["repository-layout", "tool-syntax", "conflict-markers", "swift-syntax", "duplicate-types", "duplicate-filenames",
                  "cross-module-imports", "resources", "pbxproj"]:
        e = sum(1 for f in errors if f.check == check)
        w = sum(1 for f in warnings if f.check == check)
        label = "swift-syntax (skipped)" if check == "swift-syntax" and report.stats.get("swift_syntax_skipped") else check
        out.append(f"| {label} | {e} | {w} |")
    out.append("")

    if errors:
        out.append("### Fix these first")
        out.append("")
        for finding in errors[:MAX_CONTEXT_ISSUES]:
            where = f"`{finding.file}:{finding.line}`" if finding.file else "(project)"
            out.append(f"- **{finding.check}** {where} — {finding.message.splitlines()[0]}")
            if finding.context:
                out.append("")
                out.append("  ```text")
                out.extend("  " + line for line in finding.context)
                out.append("  ```")
        if len(errors) > MAX_CONTEXT_ISSUES:
            out.append(f"- … {len(errors) - MAX_CONTEXT_ISSUES} more (see annotations / quick-check.json)")
        out.append("")
        out.append("These checks catch source/resource errors and repository drift before Xcode. "
                   "Push a fix and this check re-runs in about a minute; the full build follows once it is clean.")
        out.append("")

    if warnings:
        out.append("<details><summary>Warnings (advisory)</summary>")
        out.append("")
        for finding in warnings[:50]:
            where = f"`{finding.file}:{finding.line}`" if finding.file else ""
            out.append(f"- **{finding.check}** {where} — {finding.message.splitlines()[0]}")
        out.append("")
        out.append("</details>")
        out.append("")
    return "\n".join(out)


def run_self_tests() -> int:
    import tempfile
    import unittest

    class RepositoryChecksTests(unittest.TestCase):
        def test_single_file_is_not_redundant(self):
            self.assertEqual(layout_findings(["Tweaks/FilePickerFix.m"]), [])

        def test_redundant_chain_detected(self):
            findings = layout_findings(["Tweaks/FilePickerFix/FilePickerFix.m"])
            self.assertTrue(any("single-child" in f.message for f in findings))

        def test_standard_layouts_preserved(self):
            paths = ["Kit/Package.swift", "Kit/Sources/Kit/File.swift",
                     "Vendor/Bridge/Sources/Target/File.swift",
                     "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme",
                     "App.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
            self.assertEqual(layout_findings(paths), [])

        def test_case_and_unicode_collisions(self):
            for paths in (["Views/A.swift", "views/B.swift"],
                          ["Views/Café.swift", "Views/Cafe\u0301.swift"]):
                self.assertTrue(any("collides" in f.message for f in layout_findings(paths)))

        def test_hidden_whitespace(self):
            self.assertTrue(layout_findings(["Sources/ bad.swift"]))

        def test_intentional_swift_skip_is_distinct_from_missing_compiler(self):
            report = Report(Path("."))
            check_swift_syntax(Path("."), report, None, intentionally_skipped=True)
            self.assertFalse(report.findings)
            self.assertIn("not checked", render_summary(report, ""))
            self.assertIn("swift-syntax (skipped)", render_summary(report, ""))
            missing = Report(Path("."))
            check_swift_syntax(Path("."), missing, None)
            self.assertEqual(len(missing.warnings), 1)

        def test_tool_syntax_does_not_execute_code(self):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "good.py").write_text("raise RuntimeError('must not run')\n")
                (root / "good.sh").write_text("exit 99\n")
                report = Report(root)
                check_tool_syntax(root, ["good.py", "good.sh"], report)
                self.assertEqual(report.errors, [])

        def test_tool_syntax_reports_errors(self):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "bad.py").write_text("def broken(:\n")
                (root / "bad.sh").write_text("if then\n")
                report = Report(root)
                check_tool_syntax(root, ["bad.py", "bad.sh"], report)
                expected = 2 if shutil.which("bash") else 1
                self.assertEqual(len(report.errors), expected)

        def test_script_input_rename(self):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "Tweaks").mkdir()
                (root / "Tweaks/FilePickerFix.m").touch()
                project = root / "Project.xcodeproj/project.pbxproj"
                for value, errors in (("$(SRCROOT)/Tweaks/FilePickerFix.m", 0),
                                      ("$(SRCROOT)/Tweaks/FilePickerFix/FilePickerFix.m", 1),
                                      ("$(BUILT_PRODUCTS_DIR)/FilePickerFix.dylib", 0)):
                    report = Report(root)
                    check_script_inputs(root, project, 'inputPaths = ("' + value + '");', report)
                    self.assertEqual(len(report.errors), errors)

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RepositoryChecksTests))
    return 0 if result.wasSuccessful() else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true", help="run offline layout/build-input regressions")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--json", help="write findings as JSON to this path")
    parser.add_argument("--no-swiftc", action="store_true", help="skip the swiftc -parse check")
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    parser.add_argument("--no-annotations", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return run_self_tests()

    root = Path(args.root).resolve()
    report = Report(root)

    swiftc = None if args.no_swiftc else (os.environ.get("SWIFTC") or shutil.which("swiftc"))
    swiftc_version = ""
    if swiftc:
        try:
            swiftc_version = subprocess.run([swiftc, "--version"], capture_output=True, text=True, timeout=60).stdout.splitlines()[0]
        except Exception:  # noqa: BLE001
            swiftc_version = swiftc

    paths = check_repository_layout(root, report)
    check_tool_syntax(root, paths, report)
    check_conflict_markers(root, report)
    check_swift_syntax(root, report, swiftc, intentionally_skipped=args.no_swiftc)
    check_duplicate_types(root, report)
    check_duplicate_filenames(root, report)
    check_cross_module_imports(root, report)
    check_resources(root, report)
    check_pbxproj(root, report)

    if not args.no_annotations:
        for finding in report.findings[:300]:
            annotate(finding)

    summary = render_summary(report, swiftc_version)
    print()
    print(summary)
    if args.summary:
        try:
            with open(args.summary, "a", encoding="utf-8") as handle:
                handle.write(summary + "\n")
        except OSError as exc:
            print(f"::warning::could not write the step summary: {exc}")

    if args.json:
        payload = {
            "root": str(root),
            "swiftc": swiftc_version,
            "stats": dict(report.stats),
            "errors": len(report.errors),
            "warnings": len(report.warnings),
            "findings": [asdict(f) for f in report.findings],
        }
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(json.dumps(payload, indent=2), encoding="utf-8")

    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
