#!/usr/bin/env python3
"""Keep Localizable.xcstrings in step with the literals the app asks for.

Every `"…".localized(…)` / `String.localized("…")` call is a catalogue key. When a key is missing
from `App/iOS/VexSign/Resources/Localizable.xcstrings`, iOS falls back to the literal — which works in
English and silently breaks every other language, so the drift is invisible until someone runs the
app in German.

Usage:

    python3 Tools/Development/sync-strings.py --check    # exit 1 and list what is missing (CI)
    python3 Tools/Development/sync-strings.py --write    # add the missing keys with their English value

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

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOGUE = ROOT / "App/iOS/VexSign" / "Resources" / "Localizable.xcstrings"
SOURCE_ROOT = ROOT / "App/iOS/VexSign"

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


def source_blob():
    """All app Swift source as one string, for the stale-key presence guard."""
    parts = []
    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        try:
            parts.append(path.read_text(encoding="utf-8"))
        except UnicodeDecodeError:
            continue
    return "\n".join(parts)


def key_in_source(key, blob):
    """True when the key appears as a quoted literal anywhere in the app source.

    Broader than `collect()` (which only sees `.localized("…")`): a stale key that
    still appears in a `Text("…")` or any other literal must never be pruned.
    """
    escaped = json.dumps(key, ensure_ascii=False)[1:-1]
    return f'"{escaped}"' in blob or f'"{key}"' in blob


def stale_absent_keys(data, blob):
    """Stale catalogue keys that no longer appear as a literal in the source."""
    return sorted(
        key for key, entry in data.get("strings", {}).items()
        if entry.get("extractionState") == "stale" and not key_in_source(key, blob)
    )


def prune_stale(remove):
    """Delete the given keys, preserving Xcode's exact catalogue formatting.

    The file round-trips byte-for-byte with these dump settings, so the diff is
    limited to the removed entries instead of reformatting every key.
    """
    text = CATALOGUE.read_text(encoding="utf-8")
    data = json.loads(text)
    before = len(data["strings"])
    for key in remove:
        data["strings"].pop(key, None)
    updated = json.dumps(data, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n"
    after = json.loads(updated)["strings"]
    if len(after) != before - len(remove) or any(key in after for key in remove):
        raise SystemExit("refusing to write: the pruned catalogue did not validate")
    CATALOGUE.write_text(updated, encoding="utf-8")
    return updated


def coverage_report(data, markdown=False):
    """Per-language translation coverage across every catalogue key."""
    strings = data.get("strings", {})
    total = len(strings)
    languages = set()
    for entry in strings.values():
        languages.update(entry.get("localizations", {}).keys())
    languages.discard(data.get("sourceLanguage", "en"))
    rows = []
    for lang in sorted(languages):
        translated = 0
        for entry in strings.values():
            loc = entry.get("localizations", {}).get(lang)
            if not loc:
                continue
            unit = loc.get("stringUnit", {})
            if unit.get("state") == "translated" or "variations" in loc or "substitutions" in loc:
                translated += 1
        pct = (100.0 * translated / total) if total else 0.0
        rows.append((lang, translated, total - translated, pct))
    stale = sum(1 for e in strings.values() if e.get("extractionState") == "stale")
    if markdown:
        lines = [f"### Localisation coverage ({total} keys, {stale} marked stale)", "",
                 "| Language | Translated | Missing | Coverage |",
                 "| --- | ---: | ---: | ---: |"]
        for lang, done, miss, pct in rows:
            lines.append(f"| {lang} | {done} | {miss} | {pct:.1f}% |")
        return "\n".join(lines)
    lines = [f"localisation coverage — {total} keys, {stale} marked stale"]
    for lang, done, miss, pct in rows:
        lines.append(f"  {lang:8} {done:5}/{total}  ({pct:5.1f}%)  missing {miss}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Sync Localizable.xcstrings with the app's literals.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="fail when a literal has no catalogue key")
    group.add_argument("--write", action="store_true", help="add the missing keys with their English value")
    group.add_argument("--prune-stale", action="store_true",
                       help="remove stale keys that no longer appear in the source (never touches in-use keys)")
    group.add_argument("--report", action="store_true", help="print per-language translation coverage")
    parser.add_argument("--markdown", action="store_true", help="with --report, emit a Markdown table for CI summaries")
    parser.add_argument("--limit", type=int, default=40, help="how many missing keys to print")
    arguments = parser.parse_args()

    keys, dynamic, scanned = collect()
    data = catalog()
    missing = missing_keys(keys, data)
    total = len(data.get("strings", {}))

    if arguments.report:
        print(coverage_report(data, markdown=arguments.markdown))
        return 0

    if arguments.prune_stale:
        remove = stale_absent_keys(data, source_blob())
        if not remove:
            print("no stale-and-absent keys to prune")
            return 0
        prune_stale(remove)
        print(f"pruned {len(remove)} stale key(s) absent from the source; {total - len(remove)} catalogue keys remain")
        for key in remove[: arguments.limit]:
            print(f"  {json.dumps(key, ensure_ascii=False)}")
        return 0

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

    print(f"❌ {len(missing)} literal(s) have no catalogue key (run: python3 Tools/Development/sync-strings.py --write)")
    for key in missing[: arguments.limit]:
        files = ", ".join(keys[key][:2])
        print(f"  {json.dumps(key, ensure_ascii=False)} — {files}")
    if len(missing) > arguments.limit:
        print(f"  … and {len(missing) - arguments.limit} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
