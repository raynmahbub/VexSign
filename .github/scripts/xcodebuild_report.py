#!/usr/bin/env python3
"""Turn an xcodebuild log into GitHub annotations, a job summary and a verdict.

Used by .github/workflows/ci.yml after `xcodebuild ... build`.

    python3 xcodebuild_report.py --log build.log --build-exit 0 \
        --warnings-as-errors true --workspace "$GITHUB_WORKSPACE"

* Every compiler error becomes a `::error file=...` annotation (so it shows up
  inline on the pull request) and the job fails.
* Warnings in *first-party* code (VexSign, the widget, tests, AltSourceKit,
  NimbleKit) become annotations too and are treated as errors - without
  touching the Xcode project and without failing on warnings inside SwiftPM
  dependencies we do not own. Modes (--warnings-as-errors):
      true  (default)  new warnings fail; warnings listed in the committed
                       baseline (.github/build-warnings-baseline.json) are
                       reported but tolerated, so the gate can be adopted on
                       a codebase that already has warnings and only ever
                       ratchets down
      strict           every first-party warning fails (ignores the baseline)
      false            report only
  A fresh baseline reflecting the current warnings is always written next to
  the log (--baseline-out) so it can be committed when warnings were fixed.
* A build that failed without any parseable diagnostic (broken project file,
  failing script phase, linker) gets the log tail in the summary.

Pure stdlib. Exit status is the verdict: 0 = pass, 1 = fail.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

DIAG_RE = re.compile(r"^(?P<file>/[^:\n]+?):(?P<line>\d+):(?:(?P<col>\d+):)? (?P<sev>error|warning|note): (?P<msg>.*)$")
BARE_ERROR_RE = re.compile(r"^(?:xcodebuild: )?error: (?P<msg>.*)$")
# xcbeautify / xcpretty style lines are ignored - we only parse the raw log.

# Summary heading. The build job uses the default; the test job passes its
# own so a test run does not report itself as a build.
DEFAULT_TITLE = "Build"
DEFAULT_FIRST_PARTY = ["VexSign", "VexSignWidgetExtension", "VexSignTests", "AltSourceKit", "NimbleKit", "Tweaks"]
MAX_ANNOTATIONS = 200
MAX_LISTED = 80


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", required=True, help="raw xcodebuild log")
    parser.add_argument("--build-exit", type=int, default=0, help="exit status of xcodebuild")
    parser.add_argument("--warnings-as-errors", default="true",
                        help="true (fail on warnings not in the baseline), strict (fail on all), false (report only)")
    parser.add_argument("--baseline", default=".github/build-warnings-baseline.json",
                        help="JSON with known first-party warnings (file, message, count)")
    parser.add_argument("--baseline-out", default=None, help="write the current warnings as a baseline JSON here")
    parser.add_argument("--workspace", default=os.environ.get("GITHUB_WORKSPACE", os.getcwd()))
    parser.add_argument("--first-party", default=",".join(DEFAULT_FIRST_PARTY),
                        help="comma-separated top-level directories that count as our code")
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"), help="markdown summary file")
    parser.add_argument("--title", default=DEFAULT_TITLE, help='summary heading, e.g. "Unit tests"')
    return parser.parse_args()


def gate_mode(value: str) -> str:
    """-> 'baseline' | 'strict' | 'off'"""
    text = str(value).strip().lower()
    if text in {"strict", "all", "always"}:
        return "strict"
    if text in {"1", "true", "yes", "on", "new", "baseline"}:
        return "baseline"
    return "off"


SWIFT6_SUFFIX = "; this is an error in the swift 6 language mode"


def warning_key(rel: str, msg: str) -> tuple[str, str]:
    """Baseline identity: file + message, line numbers ignored so edits above a warning do not break the match."""
    text = " ".join(msg.split()).strip().lower()
    if text.endswith(SWIFT6_SUFFIX):
        text = text[: -len(SWIFT6_SUFFIX)]
    return rel, text


def load_baseline(path: str) -> Counter:
    known: Counter = Counter()
    if not path or not os.path.exists(path):
        return known
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"::warning::could not read the warnings baseline {path}: {exc}")
        return known
    for item in data.get("warnings", []):
        known[warning_key(item.get("file", ""), item.get("message", ""))] += int(item.get("count", 1) or 1)
    return known


def split_by_baseline(warnings: list[dict], known: Counter) -> tuple[list[dict], list[dict], Counter]:
    """-> (new, known, fixed) where fixed = baseline entries that no longer occur."""
    budget = Counter(known)
    new_items: list[dict] = []
    known_items: list[dict] = []
    for entry in warnings:
        key = warning_key(entry["rel"], entry["msg"])
        if budget[key] > 0:
            budget[key] -= 1
            known_items.append(entry)
        else:
            new_items.append(entry)
    fixed = Counter({key: count for key, count in budget.items() if count > 0})
    return new_items, known_items, fixed


def write_baseline(path: str, warnings: list[dict], note: str) -> None:
    counts: Counter = Counter()
    messages: dict[tuple[str, str], str] = {}
    for entry in warnings:
        key = warning_key(entry["rel"], entry["msg"])
        counts[key] += 1
        messages.setdefault(key, entry["msg"])
    payload = {
        "_comment": "Known first-party compiler warnings accepted by the Build check "
                    "(.github/workflows/ci.yml). New warnings that are not listed here fail the check; "
                    "fixed ones are reported so this file can be trimmed. Regenerate: download "
                    "build-warnings-baseline.json from a Build check run artifact and replace this file. "
                    "Matching ignores line numbers; 'count' is the number of occurrences allowed per file+message.",
        "generated": note,
        "warnings": [{"file": key[0], "message": messages[key], "count": count} for key, count in sorted(counts.items())],
    }
    try:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"::warning::could not write {path}: {exc}")


def relpath(path: str, workspace: str) -> str | None:
    """Path relative to the checkout, or None when the file lives outside it."""
    try:
        rel = Path(path).resolve().relative_to(Path(workspace).resolve())
    except (ValueError, OSError):
        return None
    return rel.as_posix()


def is_first_party(rel: str | None, first_party: list[str]) -> bool:
    if rel is None:
        return False
    parts = rel.split("/")
    if "DerivedData" in parts or "SourcePackages" in parts or ".build" in parts:
        return False
    return parts[0] in first_party


def annotate(kind: str, msg: str, rel: str | None = None, line: int | None = None, col: int | None = None, title: str | None = None) -> None:
    props = []
    if rel:
        props.append(f"file={rel}")
        if line:
            props.append(f"line={line}")
        if col:
            props.append(f"col={col}")
    if title:
        props.append(f"title={title}")
    # Newlines and a few characters must be escaped in workflow commands.
    msg = msg.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    head = f"::{kind} {','.join(props)}::" if props else f"::{kind}::"
    print(head + msg)


def main() -> int:
    args = parse_args()
    first_party = [item.strip() for item in args.first_party.split(",") if item.strip()]
    mode = gate_mode(args.warnings_as_errors)

    try:
        text = Path(args.log).read_text(errors="replace")
    except OSError as exc:
        annotate("error", f"Could not read the xcodebuild log: {exc}")
        return 1
    lines = text.splitlines()

    errors: dict[tuple, dict] = {}
    warnings_fp: dict[tuple, dict] = {}
    warnings_3p = Counter()
    bare_errors: list[str] = []

    for line_index, raw in enumerate(lines):
        line = raw.rstrip()
        match = DIAG_RE.match(line)
        if match:
            rel = relpath(match["file"], args.workspace)
            entry = {
                "rel": rel or match["file"],
                "line": int(match["line"]),
                "col": int(match["col"] or 1),
                "msg": match["msg"].strip(),
            }
            key = (entry["rel"], entry["line"], entry["col"], entry["msg"])
            if match["sev"] == "error":
                errors.setdefault(key, entry)
            elif match["sev"] == "warning":
                if is_first_party(rel, first_party):
                    warnings_fp.setdefault(key, entry)
                else:
                    warnings_3p[(rel or match["file"]).split("/")[0]] += 1
            continue
        match = BARE_ERROR_RE.match(line)
        if match:
            msg = match["msg"].strip()
            # SwiftPM emits the actionable dependency-resolution reason on the
            # following indented lines, not on xcodebuild's generic error line.
            if "could not resolve package dependencies" in msg.lower():
                context = []
                for following in lines[line_index + 1:line_index + 21]:
                    if not following.strip():
                        if context:
                            break
                        continue
                    if following[:1].isspace():
                        context.append(following.strip())
                    else:
                        break
                if context:
                    msg += "\n" + "\n".join(context)
            if msg and msg not in bare_errors:
                bare_errors.append(msg)

    build_failed = args.build_exit != 0
    all_warnings = list(warnings_fp.values())
    known = load_baseline(args.baseline) if mode == "baseline" else Counter()
    new_warnings, known_warnings, fixed = split_by_baseline(all_warnings, known)
    if mode == "strict":
        new_warnings, known_warnings = all_warnings, []
    gate_tripped = mode != "off" and bool(new_warnings)
    # A failed build stops compiling early, so its warning set is incomplete:
    # only offer a regenerated baseline for successful builds.
    baseline_changed = (not build_failed) and (bool(new_warnings or fixed) if mode == "baseline" else bool(all_warnings))

    if args.baseline_out and not build_failed:
        write_baseline(args.baseline_out, all_warnings,
                       f"{dt.date.today().isoformat()} from Build check run {os.environ.get('GITHUB_RUN_ID', 'local')}")

    # ---- annotations -----------------------------------------------------
    emitted = 0
    for entry in errors.values():
        if emitted >= MAX_ANNOTATIONS:
            break
        annotate("error", entry["msg"], entry["rel"], entry["line"], entry["col"], title="Compiler error")
        emitted += 1
    for msg in bare_errors[:20]:
        annotate("error", msg, title="xcodebuild")
    for entry in new_warnings:
        if emitted >= MAX_ANNOTATIONS:
            break
        kind = "error" if mode != "off" else "warning"
        title = "New warning (treated as error)" if mode == "baseline" else ("Warning treated as error" if mode == "strict" else "Compiler warning")
        annotate(kind, entry["msg"], entry["rel"], entry["line"], entry["col"], title=title)
        emitted += 1
    for entry in known_warnings:
        if emitted >= MAX_ANNOTATIONS:
            break
        annotate("warning", entry["msg"], entry["rel"], entry["line"], entry["col"], title="Known warning (baseline)")
        emitted += 1

    # ---- summary ---------------------------------------------------------
    verdict = "✅ passed"
    if build_failed:
        verdict = "❌ build failed" if args.title == DEFAULT_TITLE else "❌ failed"
    elif gate_tripped:
        verdict = (f"❌ {len(new_warnings)} new first-party warning(s) (treated as errors)" if mode == "baseline"
                   else "❌ first-party warnings (treated as errors)")
    elif known_warnings:
        verdict = f"✅ passed ({len(known_warnings)} known warnings in the baseline)"

    out: list[str] = []
    out.append(f"## {args.title} — {verdict}")
    out.append("")
    out.append("| | Count |")
    out.append("|---|---:|")
    out.append(f"| Compiler errors | {len(errors)} |")
    out.append(f"| Other errors (xcodebuild, scripts, linker) | {len(bare_errors)} |")
    out.append(f"| First-party warnings | {len(all_warnings)} |")
    if mode == "baseline":
        out.append(f"| … new (not in baseline) | {len(new_warnings)} |")
        out.append(f"| … known (baseline) | {len(known_warnings)} |")
        out.append(f"| … fixed since the baseline | {sum(fixed.values())} |")
    out.append(f"| Dependency warnings (ignored) | {sum(warnings_3p.values())} |")
    out.append("")

    if errors:
        out.append(f"### Compiler errors ({len(errors)})")
        out.append("")
        for entry in list(errors.values())[:MAX_LISTED]:
            out.append(f"- `{entry['rel']}:{entry['line']}:{entry['col']}` — {entry['msg']}")
        if len(errors) > MAX_LISTED:
            out.append(f"- … {len(errors) - MAX_LISTED} more (see the log artifact)")
        out.append("")

    if bare_errors:
        out.append("### Other errors")
        out.append("")
        for msg in bare_errors[:20]:
            out.append(f"- {msg}")
        out.append("")

    if new_warnings:
        heading = "New warnings (treated as errors)" if mode == "baseline" else (
            "Warnings treated as errors" if mode == "strict" else "First-party warnings")
        out.append(f"### {heading} ({len(new_warnings)})")
        out.append("")
        if mode == "baseline":
            out.append("The build compiled, but these warnings are not in `.github/build-warnings-baseline.json`. "
                       "Fix them (preferred), or accept them by committing the regenerated baseline from this run's "
                       "artifact. `BUILD_WARNINGS_AS_ERRORS=false` turns the gate off, `strict` fails on every warning.")
            out.append("")
        elif mode == "strict":
            out.append("The build compiled, but the check is configured to fail on every warning in first-party code "
                       "(`BUILD_WARNINGS_AS_ERRORS=strict`). Set it to `true` to tolerate the committed baseline.")
            out.append("")
        for entry in new_warnings[:MAX_LISTED]:
            out.append(f"- `{entry['rel']}:{entry['line']}:{entry['col']}` — {entry['msg']}")
        if len(new_warnings) > MAX_LISTED:
            out.append(f"- … {len(new_warnings) - MAX_LISTED} more (see the log artifact)")
        out.append("")

    if known_warnings:
        by_file = Counter(entry["rel"] for entry in known_warnings)
        out.append(f"<details><summary>Known warnings from the baseline ({len(known_warnings)}) — fix them when you touch these files</summary>")
        out.append("")
        out.append("| File | Warnings |")
        out.append("|---|---:|")
        for rel, count in by_file.most_common(40):
            out.append(f"| `{rel}` | {count} |")
        out.append("")
        for entry in known_warnings[:MAX_LISTED * 2]:
            out.append(f"- `{entry['rel']}:{entry['line']}:{entry['col']}` — {entry['msg']}")
        if len(known_warnings) > MAX_LISTED * 2:
            out.append(f"- … {len(known_warnings) - MAX_LISTED * 2} more")
        out.append("")
        out.append("</details>")
        out.append("")

    if fixed:
        out.append(f"🎉 {sum(fixed.values())} baseline warning(s) no longer occur. Commit the regenerated "
                   "`build-warnings-baseline.json` from this run's artifact to lock that in:")
        out.append("")
        for (rel, msg), count in list(fixed.items())[:30]:
            out.append(f"- `{rel}` — {msg}" + (f" (×{count})" if count > 1 else ""))
        out.append("")

    if warnings_3p:
        out.append("<details><summary>Dependency warnings by package (informational)</summary>")
        out.append("")
        for pkg, count in warnings_3p.most_common(20):
            out.append(f"- {pkg}: {count}")
        out.append("")
        out.append("</details>")
        out.append("")

    if build_failed and not errors and not bare_errors:
        tail = [line for line in lines if line.strip()][-60:]
        annotate("error", "Failed without a parsed diagnostic. Log tail:\n" +
                 "\n".join(line[:500] for line in tail), title="Unparsed build/test failure")
        out.append("### Log tail (build failed without a parseable diagnostic)")
        out.append("")
        out.append("```text")
        out.extend(tail)
        out.append("```")
        out.append("")

    summary = "\n".join(out)
    print(summary)
    if args.summary:
        try:
            with open(args.summary, "a", encoding="utf-8") as handle:
                handle.write(summary + "\n")
        except OSError as exc:
            print(f"::warning::could not write the step summary: {exc}")

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(f"baseline_changed={'true' if baseline_changed else 'false'}\n")
            handle.write(f"new_warnings={len(new_warnings)}\n")

    if build_failed:
        return 1
    if gate_tripped:
        what = "new " if mode == "baseline" else ""
        annotate("error", f"{len(new_warnings)} {what}first-party warning(s) are treated as errors "
                          "(fix them, commit an updated .github/build-warnings-baseline.json, or set the repository "
                          "variable BUILD_WARNINGS_AS_ERRORS=false).", title="Warnings gate")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
