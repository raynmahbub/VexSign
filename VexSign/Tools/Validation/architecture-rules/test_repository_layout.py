#!/usr/bin/env python3
"""Offline contracts for the feature-oriented main VexSign source tree.

These are structural/path and source-boundary checks, not SwiftPM resolution,
Xcode compilation, resource-bundle verification, or physical-device acceptance.
"""
from __future__ import annotations

import hashlib
import json
import re
import runpy
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "VexSign"
APP = SOURCE / "App/iOS"
MAP = SOURCE / "Documentation/Architecture/feature-layout-migration-map.json"
PBX = ROOT / "VexSign.xcodeproj/project.pbxproj"
WORKSPACE = ROOT / "VexSign.xcworkspace/contents.xcworkspacedata"
LAYERS = {"App", "Presentation", "Application", "Domain", "Infrastructure", "Platform", "Security", "Resources"}
SKIP = {".git", "node_modules", "dist", "__pycache__", ".pytest_cache", ".venv", ".build", ".swiftpm"}
ALIASES = (
    ("VexSign/Resources/Assets/icon.png", "icon.png"),
    ("VexSign/Resources/Templates/app-repo.json", "app-repo.json"),
    ("VexSign/Resources/Templates/repos.json", "repos.json"),
    ("VexSign/Configuration/Signing/license_plist.yml", "license_plist.yml"),
    ("VexSign/Services/WebManager/Configuration/render.yaml", "render.yaml"),
)
GROUPS = {
    "3379C1BB2DA869A1004372DA": "VexSign/App/iOS",
    "AABA5D1A2DB3C87800BFCD2C": "VexSign/Tests",
    "3A2F0EE82E96DA5A009DE4CE": "VexSign/App/WidgetExtension",
    "C0FFEE000000000000000001": "VexSign/App/TV",
    "C0FFEE00000000000000000D": "VexSign/App/Vision",
    "C0FFEE000000000000000019": "VexSign/App/Watch/VexSignWatch",
    "C0FFEE000000000000000025": "VexSign/App/Watch/VexSignWatchWidgets",
}
OBJECT = re.compile(r'(?m)^\t\t([A-F0-9]{24}) /\*[^\n]*\*/ = \{\n(.*?)^\t\t\};', re.S)


def code(path: Path) -> str:
    # Keep strings (including URLs) intact; remove whole-line source comments.
    text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
    return re.sub(r"(?m)^\s*//.*$", "", text)


class FeatureRepositoryLayoutTests(unittest.TestCase):
    def test_single_main_source_tree_and_preserved_root_entry_points(self):
        for name in ("App", "Packages", "Services", "Tests", "Resources", "Documentation", "Tools", "Configuration"):
            self.assertTrue((SOURCE / name).is_dir(), name)
        for legacy in ("App", "Packages", "Services", "Extensions", "Integrations", "Resources", "Documentation", "Tools"):
            self.assertFalse((ROOT / legacy).exists(), f"legacy ownership root remains: {legacy}")
        self.assertFalse((SOURCE / "VexSign").exists(), "unnecessary wrapper nesting")
        for name in ("README.md", "Makefile", "LICENSE", "LICENSE_ELLEKIT", "THIRD_PARTY_NOTICES.md", ".github", "VexSign.xcodeproj", "VexSign.xcworkspace"):
            self.assertTrue((ROOT / name).exists(), name)

    def test_flat_platform_roots_and_preserved_watch_hierarchy(self):
        app = SOURCE / "App"
        self.assertEqual({p.name for p in app.iterdir()},
                         {"iOS", "TV", "Vision", "WidgetExtension", "Watch", "SharedPlatformInfo"})
        for platform, entry_point in (
            ("TV", "VexSignTVApp.swift"),
            ("Vision", "VexSignVisionApp.swift"),
            ("WidgetExtension", "VexSignWidgetExtensionBundle.swift"),
        ):
            self.assertTrue((app / platform / entry_point).is_file(), platform)
            self.assertTrue((app / platform / "Assets.xcassets/Contents.json").is_file(), platform)
        for legacy in ("iOS/VexSign", "TV/VexSignTV", "Vision/VexSignVision", "Extensions"):
            self.assertFalse((app / legacy).exists(), f"redundant app wrapper remains: {legacy}")
        self.assertEqual({p.name for p in (app / "Watch").iterdir()},
                         {"VexSignWatch", "VexSignWatchWidgets"})
        self.assertTrue((app / "Watch/VexSignWatch/VexSignWatchApp.swift").is_file())
        self.assertTrue((app / "Watch/VexSignWatchWidgets/VexSignWatchWidgetBundle.swift").is_file())
        self.assertTrue((app / "SharedPlatformInfo/Companion-Info.plist").is_file())

    def test_application_has_only_the_specified_layers_and_real_feature_folders(self):
        self.assertEqual({p.name for p in APP.iterdir() if p.is_dir()}, LAYERS)
        self.assertFalse(list(APP.glob("*.swift")), "entry points belong under App/")
        for feature in ("Home", "Library", "Import", "Signing", "Certificates", "Accounts", "Devices", "Repositories", "Downloads", "Updates", "Tasks", "Backups", "Diagnostics", "Settings", "Customization", "Onboarding", "About"):
            self.assertTrue(list((APP / "Presentation/Features" / feature).rglob("*.swift")), feature)
        self.assertTrue((APP / "App/Composition/AppContainer.swift").is_file())
        for name in ("TabbarView", "TabEnum", "WorkspaceTabs", "TabBarPreferences"):
            self.assertTrue((APP / "Presentation/Shared/Navigation" / (name + ".swift")).is_file(), name)
        for legacy in ("Backend", "Utilities", "Views", "Shared", "DesignSystem"):
            self.assertFalse((APP / legacy).exists(), legacy)

    def test_migration_inventory_accounts_for_every_original_file(self):
        data = json.loads(MAP.read_text())
        self.assertEqual(data["schema"], 2)
        self.assertEqual(data["stage"], "feature-layered-main-source-tree")
        entries = data["fileMappings"]
        self.assertEqual(len(entries), data["inventoryCount"])
        self.assertEqual(len({e["old"] for e in entries}), len(entries))
        self.assertEqual(len({e["new"] for e in entries}), len(entries))
        for entry in entries:
            self.assertTrue((ROOT / entry["new"]).is_file(), entry["new"])
            self.assertRegex(entry["sha256Before"], r"^[0-9a-f]{64}$")
            self.assertNotIn("..", Path(entry["new"]).parts)
        self.assertEqual(sum(e["old"] != e["new"] for e in entries), data["relocatedFileCount"])

    def test_whole_repository_has_only_reviewed_tool_owned_wrappers(self):
        # Inventory files, not just known source roots. Include dotfiles and new
        # files; ignore deleted index paths and Git-ignored dependency/build data.
        listed = subprocess.check_output([
            "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
        ], cwd=ROOT)
        paths = sorted({p.decode() for p in listed.split(b"\0") if p and (ROOT / p.decode()).exists()})
        children = {}
        for path in paths:
            parts = Path(path).parts
            for index in range(1, len(parts)):
                children.setdefault("/".join(parts[:index]), set()).add(parts[index])
        wrappers = {
            parent: next(iter(names)) for parent, names in children.items()
            if len(names) == 1 and parent + "/" + next(iter(names)) in children
        }
        policy = runpy.run_path(str(ROOT / ".github/scripts/quick_check.py"))
        required = policy["PRESERVED_DIRECTORY_WRAPPERS"]
        self.assertEqual(wrappers, {parent: child for parent, (child, _) in required.items()})
        self.assertEqual(len(required), 4, "Each new tool-layout exception needs a reviewed rationale")
        self.assertTrue(all(reason for _, reason in required.values()))
        self.assertEqual(policy["layout_findings"](paths), [])

    def test_single_target_package_uses_flat_sources_without_renaming_the_module(self):
        package = SOURCE / "Packages/AltSourceKit"
        manifest = (package / "Package.swift").read_text()
        self.assertRegex(manifest, r'\.target\(\s*name: "AltSourceKit",\s*path: "Sources"\)')
        self.assertIn('targets: ["AltSourceKit"]', manifest)
        self.assertFalse((package / "Sources/AltSourceKit").exists())
        self.assertEqual(len(list((package / "Sources").rglob("*.swift"))), 7)

    def test_flattened_project_wrappers_are_not_reintroduced(self):
        for relative in (
            "App/iOS/Presentation/Features/About/Views",
            "App/iOS/Presentation/Features/Diagnostics/Views",
            "App/iOS/Presentation/Features/Onboarding/Views",
            "App/iOS/Presentation/Features/Updates/Views",
            "Documentation/Features/Design", "Documentation/Workflows/Distribution",
            "Integrations/EmbeddedContainer", "Resources/Assets/Branding",
            "Resources/Templates/RepositoryMetadata", "Services/Cloud/Security/Authentication",
            "Services/WebManager/Dashboard/Assets",
        ):
            self.assertFalse((SOURCE / relative).exists(), relative)

    def test_no_placeholder_modules_or_empty_source_scaffolding(self):
        for path in SOURCE.rglob("*"):
            if not path.is_dir() or any(part in SKIP for part in path.relative_to(SOURCE).parts):
                continue
            self.assertTrue(any(path.iterdir()), f"empty placeholder directory: {path.relative_to(ROOT)}")
            self.assertNotIn(path.name, {"Misc", "Others", "Common2", "Helpers2", "Manager"})
        expected = {"NimbleKit", "AltSourceKit", "NativeSigning", "DeviceBridge", "SideSign", "Vendor"}
        self.assertEqual({p.name for p in (SOURCE / "Packages").iterdir() if p.is_dir()}, expected)
        # DeviceBridge is a real, pinned Rust overlay and source builder, not a
        # second Swift placeholder/installer module or checked-in binary bundle.
        for relative in ("Native/vexsign_device.rs", "prepare.py", "inputs.lock.json", "LICENSE.idevice.txt", "test_prepare.py"):
            self.assertTrue((SOURCE / "Packages/DeviceBridge" / relative).is_file(), relative)

    def test_compatibility_aliases_and_historical_feed_bytes_are_preserved(self):
        for canonical, alias in ALIASES:
            self.assertEqual((ROOT / canonical).read_bytes(), (ROOT / alias).read_bytes(), alias)
        entries = {e["old"]: e for e in json.loads(MAP.read_text())["fileMappings"]}
        for name in ("app-repo.json", "repos.json", "LICENSE", "LICENSE_ELLEKIT"):
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), entries[name]["sha256Before"], name)
        self.assertEqual(json.loads((ROOT / "app-repo.json").read_text())["sourceURL"],
                         "https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json")
        # Pinned upstream review paths describe other repositories, not this
        # checkout. Relocation must not rewrite their historical identifiers.
        for original in ("Packages/NativeSigning/inputs.lock.json",
                         "Packages/NativeSigning/development-certificate-review.json",
                         "Documentation/Research/upstream-review-inventory.json"):
            entry = entries[original]
            data = (ROOT / entry["new"]).read_bytes()
            if original.endswith("/inputs.lock.json"):
                # These local overlays evolve independently of the pinned upstream
                # review. Verify their live hashes, then compare all other bytes
                # with the historical migration snapshot.
                for overlay in ("VexSignRegistration.swift", "VexSignProfiles.swift"):
                    source = entries[f"Packages/NativeSigning/patches/{overlay}"]
                    digest = hashlib.sha256((ROOT / source["new"]).read_bytes()).hexdigest().encode()
                    self.assertIn(digest, data)
                    data = data.replace(digest, source["sha256Before"].encode())
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256Before"], original)

    def test_original_binary_resources_are_byte_identical(self):
        for entry in json.loads(MAP.read_text())["fileMappings"]:
            if Path(entry["old"]).suffix.lower() not in {".png", ".jpg", ".wav", ".deb", ".der"}:
                continue
            self.assertEqual(hashlib.sha256((ROOT / entry["new"]).read_bytes()).hexdigest(), entry["sha256Before"], entry["new"])

    def test_domain_is_foundation_only_and_has_no_concrete_io_or_globals(self):
        files = list((APP / "Domain").rglob("*.swift"))
        self.assertTrue(files)
        for path in files:
            source = code(path)
            imports = set(re.findall(r"(?m)^import (\w+)", source))
            self.assertLessEqual(imports, {"Foundation"}, str(path))
            for pattern in (r"\.shared\b", r"FileManager\b", r"URLSession\b", r"NSFileCoordinator\b", r"UserDefaults\b", r"Data\(contentsOf:", r"Bundle\.main"):
                self.assertNotRegex(source, pattern, str(path))

    def test_application_use_cases_depend_on_ports_not_implementations(self):
        files = list((APP / "Application").rglob("*.swift"))
        self.assertTrue(files)
        for path in files:
            source = code(path)
            self.assertLessEqual(set(re.findall(r"(?m)^import (\w+)", source)), {"Foundation"}, str(path))
            for pattern in (r"\.shared\b", r"FileManager\b", r"URLSession\b", r"NSFileCoordinator\b", r"UserDefaults\b", r"AnisetteProviderFactory\b", r"DirectInstaller\b", r"ZsignEngine\b", r"ErrorBoundary\b", r"SubsystemDiagnosticsLog\b"):
                self.assertNotRegex(source, pattern, str(path))

    def test_library_display_contract_is_a_domain_value_boundary(self):
        contract = code(APP / "Domain/Entities/LibraryApp.swift")
        self.assertIn("protocol AppInfoPresentable", contract)
        self.assertNotIn("NSManagedObject", contract)
        self.assertNotIn("CoreData", contract)
        self.assertIn("struct LibraryAppRecord", code(APP / "Domain/Entities/WorkspaceSnapshot.swift"))

    def test_source_wiring_xctests_resolve_current_implementation_files(self):
        references = []
        for path in (SOURCE / "Tests").rglob("*.swift"):
            text = path.read_text()
            references.extend(re.findall(r'"(VexSign/App/[^"\n]+\.swift)"', text))
            if "RepositorySourceFixture.read(" in text:
                self.assertNotIn("URL(fileURLWithPath: #filePath)", text, str(path))
        self.assertGreaterEqual(len(references), 8, "source-reading XCTest coverage was lost")
        for relative in references:
            self.assertTrue((ROOT / relative).is_file(), relative)
        identity = (SOURCE / "Tests/UnitTests/Signing/SigningIdentityPolicyTests.swift").read_text()
        self.assertIn('Execution/SigningPipeline.swift"', identity)
        self.assertIn("SigningIdentityPolicy.rejection(for: request)",
                      (APP / "Infrastructure/Signing/Execution/SigningPipeline.swift").read_text())
        support = (SOURCE / "Tests/Support/RepositorySourceFixture.swift").read_text()
        self.assertIn("VexSign.xcodeproj/project.pbxproj", support)
        self.assertIn("directory.deleteLastPathComponent()", support)

    def test_bundle_relative_fixture_paths_are_not_repository_paths(self):
        nested = (SOURCE / "Tests/UnitTests/Signing/NestedBundleAuditTests.swift").read_text()
        native = (SOURCE / "Packages/NativeSigning/Tests/NativeOutputPolicyTests.swift").read_text()
        self.assertIn('"Extensions/Share.appex"', nested)
        self.assertNotIn('"VexSign/App/', nested)
        self.assertIn('"Resources/a&<b>.txt"', native)
        self.assertNotIn('"VexSign/Resources/', native)

    def test_engine_port_is_used_by_the_existing_pipeline(self):
        self.assertIn("protocol SigningEngine", (APP / "Domain/Protocols/SigningEngine.swift").read_text())
        self.assertIn("struct ZsignAdapter: SigningEngine", (APP / "Infrastructure/Signing/Engines/Zsign/ZsignAdapter.swift").read_text())
        self.assertIn("engine.sign(request)", (APP / "Infrastructure/Signing/Execution/ZsignHandler.swift").read_text())
        for name in ("SigningService", "UnifiedTaskCenter", "InstallQueue", "Storage"):
            declarations = []
            for path in (APP / "Infrastructure").rglob("*.swift"):
                if re.search(r"(?m)^\s*(?:final\s+)?(?:class|actor|struct)\s+" + name + r"\b", code(path)):
                    declarations.append(path)
            self.assertEqual(len(declarations), 1, f"{name}: {declarations}")

    def test_install_submission_is_not_reported_as_device_confirmation(self):
        use_case = code(APP / "Application/Installation/DirectPackageInstallUseCase.swift")
        self.assertIn(".submittedForInstallation", use_case)
        self.assertIn(".submittedForGuestImport", use_case)
        self.assertNotIn(".installedDirectly", use_case)
        self.assertIn("try Task.checkCancellation()", use_case)
        self.assertIn("installation.releaseImportedPackage", use_case)

    def test_synchronized_groups_and_membership_are_target_relative(self):
        objects = {m[1]: m[2] for m in OBJECT.finditer(PBX.read_text())}
        for ident, expected in GROUPS.items():
            actual = re.search(r"\bpath = ([^;]+);", objects[ident])[1].strip('"')
            self.assertEqual(actual, expected)
            self.assertTrue((ROOT / actual).is_dir())
        expected = json.loads(MAP.read_text()).get("membershipExceptions", {})
        self.assertTrue(expected, "original-to-new target membership evidence is required")
        for ident, paths in expected.items():
            body = re.search(r"membershipExceptions = \((.*?)\);", objects[ident], re.S)[1]
            actual = [line.strip().rstrip(',').strip('"') for line in body.splitlines() if line.strip()]
            self.assertEqual(actual, paths, ident)
        result = subprocess.run([sys.executable, str(SOURCE / "Tools/Validation/repository-validation/check-pbxproj.py")], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_project_configurations_use_existing_nonsecret_xcconfig_inputs(self):
        pbx = PBX.read_text()
        references = re.findall(r"baseConfigurationReference = ([A-F0-9]+) /\* (Debug|Release)\.xcconfig \*/;", pbx)
        self.assertEqual(len(references), 4)
        for name in ("Shared", "Debug", "Release"):
            path = SOURCE / "Configuration/Build" / (name + ".xcconfig")
            self.assertTrue(path.is_file())
            if name != "Shared":
                self.assertIn('#include "Shared.xcconfig"', path.read_text())
        for macro, relative in re.findall(r"(\$\((?:SRCROOT|PROJECT_DIR)\)/|\$\{(?:SRCROOT|PROJECT_DIR)\}/)([^\s\";\\]+)", pbx):
            self.assertTrue((ROOT / relative).exists(), macro + relative)

    def test_bridging_header_includes_resolve_inside_the_flat_ios_root(self):
        header = SOURCE / "Configuration/Build/iOS/VexSign-Bridging-Header.h"
        includes = re.findall(r'^\s*#(?:include|import)\s+"([^"]+)"', header.read_text(), re.M)
        # The count is asserted so a header that silently stops being included is caught; the
        # set below is what actually has to resolve.
        self.assertEqual(len(includes), 4, includes)
        resolved = {(header.parent / relative).resolve() for relative in includes}
        self.assertEqual(resolved, {
            APP / "Infrastructure/Archives/Extraction/Zstd/VexZstd.h",
            APP / "Infrastructure/Archives/IPA/MachO/MachOUtils.h",
            APP / "Platform/Apple/Device/iconPoc.h",
            APP / "Platform/Compatibility/EmbeddedContainerRuntime.h",
        })
        for path in resolved:
            self.assertTrue(path.is_file(), str(path))

    def test_local_swiftpm_and_workspace_references_resolve(self):
        checked = 0
        for manifest in (SOURCE / "Packages").rglob("Package.swift"):
            for relative in re.findall(r'(?m)^\s*\.package\(path:\s*"([^"]+)"', manifest.read_text()):
                self.assertTrue((manifest.parent / relative / "Package.swift").is_file(), str(manifest) + relative)
                checked += 1
        self.assertGreaterEqual(checked, 3)
        for relative in re.findall(r'location = "(?:group|container):([^"]+)"', WORKSPACE.read_text()):
            self.assertTrue((ROOT / relative).exists(), relative)
        for relative in re.findall(r"relativePath = ([^;]+);", PBX.read_text()):
            self.assertTrue((ROOT / relative.strip('"')).is_dir(), relative)

    def test_service_build_contexts_and_runtime_resources_exist(self):
        web = SOURCE / "Services/WebManager"
        cloud = SOURCE / "Services/Cloud"
        self.assertIn("$(IMAGE) VexSign/Services/WebManager", (ROOT / "Makefile").read_text())
        for name in ("API/main.py", "Configuration/requirements.txt", "Configuration/data/revoked_certs.json", "Dashboard/icon.png", "Dockerfile"):
            self.assertTrue((web / name).is_file(), name)
        service_tests = list((web / "Tests").glob("test_*.py"))
        self.assertGreaterEqual(len(service_tests), 7)
        for path in service_tests:
            self.assertIn('Path(__file__).resolve().parents[1] / "API"', path.read_text(), str(path))
        for blueprint in (ROOT / "render.yaml", web / "Configuration/render.yaml"):
            self.assertIn("rootDir: VexSign/Services/WebManager", blueprint.read_text())
            self.assertIn("uvicorn --app-dir API main:app", blueprint.read_text())
        package = json.loads((cloud / "package.json").read_text())
        self.assertEqual(package["scripts"]["start"], "node dist/API/main.js")
        self.assertEqual(package["scripts"]["worker"], "node dist/Signing/Worker/worker.js")
        self.assertEqual(package["scripts"]["test"], "tsx --test Tests/*.test.ts")
        self.assertIn('"dist/API/main.js"', (cloud / "Dockerfile").read_text())

    def test_all_cloud_relative_imports_resolve_after_subsystem_moves(self):
        cloud = SOURCE / "Services/Cloud"
        checked = 0
        for path in cloud.rglob("*.ts"):
            if any(p in SKIP for p in path.relative_to(cloud).parts):
                continue
            for relative in re.findall(r"from ['\"](\.[^'\"]+)['\"]", path.read_text()):
                target = path.parent / relative
                if target.suffix == ".js":
                    target = target.with_suffix(".ts")
                self.assertTrue(target.is_file(), str(path) + ": " + relative)
                checked += 1
        self.assertGreater(checked, 20)

    def test_ci_filters_and_validation_entry_points_follow_the_main_tree(self):
        workflows = ROOT / ".github/workflows"
        text = "\n".join(p.read_text() for p in workflows.glob("*.yml"))
        for pattern in ("VexSign/App/**", "VexSign/Packages/**", "VexSign/Tests/**", "VexSign/Tools/**", "VexSign/Documentation/**", "VexSign/Configuration/**", "VexSign/Services/Cloud/**", "VexSign/Services/WebManager/**"):
            self.assertIn(pattern, text, pattern)
        for path in (ROOT / "Makefile", workflows / "ci.yml"):
            self.assertIn("VexSign/Tools/Validation/architecture-rules/test_repository_layout.py", path.read_text())
        for match in re.finditer(r"(?:python3|bash|node)\s+(VexSign/Tools/[^\s'\";|)]+)", text):
            self.assertTrue((ROOT / match[1]).is_file(), match[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
