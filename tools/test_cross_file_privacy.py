#!/usr/bin/env python3
"""Regression guard: a `private` member must stay inside the file that declares it.

Swift's `private` is *file*-scoped, not type-scoped. For a type split across
several files — `DownloadManager.swift` plus its `+TransferControl`,
`+PackageImport`, `+Recovery`, `+LiveActivity` and `+Delegates` extensions — a
`private` member declared in one file is invisible from another, and the
compiler says so:

    'ensureKeepAlive' is inaccessible due to 'private' protection level

That is easy to introduce and easy to miss. A file split moves bodies without
editing them, every local check passes (there is no Swift typechecker among them),
and the breakage appears only in the macOS jobs. It happened in this repository:
splitting `DownloadManager` moved code that used five `private` members and broke
the build, caught by run 43108652953 after the portable gates were green.

`fileprivate` is the correct fix — it keeps the member out of the public
interface while letting the extensions that form one type reach it.

What is checked: for each group of files that extend the same type, every
`private` member must not be referenced from a file in the group that does not
declare it. `fileprivate` members are skipped: being cross-file is their purpose.
"""

from __future__ import annotations

import re
import sys
import unittest
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT_ROOTS = [ROOT / "VexSign", ROOT / "NativeSigning", ROOT / "NimbleKit", ROOT / "SideSign"]
SKIP_DIRS = {"Vendor", ".build", "build", "DerivedData", "Pods", "node_modules", ".git"}

# `private`/`fileprivate` followed by optional modifiers and then `func|var|let`.
# The keyword is required: without it this matches a parameter named `destination`
# and reports every local variable that happens to share a member's name.
DECL = re.compile(
    r"^[ \t]*(?:(?:@\w+)[ \t]+)*(private|fileprivate)[ \t]+"
    r"(?:(?:static|class|override|final|nonisolated|weak|lazy|mutating)[ \t]+)*"
    r"(?:func|var|let)[ \t]+(\w+)"
)

# `extension Foo {` / `struct Foo:` — the type a file contributes to.
#
# Deliberately NOT a regex over the whole file: an attribute prefix such as
# `(?:@\w+[^\n]*\n[ \t]*)*` backtracks exponentially on a class with many
# consecutive `@Published` lines, and `Download.swift` has dozens. That hung this
# check for minutes. A line-at-a-time scan has the same meaning and no backtracking.
TYPE_DECL = re.compile(r"^[ \t]*(?:public |internal |open )?(?:final )?"
                       r"(class|struct|enum|actor|extension)[ \t]+(\w+)")
ATTRIBUTE_LINE = re.compile(r"^[ \t]*@\w+")


def swift_files() -> list[Path]:
    out: list[Path] = []
    for root in SWIFT_ROOTS:
        if not root.is_dir():
            continue
        for path in root.rglob("*.swift"):
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            out.append(path)
    return sorted(out)


def strip_comments_and_strings(text: str) -> str:
    """Blunt but safe: blank out comments and string bodies so references are real."""
    out: list[str] = []
    i = 0
    in_string = False
    escape = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
                out.append('"')
            else:
                out.append(" ")
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append('"')
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end == -1 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end == -1 else end + 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


_STRIPPED: dict[Path, str] = {}


def stripped(path: Path) -> str:
    """Comment- and string-free source, read once. The scan is O(files x members)."""
    if path not in _STRIPPED:
        _STRIPPED[path] = strip_comments_and_strings(
            path.read_text(encoding="utf-8", errors="replace")
        )
    return _STRIPPED[path]


# A Swift file can declare several types. `WebManagerServer.swift` also holds
# `WebManagerUploadFile`, whose `private let destination` is nothing to do with
# `WebManagerServer`. Attribution therefore has to follow braces, not files.
TYPE_START = re.compile(r"^[ \t]*(?:public |internal |open )?(?:final )?"
                        r"(class|struct|enum|actor|extension)[ \t]+(\w+)")


def private_members_by_type(path: Path) -> dict[str, str]:
    """member name -> the type it is `private` inside, for this file."""
    found: dict[str, str] = {}
    stack: list[str | None] = []
    pending: str | None = None
    for line in stripped(path).splitlines():
        start = TYPE_START.match(line)
        if start:
            pending = start.group(2)
        decl = DECL.match(line)
        if decl and decl.group(1) == "private":
            owner = next((t for t in reversed(stack) if t), None)
            if owner:
                found.setdefault(decl.group(2), owner)
        for ch in line:
            if ch == "{":
                stack.append(pending)
                pending = None
            elif ch == "}" and stack:
                stack.pop()
    return found


def module_of(path: Path) -> str:
    """Files in different targets are separate modules; `private` never spans them."""
    return path.relative_to(ROOT).parts[0]


_EXTENDED: dict[Path, set[str]] = {}


def extended_types(path: Path) -> set[str]:
    """Types this file adds an `extension` to. A `class` declaration does NOT count.

    Only extensions put a file's code inside another file's type. Without this
    distinction a private member of some unrelated class declared in the same file
    (`WebManagerUploadFile.destination`) looked like it belonged to the type the
    file is named after, and every local variable called `destination` in a
    sibling file was reported.
    """
    if path not in _EXTENDED:
        found: set[str] = set()
        for line in stripped(path).splitlines():
            if ATTRIBUTE_LINE.match(line):
                continue
            match = TYPE_DECL.match(line)
            if match and match.group(1) == "extension":
                found.add(match.group(2))
        _EXTENDED[path] = found
    return _EXTENDED[path]


def declared_types(path: Path) -> set[str]:
    """Type names this file declares or extends, ignoring attribute lines above them."""
    found: set[str] = set()
    for line in stripped(path).splitlines():
        if ATTRIBUTE_LINE.match(line):
            continue
        match = TYPE_DECL.match(line)
        if match:
            found.add(match.group(2))
    return found


def type_groups():
    """Map (module, type) to the files that declare or extend it in that module."""
    groups: dict[tuple[str, str], set[Path]] = defaultdict(set)
    for path in swift_files():
        for name in declared_types(path):
            groups[(module_of(path), name)].add(path)
    return {key: files for key, files in groups.items() if len(files) > 1}


def cross_file_private_violations() -> list[str]:
    violations: list[str] = []
    for (module, type_name), files in sorted(type_groups().items()):
        private_members: dict[str, Path] = {}
        for path in files:
            # Only members `private` *inside* `type_name`. A `private` member of some
            # other type declared in the same file is not this type's business.
            for member, owner_type in private_members_by_type(path).items():
                if owner_type == type_name:
                    private_members.setdefault(member, path)

        for member, owner in sorted(private_members.items()):
            for path in files:
                if path == owner:
                    continue
                if type_name not in extended_types(path):
                    continue
                code = stripped(path)
                for ref in re.finditer(r"(?<![\w])" + re.escape(member) + r"(?![\w])", code):
                    # `self.member` and bare `member` are this type's; `other.member`
                    # is a different object's member. Only `self.` was ever safe to skip,
                    # and skipping every `.` hid `self.releaseKeepAliveIfIdle()`.
                    before = code[max(0, ref.start() - 5) : ref.start()]
                    if before.endswith(".") and not before.endswith("self."):
                        continue
                    violations.append(
                        f"{path.relative_to(ROOT)} uses `{member}`, which is `private` in "
                        f"{owner.relative_to(ROOT)}; the {type_name} extensions in {module} span "
                        "files, so this does not compile — make it `fileprivate`"
                    )
                    break
    return violations


class CrossFilePrivacyTests(unittest.TestCase):
    def test_no_private_member_is_used_across_files(self):
        violations = cross_file_private_violations()
        self.assertEqual(
            violations,
            [],
            "Swift `private` is file-scoped, so these references cannot compile:\n  "
            + "\n  ".join(violations),
        )


if __name__ == "__main__":
    violations = cross_file_private_violations()
    if violations:
        for violation in violations:
            print(" -", violation)
        sys.exit(1)
    print("no `private` member is referenced from another file of the same type")
    unittest.main(verbosity=2, exit=False)
