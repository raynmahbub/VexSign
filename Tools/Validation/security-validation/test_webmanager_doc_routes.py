#!/usr/bin/env python3
"""Keep the Web Manager route table and the server's routes in agreement.

The Web Manager section of `evidence/service-contracts.md` tells integrators
which endpoints exist
and what authenticates them. Prose that describes a route table rots the moment
someone adds an endpoint, and nothing otherwise notices: the server keeps
working, the document keeps claiming it is complete.

This gate compares the two directions:

* every route registered in the Web Manager sources must be documented, so a new
  endpoint cannot ship undocumented;
* every route in the document must still exist, so a removed endpoint cannot
  leave a promise behind.

WebDAV is a catch-all (`app.on(.PUT, catchall)`), so it is documented as a table
of methods rather than paths and is checked separately: the document must list a
row for each verb the server registers.

Text-level by design — like `test_webmanager_wiring.py` — because the point is
the *contract being stated*, not the runtime behaviour of a listener that needs
an HTTPS identity to boot. See the closing section of the document.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MANAGER = ROOT / "VexSign/Services/WebManager"
DOC = ROOT / "Tools/Validation/security-validation/evidence/service-contracts.md"

# `app.get(\"api\", \"status\")` / `app.post(\"api\", \"cleanup\")`: the method is the
# function name. `app.on(.POST, \"api\", \"sign\", body: .stream)`: the method is the
# first argument. Routes whose path is a variable (`catchall`, `path`) are WebDAV,
# documented as verbs rather than paths, and are deliberately not collected here.
SIMPLE_ROUTE = re.compile(r'app\.(get|post|put|delete)\(\s*((?:"[^"]*"(?:\s*,\s*)?)+)')
METHOD_ROUTE = re.compile(r'app\.on\(\s*\.([A-Z]+)\s*,\s*((?:"[^"]*"(?:\s*,\s*)?)+)')
ROOT_ROUTE = re.compile(r'app\.get\s*\{')
QUOTED = re.compile(r'"([^"]+)"')
DOC_ROW = re.compile(r"^\|\s*`([A-Z]+)`\s*\|\s*`([^`]+)`\s*\|", re.MULTILINE)


def registered_routes():
    """{(METHOD, path)} for every concrete route the server registers."""
    routes = set()
    for source in sorted(MANAGER.glob("*.swift")):
        text = source.read_text(encoding="utf-8")
        if ROOT_ROUTE.search(text):
            routes.add(("GET", "/"))
        for pattern in (SIMPLE_ROUTE, METHOD_ROUTE):
            for match in pattern.finditer(text):
                verb, arguments = match.group(1), QUOTED.findall(match.group(2))
                if not arguments:
                    continue
                routes.add((verb.upper(), "/" + "/".join(arguments)))
    return routes


def documented_routes():
    """{(METHOD, path)} from the JSON API table in the document."""
    text = DOC.read_text(encoding="utf-8")
    # Match the heading line, not the first mention of its name: the section
    # intro names the headings it defines.
    section = re.split(r"(?m)^### JSON API$", text)[1]
    section = re.split(r"(?m)^### WebDAV$", section)[0]
    return {(verb, path.rstrip("/") or "/") for verb, path in DOC_ROW.findall(section)}


def normalise(route):
    """`app.on(.GET, "download", ":name")` and `/download/:name` are the same route."""
    verb, path = route
    return verb.upper(), (path.rstrip("/") or "/")


def placeholders(path):
    """How many `:param` segments a path has, so `/api/x` cannot match `/api/:id`."""
    return tuple(segment for segment in path.split("/") if segment.startswith(":"))


class WebManagerRouteTableTests(unittest.TestCase):
    def test_every_registered_route_is_documented(self):
        documented = {normalise(route) for route in documented_routes()}
        missing = sorted(
            normalise(route) for route in registered_routes() if normalise(route) not in documented
        )
        self.assertEqual(
            missing, [],
            "the server registers routes the contract does not list: "
            + ", ".join(f"{verb} {path}" for verb, path in missing),
        )

    def test_every_documented_route_still_exists(self):
        registered = {normalise(route) for route in registered_routes()}
        stale = sorted(
            normalise(route) for route in documented_routes() if normalise(route) not in registered
        )
        self.assertEqual(
            stale, [],
            "the contract promises routes the server no longer registers: "
            + ", ".join(f"{verb} {path}" for verb, path in stale),
        )

    def test_document_covers_the_webdav_verbs(self):
        text = DOC.read_text(encoding="utf-8")
        webdav = re.split(r"(?m)^### WebDAV$", text)[1]
        webdav = re.split(r"(?m)^### Deliberate", webdav)[0]
        source = (ROOT / "VexSign/Services/WebManager/WebManagerServer+WebDAV.swift").read_text(encoding="utf-8")
        for verb in ("OPTIONS", "PROPFIND", "PUT", "MKCOL", "DELETE", "MOVE", "COPY", "LOCK", "UNLOCK"):
            if f'"{verb}"' not in source and f".{verb}" not in source:
                continue  # the server does not register this verb any more
            self.assertIn(f"`{verb}`", webdav, f"{verb} is registered but not documented")

    def test_authentication_differences_are_stated(self):
        text = DOC.read_text(encoding="utf-8")
        for required in ("X-VexSign-Token", "WebManagerAuthMiddleware",
                         "WebManagerSensitiveAccessMiddleware", "allowsCertificateExport"):
            self.assertIn(required, text, f"the contract must name {required}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
