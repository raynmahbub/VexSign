#!/usr/bin/env python3
"""Regression guard for the order the on-device Web Manager wires its middleware.

`THREAT_MODEL.md` says a page on the internet cannot read credentials from the Web
Manager: a rebound hostname or a cross-origin page is refused *before* the request
is authenticated or its body is parsed. That promise lives in one function —
`WebManagerServer.start()` — and the unit tests cannot see it, because
`WebManagerAccessPolicy`, `WebManagerAuthMiddleware` and
`WebManagerSensitiveAccessMiddleware` are tested independently of the order they are
installed in.

Registering routes (or the auth middleware) ahead of the origin check, or dropping
the sensitive-access gate, would leave every Swift unit test green. This gate fails
instead.

    python3 VexSign/Tools/Validation/security-validation/test_webmanager_wiring.py
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[4]
SERVER = ROOT / "VexSign/App/iOS/Infrastructure/Networking/WebManager/WebManagerServer.swift"


def _start_body(source: str) -> str:
    """The body of `func start()`, found by brace matching (not indentation)."""
    match = re.search(r"func start\(\)[^{]*\{", source)
    if not match:
        raise AssertionError("WebManagerServer.start() is gone")
    depth = 0
    for index in range(match.end() - 1, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[match.end():index]
    raise AssertionError("unbalanced braces in start()")


class WebManagerWiringTests(unittest.TestCase):
    def setUp(self):
        self.source = SERVER.read_text(encoding="utf-8")
        self.start = _start_body(self.source)

    def test_origin_check_runs_before_credentials_and_routes(self):
        order = [
            "WebManagerOriginMiddleware(",
            "WebManagerAuthMiddleware(",
            "WebManagerSensitiveAccessMiddleware(",
            "_configureHTTP(app)",
            "_configureWebDAV(app)",
        ]
        positions = []
        for needle in order:
            index = self.start.find(needle)
            self.assertNotEqual(index, -1, f"{needle} is no longer installed in start()")
            positions.append(index)
        self.assertEqual(
            positions,
            sorted(positions),
            "a rebound host must be refused before credentials are read and before "
            "routes exist; keep the origin middleware first",
        )

    def test_origin_middleware_uses_the_tested_policy_instead_of_inline_rules(self):
        policy = (ROOT / "VexSign/App/iOS/Infrastructure/Networking/WebManager/WebManagerAccess.swift")
        self.assertTrue(policy.exists(), "WebManagerAccessPolicy moved; update this gate")
        self.assertIn("enum WebManagerAccessPolicy", policy.read_text(encoding="utf-8"))
        origin_start = self.source.find("struct WebManagerOriginMiddleware")
        self.assertNotEqual(origin_start, -1)
        body = self.source[origin_start:self.source.find("\n}", origin_start)]
        self.assertIn("WebManagerAccessPolicy.isAllowedHostHeader", body)
        self.assertIn("WebManagerAccessPolicy.isAllowedOrigin", body)

    def test_credential_comparison_is_constant_time(self):
        auth_start = self.source.find("struct WebManagerAuthMiddleware")
        self.assertNotEqual(auth_start, -1)
        body = self.source[auth_start:self.source.find("\n}", auth_start)]
        self.assertIn("constantTimeEquals(basic.username, username)", body)
        self.assertIn("constantTimeEquals(basic.password, password)", body)
        self.assertNotIn("basic.password ==", body)
        self.assertNotIn("basic.password !=", body)

    def test_sensitive_gate_is_installed_exactly_once(self):
        self.assertEqual(
            self.start.count("WebManagerSensitiveAccessMiddleware("),
            1,
            "the signing/certificate/delete gate must be a single server-wide middleware",
        )

    def test_middleware_is_installed_before_the_server_listens(self):
        listen = self.start.find("app.server.start()")
        self.assertNotEqual(listen, -1)
        self.assertLess(self.start.find("WebManagerOriginMiddleware("), listen)
        self.assertLess(self.start.find("WebManagerSensitiveAccessMiddleware("), listen)


if __name__ == "__main__":
    unittest.main(verbosity=2)
