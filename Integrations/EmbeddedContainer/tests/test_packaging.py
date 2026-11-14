import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("combined_build", Path(__file__).parents[1] / "build.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def make_zip(self, entries):
        path = self.root / "input.ipa"
        with zipfile.ZipFile(path, "w") as z:
            for name, value in entries:
                z.writestr(name, value)
        return path

    def test_rejects_traversal_before_any_extraction(self):
        for unsafe in ("../escape", "/absolute", "Payload/../escape", "Payload\\..\\escape", "C:/escape"):
            with self.subTest(unsafe=unsafe):
                archive = self.make_zip([("Payload/good", b"ok"), (unsafe, b"bad")])
                with self.assertRaises(ValueError):
                    build.extract_zip(archive, self.root / "output")
                self.assertFalse((self.root / "output/Payload/good").exists())

    def test_rejects_symlink(self):
        item = zipfile.ZipInfo("Payload/link")
        item.create_system = 3
        item.external_attr = 0o120777 << 16
        archive = self.make_zip([(item, "../../escape")])
        with self.assertRaises(ValueError):
            build.extract_zip(archive, self.root / "output")

    def test_rejects_duplicate_files_and_zip_bombs(self):
        with self.assertWarns(UserWarning):
            archive = self.make_zip([("Payload/file", b"a"), ("Payload/file", b"b")])
        with self.assertRaises(ValueError):
            build.extract_zip(archive, self.root / "output")
        archive = self.make_zip([("Payload/file", b"a")])
        old = build.MAX_EXPANDED
        try:
            build.MAX_EXPANDED = 0
            with self.assertRaises(ValueError):
                build.extract_zip(archive, self.root / "output")
        finally:
            build.MAX_EXPANDED = old

    def test_embedded_guest_is_marked_without_mutating_input(self):
        info = {"CFBundleIdentifier": "com.vexsign.app", "CFBundleExecutable": "VexSign",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "10", "MinimumOSVersion": "16.0"}
        archive = self.make_zip([("Payload/VexSign.app/Info.plist", plistlib.dumps(info)),
                                 ("Payload/VexSign.app/VexSign", b"binary"),
                                 ("Payload/VexSign.app/PlugIns/Widget.appex/file", b"widget"),
                                 ("Payload/VexSign.app/embedded.mobileprovision", b"private profile"),
                                 ("Payload/VexSign.app/_CodeSignature/CodeResources", b"signature")])
        before = build.sha256(archive)
        guest, metadata = build.prepare_guest(archive, self.root)
        self.assertEqual(build.sha256(archive), before)
        self.assertTrue(metadata["VexSignEmbeddedGuest"])
        with zipfile.ZipFile(guest) as z:
            self.assertFalse(any("PlugIns" in x or "mobileprovision" in x or "_CodeSignature" in x for x in z.namelist()))
            self.assertTrue(plistlib.loads(z.read("Payload/VexSign.app/Info.plist"))["VexSignEmbeddedGuest"])

    def test_wrong_guest_is_rejected(self):
        archive = self.make_zip([("Payload/Other.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "other"}))])
        with self.assertRaises(ValueError):
            build.prepare_guest(archive, self.root)

    def test_hash_mismatch_fails_closed(self):
        data = self.root / "download"
        data.write_bytes(b"untrusted executable")
        with self.assertRaises(ValueError):
            build.verify_digest(data, "0" * 64)
        build.verify_digest(data, build.sha256(data))

    def test_dylib_header_and_fat_slices_are_checked(self):
        binary = self.root / "binary"
        dylib = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 6, 0, 0, 0, 0)
        binary.write_bytes(dylib)
        self.assertEqual(build.macho_filetypes(binary), [6])
        fat = struct.pack(">II", 0xcafebabe, 1) + struct.pack(">IIIII", 0x100000c, 0, 32, len(dylib), 0)
        binary.write_bytes(fat + b"\0" * 4 + dylib)
        self.assertEqual(build.macho_filetypes(binary), [6])
        binary.write_bytes(fat[:-2])
        with self.assertRaises(ValueError):
            build.macho_filetypes(binary)
        binary.write_bytes(b"not a Mach-O")
        with self.assertRaises(ValueError):
            build.macho_filetypes(binary)

    def test_host_keeps_runtime_identity_and_adds_side_store_metadata(self):
        host = self.root / "Host.app"
        (host / "Settings.bundle").mkdir(parents=True)
        build.write_plist(host / "Info.plist", {"CFBundleIdentifier": "com.kdt.livecontainer", "MinimumOSVersion": "15.0"})
        build.write_plist(host / "Settings.bundle/Root.plist", {"PreferenceSpecifiers": []})
        guest = {"MinimumOSVersion": "16.4", "NSLocalNetworkUsageDescription": "Local install"}
        build.configure_host_info(host, guest)
        build.configure_host_info(host, guest)
        info = build.read_plist(host / "Info.plist")
        self.assertTrue(info["VexSignCombinedHost"])
        self.assertEqual(info["CFBundleIdentifier"], "com.kdt.livecontainer")
        self.assertEqual(info["MinimumOSVersion"], "16.4")
        self.assertEqual(info["NSLocalNetworkUsageDescription"], "Local install")
        self.assertIn("group.com.SideStore.SideStore", info["ALTAppGroups"])
        self.assertEqual(len(info["CFBundleURLTypes"]), 2)
        self.assertEqual(len(build.read_plist(host / "Settings.bundle/Root.plist")["PreferenceSpecifiers"]), 1)
        build.write_plist(host / "Info.plist", {"CFBundleIdentifier": "arbitrary.host"})
        with self.assertRaises(ValueError):
            build.configure_host_info(host, guest)

    def test_incomplete_payload_cannot_be_published(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            build.validate_payload(self.root)

    def test_payload_rejects_wrong_macho_types_before_publication(self):
        host = self.root / "Combined.app"
        dylib = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 6, 0, 0, 0, 0)
        executable = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0)
        for name in ("SideStoreSupport", "LiveContainerShared", "LiveContainerSwiftUI", "SideStoreApp"):
            file = host / f"Frameworks/{name}.framework/{'SideStore' if name == 'SideStoreApp' else name}"
            file.parent.mkdir(parents=True)
            file.write_bytes(dylib)
        for name in ("LiveProcess", "LaunchAppExtension", "ShareExtension", "LiveWidgetExtension"):
            (host / f"PlugIns/{name}.appex").mkdir(parents=True)
        (host / "PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension").write_bytes(executable)
        (host / "Host").write_bytes(executable)
        (host / "VexSign.ipa").write_bytes(b"guest fixture")
        (host / "VexSignEmbedded.json").write_text(json.dumps({"sha256": build.sha256(host / "VexSign.ipa")}))
        build.write_plist(host / "Info.plist", {"CFBundleExecutable": "Host", "VexSignCombinedHost": True})
        build.validate_payload(host)
        (host / "Host").write_bytes(dylib)
        with self.assertRaisesRegex(ValueError, "MH_EXECUTE"):
            build.validate_payload(host)
        (host / "Host").write_bytes(executable)
        (host / "Frameworks/LiveContainerShared.framework/LiveContainerShared").write_bytes(executable)
        with self.assertRaisesRegex(ValueError, "MH_DYLIB"):
            build.validate_payload(host)

    def test_side_store_conversion_intents_and_widget_layout(self):
        host = self.root / "Host.app"
        (host / "Frameworks").mkdir(parents=True)
        upstream = self.root / "upstream/.github/sidelc"
        upstream.mkdir(parents=True)
        (upstream / "LCAppInfo.plist").write_bytes(plistlib.dumps({"dontSign": True}))
        (upstream / "LiveWidgetExtension_adhoc.xml").write_bytes(plistlib.dumps({}))
        info = {"CFBundleExecutable": "SideStore", "CFBundleIdentifier": "com.SideStore.SideStore"}
        widget = {"CFBundleExecutable": "AltWidgetExtension", "CFBundleIdentifier": "com.SideStore.SideStore.Widget"}
        archive = self.make_zip([
            ("Payload/SideStore.app/Info.plist", plistlib.dumps(info)),
            ("Payload/SideStore.app/SideStore", b"original executable"),
            ("Payload/SideStore.app/Intents.intentdefinition", b"intent"),
            ("Payload/SideStore.app/ViewApp.intentdefinition", b"view"),
            ("Payload/SideStore.app/Metadata.appintents/extract.actionsdata",
             b"9SideStore20RefreshAllAppsIntentV 9SideStore26RefreshAllAppsWidgetIntentV"),
            ("Payload/SideStore.app/PlugIns/AltWidgetExtension.appex/Info.plist", plistlib.dumps(widget)),
            ("Payload/SideStore.app/PlugIns/AltWidgetExtension.appex/AltWidgetExtension", b"widget")])
        def tool(*args, **kwargs):
            if str(args[0]) == "dylibify":
                Path(args[2]).write_bytes(struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 6, 0, 0, 0, 0))
        with patch.object(build, "run", side_effect=tool) as invoked:
            build.embed_sidestore(host, archive, upstream.parents[1], "dylibify", self.root)
        self.assertEqual(invoked.call_count, 3)
        self.assertEqual(build.macho_filetypes(host / "Frameworks/SideStoreApp.framework/SideStore"), [6])
        self.assertTrue((host / "Frameworks/SideStoreApp.framework/LCAppInfo.plist").exists())
        self.assertIn(b"16SideStoreSupport20RefreshAllAppsIntentV", (host / "Metadata.appintents/extract.actionsdata").read_bytes())
        embedded_widget = host / "PlugIns/LiveWidgetExtension.appex"
        self.assertEqual(build.read_plist(embedded_widget / "Info.plist")["CFBundleIdentifier"], "com.kdt.livecontainer.LiveWidget")
        self.assertTrue((embedded_widget / "LiveWidgetExtension").exists())

    def test_experimental_outputs_have_verifiable_checksums_and_honest_metadata(self):
        ipa, sources = self.root / "Combined.ipa", self.root / "Combined.integration-sources.tar.gz"
        ipa.write_bytes(b"ipa fixture")
        sources.write_bytes(b"source fixture")
        lock = {"livecontainer": {"commit": "a" * 40}}
        metadata, checksums = build.write_build_metadata(ipa, sources, lock)
        report = json.loads(metadata.read_text())
        self.assertEqual(report["validation"]["physicalDevice"], "not-run")
        self.assertEqual(report["kind"], "experimental-guest-host")
        self.assertEqual(report["inputs"], lock)
        self.assertEqual(report["files"][0]["bytes"], ipa.stat().st_size)
        self.assertEqual(report["files"][0]["sha256"], build.sha256(ipa))
        lines = checksums.read_text().splitlines()
        self.assertEqual(len(lines), 3)
        for line in lines:
            digest, name = line.split("  ")
            build.verify_digest(self.root / name, digest)
        ipa.write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            build.verify_digest(ipa, report["files"][0]["sha256"])

    def test_asset_locks_are_immutable_not_nightly_urls(self):
        lock = json.loads((Path(__file__).parents[1] / "inputs.lock.json").read_text())
        self.assertIsInstance(lock["sidestore"]["asset_id"], int)
        self.assertEqual(len(lock["sidestore"]["sha256"]), 64)
        for key in ("livecontainer", "sidestore", "dylibify"):
            self.assertEqual(len(lock[key]["commit"]), 40)
        self.assertEqual(len(lock["dylibify"]["source_sha256"]["main.m"]), 64)


if __name__ == "__main__":
    unittest.main()
