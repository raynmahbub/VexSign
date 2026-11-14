#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def load(name):
    candidates = (Path(__file__).with_name(name + '.py'),
                  ROOT / 'Tools/Release' / (name + '.py'),
                  ROOT / 'Tools/Development' / (name + '.py'))
    script = next(path for path in candidates if path.is_file())
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load('repository-autopilot')
stable = load('auto-stable-release')
controller.REPO = 'owner/repo'


class AutopilotTests(unittest.TestCase):
    def pr(self):
        return dict(draft=False, base=dict(ref='main'),
                    head=dict(ref='dependabot/npm/update', repo=dict(full_name='owner/repo')),
                    user=dict(login='dependabot[bot]'),
                    body='update-type: version-update:semver-minor')

    def files(self, *paths):
        return [dict(filename=p, status='modified') for p in paths]

    def test_minor_service_updates(self):
        self.assertTrue(controller.eligible(self.pr(), self.files('Services/API/server/requirements.txt'), 'main'))
        self.assertTrue(controller.eligible(self.pr(), self.files('Services/CloudSigning/cloud-signing/package.json', 'Services/CloudSigning/cloud-signing/package-lock.json'), 'main'))

    def test_major_missing_metadata_or_mixed_updates_rejected(self):
        for body in ('', 'update-type: version-update:semver-major',
                     'update-type: version-update:semver-minor\nupdate-type: version-update:semver-major'):
            pr = self.pr()
            pr['body'] = body
            self.assertFalse(controller.eligible(pr, self.files('Services/API/server/requirements.txt'), 'main'))

    def test_sensitive_and_unrelated_files_rejected(self):
        for path in ('.github/workflows/release.yml', 'Packages/NativeSigning/Package.swift',
                     'App/iOS/VexSign/Services/SigningService.swift', 'Services/CloudSigning/cloud-signing/src/main.ts'):
            self.assertFalse(controller.eligible(self.pr(), self.files(path), 'main'))

    def test_fork_human_draft_and_deleted_files_rejected(self):
        original = self.pr()
        variants = []
        for key, value in (('draft', True), ('user', dict(login='human')),
                           ('head', dict(ref='dependabot/npm/update', repo=dict(full_name='fork/repo')))):
            pr = copy.deepcopy(original)
            pr[key] = value
            variants.append(pr)
        for pr in variants:
            self.assertFalse(controller.eligible(pr, self.files('Services/API/server/requirements.txt'), 'main'))
        self.assertFalse(controller.eligible(original, [dict(filename='Services/API/server/requirements.txt', status='removed')], 'main'))

    def test_bot_branch_and_path_both_required(self):
        pr = self.pr()
        pr['user']['login'] = 'github-actions[bot]'
        pr['head']['ref'] = 'automation/release-listing'
        self.assertTrue(controller.eligible(pr, self.files('app-repo.json'), 'main'))
        self.assertFalse(controller.eligible(pr, self.files('App/iOS/VexSign/App.swift'), 'main'))
        pr['head']['ref'] = 'automation/unknown'
        self.assertFalse(controller.eligible(pr, self.files('app-repo.json'), 'main'))

    def test_required_workflows(self):
        self.assertEqual(controller.required_workflows(['Services/CloudSigning/cloud-signing/package.json']), ['ci.yml', 'services.yml'])
        self.assertEqual(controller.required_workflows(['Services/API/server/requirements.txt']), ['ci.yml', 'services.yml'])

        self.assertEqual(controller.required_workflows(['Services/API/server/requirements.txt', 'Services/CloudSigning/cloud-signing/package.json']), ['ci.yml', 'services.yml'])

    def test_unanimous_semantic_version(self):
        self.assertEqual(stable.version('MARKETING_VERSION = 1.2.3;\nMARKETING_VERSION = 1.2.3;'), '1.2.3')
        for text in ('', 'MARKETING_VERSION = 1.2;', 'MARKETING_VERSION = 1.2.3; MARKETING_VERSION = 2.0.0;',
                     'MARKETING_VERSION = 1.2.3; MARKETING_VERSION = invalid;'):
            self.assertIsNone(stable.version(text))

    def test_release_project_targets_share_the_selected_version(self):
        project = Path(__file__).resolve().parents[2] / 'VexSign.xcodeproj/project.pbxproj'
        self.assertEqual(stable.version(project.read_text()), '1.2.1')


class RepositoryEndpointTests(unittest.TestCase):
    def test_controller_repository_root_has_no_trailing_slash(self):
        from unittest.mock import patch
        with patch.object(controller, 'command', return_value='{"default_branch":"main"}') as command:
            self.assertEqual(controller.api('')['default_branch'], 'main')
        command.assert_called_once_with('gh', 'api', 'repos/owner/repo')

    def test_stable_repository_root_has_no_trailing_slash(self):
        import json
        import os
        from unittest.mock import patch
        with patch.dict(os.environ, GH_REPO='owner/repo', SOURCE_SHA='old'), \
             patch.object(stable.subprocess, 'check_output', side_effect=[
                 json.dumps({'default_branch': 'main'}), json.dumps({'sha': 'new'})]) as output, \
             patch.object(stable.subprocess, 'run') as dispatch:
            stable.main()
        self.assertEqual(output.call_args_list[0].args[0], ['gh', 'api', 'repos/owner/repo'])
        dispatch.assert_not_called()


class ControllerFlowTests(unittest.TestCase):
    """Exercise the controller offline: never dispatch or merge real PRs."""

    def simulate(self, state):
        import subprocess
        from unittest.mock import patch
        pr = AutopilotTests().pr()
        pr['mergeable'] = True
        pr['head']['sha'] = 'a' * 40

        def api(path):
            if state == 'api_error':
                raise subprocess.CalledProcessError(1, ['gh', 'api'], stderr='HTTP 403')
            if path == '': return {'default_branch': 'main'}
            if path.startswith('pulls?'): return [{'number': 123}]
            if path == 'pulls/123': return pr
            if path == 'pulls/123/files?per_page=100': return AutopilotTests().files('Services/API/server/requirements.txt')
            if path.startswith('compare/'): return {'behind_by': 1 if state == 'stale' else 0}
            if '/runs?' in path:
                if state == 'empty': return {'workflow_runs': []}
                return {'workflow_runs': [{'id': 456, 'event': 'workflow_dispatch',
                         'head_branch': pr['head']['ref'],
                         'status': 'in_progress' if state == 'pending' else 'completed',
                         'conclusion': 'failure' if state == 'failed' else 'success'}]}
            if path == 'actions/runs/456/jobs?per_page=100':
                # A successful quick-only run must never authorize a merge.
                return {'jobs': [{'name': 'quick · syntax, resources, gates', 'conclusion': 'success'}]}
            raise AssertionError(path)

        with patch.object(controller, 'api', side_effect=api), \
             patch.object(controller, 'command') as command, \
             patch.object(controller.subprocess, 'run') as merge:
            if state == 'api_error':
                with self.assertRaises(subprocess.CalledProcessError):
                    controller.run_prs()
            else:
                controller.run_prs()
        return command, merge

    def test_missing_runs_dispatch_full_ci_and_service_checks_only(self):
        command, merge = self.simulate('empty')
        self.assertEqual(command.call_count, 2)
        calls = [call.args for call in command.call_args_list]
        self.assertTrue(any('ci.yml' in args and 'validation=full' in args for args in calls))
        self.assertTrue(any('services.yml' in args for args in calls))
        merge.assert_not_called()

    def test_failed_pending_and_quick_only_runs_do_not_merge_or_retry(self):
        for state in ('failed', 'pending', 'quick_only'):
            with self.subTest(state=state):
                command, merge = self.simulate(state)
                command.assert_not_called()
                merge.assert_not_called()

    def test_stale_branch_refresh_is_pinned_and_not_merged(self):
        command, merge = self.simulate('stale')
        command.assert_called_once_with('gh', 'api', '--method', 'PUT',
            'repos/owner/repo/pulls/123/update-branch', '-f', 'expected_head_sha=' + 'a' * 40)
        merge.assert_not_called()

    def test_api_failure_stops_without_writes(self):
        command, merge = self.simulate('api_error')
        command.assert_not_called()
        merge.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
