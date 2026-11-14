#!/usr/bin/env python3
"""Portable gates for the clean top-level ownership-root layout.

This does not use Xcode, Swift, Git or network access. It protects the parts a
folder move can silently break: the original-to-new mapping, published root
aliases, SwiftPM relative manifests, workspace/project package references,
workflow path filters, service deployment paths and the Xcode project's settings.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAP = ROOT / "Documentation/Engineering/Changes/root-layout-migration-map.json"
PBXPROJ = ROOT / "VexSign.xcodeproj/project.pbxproj"
WORKSPACE = ROOT / "VexSign.xcworkspace/contents.xcworkspacedata"
WORKFLOWS = ROOT / ".github/workflows"
PUBLISHED_SOURCE_URL = "https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json"
PUBLISHED_REPO_LISTING_URL = "https://github.com/raynmahbub/VexSign/raw/main/app-repo.json"

OWNERSHIP_ROOTS = (
    "App", "Extensions", "Integrations", "Packages", "Resources", "Services",
    "Tools", "Documentation",
)
LEGACY_ROOTS = (
    "VexSign", "VexSignTests", "VexSignTV", "VexSignVision",
    "VexSignWidgetExtension", "VexSignWatch", "VexSignWatchWidgets",
    "PlatformInfo", "NimbleKit", "AltSourceKit", "NativeSigning", "SideSign",
    "Vendor", "EmbeddedContainer", "AnisetteServer", "server", "cloud-signing",
    "design", "Documentation.docc", "docs", "tools", "Tweaks",
)
ROOT_COMPATIBILITY_FILES = (
    "app-repo.json", "repos.json", "icon.png", "license_plist.yml", "render.yaml",
)
LEGAL_NOTICES = (
    "LICENSE", "LICENSE_ELLEKIT", "THIRD_PARTY_NOTICES.md",
)
SKIP_DIRS = {
    ".git", "node_modules", "dist", "__pycache__", ".pytest_cache", ".venv",
    ".build", "DerivedData", "packages", "Payload", ".swiftpm",
}


def iter_text_files():
    """Yield UTF-8 text files that are part of the source tree, not generated output."""
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT)
        if not path.is_file() or any(part in SKIP_DIRS for part in relative.parts):
            continue
        try:
            raw = path.read_bytes()
        except OSError:
            continue
        if b"\x00" in raw:
            continue
        try:
            yield path, raw.decode("utf-8")
        except UnicodeDecodeError:
            continue


class RepositoryLayoutTests(unittest.TestCase):
    def test_ownership_roots_and_root_compatibility_files_exist(self):
        for name in OWNERSHIP_ROOTS:
            with self.subTest(root=name):
                self.assertTrue((ROOT / name).is_dir(), f"missing ownership root {name}")
        for name in LEGACY_ROOTS:
            with self.subTest(legacy=name):
                self.assertFalse((ROOT / name).exists(), f"legacy top-level root {name} still exists")
        for name in ROOT_COMPATIBILITY_FILES + LEGAL_NOTICES:
            with self.subTest(file=name):
                self.assertTrue((ROOT / name).is_file(), f"missing root compatibility/legal file {name}")
        self.assertTrue((ROOT / "VexSign.xcodeproj").is_dir())
        self.assertTrue((ROOT / "VexSign.xcworkspace").is_dir())

    def test_migration_map_matches_the_current_tree(self):
        data = json.loads(MAP.read_text(encoding="utf-8"))
        self.assertEqual(data["schema"], 1)
        self.assertEqual(data["stage"], "top-level-ownership-roots")
        self.assertEqual(data["inventoryCount"], 1365)
        self.assertEqual(data["pathMappingCount"], 1317)
        self.assertEqual(data["relocatedFileCount"], 1312)
        self.assertEqual(data["canonicalCopyCount"], 5)
        self.assertEqual(data["unchangedFileCount"], 48)
        mappings = data["fileMappings"]
        self.assertEqual(len(mappings), data["inventoryCount"])
        kinds = {}
        for entry in mappings:
            kinds[entry["kind"]] = kinds.get(entry["kind"], 0) + 1
            new_path = ROOT / entry["new"]
            self.assertTrue(new_path.is_file(), f"mapped destination is missing: {entry['new']}")
            if entry["kind"] == "unchanged":
                self.assertEqual(entry["old"], entry["new"])
            else:
                self.assertNotEqual(entry["old"], entry["new"])
        self.assertEqual(kinds, {
            "relocation": 1312,
            "canonical-copy-plus-root-alias": 5,
            "unchanged": 48,
        })
        for path in data["postStageArtifacts"]:
            with self.subTest(artifact=path):
                self.assertTrue((ROOT / path).is_file(), f"missing post-stage artifact {path}")

    def test_compatibility_aliases_and_published_urls_are_preserved(self):
        data = json.loads(MAP.read_text(encoding="utf-8"))
        for alias in data["compatibilityAliases"]:
            canonical = ROOT / alias["canonical"]
            root_alias = ROOT / alias["rootAlias"]
            self.assertTrue(canonical.is_file())
            self.assertTrue(root_alias.is_file())
            self.assertEqual(canonical.read_bytes(), root_alias.read_bytes(),
                             f"compatibility alias drifted: {alias['rootAlias']}")
        feed = json.loads((ROOT / "app-repo.json").read_text(encoding="utf-8"))
        self.assertEqual(feed["sourceURL"], PUBLISHED_SOURCE_URL)
        repos = json.loads((ROOT / "repos.json").read_text(encoding="utf-8"))
        self.assertIn(PUBLISHED_REPO_LISTING_URL, repos)
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn(PUBLISHED_SOURCE_URL, readme)

        # A generic path rewrite must never turn an ownership path into a GitHub
        # repository slug. Build the fragments so this guard does not flag itself.
        forbidden = (
            "https://github.com/raynmahbub/" + "App/iOS/VexSign",
            "https://raw.githubusercontent.com/raynmahbub/" + "App/iOS/VexSign",
        )
        for path, text in iter_text_files():
            for fragment in forbidden:
                with self.subTest(file=path.relative_to(ROOT).as_posix()):
                    self.assertNotIn(fragment, text, "published repository URL was rewritten")

    def test_swiftpm_relative_dependencies_resolve(self):
        manifests = sorted((ROOT / "Packages").rglob("Package.swift"))
        manifests += sorted((ROOT / "Services").rglob("Package.swift"))
        manifests += sorted((ROOT / "Integrations").rglob("Package.swift"))
        self.assertTrue(manifests)
        dependency_re = re.compile(r'^\s*\.package\(path:\s*"([^"]+)"\)')
        checked = 0
        for manifest in manifests:
            for line in manifest.read_text(encoding="utf-8").splitlines():
                if line.lstrip().startswith("//"):
                    continue
                match = dependency_re.match(line)
                if not match:
                    continue
                checked += 1
                target = (manifest.parent / match.group(1)).resolve()
                self.assertTrue((target / "Package.swift").is_file(),
                                f"{manifest.relative_to(ROOT)}: unresolved local package {match.group(1)}")
        self.assertGreaterEqual(checked, 3)

    def test_service_deployment_paths_resolve(self):
        expected_context = "Services/API/server"
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        docker_commands = [
            line.strip() for line in makefile.splitlines()
            if line.startswith("\tdocker build ")
        ]
        self.assertEqual(len(docker_commands), 1)
        build_context = docker_commands[0].rsplit(" ", 1)[-1]
        self.assertEqual(build_context, expected_context)
        self.assertTrue((ROOT / build_context / "Dockerfile").is_file())
        for blueprint in (ROOT / "render.yaml", ROOT / "Services/API/render.yaml"):
            with self.subTest(blueprint=blueprint.relative_to(ROOT)):
                match = re.search(r"^\s*rootDir:\s*(\S+)\s*$",
                                  blueprint.read_text(encoding="utf-8"), re.MULTILINE)
                self.assertIsNotNone(match, "missing Render repository-root context")
                self.assertEqual(match.group(1), expected_context)
                for entry in ("requirements.txt", "main.py"):
                    self.assertTrue((ROOT / match.group(1) / entry).is_file())

    def test_workspace_and_xcode_local_package_refs_resolve(self):
        workspace = WORKSPACE.read_text(encoding="utf-8")
        locations = re.findall(r'location = "([^"]+)"', workspace)
        self.assertTrue(locations)
        for location in locations:
            if not location.startswith(("group:", "container:")):
                continue
            relative = location.split(":", 1)[1]
            with self.subTest(workspaceRef=relative):
                self.assertTrue((ROOT / relative).exists(), f"missing workspace reference {relative}")
        pbxproj = PBXPROJ.read_text(encoding="utf-8")
        local_packages = re.findall(r"relativePath = ([^;]+);", pbxproj)
        self.assertTrue(local_packages)
        for value in local_packages:
            relative = value.strip().strip('"')
            with self.subTest(localPackage=relative):
                self.assertTrue((ROOT / relative).is_dir(), f"missing local Swift package {relative}")
        result = subprocess.run(
            [sys.executable, str(ROOT / "Tools/CI/check-pbxproj.py")],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_workflow_filters_cover_the_new_roots_and_gates(self):
        workflow_text = "\n".join(
            path.read_text(encoding="utf-8") for path in sorted(WORKFLOWS.glob("*.yml"))
        )
        for pattern in (
            "'App/**'", "'Extensions/**'", "'Integrations/**'", "'Packages/**'",
            "'Resources/**'", "'Services/Anisette/**'", "'Services/API/server/**'",
            "'Services/CloudSigning/cloud-signing/**'", "'Tools/**'", "'Documentation/**'",
            "'app-repo.json'", "'repos.json'", "'icon.png'", "'license_plist.yml'",
            "'render.yaml'",
        ):
            with self.subTest(filter=pattern):
                self.assertIn(pattern, workflow_text)
        for entry_point in (ROOT / "Makefile", WORKFLOWS / "ci.yml"):
            self.assertIn("Tools/Architecture/test_repository_layout.py",
                          entry_point.read_text(encoding="utf-8"))
        self.assertIn("Tools/Development/sync_repo_aliases.py --check",
                      (WORKFLOWS / "ci.yml").read_text(encoding="utf-8"))
        self.assertIn("Tools/Development/sync_repo_aliases.py --write",
                      (WORKFLOWS / "update_repo.yml").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
