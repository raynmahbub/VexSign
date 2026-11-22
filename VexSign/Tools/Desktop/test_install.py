import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import install
import safari_install


class USBInstallTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.ipa = Path(tmp.name) / 'test app.ipa'
        with zipfile.ZipFile(self.ipa, 'w') as out:
            root = 'Payload/Fixture.app/'
            out.writestr(root + 'Info.plist', plistlib.dumps({'CFBundleIdentifier': 'com.example.fixture',
                                                           'CFBundleVersion': '12', 'CFBundleName': 'A&B'}))
            for name in ('embedded.mobileprovision', '_CodeSignature/CodeResources'):
                out.writestr(root + name, 'fixture only')
        self.args = ['--ipa', str(self.ipa), '--device', '01234567']

    @patch('install.subprocess.run')
    def test_preview_and_confirm(self, run):
        run.return_value.stdout = '01234567\n'
        install.main(self.args)
        self.assertEqual(run.call_count, 1)
        install.main(self.args + ['--confirm-install'])
        run.assert_called_with(['ideviceinstaller', '-u', '01234567', 'install', str(self.ipa.resolve())], check=True)

    @patch('install.subprocess.run')
    def test_wrong_device_no_fallback(self, run):
        run.return_value.stdout = '76543210\n'
        with self.assertRaises(ValueError):
            install.main(self.args + ['--confirm-install'])
        self.assertEqual(run.call_count, 1)

    def test_safari_deployment(self):
        out = self.ipa.parent / 'site'
        safari_install.build(self.ipa, out, 'https://install.example/releases/12/')
        self.assertEqual((out / 'app.ipa').read_bytes(), self.ipa.read_bytes())
        item, = plistlib.loads((out / 'manifest.plist').read_bytes())['items']
        self.assertEqual(item['assets'][0]['url'], 'https://install.example/releases/12/app.ipa')
        self.assertEqual(item['metadata']['bundle-version'], '12')
        page = (out / 'index.html').read_text()
        self.assertIn('A&amp;B', page)
        self.assertIn('url=https%3A%2F%2Finstall.example%2Freleases%2F12%2Fmanifest.plist', page)
        with self.assertRaises(FileExistsError):
            safari_install.build(self.ipa, out, 'https://install.example/')

    def test_safari_rejects_invalid_inputs_without_leaving_site(self):
        out = self.ipa.parent / 'site'
        for url in ['http://install.example', 'https://a:b@install.example', 'https://install.example/#x']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                safari_install.build(self.ipa, out, url)
            self.assertFalse(out.exists())
        self.ipa.write_bytes(b'not an IPA')
        with self.assertRaises(zipfile.BadZipFile):
            safari_install.build(self.ipa, out, 'https://install.example/')
        self.assertFalse(out.exists())

    def test_unsigned_archive(self):
        with zipfile.ZipFile(self.ipa, 'w') as out:
            out.writestr('Payload/F.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'com.example.fixture'}))
        with self.assertRaises(ValueError):
            install.inspect(self.ipa)


if __name__ == '__main__':
    unittest.main()
