#!/usr/bin/env python3
"""Dependency-free regression checks for this repository's CI trigger policy.

These inspect the controlled workflow layout, not arbitrary YAML. Run actionlint
or GitHub Actions as well for full workflow/schema/expression validation.
"""
from pathlib import Path
import ast
import fnmatch
import os
import re
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / ".github/workflows"
VALIDATORS = ('ci.yml', 'platform-check.yml', 'services.yml', 'embedded-container.yml', 'device-bridge.yml')
# Workflows that validate a merge to main. Every one of them shares the same rule: a push to
# main must not cancel the previous main run (see the concurrency test below).
MAIN_VALIDATORS = VALIDATORS + ('docs.yml',)


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


def trigger_paths(name, trigger):
    section = block((WORKFLOWS / name).read_text(), trigger, 2)
    return re.findall(r"^      - '([^']+)'$", section, re.MULTILINE)


def push_paths(name):
    return trigger_paths(name, 'push')


def covers(name, path):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in push_paths(name))


def covers_trigger(name, trigger, path):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in trigger_paths(name, trigger))


def native_smoke_app_sources():
    """The app files `prepare_smoke.py` compiles byte-for-byte into the native smoke package.

    Read from the preparation script rather than restated here: the smoke package builds the
    app's real lifecycle implementation, so whatever it copies is native-test input and has to
    trigger the workflow that runs those tests. Deriving the list is what keeps this check from
    becoming the third copy of a file list that can drift.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location("native_smoke_sources_for_policy", ROOT / "Packages/NativeSigning/prepare_smoke.py")
    preparation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(preparation)
    with tempfile.TemporaryDirectory() as directory:
        hashes = preparation.install_smoke_sources(Path(directory))
    # The app sources the smoke package copies are the repository-relative ones
    # (everything else in the manifest is a package-relative file).
    ours = ("VexSign/App/", "VexSign/Shared/", "VexSign/Storage/", "VexSign/Networking/", "VexSign/System/", "VexSign/DesignSystem/", "VexSign/")
    return sorted(path for path in hashes if path.startswith(ours))


#: The manifest each ecosystem needs to find in the directory Dependabot is pointed at.
DEPENDABOT_MANIFESTS = {
    'github-actions': '.github/workflows',
    'pip': 'requirements.txt',
    'npm': 'package.json',
    'swift': 'Package.swift',
    'docker': 'Dockerfile',
}


def dependabot_entries():
    """`(ecosystem, directory)` pairs from dependabot.yml, parsed without a YAML dependency.

    Split on the list marker rather than matching a fixed two-line shape: entries may carry
    comments between `package-ecosystem` and `directory`, and a regex anchored to adjacency
    would silently drop exactly the entry that needs the explanation.
    """
    text = (ROOT / '.github/dependabot.yml').read_text()
    entries = []
    for chunk in text.split('- package-ecosystem:')[1:]:
        ecosystem = chunk.split('\n', 1)[0].strip()
        directory = re.search(r'^\s+directory:\s*(\S+)\s*$', chunk, re.MULTILINE)
        if directory:
            entries.append((ecosystem, directory.group(1)))
    return entries


def dependabot_root(directory):
    """Resolve a Dependabot directory against the repository root.

    Directories are root-absolute in the config, so `/` must become the repository root and not
    the filesystem root — `Path('.') / '/'` discards the left-hand side entirely.
    """
    return ROOT / directory.lstrip('/')


class WorkflowPolicyTests(unittest.TestCase):
    def test_python_module_entry_points_are_importable_names(self):
        """"python -m pip-audit" fails with "No module named pip-audit".

        `-m` takes an importable module name, so a hyphenated tool has to be
        invoked as `python -m pip_audit` or as its console script. The failure
        reads like a missing dependency, which sends you after the wrong fix;
        this step failed red for exactly that reason on every run that audited.
        """
        offenders = []
        for workflow in sorted((ROOT / '.github/workflows').glob('*.yml')):
            for number, line in enumerate(workflow.read_text().splitlines(), start=1):
                if line.lstrip().startswith('#'):
                    continue
                match = re.search(r'python3? -m ([A-Za-z0-9_.]+-[A-Za-z0-9_.-]+)', line)
                if match:
                    offenders.append(f'{workflow.name}:{number}: python -m {match.group(1)}')
        self.assertEqual(offenders, [], 'hyphenated module name passed to python -m')

    def test_swiftpm_cache_keys_are_isolated_from_pre_move_checkouts(self):
        """A cache keyed only on the lockfiles can restore a pre-move tree.

        `Package.resolved` pins remote sources only, so relocating the local
        packages leaves it byte-identical. A restored cache from before the move
        then satisfies the key while pointing DerivedData/SourcePackages at
        directories that no longer exist, and the build fails with "Unable to
        find module dependency" instead of resolving cleanly. Every SwiftPM cache
        therefore names its checkout layout with a version prefix, and its
        restore-keys fallbacks stay inside that prefix.
        """
        layout = r'^spm-(?:platform-|release-|combined-)?v\d+-'
        seen = 0
        for workflow in sorted((ROOT / '.github/workflows').glob('*.yml')):
            text = workflow.read_text()
            for key in re.findall(r'^\s*key: (spm-\S+)', text, re.M):
                seen += 1
                self.assertRegex(key, layout,
                                 f'{workflow.name}: SwiftPM cache key has no layout version')
            for fallback in re.findall(r'^\s+(spm-\S*\$\{\{ runner\.os \}\}-\S*)$', text, re.M):
                self.assertRegex(fallback, layout,
                                 f'{workflow.name}: restore-key crosses layout versions')
        self.assertGreater(seen, 5, 'the SwiftPM cache keys were not found')

    def test_ci_scope_keeps_native_sources_and_unknown_paths(self):
        native = runpy.run_path(str(ROOT / "Tools/Validation/repository-validation/ci-scope.py"))['needs_native']
        self.assertFalse(native(['Tools/Release/test_release_assets.py', 'Tools/Release/generate-changelog.sh', 'README.md']))
        for path in ('VexSign/App/App.swift', 'Tests/Test.swift', 'Packages/NativeSigning/Tests/Test.swift',
                     'Makefile', 'Packages/SideSign/Package.swift', 'Packages/Vendor/source.cpp', '.github/workflows/ci.yml',
                     '.github/workflows/ci-repair-assistant.yml', 'Tools/Scripts/bootstrap.sh', 'unknown-file'):
            self.assertTrue(native([path]), path)
        # A removed app source must still count when renamed into Markdown.
        self.assertTrue(native(['VexSign/App/Old.swift', 'README.md']))

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
                subprocess.run(['python3', str(ROOT / "Tools/Validation/repository-validation/ci-scope.py")], cwd=root,
                               env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request',
                                    'GITHUB_EVENT_PATH': str(event), 'GITHUB_OUTPUT': str(output)},
                               check=True, capture_output=True)
                self.assertEqual(output.read_text(), f'native={expected}\n')

    def test_consolidated_triage_retains_permissions_and_prevents_recursion(self):
        text = (ROOT / ".github/workflows/repo-maintenance.yml").read_text()
        triage = block(block(text, 'jobs', 0), 'open-or-update-issue', 2)
        self.assertIn('actions: read', triage)
        self.assertIn('issues: write', triage)
        self.assertNotIn('actions/checkout', triage)
        self.assertIn("github.event.workflow_run.event != 'workflow_run'", triage)
        self.assertIn('head_repository.full_name == github.repository', triage)
        self.assertFalse((WORKFLOWS / "ci-triage.yml").exists())
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        for name in ('build', 'tests'):
            self.assertIn("needs.quick.outputs.native == 'true'", block(ci, name, 2))
        self.assertIn('-parallel-testing-worker-count 2', ci)
        combined = (ROOT / ".github/workflows/embedded-container.yml").read_text()
        self.assertIn('Restore Swift package downloads', combined)
        self.assertIn('runner.arch', combined)
        self.assertIn('TMPDIR: ${{ runner.temp }}/', combined)

    def test_make_package_caches_follow_runner_local_derived_data(self):
        # Source-directory flattening must not relocate the product/DerivedData
        # directory: make derives it from TMPDIR and the unchanged product name.
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn('NAME := VexSign', makefile)
        self.assertIn('TMP := $(if $(TMPDIR),$(TMPDIR),/tmp)/$(NAME)', makefile)
        for name in ('release.yml', 'embedded-container.yml'):
            with self.subTest(workflow=name):
                workflow = (WORKFLOWS / name).read_text()
                self.assertIn('${{ runner.temp }}/VexSign/SourcePackages', workflow)
                self.assertIn('TMPDIR: ${{ runner.temp }}/', workflow)
                self.assertNotIn('${{ runner.temp }}/VexSign/App/', workflow)

    def test_combined_native_input_uses_an_isolated_swiftpm_artifact_cache(self):
        combined = (ROOT / ".github/workflows/embedded-container.yml").read_text()
        native_input = combined.split('      - name: Build standalone VexSign native input', 1)[1]
        native_input = native_input.split('      - name: Report standalone build diagnostics', 1)[0]
        self.assertIn('SPM_CACHE_PATH: ${{ runner.temp }}/SwiftPMCache-NativeInput', native_input)
        self.assertIn('make VexSign', native_input)
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn('$(if $(SPM_CACHE_PATH),-packageCachePath "$(SPM_CACHE_PATH)",)', makefile)

    def test_combined_build_exposes_failures_and_preserves_native_input(self):
        text = (ROOT / ".github/workflows/embedded-container.yml").read_text()
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
        parser = runpy.run_path(str(ROOT / ".github/scripts/xcodebuild_report.py"))['DIAG_RE']
        for location, column in [('12:7:', '7'), ('12:', None)]:
            match = parser.match(f'/tmp/Fixture.swift:{location} error: Fixture.testCase : assertion failed')
            self.assertIsNotNone(match)
            self.assertEqual(match['line'], '12')
            self.assertEqual(match['col'], column)
            self.assertIn('assertion failed', match['msg'])

    def test_startup_crash_stack_reads_multiline_ips_after_apple_metadata(self):
        import json
        reporter = runpy.run_path(str(ROOT / '.github/scripts/surface_test_failures.py'))
        payload = {'faultingThread': 0, 'threads': [{'triggered': True, 'frames': [
            {'symbol': '_assertionFailure'}, {'symbol': 'EnvironmentObject.error()'},
            {'symbol': 'InstallQueuePill.body.getter'},
        ]}]}
        with tempfile.TemporaryDirectory() as folder:
            report = Path(folder) / 'VexSign.ips'
            report.write_text(json.dumps({'app_name': 'VexSign', 'bug_type': '309'}) + '\n' +
                              json.dumps(payload, indent=2) + '\n')
            self.assertEqual(reporter['crash_payload'](report.read_text()), payload)
            self.assertEqual(reporter['crash_stack'](folder),
                '_assertionFailure <- EnvironmentObject.error() <- InstallQueuePill.body.getter')
            payload['faultingThread'] = -1
            payload['threads'].append({'frames': [{'symbol': 'unrelated thread'}]})
            report.write_text(json.dumps(payload))
            self.assertIn('InstallQueuePill.body.getter', reporter['crash_stack'](folder))

    def test_startup_crash_stack_reads_plain_text_and_ignores_malformed_exports(self):
        reporter = runpy.run_path(str(ROOT / '.github/scripts/surface_test_failures.py'))
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'A-malformed.ips').write_text('{bad json\n}')
            (Path(folder) / 'VexSign.crash').write_text(
                'Process: VexSign\n\nThread 0 Crashed:\n'
                '0   libswiftCore.dylib    0x00000001 _assertionFailure + 100\n'
                '1   SwiftUI              0x00000002 EnvironmentObject.error() + 48\n\n'
                'Thread 1:\n0   libdispatch.dylib    0x00000003 unrelated\n')
            self.assertEqual(reporter['crash_payload']('{bad json'), {})
            self.assertEqual(reporter['crash_stack'](folder),
                '_assertionFailure + 100 <- EnvironmentObject.error() + 48')

    def test_annotations_include_details_after_the_first_five_failed_tests(self):
        import json
        reporter = runpy.run_path(str(ROOT / '.github/scripts/surface_test_failures.py'))
        with tempfile.TemporaryDirectory() as folder:
            summary = Path(folder) / 'summary.json'
            summary.write_text(json.dumps({'result': 'Failed', 'testFailures': [
                {'testName': f'testCase{index}()', 'failureText': f'precise failure {index}',
                 'sourceCodeContext': {'location': {'filePath': '/tmp/Fixture.swift', 'lineNumber': index}}}
                for index in range(14)]}))
            lines = reporter['summary_lines'](str(summary), str(Path(folder) / 'absent.json'))
            details = [line for line in lines if line.startswith('DETAILS ')]
            self.assertTrue(any('testCase13() @ Fixture.swift:13 — precise failure 13' in line for line in details))
            self.assertTrue(all(len(line) <= 830 for line in details))
            self.assertLess(len(details), 5)

    def test_startup_fatal_environment_message_survives_test_failure_chatter(self):
        reporter = runpy.run_path(str(ROOT / '.github/scripts/surface_test_failures.py'))
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'test.log'
            log.write_text('SwiftUI/EnvironmentObject.swift: Fatal error: No ObservableObject of type InstallationQueueModel found.\n' +
                           'Simulator logging chatter\n' * 100 + '** TEST FAILED **\nTesting started\n')
            contexts = reporter['log_context'](str(log))
            self.assertTrue(any('No ObservableObject of type InstallationQueueModel' in line for line in contexts))
            self.assertTrue(all(len(line) <= 400 for line in contexts))

    def _warning_gate(self, paths, baseline):
        import json
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            log, known = root / 'build.log', root / 'known.json'
            log.write_text(''.join(f'{ROOT / path}:12:3: warning: Fixture compiler warning\n' for path in paths))
            known.write_text(json.dumps({'warnings': baseline}))
            return subprocess.run([
                sys.executable, str(ROOT / '.github/scripts/xcodebuild_report.py'),
                '--log', str(log), '--build-exit', '0', '--warnings-as-errors', 'true',
                '--baseline', str(known), '--baseline-out', str(root / 'observed.json'),
                '--summary', str(root / 'summary.md'), '--workspace', str(ROOT),
            ], text=True, capture_output=True)

    def test_migrated_warning_roots_keep_first_party_and_vendor_boundaries(self):
        reporter = runpy.run_path(str(ROOT / '.github/scripts/xcodebuild_report.py'))
        is_owned, roots = reporter['is_first_party'], reporter['DEFAULT_FIRST_PARTY']
        for path in ['VexSign/App/File.swift', 'Tests/Test.swift',
                     'Packages/NimbleKit/Sources/File.swift', 'Packages/AltSourceKit/File.swift',
                     'Services/Integrations/File.swift']:
            self.assertTrue(is_owned(path, roots), path)
        for path in [None, 'Packages/Vendor/Dependency/File.swift', 'Packages/Vendor/Dependency/File.swift',
                     'VexSign/.build/File.swift', 'VexSign/SourcePackages/checkouts/Dependency/File.swift',
                     'Services/Cloud/node_modules/Dependency/File.swift', 'Elsewhere/File.swift']:
            self.assertFalse(is_owned(path, roots), path)

    def test_migrated_unbaselined_warning_cannot_silently_bypass_the_gate(self):
        path = 'VexSign/App/Infrastructure/File.swift'
        result = self._warning_gate([path], [])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(path, result.stdout)
        self.assertIn('Fixture compiler warning', result.stdout)

    def test_migrated_warning_baselines_and_vendor_exclusions_are_not_relaxed(self):
        path = 'VexSign/App/Infrastructure/File.swift'
        known = {'file': path, 'message': 'Fixture compiler warning', 'count': 1}
        result = self._warning_gate([path, 'Packages/Vendor/Dependency/File.swift'], [known])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # A historical path cannot accidentally whitelist a newly relocated warning.
        known['file'] = 'VexSign/App/iOS/VexSign/Infrastructure/File.swift'
        result = self._warning_gate([path], [known])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_unlocated_linker_failure_survives_a_long_resource_log_tail(self):
        reporter = runpy.run_path(str(ROOT / '.github/scripts/xcodebuild_report.py'))
        lines = ["Ld fixture.debug.dylib", "ld: archive member 'debian-binary' not a mach-o file in 'ellekit.deb'"]
        lines.extend(["CopyStringsFile " + "resource" * 90] * 90)
        contexts = reporter['failure_log_contexts'](lines)
        self.assertTrue(any("archive member 'debian-binary'" in context for context in contexts))
        self.assertTrue(all(len(context) < 2800 for context in contexts))

    def test_unparsed_failure_keeps_final_api_annotation_bounded_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            log = root / 'build.log'
            log.write_text(('CopyStringsFile ' + 'resource' * 90 + '\n') * 90 + 'opaque final tool detail\n')
            observed = root / 'observed.json'
            result = subprocess.run([
                sys.executable, str(ROOT / '.github/scripts/xcodebuild_report.py'),
                '--log', str(log), '--build-exit', '65', '--warnings-as-errors', 'true',
                '--baseline-out', str(observed), '--workspace', str(ROOT),
            ], env={key: value for key, value in os.environ.items() if key not in ('GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY')},
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            annotations = [line for line in result.stdout.splitlines() if line.startswith('::error')]
            self.assertEqual(len(annotations), 1)
            self.assertIn('opaque final tool detail', annotations[0])
            self.assertLess(len(annotations[0]), 3000)
            self.assertFalse(observed.exists(), 'Failed builds must not offer a smaller warning baseline')

    def test_native_pipeline_captures_failure_status_under_the_actions_errexit_shell(self):
        workflow = (WORKFLOWS / 'ci.yml').read_text()
        for job, step in [('build', 'Build (Debug)'), ('tests', 'Run tests')]:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as folder:
                source = block(workflow, job, 2)
                source = source.split('      - name: ' + step + '\n', 1)[1].split('      - name:', 1)[0]
                script = '\n'.join(line[10:] for line in block(source, 'run', 8).splitlines()[1:])
                self.assertNotIn('-continueBuildingAfterErrors', script)
                # Exercise the actual prologue and verdict-handling suffix with
                # a portable failed compiler stand-in, under GitHub's shell flags.
                prefix = script.split('\nxcodebuild ', 1)[0] + '\n'
                suffix = script[script.index('status=${PIPESTATUS[0]}'):]
                output = Path(folder) / 'outputs'
                result = subprocess.run(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c',
                    prefix + 'bash -c "exit 65" | cat\n' + suffix],
                    env={**os.environ, 'GITHUB_OUTPUT': str(output)}, text=True, capture_output=True)
                self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
                self.assertEqual(output.read_text(), 'exit_code=65\n')
                self.assertIn('status 65', result.stdout)

    def test_platform_build_uses_job_owned_package_and_temporary_paths(self):
        text = (ROOT / ".github/workflows/platform-check.yml").read_text()
        self.assertIn('TMPDIR: ${{ runner.temp }}/', text)
        self.assertIn('-packageCachePath "${RUNNER_TEMP}/SwiftPMCache-${{ matrix.scheme }}"', text)
        self.assertIn('prefetch_spm_artifacts.py', text)
        self.assertEqual(text.count("      - '.github/scripts/prefetch_spm_artifacts.py'"), 2)
        self.assertIn('--cache "${RUNNER_TEMP}/SwiftPMCache-${{ matrix.scheme }}/artifacts"', text)
        self.assertNotIn('continue-on-error:', text)

    def test_binary_prefetch_checksums_deduplication_and_failure_cleanup(self):
        import hashlib
        prefetch = runpy.run_path(str(ROOT / ".github/scripts/prefetch_spm_artifacts.py"))
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
        prefetch = runpy.run_path(str(ROOT / ".github/scripts/prefetch_spm_artifacts.py"))
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
                sys.executable, str(ROOT / ".github/scripts/prefetch_spm_artifacts.py"),
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
                sys.executable, str(ROOT / ".github/scripts/xcodebuild_report.py"),
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
                self.assertIn("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}", text)
                self.assertFalse(covers(name, 'README.md'))
                self.assertFalse(covers(name, 'CHANGELOG.md'))

    def test_a_main_push_never_cancels_the_previous_main_run(self):
        """A merged commit is already on main; cancelling its run leaves it unvalidated.

        `cancel-in-progress: true` with a group keyed only on `github.ref` replaced the running
        main build on every merge. Runs 370-386 on main were all cancelled that way, so the
        branch a release is cut from had no completed CI at all — the failure mode is invisible
        in the workflow file and only shows up in the run list. Superseding is right for a pull
        request, where the newest commit is the one under review, and wrong for main.
        """
        for name in MAIN_VALIDATORS:
            with self.subTest(workflow=name):
                section = block((WORKFLOWS / name).read_text(), 'concurrency', 0)
                self.assertIn("github.event_name == 'push' && github.sha", section,
                              'a main-push group must be keyed per commit so merges queue up')
                self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
                              section)

    def test_app_dependencies_and_vendored_package_changes_are_covered(self):
        for path in ('VexSign/App/VexSignApp.swift', 'Tests/UnitTests/Application/DesignSystemTests.swift',
                     'Packages/NimbleKit/Package.swift', 'Packages/AltSourceKit/Package.swift',
                     'VexSign.xcodeproj/project.pbxproj', 'Packages/Vendor/Zsign/Package.swift',
                     'Packages/Vendor/IDeviceKitten/Package.swift',
                     'Makefile', 'Tools/Validation/repository-validation/test_workflow_policy.py', '.github/workflows/ci-repair-assistant.yml'):
            with self.subTest(path=path):
                self.assertTrue(covers('ci.yml', path))
        self.assertFalse(covers('ci.yml', 'Services/WebManager/API/main.py'))
        self.assertFalse(covers('ci.yml', 'Services/Cloud/API/main.ts'))

    def test_component_checks_do_not_follow_unrelated_changes(self):
        self.assertTrue(covers('services.yml', 'Services/WebManager/API/main.py'))
        self.assertFalse(covers('services.yml', 'VexSign/App/VexSignApp.swift'))
        self.assertTrue(covers('services.yml', 'Services/Cloud/API/main.ts'))
        self.assertFalse(covers('services.yml', 'VexSign/Services/Identity/CertificateInspector.swift'))
        self.assertTrue(covers('platform-check.yml', 'VexSign/Services/Installation/Transport/CompanionStatus.swift'))
        self.assertTrue(covers('platform-check.yml', 'Platform/Watch/VexSignWatch/VexSignWatchApp.swift'))

    def test_native_smoke_runs_fixture_tests_without_publishing(self):
        # Folded into the combined-host workflow as a dispatch-only job so the
        # manual diagnostics share one entry point and one set of gates.
        text = (ROOT / ".github/workflows/embedded-container.yml").read_text()
        self.assertIn('      link_smoke:', text)
        self.assertIn('      unit_tests:', text)
        self.assertIn('if: inputs.unit_tests', text)
        self.assertIn('inputs.link_smoke == true', text)
        self.assertIn('swift test --package-path .build/native-signing-smoke', text)
        self.assertIn('native-signing-unit-tests.log', text)
        self.assertIn('retention-days: 3', text)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('gh release create', text)

    def test_simulator_keychain_tests_use_only_local_ad_hoc_signing(self):
        ci = (WORKFLOWS / 'ci.yml').read_text()
        tests = block(ci, 'tests', 2)
        makefile = (ROOT / 'Makefile').read_text()
        local = makefile.split('\ntest:\n', 1)[1].split('\n# Use an activated virtualenv', 1)[0]
        for source in [tests, local]:
            for setting in ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES',
                            'CODE_SIGN_IDENTITY="-"', 'AD_HOC_CODE_SIGNING_ALLOWED=YES']:
                self.assertIn(setting, source)
            self.assertNotIn('CODE_SIGNING_ALLOWED=NO', source)
            self.assertNotIn('CODE_SIGN_ENTITLEMENTS=', source, 'Do not replace the protected production entitlement file')
            self.assertNotIn('-allowProvisioningUpdates', source)
        self.assertIn('platform=iOS Simulator,id=${SIM_UDID}', tests)
        self.assertIn('platform=iOS Simulator,id=$$dest', local)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', block(ci, 'build', 2))
        self.assertIn('CODE_SIGNING_ALLOWED=NO', makefile.split('$(SCHEMES):', 1)[1].split('\n# Self-hosted', 1)[0])

    def test_manual_quick_mode_and_parallel_macos_jobs(self):
        text = (ROOT / ".github/workflows/ci.yml").read_text()
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
        ui_tests = block(text, 'ui-tests', 2)
        self.assertIn('needs: quick', ui_tests)
        self.assertIn("inputs.validation != 'quick'", ui_tests)
        self.assertIn('-parallel-testing-enabled NO', ui_tests)
        self.assertNotIn('needs: build', ui_tests)
        self.assertIn('Tools/Validation/repository-validation/test_workflow_policy.py', block(text, 'quick', 2))

    def test_identity_is_neither_downloaded_nor_bundled(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        makefile = (ROOT / "Makefile").read_text()
        self.assertNotIn('CERT_PACK_URL', release)
        self.assertNotIn('RELEASE_TLS_SHA256', release)
        self.assertNotIn('make deps', release)
        self.assertNotIn('cp deps/', makefile)
        self.assertNotIn('deps-release:', makefile)
        self.assertFalse((WORKFLOWS / "pin-release-tls.yml").exists())
        # Utility services are split by concern; the TLS rule applies to all of them.
        services = '\n'.join(p.read_text() for p in sorted((ROOT / "VexSign/App/Infrastructure").rglob('*.swift')))
        self.assertNotIn('downloadSSLCertificates', services)
        resolver = (ROOT / "VexSign/Services/Installation/Installation/TLS/ServerInstaller+TLS.swift").read_text()
        self.assertNotIn('Bundle.main', resolver)
        self.assertIn('DeviceTLSIdentity.directory', resolver)

    def test_release_build_is_read_only_and_publisher_does_not_checkout(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
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

    def test_publisher_attests_the_bytes_it_publishes(self):
        """SHA256SUMS ships beside the artifacts, so it cannot vouch for who built them."""
        publish = block((ROOT / ".github/workflows/release.yml").read_text(), 'publish', 2)
        self.assertIn('actions/attest-build-provenance@', publish)
        self.assertIn('id-token: write', publish)
        self.assertIn('attestations: write', publish)
        self.assertIn('subject-path:', publish)
        self.assertIn('upload/*.ipa', publish)
        # The attestation has to cover what was verified, not a re-downloaded copy.
        self.assertLess(publish.index('sha256sum --check SHA256SUMS'),
                        publish.index('actions/attest-build-provenance@'))
        for name in ('release.yml',):
            for use in re.findall(r'uses: ([^\s]+)', (WORKFLOWS / name).read_text()):
                self.assertRegex(use, r'@[a-f0-9]{40}$')

    def test_quick_container_checks_do_not_require_make(self):
        quick = block((ROOT / ".github/workflows/ci.yml").read_text(), 'quick', 2)
        self.assertNotRegex(quick, r'(?m)^\s+(?:run: )?make ')
        self.assertIn('Tools/Validation/repository-validation/check-docs.py', quick)
        self.assertIn('Tools/Validation/repository-validation/test_docs.py', quick)

    def test_listing_bot_uses_a_review_branch(self):
        text = (ROOT / ".github/workflows/update_repo.yml").read_text()
        self.assertIn('pull-requests: write', text)
        self.assertIn('BRANCH="automation/release-listing"', text)
        self.assertIn('gh pr create --base "$DEFAULT_BRANCH"', text)
        self.assertNotIn('git symbolic-ref --short HEAD', text)

    def test_release_visuals_metadata_and_notes_are_bundled(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn('Tools/Release/prepare-release-assets.py', text)
        for asset in ('CHANGELOG.md', 'RELEASE.json', 'VexSign-icon.png', 'Home-layout-preview.svg'):
            self.assertIn('upload/' + asset, block(text, 'build', 2))
            self.assertIn('upload/' + asset, block(text, 'publish', 2))

    def test_release_versions_are_numeric_and_packaged_bundles_are_checked(self):
        import plistlib
        import tempfile
        import zipfile
        module = runpy.run_path(str(ROOT / "Tools/Release/release-build-version.py"))
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
                    root_info = {
                        'CFBundleVersion': root,
                        'CFBundleShortVersionString': '1.2.1',
                        'CFBundleIdentifier': 'com.vexsign.app',
                        'MinimumOSVersion': '17.0',
                    }
                    extension_info = {
                        'CFBundleVersion': extension,
                        'CFBundleIdentifier': 'com.vexsign.app.test',
                    }
                    archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps(root_info))
                    archive.writestr('Payload/Test.app/PlugIns/Test.appex/Info.plist', plistlib.dumps(extension_info))
                if valid:
                    module['verify_ipa'](path, '1.0.1', expected_marketing_version='1.2.1')
                else:
                    with self.assertRaises(ValueError):
                        module['verify_ipa'](path, '1.0.1')
            with zipfile.ZipFile(path, 'w'):
                pass
            with self.assertRaises(ValueError):
                module['verify_ipa'](path, '1.0.1')
        text = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn('agvtool new-version -all "${BUILD_NUMBER}"', text)
        self.assertNotIn('BUILD_NUMBER="$(git rev-parse HEAD)"', text)
        self.assertNotIn('continuing with the committed CURRENT_PROJECT_VERSION', text)
        self.assertIn('--verify-ipa "$ipa"', text)
        upload = text.split('      - name: Upload IPA artifact\n', 1)[1].split('      - name:', 1)[0]
        self.assertIn('retention-days: 14', upload)
        diagnostics = text.split('retention-days: 14', 1)[1]
        self.assertIn('retention-days: 3', diagnostics)

    def test_release_ipa_checks_bundle_ids_marketing_version_and_minimum_os(self):
        import plistlib
        import tempfile
        import zipfile
        module = runpy.run_path(str(ROOT / "Tools/Release/release-build-version.py"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.ipa'
            def write_ipa(root_identifier='com.vexsign.app', extension_identifier='com.vexsign.app.test',
                          version='1.2.1', minimum_os='17.0'):
                with zipfile.ZipFile(path, 'w') as archive:
                    root = {
                        'CFBundleVersion': '1.0.1',
                        'CFBundleShortVersionString': version,
                        'CFBundleIdentifier': root_identifier,
                        'MinimumOSVersion': minimum_os,
                    }
                    extension = {
                        'CFBundleVersion': '1.0.1',
                        'CFBundleIdentifier': extension_identifier,
                    }
                    archive.writestr('Payload/VexSign.app/Info.plist', plistlib.dumps(root))
                    archive.writestr('Payload/VexSign.app/PlugIns/Test.appex/Info.plist', plistlib.dumps(extension))

            write_ipa()
            module['verify_ipa'](path, '1.0.1', expected_marketing_version='1.2.1')
            for overrides in (
                {'root_identifier': 'com.example.other'},
                {'extension_identifier': 'com.other.extension'},
                {'version': '1.2.0'},
                {'minimum_os': '16.0'},
            ):
                write_ipa(**overrides)
                with self.assertRaises(ValueError):
                    module['verify_ipa'](path, '1.0.1', expected_marketing_version='1.2.1')

    def test_published_ipa_bytes_are_crc_checked_and_duplicates_rejected(self):
        import plistlib
        import warnings
        import zipfile
        module = runpy.run_path(str(ROOT / "Tools/Release/release-build-version.py"))
        check = module['check_container']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.ipa'
            with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
                archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps({'CFBundleVersion': '1.0.1'}))
                archive.writestr('Payload/Test.app/Test', b'unique-payload-fixture')
            check(path)
            path.write_bytes(path.read_bytes().replace(b'unique-payload-fixture', b'broken-payload-fixture', 1))
            with self.assertRaises(ValueError):
                check(path)
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                with zipfile.ZipFile(path, 'w') as archive:
                    for _ in range(2):
                        archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps({}))
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                check(path)
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn('--check-container VexSign-unsigned.ipa', ci)
        self.assertLess(ci.index('--check-container VexSign-unsigned.ipa'), ci.index('      - name: Upload unsigned test IPA'))

    def test_every_release_runs_simulator_tests(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
        step = text.split('      - name: Release simulator tests\n', 1)[1].split('      - name:', 1)[0]
        self.assertIn('run: make test', step)
        self.assertNotIn('if:', step)

    def test_nightly_release_is_scheduled_and_immutable(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
        events = block(text, 'on', 0)
        self.assertIn('  schedule:', events)
        self.assertIn("cron: '0 3 * * *'", events)
        self.assertIn('MODE="nightly"', text)
        self.assertIn('nightly.${NIGHTLY_DATE}.${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}', text)
        self.assertIn('channel=${CHANNEL}', text)
        self.assertIn('prerelease: ${{ needs.build.outputs.prerelease ==', text)

    def test_nightly_does_not_update_the_stable_listing(self):
        update = (ROOT / ".github/workflows/update_repo.yml").read_text()
        self.assertIn("github.event.release.prerelease == false", update)
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("needs.build.outputs.channel == 'stable'", release)

    def test_automation_workflows_do_not_validate_pull_requests(self):
        # Dependabot and maintenance work through branches/issues; a PR-triggered
        # workflow must not execute privileged maintenance code from PRs.
        self.assertTrue((ROOT / ".github/dependabot.yml").is_file())
        for name in ('repo-maintenance.yml',):
            events = block((WORKFLOWS / name).read_text(), 'on', 0)
            self.assertNotIn('pull_request', events)

    #: Runners whose minutes are billed at a premium on a private repository.
    PAID_RUNNERS = ('macos-15',)
    #: A trusted private repository may accept those minutes explicitly. Publishing
    #: workflows stay public-only regardless of this variable.
    PRIVATE_MACOS_OPT_IN = "vars.VEXSIGN_PRIVATE_MACOS_VALIDATION == 'true'"
    #: Workflows that *act on* the repository — publishing releases, pushing commits,
    #: filing issues — rather than validating it. They stay tied to the canonical public
    #: repository: a private fork must not publish releases or open maintenance issues.
    PUBLISHING_WORKFLOWS = frozenset({
        'release.yml', 'repo-maintenance.yml', 'ci-repair-assistant.yml', 'update_repo.yml',
    })

    def test_free_only_workflow_policy(self):
        """Paid runner minutes stay behind the visibility gate; free validation does not.

        The gate exists to keep Actions free (macOS minutes are billed), and it used to
        cover every job in every workflow. That made a private repository — or a private
        fork, or a temporary visibility change during a security scare — skip *all*
        validation with a green check and no annotation. Ubuntu validation jobs now run
        regardless; the premium runner jobs and the workflows that write to the repository
        keep the gate, so the cost policy is unchanged where it actually costs.
        """
        validated_gate_free = []
        for path in sorted(WORKFLOWS.glob('*.yml')):
            text = path.read_text()
            jobs = block(text, 'jobs', 0)
            for job in re.findall(r'^  ([A-Za-z0-9_-]+):$', jobs, re.MULTILINE):
                job_block = block(jobs, job, 2)
                gated = 'github.event.repository.private == false' in job_block
                paid = any(f'runs-on: {runner}' in job_block for runner in self.PAID_RUNNERS)
                must_gate = paid or path.name in self.PUBLISHING_WORKFLOWS
                if must_gate:
                    self.assertTrue(
                        gated,
                        f'{path.name}:{job} spends paid runner minutes or writes to the '
                        'repository, so it needs the public-visibility gate',
                    )
                    self.assertIn("github.event.repository.visibility == 'public'", job_block)
                else:
                    self.assertFalse(
                        gated,
                        f'{path.name}:{job} is free validation: gating it means a private '
                        'repository skips every check and still reports success',
                    )
                    self.assertNotIn("github.event.repository.visibility == 'public'", job_block)
                    validated_gate_free.append(f'{path.name}:{job}')
            self.assertNotIn('models: read', text)
            for runner in re.findall(r'runs-on: (.+)', text):
                # The only self-hosted label set is the explicitly opt-in physical-device
                # runner; it is checked separately by test_physical_device_job_is_opt_in.
                if runner == '[self-hosted, macos, arm64, ios-device]':
                    continue
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
            if path.name == 'ci.yml':
                # The coverage JSON is a trend, not a failure log: it is the only artifact
                # allowed past three days, and only for that reason.
                match = re.search(r'(?ms)^      - name: Upload coverage report\n.*?retention-days: (\d+)', retention_text)
                self.assertIsNotNone(match)
                self.assertEqual(match[1], '30')
                retention_text = retention_text[:match.start()] + retention_text[match.end():]
            for retention in re.findall(r'retention-days: (\d+)', retention_text):
                self.assertLessEqual(int(retention), 3)
        # Something must actually run for a private repository, or the policy above is
        # satisfied by a tree where every job is gated.
        for expected in ('ci.yml:quick', 'docs.yml:links', 'services.yml:pytest'):
            self.assertIn(expected, validated_gate_free, expected)
        for removed in ('autopilot.yml', 'auto-stable.yml', 'dependency-audit.yml',
                        'server-tests.yml', 'ecosystem.yml'):
            self.assertFalse((WORKFLOWS / removed).exists())

    def test_private_macos_validation_is_an_explicit_opt_in(self):
        """Paid validation jobs may run on a private repo only when the owner opts in.

        The default stays public-only, so a private mirror cannot spend runner minutes by
        accident. A maintainer who needs native evidence can set the repository variable
        and make the job report a real check instead of a skip notice.
        """
        for name in (
            'ci.yml', 'device-bridge.yml', 'embedded-container.yml',
            'platform-check.yml', 'services.yml',
        ):
            text = (WORKFLOWS / name).read_text()
            jobs = block(text, 'jobs', 0)
            for job in re.findall(r'^  ([A-Za-z0-9_-]+):$', jobs, re.MULTILINE):
                job_block = block(jobs, job, 2)
                if 'runs-on: macos-15' in job_block:
                    self.assertIn(self.PRIVATE_MACOS_OPT_IN, job_block, f'{name}:{job}')
        # Publishing stays tied to the canonical public repository.
        for name in sorted(self.PUBLISHING_WORKFLOWS):
            path = WORKFLOWS / (name + '.yml')
            if not path.exists():
                continue
            jobs = block(path.read_text(), 'jobs', 0)
            for job in re.findall(r'^  ([A-Za-z0-9_-]+):$', jobs, re.MULTILINE):
                job_block = block(jobs, job, 2)
                if 'runs-on: macos-15' in job_block:
                    self.assertNotIn(self.PRIVATE_MACOS_OPT_IN, job_block, f'{name}:{job}')

    def test_ci_native_jobs_are_complete_and_honest(self):
        text = (WORKFLOWS / 'ci.yml').read_text()
        jobs = block(text, 'jobs', 0)
        build = block(jobs, 'build', 2)
        tests = block(jobs, 'tests', 2)
        ui_tests = block(jobs, 'ui-tests', 2)
        self.assertIn('- name: Build (Debug)', build)
        self.assertIn('- name: Build (Release)', build)
        self.assertIn('- name: Static analyzer', build)
        self.assertIn('- name: Quality report', tests)
        self.assertIn('Tools/Audit/quality-report.py', tests)
        self.assertIn('xcresulttool get test-results tests', tests)
        self.assertIn('- name: Upload quality report', tests)
        self.assertIn('-scheme VexSignUITests', ui_tests)
        self.assertNotIn('-scheme VexSignTests', ui_tests)
        self.assertIn('-parallel-testing-enabled NO', ui_tests)
        self.assertIn('Tools/Audit/quality-report.py', ui_tests)
        self.assertIn('- name: Upload UI xcresult, screenshots and report', ui_tests)
        self.assertIn('if: always() && steps.test.outcome != \'skipped\'', ui_tests)
        # A simulator screenshot bundle is UI evidence, not device evidence.
        self.assertNotIn('feature-acceptance.py', ui_tests)

    def test_release_requires_the_ci_quality_gate(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        self.assertIn('Verify CI quality gate for this commit', text)
        self.assertIn('Tools/Release/verify_ci_gate.py', text)
        self.assertIn('REQUIRE_DEVICE: ${{ steps.mode.outputs.publish }}', text)
        # Publishing without this check would make a skipped device job look accepted.
        self.assertIn('--require-device', text)

    def test_physical_device_job_is_opt_in_and_never_a_pull_request(self):
        """Real-iPhone jobs use a self-hosted runner and explicit operator configuration."""
        text = (WORKFLOWS / 'ci.yml').read_text()
        jobs = block(text, 'jobs', 0)
        device = block(jobs, 'device', 2)
        self.assertIn('runs-on: [self-hosted, macos, arm64, ios-device]', device)
        self.assertIn("github.event_name != 'pull_request'", device)
        self.assertIn("vars.VEXSIGN_DEVICE_RUNNER == 'true'", device)
        self.assertIn('inputs.device == true', device)
        self.assertIn('needs: [quick, build, tests, ui-tests]', device)
        self.assertIn('Tools/Audit/run-device-acceptance.py', device)
        self.assertIn('feature-acceptance.py init', device)
        # A simulator result must not be presented as hardware evidence.
        self.assertNotIn('platform=iOS Simulator', device)

    def test_ci_repair_assistant_is_same_repo_scoped_draft_only_and_least_privilege(self):
        text = (ROOT / ".github/workflows/ci-repair-assistant.yml").read_text()
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
        agent = (ROOT / "Tools/Validation/repository-validation/ci_repair_agent.py").read_text()
        self.assertIn('validate_patch', agent)
        self.assertIn('MAX_PATCH_BYTES = 80_000', agent)
        self.assertIn('MAX_PATCH_LINES = 800', agent)
        self.assertIn('automation/bugfix-agent/', agent)
        self.assertIn('--draft', agent)
        self.assertNotIn('gh", "pr", "merge', agent)

    def test_maintenance_jobs_keep_independent_permissions_and_cadence(self):
        text = (ROOT / ".github/workflows/repo-maintenance.yml").read_text()
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
        text = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn('workflows: [CI]', block(text, 'on', 0))
        self.assertIn("github.event_name != 'workflow_run'", block(text, 'build', 2))
        version = block(text, 'version-bump', 2)
        self.assertIn("github.event_name == 'workflow_run'", version)
        self.assertIn('head_repository.full_name == github.repository', version)
        self.assertIn("workflow_run.conclusion == 'success'", version)
        self.assertIn('contents: read', block(version, 'permissions', 4))
        self.assertNotIn('contents: write', block(version, 'permissions', 4))

    def test_ci_offers_disposable_ipa_without_release_permissions(self):
        text = (ROOT / ".github/workflows/ci.yml").read_text()
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
        text = (ROOT / ".github/workflows/embedded-container.yml").read_text()
        events = block(text, 'on', 0)
        self.assertIn('workflow_dispatch:', events)
        self.assertNotIn('schedule:', events)
        self.assertNotIn('pull_request_target:', events)
        self.assertTrue(covers('embedded-container.yml', 'Services/Integrations/build.py'))
        self.assertFalse(covers('embedded-container.yml', 'README.md'))
        self.assertFalse(covers('embedded-container.yml', 'Services/WebManager/API/main.py'))
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

    def test_native_unit_regressions_trigger_for_every_app_source_they_compile(self):
        """A change to app code the native smoke package compiles must run the native tests.

        `Packages/NativeSigning/prepare_smoke.py` copies the app's real Apple-account lifecycle and
        storage sources into the smoke package byte-for-byte, and `swift test` on that package is
        the only place those files are exercised as native-signing input. Three of them live in
        `VexSign/App/Infrastructure/`, which the trigger filters did not list — so a change to
        `AppleAccountSessionCoordinator.swift` ran the app's simulator tests and silently skipped
        the native regressions that compile the same file. The gap is asserted from the
        preparation script, not from a restated file list, so it cannot reopen quietly.
        """
        sources = native_smoke_app_sources()
        self.assertTrue(sources, 'expected prepare_smoke.py to compile app sources into the smoke package')
        for source in sources:
            self.assertTrue((ROOT / source).is_file(), f'{source} is compiled by prepare_smoke.py but missing')
            for trigger in ('push', 'pull_request'):
                with self.subTest(source=source, trigger=trigger):
                    self.assertTrue(
                        covers_trigger('embedded-container.yml', trigger, source),
                        f'{source} is native-test input but no {trigger} filter matches it'
                    )

    def test_native_test_files_are_all_included_in_the_smoke_manifest(self):
        """Every native test on disk must be one the smoke package actually builds."""
        text = (ROOT / "Packages/NativeSigning/prepare_smoke.py").read_text()
        mapped = set(re.findall(r"'Tests/([A-Za-z0-9_]+\.swift)'", text))
        on_disk = {path.name for path in (ROOT / "Packages/NativeSigning/Tests").glob('*.swift')}
        self.assertTrue(on_disk, 'expected native tests on disk')
        # A test that is on disk but not in the manifest is compiled by nothing: it would sit in
        # the repository looking like coverage while never running in any workflow.
        self.assertEqual(sorted(on_disk - mapped), [],
                         'native tests not copied into the smoke package')
        self.assertEqual(sorted(mapped - on_disk), [],
                         'smoke manifest names native tests that do not exist')

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
        text = (ROOT / ".github/workflows/ci.yml").read_text()
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
            payload = app / 'ellekit.deb'
            original_payload = (ROOT / 'VexSign/Resources/ellekit.deb').read_bytes()
            payload.write_bytes(original_payload)
            info = {'DTPlatformName': 'iphoneos', 'CFBundleExecutable': 'VexSign',
                    'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '42'}
            env = {**os.environ, 'PATH': str(bin_path) + os.pathsep + os.environ['PATH'],
                   'DERIVED_DATA': str(derived), 'RUNNER_TEMP': str(root), 'GITHUB_WORKSPACE': str(ROOT),
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
                self.assertEqual(archive.read('Payload/VexSign.app/ellekit.deb'), original_payload)
                self.assertNotIn('BUILD.json', archive.namelist())
            metadata = json.loads((staging / 'BUILD.json').read_text())
            self.assertEqual(metadata['commit'], 'a' * 40)
            self.assertEqual(metadata['version'], '1.2.3')
            self.assertEqual(metadata['run_attempt'], '2')
            self.assertTrue(metadata['unsigned'])
            for line in (staging / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split('  ')
                self.assertEqual(digest, hashlib.sha256((staging / name).read_bytes()).hexdigest())
            for problem in ('simulator', 'missing-executable', 'missing-resource', 'changed-resource'):
                with self.subTest(problem=problem):
                    shutil.rmtree(staging, ignore_errors=True)
                    info['DTPlatformName'] = 'iphoneos'
                    executable.write_bytes(b'fixture only, not an executable')
                    payload.write_bytes(original_payload)
                    if problem == 'simulator': info['DTPlatformName'] = 'iphonesimulator'
                    elif problem == 'missing-executable': executable.unlink()
                    elif problem == 'missing-resource': payload.unlink()
                    else: payload.write_bytes(b'changed payload')
                    rejection = run()
                    self.assertNotEqual(rejection.returncode, 0)
                    self.assertFalse((staging / 'VexSign-unsigned.ipa').exists())
                    if problem in ('missing-resource', 'changed-resource'):
                        self.assertIn('byte-identical resource', rejection.stdout)
                        self.assertFalse(staging.exists())

    def test_release_checks_use_explicit_python_and_shared_xcode_selector(self):
        release = block((ROOT / ".github/workflows/release.yml").read_text(), 'build', 2)
        self.assertRegex(release, r'uses: actions/setup-python@[a-f0-9]{40}')
        self.assertIn("python-version: '3.12'", release)
        self.assertLess(release.index('Set up Python'), release.index('run: make verify'))
        self.assertIn('run: bash .github/scripts/select_xcode.sh', release)


    def test_release_primes_and_shares_verified_binary_cache(self):
        release = block((ROOT / ".github/workflows/release.yml").read_text(), 'build', 2)
        self.assertIn('prefetch_spm_artifacts.py', release)
        self.assertIn('--cache "${RUNNER_TEMP}/SwiftPMCache-Release/artifacts"', release)
        self.assertLess(release.index('prefetch_spm_artifacts.py'), release.index('name: Compile VexSign'))
        self.assertEqual(release.count('SPM_CACHE_PATH: ${{ runner.temp }}/SwiftPMCache-Release'), 2)
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn('SPM_CACHE_PATH ?=', makefile)
        self.assertEqual(makefile.count('$(if $(SPM_CACHE_PATH),-packageCachePath "$(SPM_CACHE_PATH)",)'), 3)
        self.assertNotIn('-disablePackageRepositoryCache', release)

    def test_existing_validation_check_names_are_retained(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn('name: quick · syntax, resources, gates', ci)
        self.assertIn('name: build · VexSign Debug (unsigned)', ci)
        self.assertIn('name: tests · VexSignTests (simulator)', ci)
        services = (ROOT / ".github/workflows/services.yml").read_text()
        self.assertIn('name: pytest · server', block(services, 'pytest', 2))
        self.assertIn('  cloud:', services)  # implicit check name is still cloud
        self.assertIn('name: swift build · anisette mock', block(services, 'anisette', 2))
        self.assertIn('  links:', (ROOT / ".github/workflows/docs.yml").read_text())

    def test_failure_reporting_uses_real_workflow_names_and_serializes_issues(self):
        text = (ROOT / ".github/workflows/repo-maintenance.yml").read_text()
        watched = re.search(r'workflows: \[(.*)\]', text)[1]
        real_names = {re.search(r'^name: (.+)', p.read_text())[1] for p in WORKFLOWS.glob('*.yml')}
        for name in re.findall(r'"([^"]+)"', watched):
            self.assertIn(name, real_names)
        self.assertNotIn('"CI triage"', watched)
        self.assertNotIn('"Repository maintenance"', watched)
        self.assertIn('cancel-in-progress: false', text)
        self.assertIn('WORKFLOW_NAME:', text)

    def test_developer_entry_points_share_the_tools_directory(self):
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn('Tools/Scripts/bootstrap.sh', makefile)
        self.assertIn('Tools/Scripts/device-smoke.sh', makefile)
        self.assertIn('./Tools/Release/update-repo.sh', (ROOT / ".github/workflows/update_repo.yml").read_text())
        for relative in ('Tools/Scripts/bootstrap.sh', 'Tools/Scripts/device-smoke.sh',
                          'Tools/Release/update-repo.sh', 'Tools/Audit/tls-pack-digest.py'):
            self.assertTrue((ROOT / relative).is_file())
        self.assertFalse((ROOT / "tools").exists())
        self.assertFalse((ROOT / "Scripts").exists())
        self.assertFalse((ROOT / "update-repo.sh").exists())
        self.assertTrue((ROOT / "VexSign/Resources/brand/logo.svg").is_file())
        self.assertTrue((ROOT / "icon.png").is_file())  # published feed compatibility

    def test_security_schedule_and_release_boundaries_are_preserved(self):
        events = block((ROOT / ".github/workflows/services.yml").read_text(), 'on', 0)
        self.assertIn('  schedule:', events)
        self.assertIn("cron: '0 6 * * 2'", events)
        release = block((ROOT / ".github/workflows/release.yml").read_text(), 'on', 0)
        self.assertIn('    tags:', block(release, 'push', 2))
        self.assertNotIn('    branches:', block(release, 'push', 2))
        for name in VALIDATORS:
            self.assertIn('  contents: read', (WORKFLOWS / name).read_text())

    def test_dependabot_directories_exist_and_hold_their_manifest(self):
        """A Dependabot entry pointing at a stale path fails silently, so pin the paths here.

        Dependabot reports "no manifests found" for a missing directory and then opens nothing:
        no error, no PR, no signal. Every entry except github-actions stopped matching when the
        tree moved under `VexSign/`, so the Python service, the cloud service, both Dockerfiles
        and all three Swift packages went unwatched — including the exact `httpx`/`httpcore`
        pins the SSRF guard monkeypatches, and the floating `branch:` dependencies in SideSign.
        """
        entries = dependabot_entries()
        self.assertTrue(entries, 'expected dependabot.yml to declare updates')
        seen_ecosystems = set()
        for ecosystem, directory in entries:
            with self.subTest(ecosystem=ecosystem, directory=directory):
                self.assertIn(ecosystem, DEPENDABOT_MANIFESTS,
                              f'unknown ecosystem {ecosystem!r}: add its manifest to DEPENDABOT_MANIFESTS')
                target = dependabot_root(directory)
                self.assertTrue(target.is_dir(), f'{directory} does not exist; Dependabot will open no PRs')
                manifest = target / DEPENDABOT_MANIFESTS[ecosystem]
                self.assertTrue(manifest.exists(),
                                f'{directory} holds no {DEPENDABOT_MANIFESTS[ecosystem]} for the {ecosystem} ecosystem')
                seen_ecosystems.add(ecosystem)
        # The two network-facing services and their images are the surface worth watching.
        for ecosystem in ('github-actions', 'pip', 'npm', 'docker'):
            self.assertIn(ecosystem, seen_ecosystems, f'{ecosystem} dependencies are unwatched')

    def test_server_runtime_imports_are_declared_in_requirements(self):
        """Everything the service imports must be installed by requirements.txt.

        `cryptography` was imported by `cert_inspector.py` and installed only by CI, so the suite
        passed against a dependency set that no Dockerfile and no Render build ever produced; the
        shipped container served users the literal string "Install `cryptography` on the server".
        Deriving the requirement from the imports makes that class of drift a test failure instead
        of a production defect.
        """
        api = ROOT / 'Services/WebManager/API'
        requirements = (ROOT / 'Services/WebManager/Configuration/requirements.txt').read_text()
        declared = {re.split(r'[=<>!~;\[ ]', line.strip(), 1)[0].lower()
                    for line in requirements.splitlines()
                    if line.strip() and not line.strip().startswith('#')}
        # Import name -> PyPI distribution name, where they differ.
        aliases = {'multipart': 'python-multipart'}
        local = {path.stem for path in api.glob('*.py')}

        # Parse the AST rather than grepping for `import`: these modules carry long prose
        # docstrings, and lines such as "from walking device IDs" match a naive pattern.
        imported = set()
        for path in sorted(api.glob('*.py')):
            tree = ast.parse(path.read_text(), filename=str(path))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imported.update(alias.name.split('.', 1)[0] for alias in node.names)
                elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                    imported.add(node.module.split('.', 1)[0])

        third_party = {
            module for module in imported
            if module not in local
            and module not in sys.stdlib_module_names
            and module != '__future__'
        }
        self.assertTrue(third_party, 'expected the service to import third-party modules')

        undeclared = sorted(
            module for module in third_party
            if aliases.get(module, module).lower() not in declared
        )
        self.assertEqual(
            undeclared, [],
            'imported by Services/WebManager/API but absent from '
            'Configuration/requirements.txt, so no deployment installs it'
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
