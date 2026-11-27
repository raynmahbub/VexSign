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

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT
APP = ROOT / "VexSign" / "App"
PLATFORM = ROOT / "Platform"
PBX = ROOT / "VexSign.xcodeproj/project.pbxproj"
WORKSPACE = ROOT / "VexSign.xcworkspace/contents.xcworkspacedata"
ROOT_LAYERS = {
    "VexSign", "Packages", "VexSignTests", "Tools", "Config", "Platform",
    "Services", "Docs",
}
APP_LAYERS = {"Navigation", "Composition", "Bootstrap"}
SKIP = {".git", "node_modules", "dist", "__pycache__", ".pytest_cache", ".venv", ".build", ".swiftpm"}
ALIASES = (
    ("VexSign/Resources/Templates/app-repo.json", "app-repo.json"),
)
# The root is an entry surface, not a place to grow data files. Dotfiles are allowed
# as tool configuration; every other root file must be on this reviewed list.
ROOT_FILES = {
    ".editorconfig", ".gitattributes", ".gitignore", ".swiftformat", ".swiftlint.yml",
    "LICENSE", "Makefile", "README.md", "app-repo.json",
    # LicensePlistBuildTool reads only <project root>/license_plist.yml (Plugins/LicensePlistBuildTool).
    "license_plist.yml",
}
# Paths explicitly rejected by the adopted root contract. A synchronized-root move is
# a build change, so these must fail at the portable gate rather than at a macOS-only build.
REJECTED_PATHS = (
    "Core", "Infrastructure", "Sources", "Tests", "UITests", "Configuration",
    "Documentation", "VexSignUITests", "Platform/iOS", "VexSignTests/UI",
    "VexSign/App/iOS",
)
GROUPS = {
    "3379C1BB2DA869A1004372DA": "VexSign/App",
    "E0E0E0000000000000000001": "VexSign/Shared",
    "E0E0E0000000000000000002": "VexSign/Storage",
    "E0E0E0000000000000000003": "VexSign/Networking",
    "E0E0E0000000000000000004": "VexSign/System",
    "E0E0E0000000000000000005": "VexSign/DesignSystem",
    "E0E0E0000000000000000006": "VexSign/Services",
    "E0E0E0000000000000000007": "VexSign/Features",
    "E0E0E0000000000000000008": "VexSign/Resources",
    "E0E0E0000000000000000009": "VexSign/Security",
    "AABA5D1A2DB3C87800BFCD2C": "VexSignTests",
    "EE000000000000000000000B": "VexSignTests/UITests",
    "3A2F0EE82E96DA5A009DE4CE": "Platform/Extensions/WidgetExtension",
    "C0FFEE000000000000000001": "Platform/TV",
    "C0FFEE00000000000000000D": "Platform/Vision",
    "C0FFEE000000000000000019": "Platform/Watch/VexSignWatch",
    "C0FFEE000000000000000025": "Platform/Watch/VexSignWatchWidgets",
}
OBJECT = re.compile(r'(?m)^\t\t([A-F0-9]{24}) /\*[^\n]*\*/ = \{\n(.*?)^\t\t\};', re.S)


def code(path: Path) -> str:
    # Keep strings (including URLs) intact; remove whole-line source comments.
    text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
    return re.sub(r"(?m)^\s*//.*$", "", text)


class RepositoryLayoutTests(unittest.TestCase):
    def test_requested_root_tree_is_the_repository_root(self):
        self.assertEqual({p.name for p in ROOT.iterdir() if p.is_dir()} - SKIP - {".git", ".githooks", ".github", ".arena", ".cache", "__pycache__", ".build", ".swiftpm", ".vite", "build", "dist", "node_modules"},
                         ROOT_LAYERS | {"VexSign.xcodeproj", "VexSign.xcworkspace"})
        for legacy in ("App", "Apple", "DesignSystem", "Networking", "Shared", "Storage", "Resources",
                       "VexSign/App/iOS", "VexSign/Packages", "VexSign/Tests", "VexSign/Tools",
                       "VexSign/Configuration", "Configuration", "Documentation", "Tests", "UITests",
                       "Integrations", "app", "services", "res"):
            self.assertFalse((ROOT / legacy).exists(), f"legacy root remains: {legacy}")
        for name in ("README.md", "Makefile", "LICENSE",
                     ".github", ".github/workflows",
                     ".github/ISSUE_TEMPLATE",
                     "VexSign.xcodeproj", "VexSign.xcworkspace"):
            self.assertTrue((ROOT / name).exists(), name)

    def test_root_files_are_curated(self):
        """No new data/configuration file at the root without a reviewed contract."""
        actual = {p.name for p in ROOT.iterdir()
                  if p.is_file() and not p.name.startswith(".")}
        expected = {name for name in ROOT_FILES if not name.startswith(".")}
        self.assertEqual(actual, expected, "unexpected or missing root file")
        for name in sorted(name for name in ROOT_FILES if name.startswith(".")):
            self.assertTrue((ROOT / name).is_file(), name)

    def test_rejected_root_shapes_stay_absent(self):
        for relative in REJECTED_PATHS:
            self.assertFalse((ROOT / relative).exists(),
                             f"rejected architecture path remains: {relative}")

    def test_test_roots_match_xcode_targets(self):
        """Target names and source roots are deliberately not the same string."""
        pbx = PBX.read_text()
        self.assertIn("name = VexSignTests;", pbx)
        self.assertIn("path = VexSignTests;", pbx)
        self.assertIn("name = VexSignUITests;", pbx)
        self.assertIn("path = VexSignTests/UITests;", pbx)
        self.assertTrue((ROOT / "VexSignTests/UITests/VexSignUITests.swift").is_file())
        self.assertTrue((ROOT / "VexSignTests/UnitTests").is_dir())
        self.assertFalse((ROOT / "Tests").exists())
        self.assertFalse((ROOT / "UITests").exists())
        self.assertFalse((ROOT / "VexSignUITests").exists())

    def test_app_platform_roots_keep_every_entry_point(self):
        self.assertEqual({p.name for p in APP.iterdir() if p.is_dir()}, APP_LAYERS)
        self.assertTrue((APP / "VexSignApp.swift").is_file())
        # Platform folders are siblings of App, never inside it: a synchronized
        # root nested in another root is claimed by more than one target.
        for platform, entry_point in (
            ("TV", "VexSignTVApp.swift"),
            ("Vision", "VexSignVisionApp.swift"),
            ("Extensions/WidgetExtension", "VexSignWidgetExtensionBundle.swift"),
        ):
            self.assertTrue((PLATFORM / platform / entry_point).is_file(), platform)
            self.assertFalse((APP / platform).exists(), f"platform folder nested in App: {platform}")
        self.assertTrue((PLATFORM / "TV/Assets.xcassets/Contents.json").is_file())
        self.assertTrue((PLATFORM / "Vision/Assets.xcassets/Contents.json").is_file())
        self.assertTrue((PLATFORM / "Extensions/WidgetExtension/Assets.xcassets/Contents.json").is_file())
        self.assertEqual({p.name for p in (PLATFORM / "Watch").iterdir()},
                         {"VexSignWatch", "VexSignWatchWidgets"})
        self.assertTrue((PLATFORM / "Watch/VexSignWatch/VexSignWatchApp.swift").is_file())
        self.assertTrue((PLATFORM / "Watch/VexSignWatchWidgets/VexSignWatchWidgetBundle.swift").is_file())
        self.assertTrue((ROOT / "VexSign/Resources/SharedPlatformInfo/Companion-Info.plist").is_file())

    def test_requested_app_shell_and_navigation(self):
        for name in ("VexSignApp.swift", "AppDelegate.swift", "AppDelegate+BackgroundTasks.swift"):
            self.assertTrue((APP / name).is_file(), name)
        for name in ("AppContainer.swift", "AppEnvironment.swift", "AppLifecycleCoordinator.swift"):
            self.assertTrue((APP / "Composition" / name).is_file(), name)
        self.assertTrue((APP / "Bootstrap/AppPreferencesBootstrap.swift").is_file())
        for name in ("AppNavigationManager.swift", "WorkspaceNavigation.swift"):
            self.assertTrue((APP / "Navigation" / name).is_file(), name)
        for name in ("TabbarView", "TabEnum", "WorkspaceTabs", "TabBarPreferences"):
            self.assertTrue((APP / "Navigation/Tabs" / (name + ".swift")).is_file(), name)

    def test_features_named_in_the_target_tree_all_exist(self):
        for feature in ("Dashboard", "Library", "Import", "Signing", "Certificates", "Accounts",
                        "Devices", "Installation", "Sources", "Downloads", "Tasks", "Backup", "Settings"):
            self.assertTrue(list((ROOT / "VexSign/Features" / feature).rglob("*.swift")), feature)
        for feature in ("Updates",):
            self.assertTrue(list((ROOT / "VexSign/Features" / feature).rglob("*.swift")), feature)
        for legacy in ("Home", "Repositories", "Backups"):
            self.assertFalse((ROOT / "VexSign/Features" / legacy).exists(), legacy)

    def test_shared_design_and_support_layers(self):
        for layer in ("Models/Entities", "Models/ValueObjects", "Models/Enums", "Models/Policies",
                      "Models/Results", "Protocols", "Errors", "Localization", "Services"):
            self.assertTrue(list((ROOT / "VexSign/Shared" / layer).rglob("*.swift")), layer)
        self.assertTrue((ROOT / "VexSign/Shared/Protocols/SigningEngine.swift").is_file())
        for layer in ("Components", "Styles", "Typography"):
            self.assertTrue(list((ROOT / "VexSign/DesignSystem" / layer).rglob("*.swift")), layer)

    def test_security_networking_and_design_system_areas(self):
        # Security is a first-class area with named responsibilities, not a bucket: each
        # sub-area answers a different question, and `Policies/` holds the rules the rest
        # of the app calls instead of re-deciding them.
        for area in ("Certificates", "Cryptography", "CodeSigning", "Entitlements",
                     "Provisioning", "ArchiveValidation", "Trust", "Credentials", "Policies"):
            self.assertTrue(list((ROOT / "VexSign/Security" / area).rglob("*.swift")), area)
        for legacy in ("Validation", "Transport", "Storage", "Logging"):
            self.assertFalse((ROOT / "VexSign/Security" / legacy).exists(),
                             f"Security keeps no catch-all `{legacy}` folder")
        for area in ("HTTP", "API", "Downloads", "Authentication", "Monitoring"):
            self.assertTrue(list((ROOT / "VexSign/Networking" / area).rglob("*.swift")), area)
        for area in ("HTTP/TransferSecuritySession.swift", "HTTP/BoundedResponseFetch.swift",
                     "HTTP/HTTPTimeoutPolicy.swift",
                     "Downloads/PackageDownloadRedirectDelegate.swift",
                     "Authentication/AuthenticatedRequestBuilder.swift",
                     "Monitoring/LocalNetworkHost.swift",
                     "Monitoring/NetworkReachabilityMonitor.swift"):
            self.assertTrue((ROOT / "VexSign/Networking" / area).is_file(), area)
        for area in ("Components", "Styles", "Typography", "Modifiers"):
            self.assertTrue(list((ROOT / "VexSign/DesignSystem" / area).rglob("*.swift")), area)
        self.assertFalse((ROOT / "VexSign/DesignSystem/Styles/Modifiers").exists(),
                         "Modifiers is a sibling of Styles, not a child of it")

    def test_services_storage_networking_and_apple_layers(self):
        for service in ("Signing", "Identity", "Import", "Installation", "Repository",
                        "Download", "Backup", "Tasks", "Updates", "Accounts", "Diagnostics", "WebManager"):
            self.assertTrue(list((ROOT / "VexSign/Services" / service).rglob("*.swift")), service)
        for layer in ("Database", "Keychain", "FileSystem", "Repositories"):
            self.assertTrue(list((ROOT / "VexSign/Storage" / layer).rglob("*.swift")), layer)
        self.assertTrue((ROOT / "VexSign/Storage/Database/VexSign.xcdatamodeld").is_dir())
        self.assertTrue(list((ROOT / "VexSign/Security").rglob("*.swift")))
        for layer in ("DeviceCommunication", "BackgroundTasks", "Notifications", "Compatibility",
                      "FileCoordination", "AppIntents", "Haptics"):
            self.assertTrue(list((ROOT / "VexSign/System" / layer).rglob("*.swift")), layer)

    def test_design_system_resources_are_app_owned(self):
        self.assertTrue((ROOT / "VexSign/Resources/Assets.xcassets/Contents.json").is_file())
        self.assertTrue((ROOT / "VexSign/Resources/AppIcon.icon/icon.json").is_file())
        self.assertTrue((ROOT / "VexSign/Resources/Settings.bundle/Root.plist").is_file())
        self.assertTrue((ROOT / "VexSign/Resources/Localizations/Localizable.xcstrings").is_file())
        self.assertTrue((ROOT / "VexSign/Resources/ellekit.deb").is_file())
        self.assertTrue((ROOT / "VexSign/Resources/icon.png").is_file())

    def test_packages_use_the_canonical_sources_wrapper(self):
        expected = {"NativeSigning", "DeviceBridge", "SideSign", "AltSourceKit", "NimbleKit", "Vendor"}
        self.assertEqual({p.name for p in (ROOT / "Packages").iterdir() if p.is_dir()}, expected)
        for package, targets in (
            ("AltSourceKit", ["AltSourceKit"]),
            ("NimbleKit", ["NimbleExtensions", "NimbleJSON", "NimbleViews"]),
        ):
            manifest = (ROOT / "Packages" / package / "Package.swift").read_text()
            self.assertIn(f'Sources/{package}"' if package == "AltSourceKit" else "Sources/NimbleKit", manifest)
            for target in targets:
                self.assertTrue((ROOT / "Packages" / package / "Sources" / (package if package == "AltSourceKit" else f"NimbleKit/{target}")).is_dir(), target)
        for relative in ("Native/vexsign_device.rs", "prepare.py", "inputs.lock.json",
                         "LICENSE.idevice.txt", "test_prepare.py"):
            self.assertTrue((ROOT / "Packages/DeviceBridge" / relative).is_file(), relative)

    def test_tests_tools_and_configuration_roots(self):
        for suite in ("UnitTests", "IntegrationTests", "SecurityTests", "PerformanceTests", "Support"):
            self.assertTrue(list((ROOT / "VexSignTests" / suite).rglob("*")), suite)
        self.assertTrue((ROOT / "VexSignTests/UITests/VexSignUITests.swift").is_file())
        for name in ("Shared.xcconfig", "Debug.xcconfig", "Release.xcconfig"):
            self.assertTrue((ROOT / "Config/BuildSettings" / name).is_file(), name)
        self.assertTrue((ROOT / "Config/BuildSettings/iOS/Info.plist").is_file())
        self.assertTrue((ROOT / "Config/Entitlements/iOS/VexSign.entitlements").is_file())
        for tool in ("Validation", "Scripts", "Release", "Build", "Audit"):
            self.assertTrue(list((ROOT / "Tools" / tool).rglob("*")), tool)

    def test_services_web_and_cloud_build_contexts_resolve(self):
        web = ROOT / "Services/WebManager"
        cloud = ROOT / "Services/Cloud"
        self.assertIn("$(IMAGE) Services/WebManager", (ROOT / "Makefile").read_text())
        for name in ("API/main.py", "Configuration/requirements.txt",
                     "Configuration/data/revoked_certs.json", "Dashboard/icon.png", "Dockerfile"):
            self.assertTrue((web / name).is_file(), name)
        self.assertEqual(json.loads((cloud / "package.json").read_text())["scripts"]["start"],
                         "node dist/API/main.js")
        for blueprint in (web / "Configuration/render.yaml",):
            self.assertIn("rootDir: Services/WebManager", blueprint.read_text())

    def test_domain_is_foundation_only_and_has_no_concrete_io_or_globals(self):
        files = list((ROOT / "VexSign/Shared/Models").rglob("*.swift"))
        self.assertTrue(files)
        for path in files:
            source = code(path)
            imports = set(re.findall(r"(?m)^import (\w+)", source))
            self.assertLessEqual(imports, {"Foundation"}, str(path))
            for pattern in (r"\.shared\b", r"FileManager\b", r"URLSession\b", r"NSFileCoordinator\b",
                            r"UserDefaults\b", r"Data\(contentsOf:", r"Bundle\.main"):
                self.assertNotRegex(source, pattern, str(path))

    def test_application_use_cases_depend_on_ports_not_implementations(self):
        files = list((ROOT / "VexSign/Features").rglob("*/UseCases/**/*.swift"))
        self.assertTrue(files)
        for path in files:
            source = code(path)
            self.assertLessEqual(set(re.findall(r"(?m)^import (\w+)", source)), {"Foundation"}, str(path))
            for pattern in (r"\.shared\b", r"FileManager\b", r"URLSession\b", r"NSFileCoordinator\b",
                            r"UserDefaults\b", r"AnisetteProviderFactory\b", r"DirectInstaller\b",
                            r"ZsignEngine\b", r"ErrorBoundary\b", r"SubsystemDiagnosticsLog\b"):
                self.assertNotRegex(source, pattern, str(path))

    def test_library_display_contract_is_a_domain_value_boundary(self):
        contract = code(ROOT / "VexSign/Shared/Models/Entities/LibraryApp.swift")
        self.assertIn("protocol AppInfoPresentable", contract)
        self.assertNotIn("NSManagedObject", contract)
        self.assertNotIn("CoreData", contract)
        self.assertIn("struct LibraryAppRecord", code(ROOT / "VexSign/Shared/Models/Entities/WorkspaceSnapshot.swift"))

    def test_engine_port_is_used_by_the_existing_pipeline(self):
        self.assertIn("protocol SigningEngine", (ROOT / "VexSign/Shared/Protocols/SigningEngine.swift").read_text())
        self.assertIn("struct ZsignAdapter: SigningEngine",
                      (ROOT / "VexSign/Services/Signing/Engines/Zsign/ZsignAdapter.swift").read_text())
        self.assertIn("engine.sign(request)",
                      (ROOT / "VexSign/Services/Signing/Execution/ZsignHandler.swift").read_text())
        for name in ("SigningService", "UnifiedTaskCenter", "InstallQueue", "Storage"):
            declarations = []
            for root in (ROOT / "VexSign/Services", ROOT / "VexSign/Storage"):
                for path in root.rglob("*.swift"):
                    if re.search(r"(?m)^\s*(?:final\s+)?(?:class|actor|struct)\s+" + name + r"\b", code(path)):
                        declarations.append(path)
            self.assertEqual(len(declarations), 1, f"{name}: {declarations}")

    def test_install_submission_is_not_reported_as_device_confirmation(self):
        use_case = code(ROOT / "VexSign/Features/Installation/UseCases/DirectPackageInstallUseCase.swift")
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
        result = subprocess.run([sys.executable, str(ROOT / "Tools/Validation/repository-validation/check-pbxproj.py")],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_project_configurations_use_existing_nonsecret_xcconfig_inputs(self):
        pbx = PBX.read_text()
        references = re.findall(r"baseConfigurationReference = ([A-F0-9]+) /\* (Debug|Release)\.xcconfig \*/;", pbx)
        self.assertEqual(len(references), 4)
        for name in ("Shared", "Debug", "Release"):
            path = ROOT / "Config/BuildSettings" / (name + ".xcconfig")
            self.assertTrue(path.is_file())
            if name != "Shared":
                self.assertIn('#include "Shared.xcconfig"', path.read_text())
        for macro, relative in re.findall(r"(\$\((?:SRCROOT|PROJECT_DIR)\)/|\$\{(?:SRCROOT|PROJECT_DIR)\}/)([^\s\";\\]+)", pbx):
            self.assertTrue((ROOT / relative).exists(), macro + relative)

    def test_bridging_header_includes_resolve_under_the_new_roots(self):
        header = ROOT / "Config/BuildSettings/iOS/VexSign-Bridging-Header.h"
        includes = re.findall(r'^\s*#(?:include|import)\s+"([^"]+)"', header.read_text(), re.M)
        self.assertEqual(len(includes), 4, includes)
        resolved = {(header.parent / relative).resolve() for relative in includes}
        self.assertEqual(resolved, {
            ROOT / "VexSign/Services/Import/Extraction/Zstd/VexZstd.h",
            ROOT / "VexSign/Services/Import/IPA/MachO/MachOUtils.h",
            ROOT / "VexSign/System/DeviceCommunication/iconPoc.h",
            ROOT / "VexSign/System/Compatibility/EmbeddedContainerRuntime.h",
        })
        for path in resolved:
            self.assertTrue(path.is_file(), str(path))

    def test_local_swiftpm_and_workspace_references_resolve(self):
        checked = 0
        for manifest in (ROOT / "Packages").rglob("Package.swift"):
            for relative in re.findall(r'(?m)^\s*\.package\(path:\s*"([^"]+)"', manifest.read_text()):
                self.assertTrue((manifest.parent / relative / "Package.swift").is_file(), str(manifest) + relative)
                checked += 1
        self.assertGreaterEqual(checked, 3)
        for relative in re.findall(r'location = "(?:group|container):([^"]+)"', WORKSPACE.read_text()):
            self.assertTrue((ROOT / relative).exists(), relative)
        for relative in re.findall(r"relativePath = ([^;]+);", PBX.read_text()):
            self.assertTrue((ROOT / relative.strip('"')).is_dir(), relative)

    def test_source_fixtures_read_files_that_exist(self):
        """A test that reads a repository file by path breaks silently on a move."""
        reads = set()
        for path in sorted((ROOT / "VexSignTests").rglob("*.swift")):
            reads.update(re.findall(r'RepositorySourceFixture\.read\("([^"]+)"\)',
                                    path.read_text(encoding="utf-8")))
        self.assertTrue(reads, "no source fixtures found; the pattern changed")
        missing = sorted(r for r in reads if not (ROOT / r).is_file())
        self.assertEqual(missing, [], "source fixtures point at files that do not exist")

    def test_compatibility_aliases_are_byte_identical(self):
        for canonical, alias in ALIASES:
            self.assertEqual((ROOT / canonical).read_bytes(), (ROOT / alias).read_bytes(), alias)
        self.assertEqual(json.loads((ROOT / "app-repo.json").read_text())["sourceURL"],
                         "https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json")

    def test_no_placeholder_or_empty_scaffolding(self):
        for path in ROOT.rglob("*"):
            if not path.is_dir() or any(part in SKIP or part.startswith(".") for part in path.relative_to(ROOT).parts):
                continue
            if any(part.endswith(".xcassets") or part.endswith(".xcodeproj") or part.endswith(".xcworkspace")
                   or part.endswith(".xcdatamodeld") or part.endswith(".icon") or part.endswith(".bundle")
                   or part.endswith(".xcstrings") or part.endswith(".docc") for part in path.relative_to(ROOT).parts):
                continue
            self.assertTrue(any(path.iterdir()), f"empty placeholder directory: {path.relative_to(ROOT)}")
            self.assertNotIn(path.name, {"Misc", "Others", "Common2", "Helpers2", "Manager"})

    def test_ci_filters_and_validation_entry_points_follow_the_new_tree(self):
        workflows = ROOT / ".github/workflows"
        text = "\n".join(p.read_text() for p in workflows.glob("*.yml"))
        for pattern in ("VexSign/App/**", "Packages/**", "VexSignTests/**", "Tools/**",
                        "Config/**", "Services/Cloud/**", "Services/WebManager/**",
                        "VexSign/Shared/**", "VexSign/Services/**", "VexSign/Storage/**", "VexSign/Networking/**",
                        "VexSign/System/**", "VexSign/DesignSystem/**", "VexSign/Resources/**",
                        "VexSign/Features/**", "VexSign/Security/**"):
            self.assertIn(pattern, text, pattern)
        for path in (ROOT / "Makefile", workflows / "ci.yml"):
            self.assertIn("Tools/Validation/architecture-rules/test_repository_layout.py", path.read_text())
        for match in re.finditer(r"(?:python3|bash|node)\s+(Tools/[^\s'\";|)]+)", text):
            self.assertTrue((ROOT / match[1]).is_file(), match[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
