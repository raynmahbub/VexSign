#!/usr/bin/env python3
"""Regression tests for tools/check-package-graph.py (offline, no third-party deps)."""

import json
import runpy
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = runpy.run_path(str(ROOT / "tools/check-package-graph.py"))
check = GATE["check"]
satisfies = GATE["satisfies"]
version_key = GATE["version_key"]
manifest_requirements = GATE["manifest_requirements"]
pbx_requirements = GATE["pbx_requirements"]


def pin(version=None, branch=None, revision="a" * 40):
    state = {"revision": revision}
    if version is not None:
        state["version"] = version
    if branch is not None:
        state["branch"] = branch
    return state


class VersionTests(unittest.TestCase):
    def test_ordering_and_prerelease(self):
        self.assertLess(version_key("1.2.3"), version_key("1.10.0"))
        self.assertLess(version_key("2.0.0-alpha"), version_key("2.0.0"))
        self.assertLess(version_key("2.0.0-alpha.2"), version_key("2.0.0-alpha.10"))
        with self.assertRaises(ValueError):
            version_key("not-a-version")

    def test_requirement_kinds(self):
        p = {"state": pin(version="4.8.7")}
        self.assertTrue(satisfies(p, {"kind": "from", "version": "4.8.6"}))
        self.assertFalse(satisfies(p, {"kind": "from", "version": "4.9.0"}))
        self.assertTrue(satisfies(p, {"kind": "upToNextMinor", "version": "4.8.6"}))
        self.assertFalse(satisfies(p, {"kind": "upToNextMinor", "version": "4.7.0"}))
        self.assertTrue(satisfies(p, {"kind": "upToNextMajor", "version": "4.0.0"}))
        self.assertFalse(satisfies(p, {"kind": "upToNextMajor", "version": "5.0.0"}))
        self.assertFalse(satisfies(p, {"kind": "range", "lower": "3.6.1", "upper": "4.0.0"}))
        self.assertTrue(satisfies({"state": pin(version="3.6.1")},
                                  {"kind": "range", "lower": "3.6.1", "upper": "4.0.0"}))
        self.assertFalse(satisfies({"state": pin(version="3.3.3001")},
                                   {"kind": "range", "lower": "3.6.1", "upper": "4.0.0"}))
        self.assertTrue(satisfies({"state": pin(branch="main")}, {"kind": "branch", "branch": "main"}))
        self.assertFalse(satisfies({"state": pin(version="1.0.0")}, {"kind": "branch", "branch": "main"}))


class ManifestParsingTests(unittest.TestCase):
    def test_forms(self):
        text = '''
        .package(url: "https://github.com/apple/swift-crypto.git", "3.15.1"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.3.1"),
        .package(url: "https://github.com/mahee96/AnisetteKit.git", branch: "main"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL", from: "3.3.3001"),
        .package(name: "BitByteData", url: "https://github.com/tsolomko/BitByteData", .exact("2.0.4")),
        '''
        reqs = manifest_requirements(text)
        kinds = {identity: req["kind"] for identity, req in reqs}
        self.assertEqual(kinds["swift-crypto"], "exact")  # later exact wins in dict comprehension
        self.assertEqual(kinds["anisettekit"], "branch")
        self.assertEqual(kinds["openssl"], "from")
        self.assertIn(("openssl", {"kind": "from", "version": "3.3.3001"}), reqs)

    def test_pbx_forms(self):
        text = '''
		AA /* XCRemoteSwiftPackageReference "vapor" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/vapor/vapor";
			requirement = {
				kind = exactVersion;
				version = 4.122.3;
			};
		};
		BB /* XCRemoteSwiftPackageReference "ZIPFoundation" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/weichsel/ZIPFoundation";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 0.9.19;
			};
		};
'''
        reqs = dict(pbx_requirements(text))
        self.assertEqual(reqs["vapor"], {"kind": "exact", "version": "4.122.3"})
        self.assertEqual(reqs["zipfoundation"], {"kind": "upToNextMajor", "version": "0.9.19"})


class DriftTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for rel in ("VexSign.xcworkspace/xcshareddata/swiftpm",
                    "VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm",
                    "SideSign", "NativeSigning", "Vendor/Zsign", "VexSign.xcodeproj"):
            (self.root / rel).mkdir(parents=True, exist_ok=True)
        self.ws = self.root / "VexSign.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.proj = self.root / "VexSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        base = {"pins": [{"identity": "openssl", "kind": "remoteSourceControl",
                          "location": "https://github.com/krzyzanowskim/OpenSSL",
                          "state": pin(version="3.6.1")}], "version": 2}
        self.write(self.ws, base)
        self.write(self.proj, base)
        self.write(self.root / "SideSign/Package.resolved", {"pins": [], "version": 2})
        (self.root / "VexSign.xcodeproj/project.pbxproj").write_text("")
        for manifest in ("NativeSigning/Package.swift", "SideSign/Package.swift", "Vendor/Zsign/Package.swift"):
            (self.root / manifest).write_text(
                '.package(url: "https://github.com/krzyzanowskim/OpenSSL", from: "3.3.3001"),\n')

    def write(self, path, data):
        path.write_text(json.dumps(data), encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_agreeing_files_pass(self):
        self.assertEqual(check(self.root), [])

    def test_version_drift_fails(self):
        data = json.loads(self.proj.read_text())
        data["pins"][0]["state"] = pin(version="3.3.3001", revision="b" * 40)
        self.write(self.proj, data)
        problems = check(self.root)
        self.assertTrue(any("openssl" in p and "drift" not in p for p in problems), problems)

    def test_missing_pin_fails(self):
        self.write(self.proj, {"pins": [], "version": 2})
        problems = check(self.root)
        self.assertTrue(any("pinned only in the workspace" in p for p in problems), problems)

    def test_unsatisfied_requirement_fails(self):
        (self.root / "NativeSigning/Package.swift").write_text(
            '.package(url: "https://github.com/krzyzanowskim/OpenSSL.git", "3.7.0"..<"4.0.0"),\n')
        problems = check(self.root)
        self.assertTrue(any("does not satisfy" in p for p in problems), problems)

    def test_missing_required_pin_fails(self):
        (self.root / "SideSign/Package.swift").write_text(
            '.package(url: "https://github.com/mahee96/AnisetteKit.git", branch: "main"),\n')
        problems = check(self.root)
        self.assertTrue(any("anisettekit" in p and "missing from SideSign" in p for p in problems), problems)

    def test_branch_dependency_covered_by_sidestore_record_passes(self):
        (self.root / "SideSign/Package.swift").write_text(
            '.package(url: "https://github.com/mahee96/AnisetteKit.git", branch: "main"),\n')
        self.write(self.root / "SideSign/Package.resolved", {"pins": [
            {"identity": "anisettekit", "kind": "remoteSourceControl",
             "location": "https://github.com/mahee96/AnisetteKit.git",
             "state": pin(branch="main")}], "version": 3})
        self.assertEqual(check(self.root), [])

    def test_branch_pin_in_app_graph_fails(self):
        data = json.loads(self.ws.read_text())
        data["pins"].append({"identity": "anisettekit", "kind": "remoteSourceControl",
                             "location": "https://github.com/mahee96/AnisetteKit.git",
                             "state": pin(branch="main")})
        self.write(self.ws, data)
        self.write(self.proj, data)
        problems = check(self.root)
        self.assertTrue(any("versioned and immutable" in p for p in problems), problems)

    def test_duplicate_pin_fails(self):
        data = json.loads(self.ws.read_text())
        data["pins"].append(dict(data["pins"][0]))
        self.write(self.ws, data)
        problems = check(self.root)
        self.assertTrue(any("duplicate" in p for p in problems), problems)

    def test_format_difference_alone_passes(self):
        data = json.loads(self.proj.read_text())
        data["version"] = 3
        data["originHash"] = "f" * 64
        self.write(self.proj, data)
        self.assertEqual(check(self.root), [])


class LiveRepositoryTests(unittest.TestCase):
    def test_current_tree_passes(self):
        self.assertEqual(check(ROOT), [])


if __name__ == "__main__":
    unittest.main()
