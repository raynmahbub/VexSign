"""Portable wiring checks for install monitoring. Behavior is covered on Apple CI."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class InstallMonitoringPolicyTests(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text()

    def test_production_installer_can_ask_the_device(self):
        source = self.text('VexSign/Backend/Observable/AppInstaller.swift')
        self.assertIn('probe: InstalledAppProbing = InstalledAppProbe()', source)
        self.assertNotIn('probe: InstalledAppProbing = UnavailableInstallationProbe()', source)

    def test_no_production_caller_injects_the_unavailable_probe(self):
        for path in (ROOT / 'VexSign').rglob('*.swift'):
            self.assertNotIn('probe: UnavailableInstallationProbe()', path.read_text(), str(path))

    def test_delivery_does_not_end_monitoring_or_restart_a_finished_attempt(self):
        source = self.text('VexSign/Backend/Observable/AppInstaller.swift')
        start = source.index('case .completed(let result):')
        branch = source[start:source.index('_progressTask?.cancel()', start)]
        self.assertIn('!(_probe is UnavailableInstallationProbe)', branch)
        self.assertIn('guard !_hasFinished else { return }', branch)
        self.assertIn('_armMonitoringBackstop()', branch)
        self.assertIn('_startProgressPolling()', branch)

    def test_retry_is_checked_before_the_failed_attempt_is_torn_down(self):
        source = self.text('VexSign/Backend/Observable/InstallQueueCore.swift')
        body = source[source.index('func retryCurrent('):]
        self.assertLess(body.index('InstallRetryPolicy.refusal('), body.index('_teardownInstaller()'))


if __name__ == '__main__':
    unittest.main()
