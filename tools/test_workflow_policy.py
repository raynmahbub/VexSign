#!/usr/bin/env python3
"""Dependency-free regression checks for this repository's CI trigger policy.

These inspect the controlled workflow layout, not arbitrary YAML. Run actionlint
or GitHub Actions as well for full workflow/schema/expression validation.
"""
from pathlib import Path
import fnmatch
import re
import unittest

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
                self.assertFalse(covers(name, 'CHANGELOG.md'))

    def test_app_dependencies_and_vendored_package_changes_are_covered(self):
        for path in ('VexSign/VexSignApp.swift', 'VexSignTests/DesignSystemTests.swift',
                     'NimbleKit/Package.swift', 'AltSourceKit/Package.swift',
                     'VexSign.xcodeproj/project.pbxproj', 'Vendor/Zsign/Package.swift',
                     'Vendor/IDeviceKitten/Package.swift',
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

    def test_manual_quick_mode_and_parallel_macos_jobs(self):
        text = (WORKFLOWS / 'ci.yml').read_text()
        self.assertIn('options: [full, quick]', text)
        self.assertIn('default: full', block(text, 'validation', 6))
        build = block(text, 'build', 2)
        self.assertIn('needs: quick', build)
        self.assertIn("inputs.validation != 'quick'", build)
        tests = block(text, 'tests', 2)
        self.assertIn('needs: quick', tests)
        self.assertIn("inputs.validation != 'quick'", tests)
        self.assertIn('-parallel-testing-enabled YES', tests)
        self.assertNotIn('needs: build', tests)
        self.assertIn('python3 tools/test_workflow_policy.py', block(text, 'quick', 2))

    def test_identity_is_neither_downloaded_nor_bundled(self):
        release = (WORKFLOWS / 'release.yml').read_text()
        makefile = (ROOT / 'Makefile').read_text()
        self.assertNotIn('CERT_PACK_URL', release)
        self.assertNotIn('RELEASE_TLS_SHA256', release)
        self.assertNotIn('make deps', release)
        self.assertNotIn('cp deps/', makefile)
        self.assertNotIn('deps-release:', makefile)
        self.assertFalse((WORKFLOWS / 'pin-release-tls.yml').exists())
        self.assertNotIn('downloadSSLCertificates', (ROOT / 'VexSign/Utilities/FR.swift').read_text())
        resolver = (ROOT / 'VexSign/Backend/Server/ServerInstaller+TLS.swift').read_text()
        self.assertNotIn('Bundle.main', resolver)
        self.assertIn('DeviceTLSIdentity.directory', resolver)

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
        self.assertIn('contents: write', publish)
        self.assertIn("needs.build.outputs.channel == 'nightly'", publish)
        self.assertIn("'nightly' || 'release'", publish)
        self.assertNotIn('actions/checkout@', publish)
        self.assertIn('artifact-ids: ${{ needs.build.outputs.artifact_id }}', publish)
        self.assertIn('sha256sum --check SHA256SUMS', publish)
        self.assertIn('Release already exists', publish)
        for name in ('release.yml',):
            for use in re.findall(r'uses: ([^\s]+)', (WORKFLOWS / name).read_text()):
                self.assertRegex(use, r'@[a-f0-9]{40}$')

    def test_nightly_release_is_scheduled_and_immutable(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        events = block(text, 'on', 0)
        self.assertIn('  schedule:', events)
        self.assertIn("cron: '0 3 * * *'", events)
        self.assertIn('MODE="nightly"', text)
        self.assertIn('nightly.${NIGHTLY_DATE}.${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}', text)
        self.assertIn('channel=${CHANNEL}', text)
        self.assertIn('prerelease: ${{ needs.build.outputs.prerelease ==', text)

    def test_nightly_does_not_update_the_stable_listing(self):
        update = (WORKFLOWS / 'update_repo.yml').read_text()
        self.assertIn("github.event.release.prerelease == false", update)
        release = (WORKFLOWS / 'release.yml').read_text()
        self.assertIn("needs.build.outputs.channel == 'stable'", release)

    def test_automation_workflows_do_not_validate_pull_requests(self):
        # Dependabot and maintenance work through branches/issues; a PR-triggered
        # workflow would bypass the repository's main-only validation model.
        self.assertTrue((ROOT / '.github/dependabot.yml').is_file())
        for name in ('repo-maintenance.yml', 'ci-triage.yml', 'dependency-audit.yml'):
            events = block((WORKFLOWS / name).read_text(), 'on', 0)
            self.assertNotIn('pull_request', events)

    def test_security_schedule_and_release_boundaries_are_preserved(self):
        events = block((WORKFLOWS / 'ecosystem.yml').read_text(), 'on', 0)
        self.assertIn('  schedule:', events)
        self.assertIn("cron: '0 6 * * 2'", events)
        release = block((WORKFLOWS / 'release.yml').read_text(), 'on', 0)
        self.assertIn('    tags:', block(release, 'push', 2))
        self.assertNotIn('    branches:', block(release, 'push', 2))
        for name in VALIDATORS:
            self.assertIn('  contents: read', (WORKFLOWS / name).read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
