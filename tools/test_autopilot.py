#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
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
        self.assertTrue(controller.eligible(self.pr(), self.files('server/requirements.txt'), 'main'))
        self.assertTrue(controller.eligible(self.pr(), self.files('cloud-signing/package.json', 'cloud-signing/package-lock.json'), 'main'))

    def test_major_missing_metadata_or_mixed_updates_rejected(self):
        for body in ('', 'update-type: version-update:semver-major',
                     'update-type: version-update:semver-minor\nupdate-type: version-update:semver-major'):
            pr = self.pr()
            pr['body'] = body
            self.assertFalse(controller.eligible(pr, self.files('server/requirements.txt'), 'main'))

    def test_sensitive_and_unrelated_files_rejected(self):
        for path in ('.github/workflows/release.yml', 'NativeSigning/Package.swift',
                     'VexSign/Services/SigningService.swift', 'cloud-signing/src/main.ts'):
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
            self.assertFalse(controller.eligible(pr, self.files('server/requirements.txt'), 'main'))
        self.assertFalse(controller.eligible(original, [dict(filename='server/requirements.txt', status='removed')], 'main'))

    def test_bot_branch_and_path_both_required(self):
        pr = self.pr()
        pr['user']['login'] = 'github-actions[bot]'
        pr['head']['ref'] = 'automation/release-listing'
        self.assertTrue(controller.eligible(pr, self.files('app-repo.json'), 'main'))
        self.assertFalse(controller.eligible(pr, self.files('VexSign/App.swift'), 'main'))
        pr['head']['ref'] = 'automation/unknown'
        self.assertFalse(controller.eligible(pr, self.files('app-repo.json'), 'main'))

    def test_agent_repair_branches_never_auto_merge(self):
        pr = self.pr()
        pr['user']['login'] = 'github-actions[bot]'
        pr['head']['ref'] = 'automation/repair-' + 'a' * 12
        self.assertFalse(controller.eligible(pr, self.files('VexSign/DesignSystem/Card.swift',
            'VexSignTests/RepairCardTests.swift'), 'main'))
        self.assertFalse(controller.eligible(pr, self.files('app-repo.json'), 'main'))

    def test_required_workflows(self):
        self.assertEqual(controller.required_workflows(['cloud-signing/package.json']), ['ci.yml', 'ecosystem.yml'])
        self.assertEqual(controller.required_workflows(['server/requirements.txt']), ['ci.yml', 'server-tests.yml'])

    def test_unanimous_semantic_version(self):
        self.assertEqual(stable.version('MARKETING_VERSION = 1.2.3;\nMARKETING_VERSION = 1.2.3;'), '1.2.3')
        for text in ('', 'MARKETING_VERSION = 1.2;', 'MARKETING_VERSION = 1.2.3; MARKETING_VERSION = 2.0.0;',
                     'MARKETING_VERSION = 1.2.3; MARKETING_VERSION = invalid;'):
            self.assertIsNone(stable.version(text))


if __name__ == '__main__':
    unittest.main(verbosity=2)
