#!/usr/bin/env python3
"""Dependency-free regression checks for this repository's CI trigger policy.

These inspect the controlled workflow layout, not arbitrary YAML. Run actionlint
or GitHub Actions as well for full workflow/schema/expression validation.
"""
from pathlib import Path
import fnmatch
import re
import unittest
import os
import subprocess
import tempfile
import shutil
import json

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / '.github/workflows'
VALIDATORS = ('ci.yml', 'platform-check.yml', 'server-tests.yml', 'ecosystem.yml')


def block(text, key, indent):
    lines = text.splitlines()
    prefix = ' ' * indent + key + ':'
    start = next(i for i, line in enumerate(lines) if line.startswith(prefix))
    result = [lines[start]]
    for line in lines[start + 1:]:
        if line.strip() and not line.lstrip().startswith('#'):
            depth = len(line) - len(line.lstrip())
            if depth <= indent:
                break
        result.append(line)
    return '\n'.join(result)


def push_paths(name):
    push = block((WORKFLOWS / name).read_text(), 'push', 2)
    return re.findall(r"^      - '([^']+)'$", push, re.MULTILINE)


def covers(name, path):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in push_paths(name))


class WorkflowPolicyTests(unittest.TestCase):
    def test_no_automatic_pull_request_validation(self):
        for path in WORKFLOWS.glob('*.yml'):
            with self.subTest(workflow=path.name):
                events = block(path.read_text(), 'on', 0)
                self.assertNotRegex(events, r'(?m)^  pull_request(?:_target)?:')

    def test_validators_are_manual_or_path_filtered_main_pushes(self):
        for name in VALIDATORS:
            with self.subTest(workflow=name):
                text = (WORKFLOWS / name).read_text()
                events = block(text, 'on', 0)
                self.assertIn('  workflow_dispatch:', events)
                push = block(events, 'push', 2)
                self.assertIn('    branches: [main]', push)
                self.assertTrue(push_paths(name))
                self.assertIn('  cancel-in-progress: true', text)
                self.assertFalse(covers(name, 'README.md'))
                self.assertFalse(covers(name, 'docs/UI_POLISH.md'))

    def test_app_dependencies_and_submodule_pointer_changes_are_covered(self):
        for path in ('VexSign/VexSignApp.swift', 'VexSignTests/DesignSystemTests.swift',
                     'NimbleKit/Package.swift', 'AltSourceKit/Package.swift',
                     'VexSign.xcodeproj/project.pbxproj', 'Zsign', 'IDeviceKitten',
                     'Makefile', 'tools/test_workflow_policy.py'):
            with self.subTest(path=path):
                self.assertTrue(covers('ci.yml', path))
        self.assertFalse(covers('ci.yml', 'server/main.py'))
        self.assertFalse(covers('ci.yml', 'cloud-signing/src/main.ts'))

    def test_component_checks_do_not_follow_unrelated_changes(self):
        self.assertTrue(covers('server-tests.yml', 'server/main.py'))
        self.assertFalse(covers('server-tests.yml', 'VexSign/VexSignApp.swift'))
        self.assertTrue(covers('ecosystem.yml', 'cloud-signing/src/main.ts'))
        self.assertFalse(covers('ecosystem.yml', 'VexSign/CertificateDashboard/CertificateInspector.swift'))
        self.assertTrue(covers('platform-check.yml', 'VexSign/Companion/CompanionStatus.swift'))
        self.assertTrue(covers('platform-check.yml', 'VexSignWatch/VexSignWatchApp.swift'))

    def test_manual_quick_mode_and_fail_fast_job_order(self):
        text = (WORKFLOWS / 'ci.yml').read_text()
        self.assertIn('options: [full, quick]', text)
        self.assertIn('default: full', block(text, 'validation', 6))
        build = block(text, 'build', 2)
        self.assertIn('needs: quick', build)
        self.assertIn("inputs.validation != 'quick'", build)
        self.assertIn('needs: build', block(text, 'tests', 2))
        self.assertIn('python3 tools/test_workflow_policy.py', block(text, 'quick', 2))

    def test_pin_bootstrap_is_manual_and_uploads_only_the_public_pin(self):
        text = (WORKFLOWS / 'pin-release-tls.yml').read_text()
        events = block(text, 'on', 0)
        self.assertEqual(re.findall(r'^  ([a-z_]+):', events, re.MULTILINE),
                         ['workflow_dispatch'])
        self.assertIn('  contents: read', text)
        self.assertNotIn('contents: write', text)
        self.assertIn('make deps-pin', text)
        self.assertIn('make deps-release', text)
        self.assertEqual(re.findall(r'^          path: (.+)$', text, re.MULTILINE),
                         ['Scripts/local-tls/pinned-pack.sha256'])
        self.assertIn('if: always()', text)
        self.assertIn('Remove downloaded private-key material', text)

    def test_release_build_is_read_only_and_publisher_does_not_checkout(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        self.assertEqual([line for line in block(text, 'permissions', 0).splitlines()
                          if line.strip() and not line.startswith('#')],
                         ['permissions:', '  contents: read'])
        build = block(text, 'build', 2)
        publish = block(text, 'publish', 2)
        self.assertNotIn('contents: write', build)
        self.assertIn('persist-credentials: false', build)
        self.assertIn('git merge-base --is-ancestor', build)
        self.assertIn('RELEASE_TLS_SHA256: ${{ vars.RELEASE_TLS_SHA256 }}', build)
        self.assertIn('contents: write', publish)
        self.assertIn('environment: release', publish)
        self.assertNotIn('actions/checkout@', publish)
        self.assertIn('artifact-ids: ${{ needs.build.outputs.artifact_id }}', publish)
        self.assertIn('sha256sum --check SHA256SUMS', publish)
        self.assertIn('Release already exists', publish)
        for name in ('release.yml', 'pin-release-tls.yml'):
            for use in re.findall(r'uses: ([^\s]+)', (WORKFLOWS / name).read_text()):
                self.assertRegex(use, r'@[a-f0-9]{40}$')

    def test_security_schedule_and_release_boundaries_are_preserved(self):
        events = block((WORKFLOWS / 'ecosystem.yml').read_text(), 'on', 0)
        self.assertIn('  schedule:', events)
        self.assertIn("cron: '0 6 * * 2'", events)
        release = block((WORKFLOWS / 'release.yml').read_text(), 'on', 0)
        self.assertIn('    tags:', block(release, 'push', 2))
        self.assertNotIn('    branches:', block(release, 'push', 2))
        for name in VALIDATORS:
            self.assertIn('  contents: read', (WORKFLOWS / name).read_text())


class ReleasePinBootstrapTests(unittest.TestCase):
    def run_bootstrap(self, initial, fail_verify=False, configured=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pin = root / 'Scripts/local-tls/pinned-pack.sha256'
            pin.parent.mkdir(parents=True)
            pin.write_text(initial)
            binary = root / 'make'
            binary.write_text(r"""#!/usr/bin/env python3
from pathlib import Path
import sys, os
with open('calls', 'a') as log:
    log.write(sys.argv[1] + '\n')
if sys.argv[1] == 'deps-pin':
    Path('Scripts/local-tls/pinned-pack.sha256').write_text('sha256:' + 'a' * 64 + '\n')
if sys.argv[1] == 'deps-release' and os.environ['FAIL_VERIFY'] == '1':
    sys.exit(1)
""")
            binary.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       RUNNER_TEMP=str(root), FAIL_VERIFY=str(int(fail_verify)),
                       RELEASE_TLS_SHA256=configured)
            run = subprocess.run(['bash', str(ROOT / 'Scripts/local-tls/prepare-release-pin.sh')],
                                 cwd=root, env=env, capture_output=True, text=True)
            calls = (root / 'calls').read_text().splitlines() if (root / 'calls').exists() else []
            artifact = root / 'release-tls-pin.sha256'
            return run.returncode, calls, artifact.read_text() if artifact.exists() else None

    def test_missing_pin_requires_approved_digest(self):
        status, calls, artifact = self.run_bootstrap('# not yet pinned\n')
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, [])
        self.assertIsNone(artifact)

    def test_approved_environment_digest_is_verified_without_repinning(self):
        status, calls, artifact = self.run_bootstrap('# not yet pinned\n', configured='a' * 64)
        self.assertEqual(status, 0)
        self.assertEqual(calls, ['deps-release'])
        self.assertIn('sha256:' + 'a' * 64, artifact)

    def test_conflicting_environment_digest_fails(self):
        status, calls, artifact = self.run_bootstrap('sha256:' + 'b' * 64 + '\n', configured='a' * 64)
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, [])
        self.assertIsNone(artifact)

    def test_duplicate_pins_fail_closed(self):
        status, calls, artifact = self.run_bootstrap(('sha256:' + 'b' * 64 + '\n') * 2)
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, [])
        self.assertIsNone(artifact)

    def test_existing_pin_is_not_rotated(self):
        pin = 'sha256:' + 'b' * 64 + '\n'
        status, calls, artifact = self.run_bootstrap(pin)
        self.assertEqual(status, 0)
        self.assertEqual(calls, ['deps-release'])
        self.assertEqual(artifact, pin)

    def test_verification_failure_stops_without_repinning(self):
        status, calls, artifact = self.run_bootstrap('sha256:' + 'b' * 64 + '\n', True)
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, ['deps-release'])
        self.assertIsNone(artifact)

    def test_malformed_pin_cannot_be_silently_bootstrapped(self):
        status, calls, artifact = self.run_bootstrap('sha256:broken\n')
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, [])
        self.assertIsNone(artifact)


@unittest.skipUnless(shutil.which('openssl') and shutil.which('jq'), 'openssl and jq required')
class ReleasePackValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        cls.root = Path(cls.work.name)
        identity = cls.root / 'identity'
        env = dict(os.environ, DEV_CN='fixture.example.invalid')
        subprocess.run(['sh', str(ROOT / 'Scripts/local-tls/make-dev-identity.sh'), str(identity)],
                       env=env, check=True, capture_output=True)
        certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                           (identity / 'server.crt').read_text(), re.DOTALL)
        key = (identity / 'server.pem').read_text()
        midpoint = len(key) // 2
        cls.pack = dict(cert=certs[0], ca=certs[1], key1=key[:midpoint], key2=key[midpoint:],
                        info={'domains': {'commonName': 'fixture.example.invalid'}})
        binary = cls.root / 'bin'
        binary.mkdir()
        curl = binary / 'curl'
        curl.write_text(r'''#!/usr/bin/env python3
import os, sys, shutil
assert sys.argv[sys.argv.index('--proto') + 1] == '=https'
assert sys.argv[sys.argv.index('--proto-redir') + 1] == '=https'
shutil.copyfile(os.environ['FIXTURE_PACK'], sys.argv[sys.argv.index('-o') + 1])
''')
        curl.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def fetch(self, pack, url='https://fixture.example.invalid/pack.json'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / 'pack.json'
            fixture.write_text(json.dumps(pack))
            out = root / 'out'
            env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                       FIXTURE_PACK=str(fixture), CERT_PACK_URL=url)
            result = subprocess.run(['sh', str(ROOT / 'Scripts/local-tls/fetch-release-identity.sh'), str(out)],
                                    env=env, text=True, capture_output=True)
            mode = (out / 'server.pem').stat().st_mode & 0o777 if (out / 'server.pem').exists() else None
            return result.returncode, mode

    def test_valid_chain_hostname_and_key_are_accepted(self):
        status, mode = self.fetch(self.pack)
        self.assertEqual(status, 0)
        self.assertEqual(mode, 0o600)

    def test_http_is_rejected_before_fetch(self):
        status, _ = self.fetch(self.pack, 'http://fixture.example.invalid/pack.json')
        self.assertNotEqual(status, 0)

    def test_wrong_hostname_is_rejected(self):
        pack = dict(self.pack, info={'domains': {'commonName': 'other.example.invalid'}})
        status, _ = self.fetch(pack)
        self.assertNotEqual(status, 0)

    def test_non_string_pack_fields_are_rejected(self):
        status, _ = self.fetch(dict(self.pack, key1=42))
        self.assertNotEqual(status, 0)

    def test_broken_key_is_rejected(self):
        status, _ = self.fetch(dict(self.pack, key1='-----BEGIN PRIVATE KEY-----\nbroken', key2=''))
        self.assertNotEqual(status, 0)

    def test_valid_but_mismatched_private_key_is_rejected(self):
        key = subprocess.run(['openssl', 'genrsa', '2048'], check=True,
                             capture_output=True, text=True).stdout
        midpoint = len(key) // 2
        status, _ = self.fetch(dict(self.pack, key1=key[:midpoint], key2=key[midpoint:]))
        self.assertNotEqual(status, 0)

    def test_expired_certificate_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            leaf = root / 'leaf.crt'
            leaf.write_text(self.pack['cert'])
            expired = root / 'expired.crt'
            subprocess.run(['openssl', 'x509', '-in', str(leaf), '-signkey',
                            str(self.root / 'identity/server.pem'), '-days', '-1',
                            '-out', str(expired)], check=True, capture_output=True)
            check = subprocess.run(['openssl', 'x509', '-in', str(expired), '-checkend', '0', '-noout'],
                                   capture_output=True)
            self.assertNotEqual(check.returncode, 0)
            status, _ = self.fetch(dict(self.pack, cert=expired.read_text()))
            self.assertNotEqual(status, 0)

    def test_unrelated_ca_is_rejected(self):
        # A leaf is not a valid trust anchor for the CA that issued it.
        status, _ = self.fetch(dict(self.pack, ca=self.pack['cert']))
        self.assertNotEqual(status, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
