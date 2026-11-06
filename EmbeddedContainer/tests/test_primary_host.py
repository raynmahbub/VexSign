import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location('primary_build', HERE / 'build.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


def macho(kind):
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, kind, 0, 0, 0, 0)


class PrimaryHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.host = self.root / 'Host.app'
        self.host.mkdir()

    def input(self, **overrides):
        info = dict(CFBundleIdentifier='com.vexsign.app', CFBundleExecutable='VexSign',
                    CFBundleVersion='10', CFBundleShortVersionString='1.0', DTPlatformName='iphoneos')
        info.update(overrides)
        archive = self.root / 'input.ipa'
        with zipfile.ZipFile(archive, 'w') as z:
            for name, data in {'Info.plist': plistlib.dumps(info), 'VexSign': macho(2),
                               'Frameworks/SDK.framework/SDK': macho(6), 'Assets.car': b'native assets',
                               'Metadata.appintents/extract.actionsdata': b'standalone intent metadata',
                               'PlugIns/Widget.appex/Widget': b'standalone extension'}.items():
                z.writestr('Payload/VexSign.app/' + name, data)
        return archive

    def tool(self, *args, **kwargs):
        if args[0] == 'dylibify':
            Path(args[2]).write_bytes(macho(6))

    def embed(self, archive):
        with patch.object(build, 'output', return_value='000000 T _VexSignPrimaryMain'), patch.object(build, 'run', side_effect=self.tool):
            return build.embed_primary(self.host, archive, 'dylibify', self.root)

    def test_primary_contains_native_image_not_guest_archive(self):
        archive = self.input()
        before = build.sha256(archive)
        info = self.embed(archive)
        self.assertEqual(build.sha256(archive), before)
        self.assertNotIn('VexSignEmbeddedGuest', info)
        image = self.host / 'Frameworks/VexSignPrimary.framework/VexSignPrimary'
        self.assertEqual(build.macho_filetypes(image), [6])
        self.assertTrue((self.host / 'Frameworks/SDK.framework/SDK').exists())
        self.assertFalse((self.host / 'VexSign.ipa').exists())
        self.assertFalse((self.host / 'PlugIns/Widget.appex').exists())
        self.assertFalse((self.host / 'Metadata.appintents').exists())

    def test_guest_or_simulator_inputs_are_rejected(self):
        for overrides in [{'VexSignEmbeddedGuest': True}, {'DTPlatformName': 'iphonesimulator'}]:
            with self.subTest(overrides=overrides), self.assertRaisesRegex(ValueError, 'standalone VexSign device'):
                self.embed(self.input(**overrides))
            # Each attempted extraction is intentionally fresh.
            import shutil
            shutil.rmtree(self.root / 'primary-input')

    def test_missing_export_is_not_silently_loaded_as_guest(self):
        with patch.object(build, 'output', return_value='000000 T _main'), self.assertRaisesRegex(ValueError, 'exported native primary'):
            build.embed_primary(self.host, self.input(), 'dylibify', self.root)
        self.assertFalse((self.host / 'Frameworks').exists())

    def test_native_openssl_is_namespaced_without_touching_host_crypto(self):
        source = self.root / 'native'
        framework = source / 'Frameworks/OpenSSL.framework'
        framework.mkdir(parents=True)
        build.write_plist(framework / 'Info.plist', {'CFBundleExecutable': 'OpenSSL'})
        (framework / 'OpenSSL').write_bytes(macho(6))
        (source / 'VexSign').write_bytes(macho(2))
        host_crypto = self.host / 'Frameworks/OpenSSL.framework/OpenSSL'
        host_crypto.parent.mkdir(parents=True)
        host_crypto.write_bytes(b'host crypto must stay untouched')
        old = '@rpath/OpenSSL.framework/OpenSSL'
        new = '@rpath/VexSignOpenSSL.framework/VexSignOpenSSL'
        rewritten = set()
        identities = {}
        def run(*args):
            if '-change' in args:
                self.assertEqual(args[3:5], (old, new))
                rewritten.add(Path(args[-1]))
            if '-id' in args:
                identities[Path(args[-1])] = args[3]
        def output(*args):
            image = Path(args[-1])
            if args[2] == '-D':
                return str(image) + '\n' + identities[image]
            dependency = identities.get(image, new if image in rewritten else old)
            return str(image) + ':\n\t' + dependency + ' (compatibility version 1.0.0)'
        with patch.object(build, 'run', side_effect=run), patch.object(build, 'output', side_effect=output):
            build.namespace_primary_openssl(source)
        build.merge_primary_files(source, self.host)
        self.assertEqual(host_crypto.read_bytes(), b'host crypto must stay untouched')
        private = self.host / 'Frameworks/VexSignOpenSSL.framework'
        self.assertEqual(build.read_plist(private / 'Info.plist')['CFBundleExecutable'], 'VexSignOpenSSL')
        self.assertEqual(build.macho_filetypes(private / 'VexSignOpenSSL'), [6])
        self.assertIn(source / 'VexSign', rewritten)
        self.assertFalse(framework.exists())

    def test_unreviewed_openssl_loader_path_fails_before_renaming(self):
        source = self.root / 'native'
        framework = source / 'Frameworks/OpenSSL.framework'
        framework.mkdir(parents=True)
        build.write_plist(framework / 'Info.plist', {'CFBundleExecutable': 'OpenSSL'})
        (framework / 'OpenSSL').write_bytes(macho(6))
        (source / 'VexSign').write_bytes(macho(2))
        with patch.object(build, 'output', return_value='image:\n\t@rpath/OpenSSL.framework/Versions/A/OpenSSL (compatibility version 1)'), patch.object(build, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Unsupported native OpenSSL load path'):
                build.namespace_primary_openssl(source)
            run.assert_not_called()
        self.assertTrue(framework.exists())

    def test_dependency_conflict_is_atomic_and_fails_closed(self):
        source = self.root / 'source'
        (source / 'Frameworks/SDK.framework').mkdir(parents=True)
        (source / 'Assets.car').write_bytes(b'new assets')
        (source / 'Frameworks/SDK.framework/SDK').write_bytes(b'new SDK')
        (self.host / 'Frameworks/SDK.framework').mkdir(parents=True)
        (self.host / 'Frameworks/SDK.framework/SDK').write_bytes(b'different SDK')
        (self.host / 'Assets.car').write_bytes(b'old assets')
        with self.assertRaisesRegex(ValueError, 'Conflicting native dependency'):
            build.merge_primary_files(source, self.host)
        self.assertEqual((self.host / 'Assets.car').read_bytes(), b'old assets')

    def test_dependency_destination_cannot_escape_through_symlink(self):
        source = self.root / 'source'
        (source / 'Frameworks').mkdir(parents=True)
        (source / 'Frameworks/file').write_bytes(b'data')
        outside = self.root / 'outside'
        outside.mkdir()
        (self.host / 'Frameworks').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            build.merge_primary_files(source, self.host)
        self.assertFalse((outside / 'file').exists())

    def test_primary_metadata_keeps_real_runtime_identity_and_background_identifiers(self):
        (self.host / 'Settings.bundle').mkdir()
        build.write_plist(self.host / 'Settings.bundle/Root.plist', {'PreferenceSpecifiers': []})
        build.write_plist(self.host / 'Info.plist', {'CFBundleIdentifier': 'com.kdt.livecontainer'})
        source = dict(CFBundleVersion='42', CFBundleShortVersionString='2.0',
                      BGTaskSchedulerPermittedIdentifiers=['com.vexsign.refresh'])
        build.configure_host_info(self.host, source, 'native-primary')
        info = build.read_plist(self.host / 'Info.plist')
        self.assertTrue(info['VexSignPrimaryHost'])
        self.assertNotIn('VexSignEmbeddedGuest', info)
        self.assertEqual(info['CFBundleIdentifier'], 'com.kdt.livecontainer')
        self.assertEqual(info['CFBundleDisplayName'], 'VexSign')
        self.assertEqual(info['BGTaskSchedulerPermittedIdentifiers'], source['BGTaskSchedulerPermittedIdentifiers'])

    def test_primary_manifest_hash_is_of_final_image_and_metadata_is_experimental(self):
        self.embed(self.input())
        manifest = self.host / 'VexSignEmbedded.json'
        manifest.write_text(json.dumps({'mode': 'native-primary'}))
        build.finalize_primary_manifest(self.host)
        digest = json.loads(manifest.read_text())['imageSHA256']
        build.verify_digest(self.host / 'Frameworks/VexSignPrimary.framework/VexSignPrimary', digest)
        ipa, sources = self.root / 'combined.ipa', self.root / 'sources.tar.gz'
        ipa.write_bytes(b'fixture'); sources.write_bytes(b'fixture')
        metadata, _ = build.write_build_metadata(ipa, sources, {}, 'native-primary')
        report = json.loads(metadata.read_text())
        self.assertEqual(report['kind'], 'experimental-native-primary')
        self.assertEqual(report['validation']['physicalDevice'], 'not-run')

    def test_full_native_payload_checks_hash_and_rejects_guest_contamination(self):
        self.embed(self.input())
        for framework, executable in [('SideStoreSupport', 'SideStoreSupport'), ('LiveContainerShared', 'LiveContainerShared'),
                                      ('LiveContainerSwiftUI', 'LiveContainerSwiftUI'), ('SideStoreApp', 'SideStore')]:
            folder = self.host / f'Frameworks/{framework}.framework'
            folder.mkdir()
            (folder / executable).write_bytes(macho(6))
        for name in ['LiveProcess', 'LaunchAppExtension', 'ShareExtension', 'LiveWidgetExtension']:
            (self.host / f'PlugIns/{name}.appex').mkdir(parents=True)
        (self.host / 'PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension').write_bytes(macho(2))
        (self.host / 'Host').write_bytes(macho(2))
        build.write_plist(self.host / 'Info.plist', {'CFBundleIdentifier': 'com.kdt.livecontainer',
                          'CFBundleExecutable': 'Host', 'VexSignPrimaryHost': True, 'VexSignCombinedHost': True})
        (self.host / 'VexSignEmbedded.json').write_text(json.dumps({'mode': 'native-primary'}))
        build.finalize_primary_manifest(self.host)
        build.validate_payload(self.host)
        guest = self.host / 'VexSign.ipa'
        guest.write_bytes(b'must not be here')
        with self.assertRaisesRegex(ValueError, 'must not contain a VexSign guest'):
            build.validate_payload(self.host)
        guest.unlink()
        image = self.host / 'Frameworks/VexSignPrimary.framework/VexSignPrimary'
        image.write_bytes(image.read_bytes() + b'tamper')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            build.validate_payload(self.host)

    def test_primary_default_keychain_group_is_host_identity_not_guest_slot(self):
        upstream = self.root / 'upstream'
        template = {'application-identifier': '$(DEVELOPMENT_TEAM).$(PRODUCT_BUNDLE_IDENTIFIER)',
                    'keychain-access-groups': ['$(AppIdentifierPrefix)com.kdt.livecontainer.shared']}
        rows = [(self.host, 'entitlements.xml')]
        for name, entitlement in [('LiveProcess', 'LiveProcess/LiveProcess.entitlements'),
                                  ('LaunchAppExtension', 'LaunchAppExtension/LaunchAppExtension.entitlements'),
                                  ('ShareExtension', 'ShareExtension/ShareExtension.entitlements'),
                                  ('LiveWidgetExtension', '.github/sidelc/LiveWidgetExtension_adhoc.xml')]:
            rows.append((self.host / f'PlugIns/{name}.appex', entitlement))
        for bundle, path in rows:
            bundle.mkdir(parents=True, exist_ok=True)
            build.write_plist(bundle / 'Info.plist', {'CFBundleIdentifier': 'com.kdt.livecontainer',
                              'CFBundleExecutable': 'Host', 'VexSignPrimaryHost': bundle == self.host})
            (upstream / path).parent.mkdir(parents=True, exist_ok=True)
            build.write_plist(upstream / path, template)
        with patch.object(build, 'run'):
            build.ad_hoc_sign(self.host, upstream, self.root)
        entitlements = build.read_plist(self.root / 'entitlements-0.plist')
        self.assertEqual(entitlements['keychain-access-groups'][0], entitlements['application-identifier'])
        self.assertTrue(entitlements['keychain-access-groups'][1].endswith('.shared'))


if __name__ == '__main__':
    unittest.main()
