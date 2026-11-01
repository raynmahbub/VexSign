#!/usr/bin/env python3
"""Parse every Swift file in the repository with tree-sitter and report syntax errors.

There is no Swift toolchain on Linux and the real compile happens in CI on macOS
(`.github/workflows/ci.yml`), so this is the local guard against a stray brace,
unbalanced parenthesis or truncated string before a build is spent on it.

    python3 tools/check-swift-syntax.py            # check the whole repo
    python3 tools/check-swift-syntax.py path …     # check files or directories

Only real `ERROR`/`MISSING` nodes count as failures. tree-sitter-swift sets `has_error`
on some zero-width `custom_operator` nodes (`as?` immediately followed by `??`) without
producing an error node at all — those are reported as notes and ignored.

Known grammar noise: about a dozen existing files (~12/296 on the tree this was written
against) trip the parser on valid Swift — `try await` on its own line, multi-part string
interpolation like `"\(a).\(b)"`. They are listed, so a *new* name in that list is the
signal; the baseline itself is not a real failure.

Exits non-zero when anything fails to parse.
"""

from __future__ import annotations

import sys
from pathlib import Path

import tree_sitter_swift
from tree_sitter import Language, Node, Parser

ROOT = Path(__file__).resolve().parents[1]

# Nothing here is ours to fix, and the submodules ship their own build.
SKIP = {".git", "Zsign", "IDeviceKitten", "_upstream_vexsign", ".build", "build"}


def swift_files(paths: list[str]) -> list[Path]:
    if not paths:
        paths = [str(ROOT)]
    found: list[Path] = []
    for raw in paths:
        path = Path(raw).resolve()
        if path.is_dir():
            for item in sorted(path.rglob("*.swift")):
                if SKIP.isdisjoint(item.relative_to(ROOT).parts):
                    found.append(item)
        elif path.suffix == ".swift":
            found.append(path)
    return found


def walk(node: Node):
    yield node
    for child in node.children:
        yield from walk(child)


def main() -> int:
    parser = Parser(Language(tree_sitter_swift.language()))
    files = swift_files(sys.argv[1:])
    failures = 0
    notes = 0

    for path in files:
        source = path.read_bytes()
        tree = parser.parse(source)
        errors = [node for node in walk(tree.root_node) if node.type == "ERROR" or node.is_missing]

        if not errors:
            notes += 1 if tree.root_node.has_error else 0
            continue

        failures += 1
        print(f"{path.relative_to(ROOT)}")
        for node in sorted(errors, key=lambda n: n.start_byte):
            row, column = node.start_point
            snippet = source[node.start_byte : node.end_byte][:120].decode("utf-8", "replace")
            label = "missing" if node.is_missing else "error"
            print(f"  {row + 1}:{column + 1}  {label} {node.type!r}  {snippet!r}")

    print(f"\n{files.__len__() - failures}/{files.__len__()} Swift files parse cleanly.", end="")
    print(f" ({notes} grammar quirk(s) ignored)" if notes else "")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
