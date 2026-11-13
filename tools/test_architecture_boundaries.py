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

ROOT = Path(__file__).resolve().parent.parent
VEXSIGN = ROOT / "VexSign"


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def _imports(source: str) -> set[str]:
    return set(re.findall(r"(?m)^\s*import\s+([A-Za-z0-9_]+)\b", source))


class ArchitectureBoundaryTests(unittest.TestCase):
    def test_domain_layer_is_pure_foundation_without_globals(self) -> None:
        domain_dir = VEXSIGN / "Domain"
        swift_files = sorted(domain_dir.glob("*.swift"))
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
        app_dir = VEXSIGN / "Application"
        swift_files = sorted(app_dir.glob("*.swift"))
        self.assertTrue(swift_files, "Application layer must exist")

        for path in swift_files:
            src = _strip_comments(path.read_text(encoding="utf-8"))
            imports = _imports(src)
            self.assertNotIn("SwiftUI", imports, f"{path.relative_to(ROOT)} must not import SwiftUI")
            self.assertNotIn("Nuke", imports, f"{path.relative_to(ROOT)} must not import Nuke")
            self.assertNotIn(
                "URLSession.shared",
                src,
                f"{path.relative_to(ROOT)} must delegate transfers through SecureTransferProviding",
            )

    def test_presentation_layer_avoids_coredata_and_direct_urlsession(self) -> None:
        pres_dir = VEXSIGN / "Presentation"
        swift_files = sorted(pres_dir.glob("*.swift"))
        self.assertTrue(swift_files, "Presentation layer must exist")

        for path in swift_files:
            src = _strip_comments(path.read_text(encoding="utf-8"))
            imports = _imports(src)
            self.assertNotIn("CoreData", imports, f"{path.relative_to(ROOT)} must not import CoreData")
            self.assertNotIn("Nuke", imports, f"{path.relative_to(ROOT)} must not import Nuke")
            self.assertNotIn("URLSession.shared", src, f"{path.relative_to(ROOT)} must not call URLSession.shared")

    def test_refactored_views_no_longer_hold_network_persistence_or_business_logic(self) -> None:
        strict_view_checks: dict[str, tuple[str, ...]] = {
            "VexSign/Views/Library/DirectInstallSheet.swift": (
                "URLSession.shared",
                "FileManager.default",
                "AppOperationRegistry.shared",
                "DirectInstaller.shared",
                "SigningModeManager.shared",
                "PackageImportService.importPackage",
                "FR.handlePackageFile",
                "UIAlertController",
            ),
            "VexSign/Views/FileManager/IPSWBrowserView.swift": (
                "URLSession.shared",
                "FileManager.default",
                "BackgroundTaskManager",
                "IPSWBrowser.",
            ),
            "VexSign/Views/Settings/Reset/ResetView.swift": (
                "static func ",
                "Storage.shared",
                "TweakManager.shared",
                "URLCache.shared",
                "HTTPCookieStorage.shared",
                "UIApplication.shared",
                "import Nuke",
            ),
            "VexSign/Views/Settings/Updates/FavoritesAndAutoUpdatesSettingsView.swift": (
                "import CoreData",
                "@FetchRequest",
                "Storage.shared",
            ),
            "VexSign/Views/Settings/Security/HiddenAppsSettingsView.swift": (
                "import CoreData",
                "@FetchRequest",
                "AppLockManager.shared",
                "Storage.shared",
            ),
            "VexSign/Views/Settings/Security/SpecificAppLockSettingsView.swift": (
                "import CoreData",
                "@FetchRequest",
                "AppLockManager.shared",
                "Storage.shared",
            ),
            "VexSign/Views/Settings/About/DiagnosticsCenterView.swift": (
                "import CoreData",
                "@FetchRequest",
                "CredentialMigrationDiagnostics.shared",
                "UnifiedTaskCenter.shared",
                "SourcesViewModel.shared",
                "DiagnosticBundleExporter",
                "UIActivityViewController",
            ),
            "VexSign/Views/TabView/DownloadsTabView.swift": (
                "contentsOfDirectory",
                "UIPasteboard.general",
                "UIApplication.open",
            ),
            "VexSign/Views/Settings/AnisetteProviderConfigView.swift": (
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
        app_src = _strip_comments((VEXSIGN / "VexSignApp.swift").read_text(encoding="utf-8"))
        self.assertIn("AppContainer.live()", app_src)
        self.assertIn(".environment(\\.appContainer, appContainer)", app_src)
        self.assertIn("appContainer.makeDeepLinkRouter().handle(url)", app_src)
        self.assertIn("BackgroundAndLifecyclePlatform.configureImagePipeline()", app_src)
        self.assertIn("BackgroundAndLifecyclePlatform.ensureDocumentsDirectories()", app_src)
        self.assertNotIn("import Nuke", app_src)

    def test_transfer_security_session_enforces_http_2xx_and_redirects(self) -> None:
        transfer_src = _strip_comments(
            (VEXSIGN / "Security" / "TransferSecuritySession.swift").read_text(encoding="utf-8")
        )
        integrity_src = _strip_comments(
            (VEXSIGN / "Utilities" / "DownloadIntegrity.swift").read_text(encoding="utf-8")
        )
        self.assertIn("DownloadIntegrity.isAcceptableHTTPStatus(status)", transfer_src)
        self.assertIn("(200..<300).contains", integrity_src)
        self.assertIn("PackageDownloadRedirectDelegate", transfer_src)
        self.assertIn("ephemeral", transfer_src)


if __name__ == "__main__":
    unittest.main()
