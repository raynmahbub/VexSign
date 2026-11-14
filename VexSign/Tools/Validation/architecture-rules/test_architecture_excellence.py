#!/usr/bin/env python3
"""Architecture-excellence contracts and a legacy dependency-drift ratchet.

The shared architecture brief asks for six logical layers, one owner per core
system, and no new Presentation→Infrastructure shortcuts. This guard does not
pretend the existing SwiftUI tree is already free of legacy coupling. It records
the current, reviewed violations in ``VexSign/Tools/Validation/architecture-rules/architecture-drift-baseline.json``,
asserts that no *new* file joins them, and checks the machine-readable owner map
and documentation/CI wiring.

Run ``python3 VexSign/Tools/Validation/architecture-rules/test_architecture_excellence.py --report`` for a concise
drift report, or ``--write-baseline`` after intentionally removing legacy
violations. Ordinary execution is a unittest suite used by ``make verify`` and
the CI quick job.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
BASELINE = ROOT / "VexSign/Tools/Validation/architecture-rules/architecture-drift-baseline.json"
COMPONENT_MAP = ROOT / "VexSign/Documentation/Architecture/component-map.json"
ARCHITECTURE_DOC = ROOT / "VexSign/Documentation/Architecture/ARCHITECTURE.md"
DEPENDENCY_RULES = ROOT / "VexSign/Documentation/Architecture/dependency-rules.md"
SOURCE_DECISIONS = ROOT / "VexSign/Documentation/Decisions/Research/source-guided-architecture-decisions.md"
AUDIT = ROOT / "VexSign/Documentation/Decisions/Research/architecture-excellence-audit.md"
ADR = ROOT / "VexSign/Documentation/Decisions/History/architecture-excellence-drift-guard.md"
CHANGELOG = ROOT / "CHANGELOG.md"
MAKEFILE = ROOT / "Makefile"
CI = ROOT / ".github/workflows/ci.yml"
DOCS_INDEX = ROOT / "VexSign/Documentation/README.md"

LAYERS = (
    "App",
    "Presentation",
    "Application",
    "Domain",
    "Infrastructure",
    "Platform",
    "Security",
    "Resources",
    "External integrations",
    "Tooling",
)

CORE_SYSTEMS = (
    "SigningOrchestrator",
    "IdentityManager",
    "ProvisioningValidator",
    "ApplicationRegistry",
    "InstallationCoordinator",
    "DeviceCapabilityResolver",
    "UnifiedTaskCenter",
    "PersistentTaskJournal",
    "RepositoryManager",
    "DownloadManager",
    "ArtifactStorage",
    "BackupRestoreCoordinator",
    "AutomationCoordinator",
    "DiagnosticService",
)

REQUIRED_COMPONENT_FIELDS = (
    "responsibilities",
    "dependencies",
    "publicInterfaces",
    "stateOwnership",
    "concurrencyModel",
    "persistence",
    "existingTests",
    "failureModes",
    "refactoringRequirement",
    "sourceEvidence",
)

# Each rule is intentionally source-level. It is a guard against architectural
# drift, not a substitute for Xcode compilation or device acceptance.
RULES: dict[str, dict[str, object]] = {
    "domain_forbidden_imports": {
        "roots": ("VexSign/App/iOS/VexSign/Domain",),
        "patterns": (r"^\s*import\s+(SwiftUI|UIKit|CoreData|Nuke|NativeSigning|IDeviceSwift|AltSourceKit|SwiftSoup)\b",),
    },
    "application_platform_imports": {
        "roots": ("VexSign/App/iOS/VexSign/Application",),
        "patterns": (r"^\s*import\s+(SwiftUI|UIKit|CoreData|Nuke|IDeviceSwift|AltSourceKit|SwiftSoup)\b",),
    },
    "application_external_integration_imports": {
        "roots": ("VexSign/App/iOS/VexSign/Application",),
        "patterns": (r"^\s*import\s+(NativeSigning|IDeviceSwift|AltSourceKit|SwiftSoup)\b",),
    },
    "presentation_direct_storage": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"Storage\.shared", r"@FetchRequest", r"^\s*import\s+CoreData\b", r"FileManager\.default"),
    },
    "views_coredata_imports": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"^\s*import\s+CoreData\b",),
    },
    "views_direct_storage": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"Storage\.shared", r"@FetchRequest"),
    },
    "views_direct_install": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"DirectInstaller\.shared\.install", r"InstallQueue\.shared\.enqueue", r"AppInstaller\.shared"),
    },
    "views_direct_signing": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"SigningService", r"SigningHandler", r"ZsignEngine", r"PackageImportService\.importPackage"),
    },
    "presentation_file_io": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"\b(?:Data|String)\s*\(contentsOf:", r"\bFileHandle\s*\(", r"\.write\(to:", r"contentsOfDirectory\("),
    },
    "presentation_consumed_engine_owners": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"\b(?:UnifiedTaskCenter|NativeSigningManager|BackupManager|BackupCrypto|CloudSigningClient|AppCloner|TweakManager|EntitlementsManager|OptionsManager|CertificateRemoval|CertificateExporter)\b",),
    },
    "presentation_managed_record_types": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"(?:\b(?:as[?!]?|is)\s+|:\s*|->\s*)(?:any\s+)?\[?(?:Signed|Imported|CertificatePair|AltSource)\b",),
    },
    "views_urlsession_shared": {
        "roots": ("VexSign/App/iOS/VexSign/Presentation",),
        "patterns": (r"URLSession\.shared",),
    },
}


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def _iter_swift_files(root: Path, relative_roots: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    for relative_root in relative_roots:
        directory = root / relative_root
        if directory.is_dir():
            files.extend(sorted(directory.rglob("*.swift")))
    return files


def compute_violations(root: Path = ROOT) -> dict[str, list[str]]:
    """Return sorted relative file paths that match each drift rule."""
    violations: dict[str, list[str]] = {rule: [] for rule in RULES}
    for rule, spec in RULES.items():
        relative_roots = spec["roots"]
        assert isinstance(relative_roots, tuple)
        patterns = tuple(re.compile(str(pattern), re.MULTILINE) for pattern in spec["patterns"])  # type: ignore[union-attr]
        for path in _iter_swift_files(root, relative_roots):
            source = _strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
            if any(pattern.search(source) for pattern in patterns):
                violations[rule].append(path.relative_to(root).as_posix())
    return {rule: sorted(set(paths)) for rule, paths in violations.items()}


def _baseline_rules() -> dict[str, list[str]]:
    data = json.loads(BASELINE.read_text(encoding="utf-8"))
    rules = data.get("rules", {})
    return {str(rule): sorted(set(map(str, paths))) for rule, paths in rules.items()}


def write_baseline() -> None:
    current = compute_violations()
    payload = json.loads(BASELINE.read_text(encoding="utf-8")) if BASELINE.exists() else {}
    previous = payload.get("rules", {})
    # Preserve the original migrationReview, including why expanded matches were
    # accepted then. A real zero is progress, not permission to erase the history.
    if previous != current:
        payload.setdefault("history", []).append({
            "previousGeneratedAt": payload.get("generatedAt"),
            "rules": previous,
            "reason": "Consumed feature ports replace legacy storage/I/O/engine access; original review retained.",
        })
    payload["generatedAt"] = datetime.now(timezone.utc).date().isoformat()
    payload["description"] = "Reviewed whole-Presentation boundary ratchet; zero violations are allowed and synthetic probes keep each rule live."
    payload["rules"] = current
    BASELINE.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {BASELINE.relative_to(ROOT)}")


def print_report() -> None:
    current = compute_violations()
    baseline = _baseline_rules()
    print("Architecture drift report")
    for rule in RULES:
        current_set = set(current[rule])
        baseline_set = set(baseline.get(rule, []))
        new = sorted(current_set - baseline_set)
        removed = sorted(baseline_set - current_set)
        print(f"  {rule}: {len(current_set)} baseline files, {len(new)} new, {len(removed)} removed")
        for path in new:
            print(f"    NEW {path}")
        for path in removed:
            print(f"    REMOVED {path}")


class ArchitectureExcellenceTests(unittest.TestCase):
    def test_drift_baseline_matches_current_tree(self) -> None:
        current = compute_violations()
        baseline = _baseline_rules()
        self.assertEqual(set(current), set(baseline), "drift baseline rule names changed")
        for rule in RULES:
            self.assertEqual(
                current[rule],
                baseline.get(rule, []),
                f"{rule} drifted; inspect with --report and update only after an intentional migration",
            )

    def test_domain_and_application_platform_imports_are_clean(self) -> None:
        current = compute_violations()
        self.assertEqual(current["domain_forbidden_imports"], [])
        self.assertEqual(current["application_platform_imports"], [])

    def test_zero_debt_is_allowed_without_disabling_the_rules(self) -> None:
        baseline = _baseline_rules()
        self.assertEqual(set(baseline), set(RULES))
        self.assertTrue(all(spec["patterns"] and spec["roots"] for spec in RULES.values()))
        metadata = json.loads(BASELINE.read_text(encoding="utf-8"))
        self.assertIn("migrationReview", metadata, "do not erase the earlier relocation/review provenance")

    def test_rules_detect_synthetic_violations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VexSign/App/iOS/VexSign/Domain").mkdir(parents=True)
            (root / "VexSign/App/iOS/VexSign/Application").mkdir(parents=True)
            (root / "VexSign/App/iOS/VexSign/Presentation/Features/Test/Views").mkdir(parents=True)
            (root / "VexSign/App/iOS/VexSign/Domain/Bad.swift").write_text("import SwiftUI\n", encoding="utf-8")
            (root / "VexSign/App/iOS/VexSign/Application/Bad.swift").write_text("import UIKit\n", encoding="utf-8")
            (root / "VexSign/App/iOS/VexSign/Presentation/Features/Test/Views/Bad.swift").write_text(
                "import CoreData\nStorage.shared\nURLSession.shared\nData(contentsOf: url)\nlet row: CertificatePair\nUnifiedTaskCenter.shared\n", encoding="utf-8"
            )
            (root / "VexSign/App/iOS/VexSign/Presentation/Features/Test/Views/Good.swift").write_text(
                "let isSigned: Bool\napp.isSigned\nfunc value(isSigned: Bool) {}\n", encoding="utf-8"
            )
            found = compute_violations(root)
            self.assertEqual(found["presentation_managed_record_types"], ["VexSign/App/iOS/VexSign/Presentation/Features/Test/Views/Bad.swift"])
            self.assertIn("VexSign/App/iOS/VexSign/Domain/Bad.swift", found["domain_forbidden_imports"])
            self.assertIn("VexSign/App/iOS/VexSign/Application/Bad.swift", found["application_platform_imports"])
            for rule in ("views_coredata_imports", "views_direct_storage", "views_urlsession_shared", "presentation_file_io", "presentation_consumed_engine_owners", "presentation_managed_record_types"):
                self.assertIn("VexSign/App/iOS/VexSign/Presentation/Features/Test/Views/Bad.swift", found[rule])

    def test_component_map_covers_layers_and_core_systems(self) -> None:
        data = json.loads(COMPONENT_MAP.read_text(encoding="utf-8"))
        self.assertEqual(tuple(data["layers"]), LAYERS)
        owners = {entry["name"]: entry for entry in data["coreSystems"]}
        self.assertEqual(set(owners), set(CORE_SYSTEMS))
        for name, entry in owners.items():
            self.assertTrue(entry["owner"], f"{name} has no owner")
            self.assertIn(entry["layer"], LAYERS)
            self.assertTrue(entry["sourceEvidence"], f"{name} has no source evidence")

    def test_component_map_entries_have_all_required_fields(self) -> None:
        data = json.loads(COMPONENT_MAP.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(data["components"]), 20, "dependency map is not complete")
        for entry in data["components"]:
            self.assertIn(entry["layer"], LAYERS)
            for field in REQUIRED_COMPONENT_FIELDS:
                self.assertIn(field, entry, f"{entry['name']} is missing {field}")
                self.assertTrue(entry[field], f"{entry['name']}.{field} is empty")
            for path in entry["sourceEvidence"]:
                self.assertTrue((ROOT / path).exists(), f"{entry['name']} cites missing {path}")
        self.assertTrue(data["sourceReferences"], "source-specific feature references are missing")

    def test_drift_guard_is_wired_into_local_and_ci_gates(self) -> None:
        for path in (MAKEFILE, CI):
            self.assertIn("VexSign/Tools/Validation/architecture-rules/test_architecture_excellence.py", path.read_text(encoding="utf-8"))

    def test_architecture_documentation_is_updated_and_linked(self) -> None:
        architecture = ARCHITECTURE_DOC.read_text(encoding="utf-8")
        self.assertIn("Architecture drift ratchet", architecture)
        self.assertIn("dependency-rules.md", architecture)
        self.assertIn("component-map.json", architecture)
        self.assertIn("../Decisions/Research/architecture-excellence-audit.md", architecture)
        rules = DEPENDENCY_RULES.read_text(encoding="utf-8")
        for layer in LAYERS:
            self.assertIn(layer, rules)
        self.assertIn("Domain", rules)
        self.assertIn("inward", rules)
        self.assertIn("Source-guided architecture decisions", SOURCE_DECISIONS.read_text(encoding="utf-8"))
        self.assertIn("Initial architecture audit", AUDIT.read_text(encoding="utf-8"))
        self.assertIn("ADR", ADR.read_text(encoding="utf-8"))
        self.assertIn("architecture drift", CHANGELOG.read_text(encoding="utf-8").lower())
        self.assertIn("Architecture/dependency-rules.md", DOCS_INDEX.read_text(encoding="utf-8"))


if __name__ == "__main__":
    if "--write-baseline" in sys.argv:
        write_baseline()
    elif "--report" in sys.argv:
        print_report()
    else:
        unittest.main(verbosity=2)
