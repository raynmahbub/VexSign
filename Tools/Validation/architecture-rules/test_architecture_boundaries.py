#!/usr/bin/env python3
"""Source guardrails for VexSign's feature-oriented architecture.

Shared models stay independent of UI/infrastructure, feature use cases consume
ports, and selected views/view models delegate workflows. Security owns trust
policy, Networking owns transport, and App owns composition. These portable
checks do not prove Swift compilation or runtime/device behavior.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
VEXSIGN = ROOT / "VexSign"
APP = ROOT / "VexSign" / "App"
SHARED = ROOT / "VexSign" / "Shared"
SERVICES = ROOT / "VexSign/Services"
NETWORKING = ROOT / "VexSign" / "Networking"
FEATURES = VEXSIGN / "Features"
SECURITY = VEXSIGN / "Security"


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def _imports(source: str) -> set[str]:
    return set(re.findall(r"(?m)^\s*import\s+([A-Za-z0-9_]+)\b", source))


class ArchitectureBoundaryTests(unittest.TestCase):
    def swift_sources(self, directory: Path) -> list[Path]:
        self.assertTrue(directory.is_dir(), f"Missing architecture area: {directory}")
        files = sorted(directory.rglob("*.swift"))
        self.assertTrue(files, f"No Swift sources in {directory}; boundary scan would be empty")
        return files

    def test_current_architecture_areas_have_sources(self) -> None:
        for area in ("App", "Features", "DesignSystem", "Shared", "Services",
                     "Storage", "Networking", "Security", "System"):
            with self.subTest(area=area):
                self.swift_sources(VEXSIGN / area)

    def test_shared_models_avoid_ui_infrastructure_and_globals(self) -> None:
        swift_files = self.swift_sources(SHARED / "Models")

        forbidden_imports = {
            "SwiftUI",
            "UIKit",
            "CoreData",
            "Nuke",
            "NativeSigning",
            "IDeviceSwift",
            "AltSourceKit",
            "SwiftSoup",
        }
        for path in swift_files:
            src = _strip_comments(path.read_text(encoding="utf-8"))
            imports = _imports(src)
            self.assertTrue(
                imports.isdisjoint(forbidden_imports),
                f"{path.relative_to(ROOT)} imports UI/infra modules: {imports & forbidden_imports}",
            )
            for symbol in (".shared", "Storage.", "FileManager.default", "UserDefaults."):
                self.assertNotIn(
                    symbol,
                    src,
                    f"{path.relative_to(ROOT)} must not reference {symbol}",
                )

    def test_feature_use_cases_avoid_ui_frameworks_and_shared_urlsession(self) -> None:
        # Feature use cases orchestrate through ports; workspace contracts are shared.
        swift_files = [path for path in self.swift_sources(FEATURES) if "UseCases" in path.parts]
        self.assertTrue(swift_files, "Feature use cases must exist")
        swift_files += self.swift_sources(SHARED / "Models/Workspace")
        swift_files = sorted({path for path in swift_files if not path.is_dir()})
        self.assertTrue(swift_files, "Use cases and workspace contracts must exist")

        for path in swift_files:
            src = _strip_comments(path.read_text(encoding="utf-8"))
            imports = _imports(src)
            for forbidden in ("SwiftUI", "UIKit", "CoreData", "Nuke", "IDeviceSwift", "AltSourceKit", "NativeSigning", "NimbleExtensions"):
                self.assertNotIn(
                    forbidden,
                    imports,
                    f"{path.relative_to(ROOT)} must not import {forbidden}",
                )
            self.assertNotIn(
                "URLSession.shared",
                src,
                f"{path.relative_to(ROOT)} must delegate transfers through SecureTransferProviding",
            )

    def test_workspace_support_use_case_uses_platform_ports(self) -> None:
        path = VEXSIGN / "Features/Dashboard/UseCases/WorkspaceSupportUseCase.swift"
        src = _strip_comments(path.read_text(encoding="utf-8"))
        self.assertNotIn("import UIKit", src)
        self.assertNotIn("UIAlertController", src)
        self.assertNotIn("UIDevice.current", src)
        self.assertNotIn("UserDefaults.standard", src)
        self.assertNotIn("SigningModeManager.shared", src)
        self.assertNotIn("FileManager.default", src)
        self.assertIn("WorkspaceSupportEnvironmentProviding", src)
        self.assertIn("environment.supportSnapshot()", src)

    def test_presentation_layer_avoids_coredata_and_direct_urlsession(self) -> None:
        pres_dir = FEATURES
        strict_originals = (
            "../App/Navigation/State/AppContainerEnvironment.swift",
            "Certificates/ViewModels/CertificatesCoordinator.swift",
            "Installation/ViewModels/DirectInstallViewModel.swift",
            "Downloads/ViewModels/DownloadsTabViewModel.swift",
            "Dashboard/Home/ViewModels/HomeActionCoordinator.swift",
            "Settings/ViewModels/SettingsAndSecurityViewModels.swift",
        )
        swift_files = sorted(set(pres_dir.rglob("*ViewModel*.swift")) | {pres_dir / name for name in strict_originals})
        self.assertTrue(swift_files, "Presentation ViewModels must exist")

        for path in swift_files:
            src = _strip_comments(path.read_text(encoding="utf-8"))
            imports = _imports(src)
            self.assertNotIn("CoreData", imports, f"{path.relative_to(ROOT)} must not import CoreData")
            self.assertNotIn("Nuke", imports, f"{path.relative_to(ROOT)} must not import Nuke")
            self.assertNotIn("URLSession.shared", src, f"{path.relative_to(ROOT)} must not call URLSession.shared")

    def test_refactored_views_no_longer_hold_network_persistence_or_business_logic(self) -> None:
        strict_view_checks: dict[str, tuple[str, ...]] = {
            "VexSign/Features/Library/Views/DirectInstallSheet.swift": (
                "URLSession.shared",
                "FileManager.default",
                "AppOperationRegistry.shared",
                "DirectInstaller.shared",
                "SigningModeManager.shared",
                "PackageImportService.importPackage",
                "FR.handlePackageFile",
                "UIAlertController",
            ),
            "VexSign/Features/Import/Files/Views/IPSWBrowserView.swift": (
                "URLSession.shared",
                "FileManager.default",
                "BackgroundTaskManager",
                "IPSWBrowser.",
            ),
            "VexSign/Features/Settings/Views/Reset/ResetView.swift": (
                "static func ",
                "Storage.shared",
                "TweakManager.shared",
                "URLCache.shared",
                "HTTPCookieStorage.shared",
                "UIApplication.shared",
                "import Nuke",
            ),
            "VexSign/Features/Updates/FavoritesAndAutoUpdatesSettingsView.swift": (
                "import CoreData",
                "@FetchRequest",
                "Storage.shared",
            ),
            "VexSign/Features/Settings/Views/Security/HiddenAppsSettingsView.swift": (
                "import CoreData",
                "@FetchRequest",
                "AppLockManager.shared",
                "Storage.shared",
            ),
            "VexSign/Features/Settings/Views/Security/SpecificAppLockSettingsView.swift": (
                "import CoreData",
                "@FetchRequest",
                "AppLockManager.shared",
                "Storage.shared",
            ),
            "VexSign/Features/Dashboard/About/DiagnosticsCenterView.swift": (
                "import CoreData",
                "@FetchRequest",
                "CredentialMigrationDiagnostics.shared",
                "UnifiedTaskCenter.shared",
                "SourcesViewModel.shared",
                "DiagnosticBundleExporter",
                "UIActivityViewController",
            ),
            "VexSign/Features/Downloads/Views/DownloadsTabView.swift": (
                "contentsOfDirectory",
                "UIPasteboard.general",
                "UIApplication.open",
            ),
            "VexSign/Features/Accounts/Views/AnisetteProviderConfigView.swift": (
                "HTTPSAnisetteProvider",
                "NativeV3AnisetteProvider",
                "AnisetteServerCatalog.bundled",
                "NativeSigningManager.shared",
            ),
        }

        for rel_path, forbidden in strict_view_checks.items():
            src = _strip_comments((ROOT / rel_path).read_text(encoding="utf-8"))
            for token in forbidden:
                self.assertNotIn(
                    token,
                    src,
                    f"{rel_path} still contains coupled logic `{token}`",
                )

    def test_composition_root_wires_app_container_and_deep_links(self) -> None:
        app_src = _strip_comments((APP / "VexSignApp.swift").read_text(encoding="utf-8"))
        self.assertIn("AppContainer.live()", app_src)
        # The container and its stores are injected by AppEnvironment, which is also where
        # `\.appContainer` is set; the scene applies it once. See VexSign/App/Composition/AppEnvironment.swift.
        self.assertIn("AppEnvironment(container: appContainer", app_src)
        # Every external URL goes through the lock-aware entry point; the raw
        # router call there would bypass the App Lock buffering.
        self.assertIn("appContainer.handleExternalURL(url)", app_src)
        self.assertNotIn("appContainer.makeDeepLinkRouter().handle(url)", app_src)
        delegate = _strip_comments((APP / "AppDelegate.swift").read_text(encoding="utf-8"))
        self.assertIn("BackgroundAndLifecyclePlatform.configureImagePipeline()", delegate)
        self.assertIn("BackgroundAndLifecyclePlatform.ensureDocumentsDirectories()", delegate)
        self.assertIn("AppPreferencesBootstrap.prepare()", app_src)
        self.assertIn("AppLifecycleCoordinator.launch()", app_src)
        self.assertNotIn("class AppDelegate", app_src)
        self.assertNotIn("_migrateLegacyUserDefaults", app_src)
        self.assertNotIn("import Nuke", app_src)

    def test_transfer_security_session_enforces_http_2xx_and_redirects(self) -> None:
        transfer_src = _strip_comments(
            (NETWORKING / "HTTP/TransferSecuritySession.swift").read_text(encoding="utf-8")
        )
        policy_src = _strip_comments(
            (VEXSIGN / "Security/Policies/TransferAcceptancePolicy.swift").read_text(encoding="utf-8")
        )
        integrity_src = _strip_comments(
            (SERVICES / "Download/DownloadIntegrity.swift").read_text(encoding="utf-8")
        )
        # Transport asks the policy, not the download workflow that happens to use it.
        self.assertIn("TransferAcceptancePolicy.isAcceptableHTTPStatus(status)", transfer_src)
        self.assertNotIn("DownloadIntegrity", transfer_src)
        self.assertIn("(200..<300).contains", policy_src)
        # One definition of the rule: the workflow layer delegates instead of copying it.
        self.assertNotIn("(200..<300).contains", integrity_src)
        self.assertIn("TransferAcceptancePolicy.isAcceptableHTTPStatus", integrity_src)
        self.assertIn("PackageDownloadRedirectDelegate", transfer_src)
        self.assertIn("ephemeral", transfer_src)

    def test_security_layer_has_no_ui_or_persistence_dependency(self) -> None:
        # Security decides; it never renders and it never opens a managed object context.
        # Storage owns persistence, so a Core Data bridge belongs in Storage/Keychain.
        forbidden = {"SwiftUI", "UIKit", "CoreData", "Nuke", "AppKit"}
        offenders = {}
        for path in self.swift_sources(SECURITY):
            hits = _imports(_strip_comments(path.read_text(encoding="utf-8"))) & forbidden
            if hits:
                offenders[path.relative_to(ROOT).as_posix()] = sorted(hits)
        self.assertEqual({}, offenders, "Security must not import UI or persistence frameworks")

    def test_networking_layer_has_no_ui_or_workflow_dependency(self) -> None:
        # Transport compiles without SwiftUI, without persistence, and without the
        # download workflow that consumes it: the shared rules live in Security/Policies.
        forbidden = {"SwiftUI", "UIKit", "CoreData", "Nuke", "AppKit"}
        offenders = {}
        workflow_types = ("DownloadIntegrity.", "DownloadManager.", "DownloadPreferences.")
        leaks = {}
        for path in self.swift_sources(NETWORKING):
            source = _strip_comments(path.read_text(encoding="utf-8"))
            hits = _imports(source) & forbidden
            if hits:
                offenders[path.relative_to(ROOT).as_posix()] = sorted(hits)
            named = [name for name in workflow_types if name in source]
            if named:
                leaks[path.relative_to(ROOT).as_posix()] = named
        self.assertEqual({}, offenders, "Networking must not import UI or persistence frameworks")
        self.assertEqual({}, leaks, "Networking must not depend on the Services/Download workflow")

    def test_app_target_declares_each_type_once(self) -> None:
        # A type that is declared in two files cannot compile, and the copy that survives
        # the fix is invisible in review: `PackageDownloadRedirectDelegate` lived in both
        # Security/Validation and Networking/Downloads until the networking area moved.
        declaration = re.compile(
            r"^(?:@[A-Za-z0-9_]+(?:\([^)]*\))?\s*)*"
            r"(?:public |internal |private |fileprivate |final |open )*"
            r"(?:class|struct|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"
        )
        declared: dict[str, list[str]] = {}
        for path in sorted(VEXSIGN.rglob("*.swift")):
            if "Resources" in path.parts:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                match = declaration.match(line)
                if match:
                    declared.setdefault(match.group(1), []).append(
                        f"{path.relative_to(ROOT).as_posix()}:{number}"
                    )
        self.assertTrue(declared, "no type declarations found; the scan is broken")
        duplicates = {name: where for name, where in declared.items() if len(where) > 1}
        self.assertEqual({}, duplicates, "one type declared in more than one file")


if __name__ == "__main__":
    unittest.main()
