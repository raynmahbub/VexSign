#!/usr/bin/env python3
"""Keep Localizable.xcstrings in step with the literals the app asks for.

Every `"…".localized(…)` / `String.localized("…")` call is a catalogue key. When a key is missing
from `VexSign/Resources/Localizable.xcstrings`, iOS falls back to the literal — which works in
English and silently breaks every other language, so the drift is invisible until someone runs the
app in German.

Usage:

    python3 tools/sync-strings.py --check    # exit 1 and list what is missing (CI)
    python3 tools/sync-strings.py --write    # add the missing keys with their English value

The check fails on drift only. It never asks for translations: new keys are added as
`extractionState: manual` with the English literal as their `en` value, which is exactly the state
an untranslated key is supposed to be in. Machine translation is deliberately not attempted.

Interpolated literals (`"... \\(value)"`) are reported separately and never added: their runtime
value is not a stable key, so a catalogue entry for them would be dead weight.

The catalogue is edited textually — new entries are appended to the existing `"strings"` object —
so the diff stays additive instead of reformatting 1,400 keys the way a JSON round-trip would.
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "VexSign" / "Resources" / "Localizable.xcstrings"
SOURCE_ROOT = ROOT / "VexSign"

# `.localized("…")` covers `String.localized("…")`, `LocalizedStringKey.localized("…")` and
# `"…".localized()` is not a catalogue key, so only the call form is matched.
CALL = re.compile(r'\.localized\(\s*"((?:[^"\\]|\\.)*)"')
INTERPOLATION = re.compile(r'\\\(')

UNESCAPE = {"\\": "\\", '"': '"', "n": "\n", "t": "\t", "r": "\r", "0": "\0"}


def _unescape(literal):
    out = []
    index = 0
    while index < len(literal):
        character = literal[index]
        if character != "\\" or index + 1 >= len(literal):
            out.append(character)
            index += 1
            continue
        following = literal[index + 1]
        out.append(UNESCAPE.get(following, following))
        index += 2
    return "".join(out)


def collect():
    """Returns (keys -> sorted files, dynamic literals, files scanned)."""
    keys = {}
    dynamic = []
    scanned = 0

    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        scanned += 1
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue

        relative = path.relative_to(ROOT).as_posix()
        for match in CALL.finditer(text):
            literal = match.group(1)
            if INTERPOLATION.search(literal):
                dynamic.append((relative, literal))
                continue
            key = _unescape(literal)
            if not key.strip():
                continue
            keys.setdefault(key, set()).add(relative)

    return {key: sorted(files) for key, files in keys.items()}, dynamic, scanned


def catalog():
    return json.loads(CATALOGUE.read_text(encoding="utf-8"))


def missing_keys(keys, catalogue):
    present = catalogue.get("strings", {})
    return sorted(key for key in keys if key not in present)


def entry_block(key):
    quoted = json.dumps(key, ensure_ascii=False)
    value = json.dumps(key, ensure_ascii=False)
    return (
        f'    {quoted} : {{\n'
        f'      "extractionState" : "manual",\n'
        f'      "localizations" : {{\n'
        f'        "en" : {{\n'
        f'          "stringUnit" : {{\n'
        f'            "state" : "translated",\n'
        f'            "value" : {value}\n'
        f'          }}\n'
        f'        }}\n'
        f'      }}\n'
        f'    }}'
    )


def write(keys):
    """Appends the entries textually, keeping the rest of the file byte-identical."""
    text = CATALOGUE.read_text(encoding="utf-8")
    marker = '\n  },\n  "version"'
    index = text.rindex(marker)
    head, tail = text[:index], text[index:]

    block = ",\n".join(entry_block(key) for key in keys)
    updated = f"{head},\n{block}{tail}"

    # Refuse to write anything that would not parse or would lose an entry.
    before = json.loads(text)["strings"]
    after = json.loads(updated)["strings"]
    if len(after) != len(before) + len(keys) or any(key not in after for key in keys):
        raise SystemExit("refusing to write: the merged catalogue did not validate")

    CATALOGUE.write_text(updated, encoding="utf-8")
    return updated


def main():
    parser = argparse.ArgumentParser(description="Sync Localizable.xcstrings with the app's literals.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="fail when a literal has no catalogue key")
    group.add_argument("--write", action="store_true", help="add the missing keys with their English value")
    parser.add_argument("--limit", type=int, default=40, help="how many missing keys to print")
    arguments = parser.parse_args()

    keys, dynamic, scanned = collect()
    data = catalog()
    missing = missing_keys(keys, data)
    total = len(data.get("strings", {}))

    print(f"scanned {scanned} Swift files · {len(keys)} distinct literals · {total} catalogue keys")

    if dynamic:
        print(f"{len(dynamic)} interpolated literal(s) are not catalogue keys:")
        for relative, literal in dynamic[:5]:
            print(f"  {relative}: \"{literal}\"")

    if arguments.write:
        if not missing:
            print("nothing to add — the catalogue already covers every literal")
            return 0
        write(missing)
        print(f"added {len(missing)} key(s): {len(keys)} literals · {total + len(missing)} catalogue keys")
        return 0

    if not missing:
        print("✅ every literal has a catalogue key")
        return 0

    print(f"❌ {len(missing)} literal(s) have no catalogue key (run: python3 tools/sync-strings.py --write)")
    for key in missing[: arguments.limit]:
        files = ", ".join(keys[key][:2])
        print(f"  {json.dumps(key, ensure_ascii=False)} — {files}")
    if len(missing) > arguments.limit:
        print(f"  … and {len(missing) - arguments.limit} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
