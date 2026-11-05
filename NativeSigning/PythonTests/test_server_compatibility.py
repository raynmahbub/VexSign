import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location('prepare_server_compatibility', HERE / 'prepare_server_compatibility.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class ServerCompatibilityPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name) / 'candidate'
        self.review = json.loads((module.INPUTS / 'candidate-review.json').read_text())

    def resolved_fixture(self):
        review = copy.deepcopy(self.review)
        source = self.work / '.build/checkouts/vapor'
        fixtures = {}
        for relative in review['vapor']['reviewed_files']:
            data = ('synthetic fixture ' + relative).encode()
            fixtures[relative] = data
            review['vapor']['reviewed_files'][relative] = module.digest(data)
        module.prepare(self.work, review)
        for relative, data in fixtures.items():
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.write_pins(review['required_pins'])
        return review

    def write_pins(self, pins):
        (self.work / 'Package.resolved').write_text(json.dumps({'pins': [
            {'identity': name, 'state': state} for name, state in pins.items()
        ]}))

    def test_stages_actual_factory_byte_identically_without_editing_app(self):
        before = module.APP_PINS.read_bytes()
        module.prepare(self.work, self.review)
        staged = self.work / 'Sources/ServerDependencyCompatibility/ServerApplicationFactory.swift'
        self.assertEqual(staged.read_bytes(), (module.ROOT / module.FACTORY).read_bytes())
        self.assertEqual(before, module.APP_PINS.read_bytes())
        template = (self.work / 'Package.swift').read_text()
        for state in self.review['required_pins'].values():
            self.assertIn('exact: "' + state['version'] + '"', template)

    def test_existing_directory_is_never_reused_or_removed(self):
        self.work.mkdir()
        sentinel = self.work / 'keep'
        sentinel.write_text('untouched')
        with self.assertRaises(FileExistsError):
            module.prepare(self.work, self.review)
        self.assertEqual(sentinel.read_text(), 'untouched')

    def test_app_baseline_drift_fails_before_staging(self):
        self.review['app_baseline_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'App pins changed'):
            module.prepare(self.work, self.review)
        self.assertFalse(self.work.exists())

    def test_verified_resolution_records_all_pins(self):
        review = self.resolved_fixture()
        module.verify(self.work, review)
        attestation = json.loads((self.work / 'resolution-attestation.json').read_text())
        self.assertEqual(attestation['pins'], review['required_pins'])

    def test_moved_tag_or_changed_revision_is_rejected(self):
        review = self.resolved_fixture()
        pins = copy.deepcopy(review['required_pins'])
        pins['vapor']['revision'] = '0' * 40
        self.write_pins(pins)
        with self.assertRaisesRegex(ValueError, 'version/revision: vapor'):
            module.verify(self.work, review)

    def test_unreviewed_alternate_manifest_is_rejected(self):
        review = self.resolved_fixture()
        (self.work / '.build/checkouts/vapor/Package@swift-6.2.swift').write_text('unreviewed')
        with self.assertRaisesRegex(ValueError, 'compiler-specific'):
            module.verify(self.work, review)

    def test_upstream_source_and_prepared_factory_drift_fail_closed(self):
        review = self.resolved_fixture()
        upstream = self.work / '.build/checkouts/vapor/Sources/Vapor/Application.swift'
        original = upstream.read_bytes()
        upstream.write_text('changed')
        with self.assertRaisesRegex(ValueError, 'source differs'):
            module.verify(self.work, review)
        upstream.write_bytes(original)
        factory = self.work / 'Sources/ServerDependencyCompatibility/ServerApplicationFactory.swift'
        factory.write_text('changed')
        with self.assertRaisesRegex(ValueError, 'first-party source changed'):
            module.verify(self.work, review)

    def test_real_callers_keep_https_guard_and_distinct_server_policy(self):
        installer = (module.ROOT / 'VexSign/Backend/Server/ServerInstaller+TLS.swift').read_text()
        manager = (module.ROOT / 'VexSign/Backend/Server/WebManagerServer.swift').read_text()
        self.assertIn('guard let configuration = try tls() else { throw LocalInstallError.missingTLS }', installer)
        self.assertIn('transport = .https(configuration)', installer)
        self.assertLess(installer.index('transport = .https(configuration)'), installer.index('ServerApplicationFactory.make'))
        self.assertIn('bodyLimit: "128mb", caseInsensitive: false', installer)
        self.assertIn('bodyLimit: "32mb", caseInsensitive: true', manager)


if __name__ == '__main__':
    unittest.main()
