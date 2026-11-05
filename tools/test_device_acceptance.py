#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('acceptance', Path(__file__).with_name('device-acceptance.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AcceptanceTests(unittest.TestCase):
    def report(self):
        return dict(commit='a' * 40, ipa_sha256='b' * 64, tester='Tester',
                    device_model='Test iPhone', os_version='26',
                    tested_at_utc='2026-11-06T10:00:00Z', checks={
                        case: dict(result='pass', notes='Observed on test device')
                        for case in module.CASES})

    def test_complete(self):
        self.assertEqual(module.validate(self.report(), 'a' * 40, 'b' * 64), [])

    def test_wrong_artifact_or_commit(self):
        self.assertEqual(len(module.validate(self.report(), 'c' * 40, 'd' * 64)), 2)

    def test_missing_pending_failed_or_unobserved_checks(self):
        for value in (None, dict(result='pending', notes=''),
                      dict(result='fail', notes='Failed'), dict(result='pass', notes='')):
            report = self.report()
            report['checks']['launch'] = value
            self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))

    def test_missing_metadata(self):
        report = self.report()
        report['tester'] = ''
        report['tested_at_utc'] = 'not a timestamp'
        self.assertTrue(module.validate(report, 'a' * 40, 'b' * 64))


if __name__ == '__main__':
    unittest.main(verbosity=2)
