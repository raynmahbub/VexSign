#!/usr/bin/env python3
"""Architecture boundary guardrails for VexSign's Clean Architecture layers.

Ensures Domain remains pure Foundation, Presentation/Views stay decoupled from raw
network/persistence/business logic, and VexSignApp wires the explicit AppContainer.
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
STORAGE = ROOT / "VexSign" / "Storage"
DESIGN = ROOT / "VexSign" / "DesignSystem"
APPLE = ROOT / "VexSign" / "System"


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def _imports(source: str) -> set[str]:
    return set(re.findall(r"(?m)^\s*import\s+([A-Za-z0-9_]+)\b", source))


class ArchitectureBoundaryTests(unittest.TestCase):
    def test_domain_layer_is_pure_foundation_without_globals(self) -> None:
        domain_dir = SHARED / "Models"
        swift_files = sorted(domain_dir.rglob("*.swift"))
        self.assertTrue(swift_files, "Domain layer must exist")

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

    def test_application_layer_avoids_ui_frameworks_and_shared_urlsession(self) -> None:
        # Use cases are the application layer. Feature Views/ViewModels/Models are
        # presentation and are covered by the presentation checks below.
        swift_files = sorted(VEXSIGN.rglob("**/UseCases/**/*.swift"))
        swift_files += sorted((SHARED / "Models/Workspace").rglob("*.swift"))
        swift_files = sorted({path for path in swift_files if not path.is_dir()})
        self.assertTrue(swift_files, "Application layer must exist")

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
        pres_dir = VEXSIGN / "Features"
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
        integrity_src = _strip_comments(
            (SERVICES / "Download/DownloadIntegrity.swift").read_text(encoding="utf-8")
        )
        self.assertIn("DownloadIntegrity.isAcceptableHTTPStatus(status)", transfer_src)
        self.assertIn("(200..<300).contains", integrity_src)
        self.assertIn("PackageDownloadRedirectDelegate", transfer_src)
        self.assertIn("ephemeral", transfer_src)

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
