#!/usr/bin/env python3
"""Offline positive/negative tests for the read-only preservation auditor.

Fixtures are synthetic metadata, not Xcode, Swift or device acceptance. No test
requires the migration's original Git revision or mutates a real baseline.
"""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import audit_feature_preservation as preservation


def openstep(value) -> str:
    if isinstance(value, dict):
        return "{" + "".join(json.dumps(key) + "=" + openstep(item) + ";" for key, item in value.items()) + "}"
    if isinstance(value, list):
        return "(" + ",".join(openstep(item) for item in value) + ")"
    return json.dumps(value)


class PreservationAuditorTests(unittest.TestCase):
    def setUp(self):
        self.mapping = {
            "baseCommit": "synthetic-only", "branch": "fixture",
            "directoryMappings": {
                "App/iOS/VexSign": "VexSign/App/iOS/VexSign",
                "Packages": "VexSign/Packages",
            },
            "fileMappings": [
                {"old": "App/iOS/VexSign/Resources/Info.plist", "new": "VexSign/Configuration/Build/iOS/Info.plist"},
                {"old": "App/iOS/VexSign/Companion/Shared.swift", "new": "VexSign/App/iOS/VexSign/Infrastructure/Devices/Shared.swift"},
                {"old": "Tools/Development/FilePickerFix.m", "new": "VexSign/Configuration/Build/FilePickerFix.m"},
            ],
        }
        self.base = {
            "objectVersion": "77", "rootObject": "PROJECT", "objects": {
                "PROJECT": {"isa": "PBXProject"},
                "ROOT": {"isa": "PBXGroup", "sourceTree": "<group>", "children": []},
                "TARGET": {"isa": "PBXNativeTarget", "name": "Fixture", "productName": "Fixture", "productType": "com.apple.product-type.application", "buildConfigurationList": "LIST", "productReference": "PRODUCT"},
                "CONFIG": {"isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": {
                    "SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.fixture", "MARKETING_VERSION": "1.0",
                    "INFOPLIST_FILE": "App/iOS/VexSign/Resources/Info.plist", "ALWAYS_SEARCH_USER_PATHS": "NO",
                    "DEBUG_INFORMATION_FORMAT": "dwarf", "LIBRARY_SEARCH_PATHS": ["$(inherited)", "$(PROJECT_DIR)/App/iOS/VexSign/Resources"],
                }},
                "GROUP": {"isa": "PBXFileSystemSynchronizedRootGroup", "path": "App/iOS/VexSign", "sourceTree": "<group>", "exceptions": ["EXCEPTION"]},
                "EXCEPTION": {"isa": "PBXFileSystemSynchronizedBuildFileExceptionSet", "target": "TARGET", "membershipExceptions": ["Resources/Info.plist", "Companion/Shared.swift"]},
                "REMOTE": {"isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/example/package", "requirement": {"kind": "revision", "revision": "original-pin"}},
                "LOCAL": {"isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/Fixture"},
                "DEPENDENCY": {"isa": "XCSwiftPackageProductDependency", "package": "REMOTE", "productName": "FixtureLibrary"},
                "SCRIPT": {"isa": "PBXShellScriptBuildPhase", "inputPaths": ["$(SRCROOT)/Tools/Development/FilePickerFix.m"], "shellScript": 'set -e\nclang "${SRCROOT}/Tools/Development/FilePickerFix.m"\n'},
            },
        }
        self.current = deepcopy(self.base)
        self.paths = preservation.relocations(self.mapping)
        objects = self.current["objects"]
        objects["GROUP"]["path"] = "VexSign/App/iOS/VexSign"
        objects["EXCEPTION"]["membershipExceptions"] = ["Infrastructure/Devices/Shared.swift"]
        objects["LOCAL"]["relativePath"] = "VexSign/Packages/Fixture"
        objects["CONFIG"]["buildSettings"] = preservation.relocate_path(objects["CONFIG"]["buildSettings"], self.paths)
        del objects["CONFIG"]["buildSettings"]["ALWAYS_SEARCH_USER_PATHS"]
        del objects["CONFIG"]["buildSettings"]["DEBUG_INFORMATION_FORMAT"]
        objects["CONFIG"]["baseConfigurationReference"] = "CONFIG_FILE"
        objects["ROOT"]["children"] = ["CONFIG_GROUP"]
        objects["CONFIG_GROUP"] = {"isa": "PBXGroup", "path": "VexSign/Configuration/Build", "sourceTree": "<group>", "children": ["CONFIG_FILE"]}
        objects["CONFIG_FILE"] = {"isa": "PBXFileReference", "path": "Debug.xcconfig", "sourceTree": "<group>"}
        objects["SCRIPT"]["inputPaths"] = ["$(SRCROOT)/VexSign/Configuration/Build/FilePickerFix.m"]
        objects["SCRIPT"]["shellScript"] = 'set -e\nclang "${SRCROOT}/VexSign/Configuration/Build/FilePickerFix.m"\n'
        self.blobs = {
            "VexSign/Configuration/Build/Shared.xcconfig": b"ALWAYS_SEARCH_USER_PATHS = NO\n",
            "VexSign/Configuration/Build/Debug.xcconfig": b'#include "Shared.xcconfig"\nDEBUG_INFORMATION_FORMAT = dwarf\n',
        }

    def compare(self):
        return preservation.project_preservation(openstep(self.base).encode(), openstep(self.current).encode(), self.paths, self.blobs)

    def test_openstep_reader_preserves_quoted_delimiters_comments_and_escapes(self):
        value = {"CODE_SIGN_IDENTITY[sdk=iphoneos*]": "", "script": 'echo "// /* { } \\n"', "array": ["a", "b"]}
        self.assertEqual(preservation.parse_openstep("// header\n/* comment */" + openstep(value)), value)

    def test_openstep_reader_rejects_duplicate_truncated_and_unseparated_input(self):
        for source in ("{a=b;a=c;}", "{a=(one two);}", "{a=b", "{} trailing", "/* missing", '{a="unterminated;}'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                preservation.parse_openstep(source)

    def test_path_relocation_does_not_relocate_a_destination_twice_or_touch_urls(self):
        path = "App/iOS/VexSign/Resources/Info.plist"
        self.assertEqual(preservation.relocate_path(path, self.paths), "VexSign/Configuration/Build/iOS/Info.plist")
        self.assertEqual(preservation.relocate_path("$(SRCROOT)/" + path, self.paths), "$(SRCROOT)/VexSign/Configuration/Build/iOS/Info.plist")
        url = "https://example.invalid/App/iOS/VexSign/Resources/Info.plist"
        self.assertEqual(preservation.relocate_path(url, self.paths), url)

    def test_attribution_path_relocation_preserves_prose_license_terms_and_urls(self):
        source = "App Store, MIT; `App/iOS/VexSign/Resources/Info.plist`; https://example.invalid/App/iOS/VexSign/Resources/Info.plist"
        expected = source.replace("`App/iOS/VexSign/Resources/Info.plist`", "`VexSign/Configuration/Build/iOS/Info.plist`")
        self.assertEqual(preservation.relocate_references(source, self.paths), expected)
        self.assertNotEqual(preservation.relocate_references(source, self.paths), expected.replace("MIT", "Other terms"))

    def test_original_identity_membership_and_effective_setting_values_survive_extraction(self):
        result = self.compare()
        self.assertEqual(result["failures"], [])
        self.assertEqual(len(result["targets"]), 1)
        self.assertEqual(result["configurations"][0]["changedSettingKeys"], [])
        self.assertEqual(result["missingOriginalObjectIDs"], [])

    def test_changed_target_product_is_rejected_even_with_same_target_count(self):
        self.current["objects"]["TARGET"]["productName"] = "Changed"
        self.assertTrue(any("target identities" in failure for failure in self.compare()["failures"]))

    def test_changed_bundle_version_and_sdk_setting_values_are_rejected(self):
        settings = self.current["objects"]["CONFIG"]["buildSettings"]
        for key in ("PRODUCT_BUNDLE_IDENTIFIER", "MARKETING_VERSION", "SDKROOT"):
            with self.subTest(key=key):
                before = settings[key]
                settings[key] = "changed"
                self.assertIn(key, self.compare()["configurations"][0]["changedSettingKeys"])
                settings[key] = before

    def test_changed_extracted_xcconfig_value_is_not_hidden_by_setting_counts(self):
        self.blobs["VexSign/Configuration/Build/Shared.xcconfig"] = b"ALWAYS_SEARCH_USER_PATHS = YES\n"
        self.assertIn("ALWAYS_SEARCH_USER_PATHS", self.compare()["configurations"][0]["changedSettingKeys"])

    def test_remote_pin_and_product_identity_changes_are_rejected(self):
        self.current["objects"]["REMOTE"]["requirement"]["revision"] = "different-pin"
        self.assertTrue(any("package identity" in failure for failure in self.compare()["failures"]))

    def test_missing_object_identity_is_rejected_even_if_replaced_by_another_id(self):
        self.current["objects"]["NEW_ID"] = self.current["objects"].pop("PROJECT")
        self.assertIn("PROJECT", self.compare()["missingOriginalObjectIDs"])

    def test_membership_relocation_cannot_silently_drop_a_shared_file(self):
        self.current["objects"]["EXCEPTION"]["membershipExceptions"] = []
        self.assertTrue(any("target-relative membership" in failure for failure in self.compare()["failures"]))

    def test_only_the_reviewed_debian_payload_type_override_is_admitted(self):
        group_id = "3379C1BB2DA869A1004372DA"
        for project in (self.base, self.current):
            project["objects"][group_id] = project["objects"].pop("GROUP")
        group = self.current["objects"][group_id]
        group["explicitFileTypes"] = {"Resources/ellekit.deb": "file"}
        result = self.compare()
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["reviewedResourceTypeRepairs"],
            [{"group": group_id, "path": "Resources/ellekit.deb", "fileType": "file"}])
        for value in ({}, {"Resources/ellekit.deb": "archive.ar"},
                      {"Resources/ellekit.deb": "file", "Infrastructure/Owner.swift": "file"}):
            group["explicitFileTypes"] = value
            self.assertTrue(any("resource file type" in failure for failure in self.compare()["failures"]))

    def test_unreviewed_synchronized_file_types_and_folder_metadata_are_rejected(self):
        group = self.current["objects"]["GROUP"]
        group["explicitFileTypes"] = {"Hidden.swift": "file"}
        self.assertTrue(any("resource file type" in failure for failure in self.compare()["failures"]))
        del group["explicitFileTypes"]
        group["explicitFolders"] = ["Infrastructure"]
        self.assertTrue(any("synchronized group metadata" in failure for failure in self.compare()["failures"]))

    def test_changed_shell_command_is_not_excused_as_path_relocation(self):
        self.current["objects"]["SCRIPT"]["shellScript"] += "echo unexpected-command\n"
        self.assertTrue(any("shell-script phase" in failure for failure in self.compare()["failures"]))

    def test_xcconfig_cycles_and_unsupported_assignment_syntax_fail_closed(self):
        path = "VexSign/Configuration/Build/Debug.xcconfig"
        for content in (b'#include "Debug.xcconfig"\n', b"SDKROOT += unsafe\n", b"#include? missing.xcconfig\n"):
            with self.subTest(content=content), self.assertRaises(ValueError):
                preservation.xcconfig_settings(path, {path: content})

    def test_bridging_header_keeps_the_same_inputs_and_nonpath_content(self):
        before = b'#include "Header.h"\n#import "../Companion/Host.h"\n'
        old = "App/iOS/VexSign/Supporting/Header.h"
        new = "VexSign/Configuration/Build/iOS/Header.h"
        paths = {"App/iOS/VexSign/Utilities/Header.h": "VexSign/App/iOS/VexSign/Platform/Header.h",
                 "App/iOS/VexSign/Companion/Host.h": "VexSign/App/iOS/VexSign/Platform/Host.h"}
        originals = {path: ("100644", b"synthetic-header") for path in paths}
        after = b'#include "../../../App/iOS/VexSign/Platform/Header.h"\n#import "../../../App/iOS/VexSign/Platform/Host.h"\n'
        result = preservation.bridging_header_preservation(old, new, before, after, paths, originals)
        self.assertTrue(result["onlyIncludePathsChanged"])
        self.assertEqual(len(result["includes"]), 2)
        self.assertFalse(preservation.bridging_header_preservation(old, new, before, after + b"#define NEW 1\n", paths, originals)["onlyIncludePathsChanged"])

    def test_dangling_symlink_blobs_are_the_link_target_not_dereferenced_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "link"
            path.symlink_to("missing-target")
            self.assertEqual(preservation.working_blob(path), b"missing-target")

    def fixture_audit(self, mutate=lambda root, mapping: None, additional_files=None):
        """Execute the real auditor on a tiny synthetic original/current tree."""
        base_blobs = {
            "VexSign.xcodeproj/project.pbxproj": openstep(self.base).encode(),
            "LICENSE": b"Synthetic MIT fixture; preserve these terms.\n",
            "THIRD_PARTY_NOTICES.md": b"MIT; see `App/iOS/VexSign/Resources/Info.plist`. App Store policies differ.\n",
            "App/iOS/VexSign/Resources/Info.plist": b"synthetic plist bytes",
            "App/iOS/VexSign/Companion/Shared.swift": b"// synthetic shared source\n",
            "Tools/Development/FilePickerFix.m": b"// synthetic tool source\n",
            "Documentation/guide.md": b"Keep https://example.invalid/preserved-resource\n",
        }
        current_blobs = {
            "VexSign.xcodeproj/project.pbxproj": openstep(self.current).encode(),
            "LICENSE": base_blobs["LICENSE"],
            "THIRD_PARTY_NOTICES.md": preservation.relocate_references(base_blobs["THIRD_PARTY_NOTICES.md"].decode(), self.paths).encode(),
            "VexSign/Configuration/Build/iOS/Info.plist": base_blobs["App/iOS/VexSign/Resources/Info.plist"],
            "VexSign/App/iOS/VexSign/Infrastructure/Devices/Shared.swift": base_blobs["App/iOS/VexSign/Companion/Shared.swift"],
            "VexSign/Configuration/Build/FilePickerFix.m": base_blobs["Tools/Development/FilePickerFix.m"],
            "Documentation/guide.md": base_blobs["Documentation/guide.md"],
            preservation.PRESERVATION_REPORT: b"{}\n",
            **self.blobs,
        }
        for alias, canonical in preservation.ROOT_ALIASES.items():
            data = b"\x89PNG\0synthetic-binary" if alias == "icon.png" else b"synthetic alias bytes\n"
            base_blobs[alias] = data
            current_blobs[alias] = current_blobs[canonical] = data
        for path, (before, after) in (additional_files or {}).items():
            base_blobs[path] = before
            current_blobs[path] = after
        destinations = {entry["old"]: entry["new"] for entry in self.mapping["fileMappings"]}
        entries = [{"old": old, "new": destinations.get(old, old), "sha256Before": preservation.digest(value)} for old, value in base_blobs.items()]
        mapping = {**self.mapping, "fileMappings": entries}
        mapping["rewrittenFiles"] = sorted(entry["new"] for entry in entries if base_blobs[entry["old"]] != current_blobs[entry["new"]])
        mapping["addedFiles"] = sorted(set(current_blobs) - {entry["new"] for entry in entries})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, value in current_blobs.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value)
            mutate(root, mapping)
            map_file = root / "fixture-map.json"
            map_file.write_text(json.dumps(mapping))
            with patch.object(preservation, "ROOT", root), patch.object(preservation, "MAP", map_file), \
                 patch.object(preservation, "original_blobs", return_value={path: ("100644", value) for path, value in base_blobs.items()}), \
                 patch.object(preservation, "current_paths", return_value=sorted(current_blobs)):
                return preservation.audit()

    def test_full_synthetic_audit_accepts_only_path_changed_notices_and_matching_aliases(self):
        result = self.fixture_audit()
        self.assertEqual(result["failures"], [])
        self.assertTrue(all(row["onlyRepositoryPathsChanged"] for row in result["attributionIndexes"]))
        self.assertTrue(all(row["identical"] for row in result["rootCompatibilityAliases"]))

    def test_license_text_and_attribution_terms_cannot_be_changed(self):
        for name, message in (("LICENSE", "License/attribution bytes changed"), ("THIRD_PARTY_NOTICES.md", "Attribution/index content changed")):
            with self.subTest(name=name):
                result = self.fixture_audit(lambda root, _: (root / name).write_text("Changed legal terms"))
                self.assertTrue(any(message in failure for failure in result["failures"]))

    def test_protected_build_input_changes_are_rejected(self):
        result = self.fixture_audit(lambda root, _: (root / "VexSign/Configuration/Build/iOS/Info.plist").write_text("different input"))
        self.assertTrue(any("Protected input bytes changed" in failure for failure in result["failures"]))

    def test_only_the_exact_public_security_linkage_is_a_reviewed_protected_change(self):
        before = b'header\n\t\t\t\t.linkedFramework("OpenSSL"),\nfooter\n'
        addition = b'                .linkedFramework("Security"),\n'
        after = before.replace(b'footer', addition + b'footer')
        path = "Packages/Vendor/Zsign/Package.swift"
        self.assertTrue(preservation.reviewed_security_linkage(path, before, after))
        for old, changed in [
            ("Packages/Other/Package.swift", after), (path, after + b'new target'),
            (path, after.replace(b'Security', b'PrivateFramework')),
            (path, after.replace(b'OpenSSL', b'OtherCrypto')),
            (path, before), (path, after.replace(addition, addition + addition)),
        ]:
            with self.subTest(old=old, changed=changed):
                self.assertFalse(preservation.reviewed_security_linkage(old, before, changed))

    def dependency_lock_fixture(self):
        before = b'{"resolved":"https://registry.npmjs.org/example/-/example-1.0.0.tgz"}\n'
        after = b'{"resolved":"https://registry.npmjs.org/example/-/example-1.0.1.tgz"}\n'
        review = {**preservation.REVIEWED_MAIN_DEPENDENCY_LOCK,
            "sha256Before": preservation.digest(before), "sha256After": preservation.digest(after)}
        return before, after, review

    def test_only_exact_reviewed_main_dependency_lock_bytes_are_accepted(self):
        before, after, review = self.dependency_lock_fixture()
        with patch.object(preservation, "REVIEWED_MAIN_DEPENDENCY_LOCK", review):
            self.assertTrue(preservation.reviewed_main_dependency_lock(review["path"], before, after))
            for old, original, changed in [
                ("Other/package-lock.json", before, after), (review["path"], before + b" ", after),
                (review["path"], before, after + b" "), (review["path"], before, before),
            ]:
                with self.subTest(old=old, original=original, changed=changed):
                    self.assertFalse(preservation.reviewed_main_dependency_lock(old, original, changed))

    def test_reviewed_main_lock_accounts_only_for_its_exact_superseded_dependency_urls(self):
        before, after, review = self.dependency_lock_fixture()
        files = {review["path"]: (before, after)}
        with patch.object(preservation, "REVIEWED_MAIN_DEPENDENCY_LOCK", review):
            result = self.fixture_audit(additional_files=files)
            self.assertEqual(result["failures"], [])
            self.assertEqual(result["supersededMainDependencyURLs"], preservation.URL.findall(before.decode()))
            evidence = next(row for row in result["protectedInputs"] if row["path"] == review["path"])
            self.assertEqual(evidence["sourceRevision"], review["revision"])
            self.assertEqual(evidence["sha256Before"], review["sha256Before"])
            self.assertFalse(evidence["identical"])
            changed = self.fixture_audit(lambda root, _: (root / review["path"]).write_bytes(after + b" "), additional_files=files)
            self.assertTrue(any("Protected input bytes changed" in failure for failure in changed["failures"]))
            self.assertEqual(changed["supersededMainDependencyURLs"], [])
            self.assertIn(preservation.URL.findall(before.decode())[0], changed["missingOriginalURLs"])
            unrelated = self.fixture_audit(lambda root, _: (root / "Documentation/guide.md").write_text("removed"), additional_files=files)
            self.assertIn("https://example.invalid/preserved-resource", unrelated["missingOriginalURLs"])

    def test_binary_and_published_alias_drift_are_rejected(self):
        result = self.fixture_audit(lambda root, _: (root / "icon.png").write_bytes(b"changed binary"))
        self.assertTrue(any("Binary bytes changed" in failure for failure in result["failures"]))
        self.assertTrue(any("Published root alias differs" in failure for failure in result["failures"]))

    def test_incorrect_original_hash_and_stale_added_inventory_are_rejected(self):
        def mutate(_, mapping):
            mapping["fileMappings"][0]["sha256Before"] = "incorrect"
            mapping["addedFiles"] = []
        result = self.fixture_audit(mutate)
        self.assertTrue(any("Incorrect original SHA256" in failure for failure in result["failures"]))
        self.assertTrue(any("addedFiles inventory" in failure for failure in result["failures"]))

    def test_executable_mode_change_is_rejected(self):
        result = self.fixture_audit(lambda root, _: (root / "LICENSE").chmod(0o755))
        self.assertTrue(any("Executable mode changed" in failure for failure in result["failures"]))
        def replace_with_link(root, _):
            path = root / "LICENSE"
            path.unlink()
            path.symlink_to("THIRD_PARTY_NOTICES.md")
        result = self.fixture_audit(replace_with_link)
        self.assertTrue(any("Regular file replaced by symlink" in failure for failure in result["failures"]))

    def test_old_evidence_report_cannot_hide_a_removed_real_source_url(self):
        def mutate(root, _):
            (root / "Documentation/guide.md").write_text("URL removed from the source")
            (root / preservation.PRESERVATION_REPORT).write_text("https://example.invalid/preserved-resource")
        result = self.fixture_audit(mutate)
        self.assertIn("https://example.invalid/preserved-resource", result["missingOriginalURLs"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
