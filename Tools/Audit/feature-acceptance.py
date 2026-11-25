#!/usr/bin/env python3
"""Build and check an explicit acceptance matrix for every registered feature.

This tool never claims a device pass from source inspection. `init` creates one case per
entry in `VexSign/Services/Diagnostics/FeatureStatusRegistry.swift`, bound to an exact
IPA SHA-256 and source commit. Entries marked `implemented` accept an XCTest source as
evidence; entries marked `needsDevice` require a named tester, device model, OS version,
timestamp and an observation that is not a synthetic fixture. `check` refuses a report
that omits a feature or leaves any case unobserved.

It is a checklist with teeth: it makes it hard to say "all features work" without the
evidence to support that claim.
"""

from datetime import datetime
import argparse
import hashlib
import importlib.util
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / "VexSign/Services/Diagnostics/FeatureStatusRegistry.swift"
SCHEMA = 1
STAMP = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
SYNTHETIC = re.compile(r"synthetic|fixture|simulated|placeholder|todo|not device", re.IGNORECASE)


def _device_module():
    """Reuse the commit-resolution policy from device-acceptance.py."""
    path = Path(__file__).resolve().with_name("device-acceptance.py")
    spec = importlib.util.spec_from_file_location("vexsign_device_acceptance", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_registry(path=REGISTRY):
    """Parse the one source of truth for the feature list and its honest status."""
    text = Path(path).read_text(encoding="utf-8")
    starts = [match.start() for match in re.finditer(r"FeatureStatusEntry\(", text)]
    entries = {}
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(text)
        block = text[start:end]
        identifier = re.search(r'id:\s*"([^"]+)"', block)
        name = re.search(r'name:\s*"([^"]+)"', block)
        status = re.search(r"status:\s*\.(implemented|needsDevice)", block)
        if not (identifier and name and status):
            raise ValueError(f"Unparsable FeatureStatusEntry at offset {start}")
        entries[identifier.group(1)] = {
            "name": name.group(1),
            "source_status": status.group(1),
            "kind": "unit" if status.group(1) == "implemented" else "device",
        }
    if not entries:
        raise ValueError("FeatureStatusRegistry.swift has no entries")
    return entries


def build_report(ipa, commit, registry_path=REGISTRY):
    """Create a pending report; it deliberately contains no passes."""
    registry_path = Path(registry_path)
    cases = {}
    for identifier, entry in load_registry(registry_path).items():
        cases[identifier] = {
            "name": entry["name"],
            "source_status": entry["source_status"],
            "kind": entry["kind"],
            "result": "pending",
            "notes": "",
            "evidence": "",
            "tester": "",
            "device_model": "",
            "os_version": "",
            "observed_at_utc": "",
        }
    return {
        "schema": SCHEMA,
        "source_commit": commit,
        "ipa_sha256": sha256(ipa),
        "registry": str(registry_path.relative_to(ROOT)),
        "registry_sha256": sha256(registry_path),
        "cases": cases,
    }


def check_report(report, ipa, commit, registry_path=REGISTRY):
    """Return every reason this report cannot be called an accepted build."""
    registry_path = Path(registry_path)
    errors = []
    if report.get("schema") != SCHEMA:
        errors.append(f"Unsupported schema: {report.get('schema')!r}")
    if report.get("source_commit") != commit:
        errors.append("Report source_commit does not match this checkout")
    if report.get("ipa_sha256") != sha256(ipa):
        errors.append("Report IPA checksum differs from the supplied artifact")
    if report.get("registry_sha256") != sha256(registry_path):
        errors.append("FeatureStatusRegistry changed after the report was created")

    expected = load_registry(registry_path)
    cases = report.get("cases")
    if not isinstance(cases, dict):
        return errors + ["cases must be an object"]
    missing = sorted(set(expected) - set(cases))
    extra = sorted(set(cases) - set(expected))
    errors.extend(f"{identifier}: registered feature is absent from the report" for identifier in missing)
    errors.extend(f"{identifier}: report case is not in the registry" for identifier in extra)

    for identifier, entry in expected.items():
        case = cases.get(identifier)
        if not isinstance(case, dict):
            continue
        if case.get("result") != "pass":
            errors.append(f"{identifier}: requires explicit result=pass")
        if case.get("source_status") != entry["source_status"] or case.get("kind") != entry["kind"]:
            errors.append(f"{identifier}: registry status changed after init")
        notes = case.get("notes")
        if not isinstance(notes, str) or not notes.strip():
            errors.append(f"{identifier}: requires observation notes")
        if case.get("kind") == "unit":
            evidence = case.get("evidence")
            if not isinstance(evidence, str) or not evidence.startswith("Tests/"):
                errors.append(f"{identifier}: unit evidence must name a Tests/ file")
                continue
            path = ROOT / evidence
            if not path.is_file() or "func test" not in path.read_text(encoding="utf-8"):
                errors.append(f"{identifier}: unit evidence file does not contain an XCTest case")
        elif case.get("kind") == "device":
            for field in ("tester", "device_model", "os_version", "observed_at_utc"):
                value = case.get(field)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{identifier}: missing {field}")
            stamp = case.get("observed_at_utc", "")
            if not isinstance(stamp, str) or not STAMP.fullmatch(stamp):
                errors.append(f"{identifier}: observed_at_utc must be YYYY-MM-DDTHH:MM:SSZ")
            try:
                datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
            except (TypeError, ValueError):
                errors.append(f"{identifier}: observed_at_utc is not a real timestamp")
            if isinstance(notes, str) and SYNTHETIC.search(notes):
                errors.append(f"{identifier}: synthetic notes cannot certify a device observation")
        else:
            errors.append(f"{identifier}: unknown evidence kind {case.get('kind')!r}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("init", "check"))
    parser.add_argument("--ipa", required=True, type=Path, help="Exact build artifact the report attests")
    parser.add_argument("--report", required=True, type=Path, help="Report to create or check")
    parser.add_argument("--commit", help="Source commit. Defaults to VEXSIGN_SOURCE_COMMIT/GITHUB_SHA, then git HEAD.")
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.exit(1, f"error: IPA not found: {args.ipa}\n")
    try:
        commit = _device_module().resolve_commit(args.commit)
    except Exception as error:  # CommitUnavailable lives in the loaded module.
        parser.exit(2, f"error: {error}\n")

    if args.mode == "init":
        report = build_report(args.ipa, commit)
        try:
            with args.report.open("x", encoding="utf-8") as handle:
                json.dump(report, handle, indent=2)
                handle.write("\n")
        except FileExistsError:
            parser.exit(1, f"error: {args.report} already exists; refusing to overwrite evidence\n")
        print(f"Created {args.report} with {len(report['cases'])} pending feature cases.")
        return

    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        parser.exit(1, f"error: {error}\n")
    errors = check_report(report, args.ipa, commit)
    if errors:
        for error in errors:
            print(f"FAIL {error}")
        print(f"{len(errors)} problem(s); no feature acceptance is claimed.")
        raise SystemExit(1)
    print(f"PASS: {len(report['cases'])} features have evidence for this exact IPA and commit.")


if __name__ == "__main__":
    main()
