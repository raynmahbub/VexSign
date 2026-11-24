#!/usr/bin/env python3
"""Cross-service contract guard: Python `web_signer.py` relay <-> iOS `WebManagerServer`.

`Services/WebManager/API/web_signer.py` relays browser signing and read-only status
requests to the iPhone's on-device `WebManagerServer`. Because one side is Python (FastAPI +
httpx) and the other is Swift (Vapor), a header rename, route drift, or TLS/IP policy mismatch
would compile cleanly on both sides and fail only when a user connects to their phone.
"""

from __future__ import annotations

import ast
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEB_SIGNER = ROOT / "Services/WebManager/API/web_signer.py"
URL_GUARD = ROOT / "Services/WebManager/API/url_guard.py"
SWIFT_ACCESS = ROOT / "VexSign/Services/WebManager/WebManagerAccess.swift"
SWIFT_SERVER = ROOT / "VexSign/Services/WebManager/WebManagerServer.swift"
SWIFT_API = ROOT / "VexSign/Services/WebManager/WebManagerServer+API.swift"
SWIFT_LOCAL_HOST = ROOT / "VexSign/Networking/Monitoring/LocalNetworkHost.swift"


def _python_constant(path: Path, name: str):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise AssertionError(f"{name} not found in {path}")


class WebManagerRelayContractTests(unittest.TestCase):
    def test_token_header_matches_between_python_relay_and_swift_server(self):
        signer_src = WEB_SIGNER.read_text(encoding="utf-8")
        access_src = SWIFT_ACCESS.read_text(encoding="utf-8")
        m = re.search(r'static let tokenHeader\s*=\s*"([^"]+)"', access_src)
        self.assertIsNotNone(m, "WebManagerAccessPolicy.tokenHeader missing")
        token_header = m.group(1)
        self.assertIn(f'headers["{token_header}"]', signer_src)

    def test_proxy_endpoints_and_sign_route_exist_on_ios_server(self):
        proxy_endpoints = set(_python_constant(WEB_SIGNER, "PROXY_PATHS"))
        self.assertEqual(proxy_endpoints, {"status", "library", "updates"})

        api_src = SWIFT_API.read_text(encoding="utf-8")
        for endpoint in proxy_endpoints:
            self.assertIn(f'app.get("api", "{endpoint}")', api_src)
        self.assertIn('app.on(.POST, "api", "sign", body: .stream)', api_src)

    def test_signed_app_metadata_header_and_fields_match(self):
        signer_src = WEB_SIGNER.read_text(encoding="utf-8")
        api_src = SWIFT_API.read_text(encoding="utf-8")
        self.assertIn('"X-VexSign-Signed-App"', signer_src)
        self.assertIn('"X-VexSign-Signed-App"', api_src)

        m = re.search(r"private struct APISignResponse:\s*Content\s*\{([^}]+)\}", api_src)
        self.assertIsNotNone(m, "APISignResponse struct missing in WebManagerServer+API.swift")
        swift_fields = set(re.findall(r"\blet\s+(\w+)\s*:", m.group(1)))
        self.assertEqual(swift_fields, {"name", "bundleID", "version", "ipa"})

    def test_https_default_pinning_and_tailscale_cgnat_align(self):
        signer_src = WEB_SIGNER.read_text(encoding="utf-8")
        guard_src = URL_GUARD.read_text(encoding="utf-8")
        server_src = SWIFT_SERVER.read_text(encoding="utf-8")
        access_src = SWIFT_ACCESS.read_text(encoding="utf-8")
        local_src = SWIFT_LOCAL_HOST.read_text(encoding="utf-8")

        # Both sides default to HTTPS because WebManagerServer is HTTPS-only.
        self.assertIn('f"https://{raw}"', signer_src)
        self.assertIn("transport: .https(tls)", server_src)
        self.assertIn("tlsCertSha256", signer_src)
        self.assertIn("PinnedTLSStream", guard_src)

        # Both sides accept Tailscale CGNAT 100.64.0.0/10.
        self.assertIn("100.64.0.0/10", guard_src)
        self.assertIn("case 100: return octets[1] >= 64 && octets[1] <= 127", access_src)
        self.assertIn("(100, 64...127)", local_src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
