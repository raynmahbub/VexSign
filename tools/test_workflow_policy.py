#!/usr/bin/env python3
"""Dependency-free regression checks for this repository's CI trigger policy.

These inspect the controlled workflow layout, not arbitrary YAML. Run actionlint
or GitHub Actions as well for full workflow/schema/expression validation.
"""
from pathlib import Path
import fnmatch
import os
import re
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / '.github/workflows'
VALIDATORS = ('ci.yml', 'platform-check.yml', 'services.yml', 'embedded-container.yml')


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
    def test_ci_scope_keeps_native_sources_and_unknown_paths(self):
        native = runpy.run_path(str(ROOT / 'tools/ci-scope.py'))['needs_native']
        self.assertFalse(native(['tools/test_release_assets.py', 'tools/generate-changelog.sh', 'docs/RELEASING.md']))
        for path in ('VexSign/App.swift', 'VexSignTests/Test.swift', 'NativeSigning/Tests/Test.swift',
                     'Makefile', 'SideSign/Package.swift', 'Vendor/source.cpp', '.github/workflows/ci.yml',
                     '.github/workflows/ci-repair-assistant.yml', 'tools/bootstrap.sh', 'unknown-file'):
            self.assertTrue(native([path]), path)
        # A removed app source must still count when renamed into documentation.
        self.assertTrue(native(['VexSign/Old.swift', 'docs/Old.md']))

    def test_ci_scope_uses_whole_pr_and_falls_back_to_native(self):
        import json
        import os
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('commit', '--allow-empty', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (root / 'App.swift').write_text('// fixture')
            git('add', '.')
            git('commit', '-qm', 'native')
            middle = git('rev-parse', 'HEAD')
            (root / 'README.md').write_text('docs')
            git('add', '.')
            git('commit', '-qm', 'docs')
            event, output = root / 'event.json', root / 'output.txt'
            for sha, expected in ((base, 'true'), (middle, 'false'), ('f' * 40, 'true')):
                event.write_text(json.dumps({'pull_request': {'base': {'sha': sha}}}))
                output.write_text('')
                subprocess.run(['python3', str(ROOT / 'tools/ci-scope.py')], cwd=root,
                               env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request',
                                    'GITHUB_EVENT_PATH': str(event), 'GITHUB_OUTPUT': str(output)},
                               check=True, capture_output=True)
                self.assertEqual(output.read_text(), f'native={expected}\n')

    def test_consolidated_triage_retains_permissions_and_prevents_recursion(self):
        text = (WORKFLOWS / 'repo-maintenance.yml').read_text()
        triage = block(block(text, 'jobs', 0), 'open-or-update-issue', 2)
        self.assertIn('actions: read', triage)
        self.assertIn('issues: write', triage)
        self.assertNotIn('actions/checkout', triage)
        self.assertIn("github.event.workflow_run.event != 'workflow_run'", triage)
        self.assertIn('head_repository.full_name == github.repository', triage)
        self.assertFalse((WORKFLOWS / 'ci-triage.yml').exists())
        ci = (WORKFLOWS / 'ci.yml').read_text()
        for name in ('build', 'tests'):
            self.assertIn("needs.quick.outputs.native == 'true'", block(ci, name, 2))
        self.assertIn('-parallel-testing-worker-count 2', ci)
        combined = (WORKFLOWS / 'embedded-container.yml').read_text()
        self.assertIn('Restore Swift package downloads', combined)
        self.assertIn('runner.arch', combined)
        self.assertIn('TMPDIR: ${{ runner.temp }}/', combined)

    def test_combined_build_exposes_failures_and_preserves_native_input(self):
        text = (WORKFLOWS / 'embedded-container.yml').read_text()
        for stage in ('native_input', 'combined'):
            self.assertIn(f'id: {stage}', text)
            self.assertIn(f"if: always() && steps.{stage}.outcome != 'skipped'", text)
            self.assertIn(f'steps.{stage}.outputs.exit_code', text)
        self.assertIn("if: always() && steps.native_input.outcome == 'success'", text)
        self.assertIn('name: VexSign-native-input-unsigned', text)
        self.assertIn('echo "app_version=${APP_VERSION}" >> "$GITHUB_OUTPUT"', text)
        versioned_ipa = 'packages/VexSign-${{ steps.native_input.outputs.app_version }}.ipa'
        self.assertIn(f'path: {versioned_ipa}', text)
        self.assertIn(f'--vexsign-ipa "{versioned_ipa}"', text)
        self.assertNotIn('packages/VexSign.ipa', text)
        self.assertNotIn('continue-on-error:', text)

    def test_native_diagnostics_parse_both_compiler_and_xctest_locations(self):
        parser = runpy.run_path(str(ROOT / '.github/scripts/xcodebuild_report.py'))['DIAG_RE']
        for location, column in [('12:7:', '7'), ('12:', None)]:
            match = parser.match(f'/tmp/Fixture.swift:{location} error: Fixture.testCase : assertion failed')
            self.assertIsNotNone(match)
            self.assertEqual(match['line'], '12')
            self.assertEqual(match['col'], column)
            self.assertIn('assertion failed', match['msg'])

    def test_platform_build_uses_job_owned_package_and_temporary_paths(self):
        text = (WORKFLOWS / 'platform-check.yml').read_text()
        self.assertIn('TMPDIR: ${{ runner.temp }}/', text)
        self.assertIn('-packageCachePath "${RUNNER_TEMP}/SwiftPMCache-${{ matrix.scheme }}"', text)
        self.assertIn('prefetch_spm_artifacts.py', text)
        self.assertEqual(text.count("      - '.github/scripts/prefetch_spm_artifacts.py'"), 2)
        self.assertIn('--cache "${RUNNER_TEMP}/SwiftPMCache-${{ matrix.scheme }}/artifacts"', text)
        self.assertNotIn('continue-on-error:', text)

    def test_binary_prefetch_checksums_deduplication_and_failure_cleanup(self):
        import hashlib
        prefetch = runpy.run_path(str(ROOT / '.github/scripts/prefetch_spm_artifacts.py'))
        payload = b'verified archive bytes'
        checksum = hashlib.sha256(payload).hexdigest()
        urls = ['https://github.com/example/archive.zip#A', 'https://github.com/example/archive.zip#B']
        calls = []

        def download(url, destination):
            calls.append(url)
            destination.write_bytes(payload)

        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder)
            artifacts = [(url, checksum) for url in urls]
            prefetch['prefetch'](cache, artifacts, download)
            self.assertEqual(calls, ['https://github.com/example/archive.zip'])
            for url in urls:
                self.assertEqual((cache / prefetch['cache_key'](url)).read_bytes(), payload)
            prefetch['prefetch'](cache, artifacts, download)
            self.assertEqual(len(calls), 1)
            original = cache / prefetch['cache_key'](urls[0])
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                prefetch['prefetch'](cache, [(urls[0], '0' * 64)], download)
            self.assertEqual(original.read_bytes(), payload)
            self.assertFalse(any(path.name.startswith('.prefetch-') for path in cache.iterdir()))

    def test_binary_prefetch_never_publishes_failed_downloads(self):
        prefetch = runpy.run_path(str(ROOT / '.github/scripts/prefetch_spm_artifacts.py'))
        def download(url, destination):
            destination.write_bytes(b'partial')
            raise RuntimeError('network failure')
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder)
            with self.assertRaisesRegex(RuntimeError, 'network failure'):
                prefetch['prefetch'](cache, [('https://github.com/example/archive.zip', '0' * 64)], download)
            self.assertEqual(list(cache.iterdir()), [])

    def test_binary_prefetch_download_failure_is_annotated_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            curl = root / 'curl'
            curl.write_text('#!/bin/sh\nprintf "HTTP failure 100%%\\nsecond line\\n" >&2\nexit 22\n')
            curl.chmod(0o755)
            env = dict(os.environ, PATH=str(root))
            result = subprocess.run([
                sys.executable, str(ROOT / '.github/scripts/prefetch_spm_artifacts.py'),
                '--cache', str(root / 'cache'),
            ], text=True, capture_output=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('::error title=Binary archive prefetch failed::', result.stdout)
            self.assertIn('curl exit 22', result.stdout)
            self.assertIn('HTTP failure 100%25%0Asecond line', result.stdout)
            self.assertIn('OpenSSL.xcframework.zip', result.stdout)
            self.assertEqual(list((root / 'cache').iterdir()), [])

    def test_package_resolution_annotations_include_the_root_cause(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'build.log'
            log.write_text('xcodebuild: error: Could not resolve package dependencies:\n'
                           '  Package Example requires a newer Swift tools version.\n'
                           '  Required: 6.4; installed: 6.2.\n\n')
            result = subprocess.run([
                sys.executable, str(ROOT / '.github/scripts/xcodebuild_report.py'),
                '--log', str(log), '--build-exit', '74', '--warnings-as-errors', 'false',
                '--summary', str(Path(folder) / 'summary.md'), '--workspace', str(ROOT),
            ], text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Package Example requires a newer Swift tools version.', result.stdout)
            self.assertIn('Required: 6.4; installed: 6.2.', result.stdout)
            self.assertIn('::error', result.stdout)

    def test_pull_requests_run_only_path_filtered_validators(self):
        validators = {*VALIDATORS, 'docs.yml'}
        for path in WORKFLOWS.glob('*.yml'):
            with self.subTest(workflow=path.name):
                events = block(path.read_text(), 'on', 0)
                if path.name in validators:
                    pr = block(events, 'pull_request', 2)
                    self.assertIn('    branches: [main]', pr)
                    push = block(events, 'push', 2)
                    self.assertEqual(pr.replace('pull_request:', 'push:', 1), push)
                else:
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
                     'Makefile', 'tools/test_workflow_policy.py', '.github/workflows/ci-repair-assistant.yml'):
            with self.subTest(path=path):
                self.assertTrue(covers('ci.yml', path))
        self.assertFalse(covers('ci.yml', 'server/main.py'))
        self.assertFalse(covers('ci.yml', 'cloud-signing/src/main.ts'))

    def test_component_checks_do_not_follow_unrelated_changes(self):
        self.assertTrue(covers('services.yml', 'server/main.py'))
        self.assertFalse(covers('services.yml', 'VexSign/VexSignApp.swift'))
        self.assertTrue(covers('services.yml', 'cloud-signing/src/main.ts'))
        self.assertFalse(covers('services.yml', 'VexSign/CertificateDashboard/CertificateInspector.swift'))
        self.assertTrue(covers('platform-check.yml', 'VexSign/Companion/CompanionStatus.swift'))
        self.assertTrue(covers('platform-check.yml', 'VexSignWatch/VexSignWatchApp.swift'))

    def test_native_smoke_runs_fixture_tests_without_publishing(self):
        # Folded into the combined-host workflow as a dispatch-only job so the
        # manual diagnostics share one entry point and one set of gates.
        text = (WORKFLOWS / 'embedded-container.yml').read_text()
        self.assertIn('      link_smoke:', text)
        self.assertIn('      unit_tests:', text)
        self.assertIn('if: inputs.unit_tests', text)
        self.assertIn('inputs.link_smoke == true', text)
        self.assertIn('swift test --package-path .build/native-signing-smoke', text)
        self.assertIn('native-signing-unit-tests.log', text)
        self.assertIn('retention-days: 3', text)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('gh release create', text)

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

    def test_quick_container_checks_do_not_require_make(self):
        quick = block((WORKFLOWS / 'ci.yml').read_text(), 'quick', 2)
        self.assertNotRegex(quick, r'(?m)^\s+(?:run: )?make ')
        self.assertIn('python3 tools/check-docs.py', quick)
        self.assertIn('python3 tools/test_docs.py', quick)

    def test_listing_bot_uses_a_review_branch(self):
        text = (WORKFLOWS / 'update_repo.yml').read_text()
        self.assertIn('pull-requests: write', text)
        self.assertIn('BRANCH="automation/release-listing"', text)
        self.assertIn('gh pr create --base "$DEFAULT_BRANCH"', text)
        self.assertNotIn('git symbolic-ref --short HEAD', text)

    def test_release_visuals_metadata_and_notes_are_bundled(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        self.assertIn('python3 tools/prepare-release-assets.py', text)
        for asset in ('CHANGELOG.md', 'RELEASE.json', 'VexSign-icon.png', 'Home-layout-preview.svg'):
            self.assertIn('upload/' + asset, block(text, 'build', 2))
            self.assertIn('upload/' + asset, block(text, 'publish', 2))

    def test_release_versions_are_numeric_and_packaged_bundles_are_checked(self):
        import plistlib
        import tempfile
        import zipfile
        module = runpy.run_path(str(ROOT / 'tools/release-build-version.py'))
        version = module['build_version']
        for count in (1, 99, 100, 9999, 10000, 99989999):
            self.assertRegex(version(count), r'^[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}$')
        self.assertEqual(version(9999), '1.99.99')
        self.assertEqual(version(10000), '2.0.0')
        for count in (0, -1, 99990000):
            with self.assertRaises(ValueError):
                version(count)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.ipa'
            for root, extension, valid in [('1.0.1', '1.0.1', True),
                                           ('deadbeef', '1.0.1', False),
                                           ('1.0.1', '2', False)]:
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps({'CFBundleVersion': root}))
                    archive.writestr('Payload/Test.app/PlugIns/Test.appex/Info.plist', plistlib.dumps({'CFBundleVersion': extension}))
                if valid:
                    module['verify_ipa'](path, '1.0.1')
                else:
                    with self.assertRaises(ValueError):
                        module['verify_ipa'](path, '1.0.1')
            with zipfile.ZipFile(path, 'w'):
                pass
            with self.assertRaises(ValueError):
                module['verify_ipa'](path, '1.0.1')
        text = (WORKFLOWS / 'release.yml').read_text()
        self.assertIn('agvtool new-version -all "${BUILD_NUMBER}"', text)
        self.assertNotIn('BUILD_NUMBER="$(git rev-parse HEAD)"', text)
        self.assertNotIn('continuing with the committed CURRENT_PROJECT_VERSION', text)
        self.assertIn('--verify-ipa "$ipa"', text)
        upload = text.split('      - name: Upload IPA artifact\n', 1)[1].split('      - name:', 1)[0]
        self.assertIn('retention-days: 14', upload)
        diagnostics = text.split('retention-days: 14', 1)[1]
        self.assertIn('retention-days: 3', diagnostics)

    def test_every_release_runs_simulator_tests(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        step = text.split('      - name: Release simulator tests\n', 1)[1].split('      - name:', 1)[0]
        self.assertIn('run: make test', step)
        self.assertNotIn('if:', step)

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
        # workflow must not execute privileged maintenance code from PRs.
        self.assertTrue((ROOT / '.github/dependabot.yml').is_file())
        for name in ('repo-maintenance.yml',):
            events = block((WORKFLOWS / name).read_text(), 'on', 0)
            self.assertNotIn('pull_request', events)

    def test_free_only_workflow_policy(self):
        for path in WORKFLOWS.glob('*.yml'):
            text = path.read_text()
            for job in re.findall(r'^  ([A-Za-z0-9_-]+):$', block(text, 'jobs', 0), re.MULTILINE):
                self.assertIn('github.event.repository.private == false', block(block(text, 'jobs', 0), job, 2))
                self.assertIn("github.event.repository.visibility == 'public'", block(block(text, 'jobs', 0), job, 2))
            self.assertNotIn('models: read', text)
            for runner in re.findall(r'runs-on: (.+)', text):
                self.assertIn(runner, ('ubuntu-24.04', 'macos-15'))
            # Device-testing IPAs have a 14-day exception; logs, quick findings
            # and release publishing-staging artifacts stay at <= 3 days.
            retention_text = text
            if path.name in ('ci.yml', 'embedded-container.yml', 'release.yml'):
                artifact_steps = {
                    'ci.yml': ['Upload unsigned test IPA'],
                    'embedded-container.yml': ['Upload combined build and integration sources', 'Preserve unsigned native input'],
                    'release.yml': ['Upload IPA artifact'],
                }[path.name]
                for artifact_step in artifact_steps:
                    match = re.search(r'(?ms)^      - name: ' + re.escape(artifact_step) + r'\n.*?(?=^      - name:)', retention_text)
                    self.assertIsNotNone(match)
                    self.assertEqual(re.findall(r'retention-days: (\d+)', match[0]), ['14'])
                    retention_text = retention_text[:match.start()] + retention_text[match.end():]
            for retention in re.findall(r'retention-days: (\d+)', retention_text):
                self.assertLessEqual(int(retention), 3)
        for removed in ('autopilot.yml', 'auto-stable.yml', 'dependency-audit.yml',
                        'server-tests.yml', 'ecosystem.yml'):
            self.assertFalse((WORKFLOWS / removed).exists())

    def test_ci_repair_assistant_is_same_repo_scoped_draft_only_and_least_privilege(self):
        text = (WORKFLOWS / 'ci-repair-assistant.yml').read_text()
        events = block(text, 'on', 0)
        self.assertIn('workflows: ["CI"]', events)
        self.assertIn('types: [completed]', events)
        jobs = block(text, 'jobs', 0)
        propose = block(jobs, 'propose', 2)
        validate = block(jobs, 'validate', 2)
        publish = block(jobs, 'publish', 2)
        for condition in ("github.event.workflow_run.event == 'pull_request'",
                          "github.event.workflow_run.conclusion == 'failure'",
                          'github.event.workflow_run.head_repository.full_name == github.repository',
                          "!startsWith(github.event.workflow_run.head_branch, 'automation/bugfix-agent/')"):
            self.assertIn(condition, propose)
        self.assertIn('OPENAI_API_KEY', propose)
        self.assertIn('contents: read', block(propose, 'permissions', 4))
        self.assertNotIn('contents: write', block(propose, 'permissions', 4))
        self.assertIn('persist-credentials: false', validate)
        self.assertIn('contents: write', block(publish, 'permissions', 4))
        self.assertIn('pull-requests: write', block(publish, 'permissions', 4))
        self.assertIn('persist-credentials: true', publish)
        self.assertIn('validate', publish)
        self.assertIn('publish', publish)
        agent = (ROOT / 'tools/ci_repair_agent.py').read_text()
        self.assertIn('validate_patch', agent)
        self.assertIn('MAX_PATCH_BYTES = 80_000', agent)
        self.assertIn('MAX_PATCH_LINES = 800', agent)
        self.assertIn('automation/bugfix-agent/', agent)
        self.assertIn('--draft', agent)
        self.assertNotIn('gh", "pr", "merge', agent)

    def test_maintenance_jobs_keep_independent_permissions_and_cadence(self):
        text = (WORKFLOWS / 'repo-maintenance.yml').read_text()
        self.assertEqual(block(text, 'permissions', 0).strip(), 'permissions:\n  contents: read')
        jobs = block(text, 'jobs', 0)
        maintain = block(jobs, 'maintain', 2)
        self.assertIn("github.event.schedule == '17 */4 * * *'", maintain)
        self.assertIn("inputs.task == 'bot-prs'", maintain)
        self.assertIn('actions: write', block(maintain, 'permissions', 4))
        for job in ('hygiene', 'audit'):
            content = block(jobs, job, 2)
            self.assertIn("github.event.schedule == '40 4 * * 1'", content)
            self.assertNotIn("github.event.schedule == '17 */4 * * *'", content)
            self.assertNotIn('actions: write', block(content, 'permissions', 4))
        audit_permissions = block(block(jobs, 'audit', 2), 'permissions', 4)
        self.assertIn('contents: read', audit_permissions)
        self.assertNotIn('contents: write', audit_permissions)
        self.assertNotIn('pull-requests: write', audit_permissions)

    def test_ci_completion_only_dispatches_release_and_cannot_start_build(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        self.assertIn('workflows: [CI]', block(text, 'on', 0))
        self.assertIn("github.event_name != 'workflow_run'", block(text, 'build', 2))
        version = block(text, 'version-bump', 2)
        self.assertIn("github.event_name == 'workflow_run'", version)
        self.assertIn('head_repository.full_name == github.repository', version)
        self.assertIn("workflow_run.conclusion == 'success'", version)
        self.assertIn('contents: read', block(version, 'permissions', 4))
        self.assertNotIn('contents: write', block(version, 'permissions', 4))

    def test_ci_offers_disposable_ipa_without_release_permissions(self):
        text = (WORKFLOWS / 'ci.yml').read_text()
        build = block(text, 'build', 2)
        self.assertIn('needs: quick', build)
        self.assertIn("inputs.validation != 'quick'", build)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('environment: release', text)
        self.assertNotIn('gh release', text)
        self.assertLess(build.index('name: Report diagnostics'), build.index('name: Package unsigned test IPA'))
        self.assertIn('Debug-iphoneos/VexSign.app', build)
        self.assertIn('ditto -c -k --keepParent Payload', build)
        self.assertIn('name: VexSign-unsigned-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}', build)
        self.assertRegex(build, r'(?s)name: Upload unsigned test IPA.*?retention-days: 14')
        self.assertIn('if-no-files-found: error', build)
        self.assertIn('Check the separate simulator-test job', build)

    def test_combined_build_is_read_only_path_filtered_and_includes_verification_outputs(self):
        text = (WORKFLOWS / 'embedded-container.yml').read_text()
        events = block(text, 'on', 0)
        self.assertIn('workflow_dispatch:', events)
        self.assertNotIn('schedule:', events)
        self.assertNotIn('pull_request_target:', events)
        self.assertTrue(covers('embedded-container.yml', 'EmbeddedContainer/build.py'))
        self.assertFalse(covers('embedded-container.yml', 'README.md'))
        self.assertFalse(covers('embedded-container.yml', 'server/main.py'))
        self.assertIn("github.event.repository.visibility == 'public'", text)
        self.assertIn('swift test --package-path .build/native-signing-smoke', text)
        self.assertIn('native-signing-unit-tests.log', text)
        self.assertIn('run: bash .github/scripts/select_xcode.sh', text)
        self.assertIn("python-version: '3.12'", text)
        self.assertIn('contents: read', text)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('gh release', text)
        for suffix in ('.ipa', '.integration-sources.tar.gz', '.build.json', '.checksums.txt'):
            self.assertIn('packages/VexSign+LiveContainer+SideStore' + suffix, text)
        self.assertRegex(text, r'(?s)name: Upload build logs.*?retention-days: 3')

    def test_ci_ipa_packaging_layout_metadata_and_rejections(self):
        """Exercise the actual workflow shell with a ditto stand-in, not a native build."""
        import hashlib
        import json
        import os
        import plistlib
        import shutil
        import subprocess
        import tempfile
        import textwrap
        import zipfile

        if not shutil.which('bash') or not shutil.which('shasum'):
            self.skipTest('bash/shasum unavailable')
        text = (WORKFLOWS / 'ci.yml').read_text()
        step = text.split('      - name: Package unsigned test IPA\n', 1)[1].split('\n      - name:', 1)[0]
        script = textwrap.dedent(step.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_path = root / 'bin'
            bin_path.mkdir()
            # Model ditto's two operations for offline shell/structure checks.
            # Apple's archive metadata/symlink handling still needs a macOS run.
            ditto = bin_path / 'ditto'
            ditto.write_text('#!/usr/bin/env python3\n' + textwrap.dedent('''\
                import pathlib, shutil, sys, zipfile
                args = sys.argv[1:]
                if args[:4] == ['-c', '-k', '--keepParent', 'Payload']:
                    with zipfile.ZipFile(args[4], 'w') as archive:
                        for path in pathlib.Path('Payload').rglob('*'):
                            if path.is_file(): archive.write(path, path.as_posix())
                else:
                    shutil.copytree(args[0], args[1], dirs_exist_ok=True)
                '''))
            ditto.chmod(0o755)
            derived = root / 'DerivedData'
            app = derived / 'Build/Products/Debug-iphoneos/VexSign.app'
            app.mkdir(parents=True)
            executable = app / 'VexSign'
            executable.write_bytes(b'fixture only, not an executable')
            info = {'DTPlatformName': 'iphoneos', 'CFBundleExecutable': 'VexSign',
                    'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '42'}
            env = {**os.environ, 'PATH': str(bin_path) + os.pathsep + os.environ['PATH'],
                   'DERIVED_DATA': str(derived), 'RUNNER_TEMP': str(root),
                   'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2'}
            def run():
                (app / 'Info.plist').write_bytes(plistlib.dumps(info))
                return subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            staging = root / 'ci-ipa'
            with zipfile.ZipFile(staging / 'VexSign-unsigned.ipa') as archive:
                self.assertIn('Payload/VexSign.app/Info.plist', archive.namelist())
                self.assertIn('Payload/VexSign.app/VexSign', archive.namelist())
                self.assertNotIn('BUILD.json', archive.namelist())
            metadata = json.loads((staging / 'BUILD.json').read_text())
            self.assertEqual(metadata['commit'], 'a' * 40)
            self.assertEqual(metadata['version'], '1.2.3')
            self.assertEqual(metadata['run_attempt'], '2')
            self.assertTrue(metadata['unsigned'])
            for line in (staging / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split('  ')
                self.assertEqual(digest, hashlib.sha256((staging / name).read_bytes()).hexdigest())
            for problem in ('simulator', 'missing-executable'):
                with self.subTest(problem=problem):
                    shutil.rmtree(staging)
                    if problem == 'simulator': info['DTPlatformName'] = 'iphonesimulator'
                    else:
                        info['DTPlatformName'] = 'iphoneos'
                        executable.unlink()
                    self.assertNotEqual(run().returncode, 0)
                    self.assertFalse((staging / 'VexSign-unsigned.ipa').exists())

    def test_release_checks_use_explicit_python_and_shared_xcode_selector(self):
        release = block((WORKFLOWS / 'release.yml').read_text(), 'build', 2)
        self.assertRegex(release, r'uses: actions/setup-python@[a-f0-9]{40}')
        self.assertIn("python-version: '3.12'", release)
        self.assertLess(release.index('Set up Python'), release.index('run: make verify'))
        self.assertIn('run: bash .github/scripts/select_xcode.sh', release)


    def test_release_primes_and_shares_verified_binary_cache(self):
        release = block((WORKFLOWS / 'release.yml').read_text(), 'build', 2)
        self.assertIn('prefetch_spm_artifacts.py', release)
        self.assertIn('--cache "${RUNNER_TEMP}/SwiftPMCache-Release/artifacts"', release)
        self.assertLess(release.index('prefetch_spm_artifacts.py'), release.index('name: Compile VexSign'))
        self.assertEqual(release.count('SPM_CACHE_PATH: ${{ runner.temp }}/SwiftPMCache-Release'), 2)
        makefile = (ROOT / 'Makefile').read_text()
        self.assertIn('SPM_CACHE_PATH ?=', makefile)
        self.assertEqual(makefile.count('$(if $(SPM_CACHE_PATH),-packageCachePath "$(SPM_CACHE_PATH)",)'), 2)
        self.assertNotIn('-disablePackageRepositoryCache', release)

    def test_existing_validation_check_names_are_retained(self):
        ci = (WORKFLOWS / 'ci.yml').read_text()
        self.assertIn('name: quick · syntax, resources, gates', ci)
        self.assertIn('name: build · VexSign Debug (unsigned)', ci)
        self.assertIn('name: tests · VexSignTests (simulator)', ci)
        services = (WORKFLOWS / 'services.yml').read_text()
        self.assertIn('name: pytest · server', block(services, 'pytest', 2))
        self.assertIn('  cloud:', services)  # implicit check name is still cloud
        self.assertIn('  links:', (WORKFLOWS / 'docs.yml').read_text())

    def test_failure_reporting_uses_real_workflow_names_and_serializes_issues(self):
        text = (WORKFLOWS / 'repo-maintenance.yml').read_text()
        watched = re.search(r'workflows: \[(.*)\]', text)[1]
        real_names = {re.search(r'^name: (.+)', p.read_text())[1] for p in WORKFLOWS.glob('*.yml')}
        for name in re.findall(r'"([^"]+)"', watched):
            self.assertIn(name, real_names)
        self.assertNotIn('"CI triage"', watched)
        self.assertNotIn('"Repository maintenance"', watched)
        self.assertIn('cancel-in-progress: false', text)
        self.assertIn('WORKFLOW_NAME:', text)

    def test_developer_entry_points_share_the_tools_directory(self):
        makefile = (ROOT / 'Makefile').read_text()
        self.assertIn('bash tools/bootstrap.sh', makefile)
        self.assertIn('bash tools/device-smoke.sh', makefile)
        self.assertIn('./tools/update-repo.sh', (WORKFLOWS / 'update_repo.yml').read_text())
        for name in ('bootstrap.sh', 'device-smoke.sh', 'update-repo.sh', 'tls-pack-digest.py'):
            self.assertTrue((ROOT / 'tools' / name).is_file())
        self.assertFalse((ROOT / 'Scripts').exists())
        self.assertFalse((ROOT / 'update-repo.sh').exists())
        self.assertTrue((ROOT / 'docs/assets/logo.svg').is_file())
        self.assertTrue((ROOT / 'icon.png').is_file())  # published feed compatibility

    def test_security_schedule_and_release_boundaries_are_preserved(self):
        events = block((WORKFLOWS / 'services.yml').read_text(), 'on', 0)
        self.assertIn('  schedule:', events)
        self.assertIn("cron: '0 6 * * 2'", events)
        release = block((WORKFLOWS / 'release.yml').read_text(), 'on', 0)
        self.assertIn('    tags:', block(release, 'push', 2))
        self.assertNotIn('    branches:', block(release, 'push', 2))
        for name in VALIDATORS:
            self.assertIn('  contents: read', (WORKFLOWS / name).read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
