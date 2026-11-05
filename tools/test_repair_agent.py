#!/usr/bin/env python3
"""Offline tests; never call an inference API, spend tokens or create GitHub objects."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('repair_agent', Path(__file__).with_name('repair-agent.py'))
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class RepairPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = 'VexSign/DesignSystem/Card.swift'
        target = self.root / self.path
        target.parent.mkdir(parents=True)
        target.write_text('let value = 1\n')
        (self.root / 'VexSignTests').mkdir()
        self.proposal = dict(summary='Repair value with coverage', edits=[
            dict(path=self.path, before_sha256=hashlib.sha256(target.read_bytes()).hexdigest(), content='let value = 2\n'),
            dict(path='VexSignTests/RepairCardTests.swift', before_sha256=None,
                 content='import XCTest\nfinal class RepairCardTests: XCTestCase { func testValue() { XCTAssertEqual(2, 2) } }\n')])

    def test_small_source_and_new_test(self):
        self.assertEqual(len(agent.validate(self.proposal, self.root)), 2)

    def test_sensitive_paths_and_traversal_rejected(self):
        for path in ('.github/workflows/ci.yml', 'tools/repair-agent.py', 'Makefile',
                     'NativeSigning/Signing/Engine.swift', 'VexSign/Services/Signing.swift',
                     'server/requirements.txt', '/tmp/bad.swift', '../Card.swift',
                     'VexSign/DesignSystem/../Services/Bad.swift', 'VexSign\\DesignSystem\\Card.swift'):
            with self.subTest(path=path):
                proposal = copy.deepcopy(self.proposal)
                proposal['edits'][0]['path'] = path
                with self.assertRaises(ValueError):
                    agent.validate(proposal, self.root)

    def test_existing_tests_cannot_be_weakened(self):
        (self.root / 'VexSignTests/RepairCardTests.swift').write_text('existing')
        with self.assertRaises(ValueError):
            agent.validate(self.proposal, self.root)

    def test_checksum_and_duplicate_paths(self):
        proposal = copy.deepcopy(self.proposal)
        proposal['edits'][0]['before_sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            agent.validate(proposal, self.root)
        proposal = copy.deepcopy(self.proposal)
        proposal['edits'].append(proposal['edits'][0])
        with self.assertRaises(ValueError):
            agent.validate(proposal, self.root)

    def test_empty_and_over_budget_proposals(self):
        for edits in ([], self.proposal['edits'][:1], self.proposal['edits'] * 2):
            with self.assertRaises(ValueError):
                agent.validate(dict(summary='test', edits=edits), self.root)
        for content in ('x\n' * 210, 'x' * 24001, '\x00', ''):
            proposal = copy.deepcopy(self.proposal)
            proposal['edits'][0]['content'] = content
            with self.assertRaises(ValueError):
                agent.validate(proposal, self.root)

    def test_symlink_and_noop_rejected(self):
        target = self.root / self.path
        target.unlink()
        target.symlink_to('/tmp/outside.swift')
        with self.assertRaises(ValueError):
            agent.validate(self.proposal, self.root)
        target.unlink()
        target.write_text('let value = 1\n')
        proposal = copy.deepcopy(self.proposal)
        proposal['edits'][0]['content'] = target.read_text()
        with self.assertRaises(ValueError):
            agent.validate(proposal, self.root)

    def test_unknown_fields_and_fake_tests_rejected(self):
        proposal = copy.deepcopy(self.proposal)
        proposal['command'] = 'echo unsafe'
        with self.assertRaises(ValueError):
            agent.validate(proposal, self.root)
        proposal = copy.deepcopy(self.proposal)
        proposal['edits'][1]['content'] = '// no test\n'
        with self.assertRaises(ValueError):
            agent.validate(proposal, self.root)

    def test_hosted_inference_is_hard_disabled(self):
        with patch.object(agent, 'api') as api, patch.object(agent, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'free-only'):
                agent.propose(1, self.root)
            api.assert_not_called()
            command.assert_not_called()

    def test_common_credentials_are_redacted(self):
        text = agent.redact('Bearer abc123 token=secret password: hidden ghp_abcdefgh sk-exampleKEY a@example.com')
        for secret in ('abc123', '=secret', 'hidden', 'ghp_abcdefgh', 'sk-exampleKEY', 'a@example.com'):
            self.assertNotIn(secret, text)
        self.assertLessEqual(len(agent.redact('x' * 10000)), 4000)

    def test_private_fork_stale_or_nonmain_failures_rejected(self):
        base_run = dict(head_repository=dict(full_name='owner/repo'), head_branch='main',
                        conclusion='failure', event='push', path='.github/workflows/ci.yml', head_sha='a' * 40)
        info = dict(private=False, default_branch='main')
        variants = [dict(head_branch='feature'), dict(event='pull_request'),
                    dict(conclusion='success'), dict(path='.github/workflows/release.yml'),
                    dict(head_repository=dict(full_name='fork/repo'))]
        for change in variants:
            run = {**base_run, **change}
            with patch.object(agent, 'repo', return_value='owner/repo'), patch.object(agent, 'api', side_effect=[info, run]):
                with self.assertRaises(ValueError):
                    agent.current_run(1)
        for repo_info, latest in ((dict(private=True, default_branch='main'), None), (info, dict(sha='b' * 40))):
            with patch.object(agent, 'repo', return_value='owner/repo'), patch.object(agent, 'api', side_effect=[repo_info, base_run, latest]):
                with self.assertRaises(ValueError):
                    agent.current_run(1)


class AdmissionBudgetTests(unittest.TestCase):
    def test_existing_closed_attempt_is_not_retried(self):
        run = dict(head_sha='a' * 40, html_url='https://github.com/owner/repo/actions/runs/1')
        import json
        pages = [[dict(title='Repair attempt: ' + 'a' * 40, created_at='2000-01-01T00:00:00Z', state='closed')]]
        with patch.object(agent, 'current_run', return_value=(run, {})), \
             patch.object(agent, 'repo', return_value='owner/repo'), \
             patch.object(agent, 'command', return_value=json.dumps(pages)) as command, \
             patch.object(agent, 'api') as api, patch.object(agent, 'output') as output:
            agent.admit(1)
            api.assert_not_called()
            output.assert_not_called()
            self.assertIn('--paginate', command.call_args.args)

    def test_daily_limit_spans_all_pages(self):
        import json
        today = agent.dt.datetime.now(agent.dt.timezone.utc).date().isoformat()
        pages = [[dict(title='Repair attempt: prior1', created_at=today + 'T00:00:00Z')],
                 [dict(title='Repair attempt: prior2', created_at=today + 'T00:01:00Z')]]
        run = dict(head_sha='a' * 40)
        with patch.object(agent, 'current_run', return_value=(run, {})), \
             patch.object(agent, 'repo', return_value='owner/repo'), \
             patch.object(agent, 'command', return_value=json.dumps(pages)), \
             patch.object(agent, 'api') as api, patch.object(agent, 'output') as output:
            agent.admit(1)
            api.assert_not_called()
            output.assert_not_called()

    def test_one_attempt_is_reserved_before_inference(self):
        run = dict(head_sha='a' * 40, html_url='https://github.com/owner/repo/actions/runs/1')
        with patch.object(agent, 'current_run', return_value=(run, {})), \
             patch.object(agent, 'repo', return_value='owner/repo'), \
             patch.object(agent, 'command', return_value='[[]]'), \
             patch.object(agent, 'api', return_value=dict(number=42)) as api, \
             patch.object(agent, 'output') as output:
            agent.admit(1)
            self.assertIn('POST', api.call_args.args)
            output.assert_called_once_with(admitted='true', source_sha='a' * 40, issue=42)


if __name__ == '__main__':
    unittest.main(verbosity=2)
