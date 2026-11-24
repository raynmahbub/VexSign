"""Portable install-monitoring wiring guards, not a substitute for Swift/device tests.

Private LaunchServices was removed as the production authority. The old dormant
checks in this module required that private probe, contradicting the supported
inventory policy; these checks now run in both make verify and CI.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
INSTALLATION = 'VexSign/Services/Installation/Installation/'


class InstallMonitoringPolicyTests(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text()

    def test_ota_has_no_implicit_private_inventory_authority(self):
        source = self.text(INSTALLATION + 'AppInstaller.swift')
        self.assertIn('probe: InstalledAppProbing = UnavailableInstallationProbe()', source)
        self.assertNotIn('probe: InstalledAppProbing = InstalledAppProbe()', source)
        self.assertIn('progress: { nil }', source)
        self.assertIn('"supported-installation-inventory-unavailable"', source)

    def test_paired_confirmation_uses_the_frozen_selected_request(self):
        source = self.text(INSTALLATION + 'AppInstaller.swift')
        confirmation = source.split('private func _confirmIdeviceInstall()', 1)[1]
        self.assertIn('probe: PairedDeviceInstallationProbe(request: request)', confirmation)
        self.assertIn('deviceBinding: binding, evidenceNotBefore: submission.acknowledgedAt', confirmation)
        self.assertNotIn('InstalledAppProbe()', confirmation)

    def test_delivery_does_not_end_observation_or_restart_a_finished_attempt(self):
        source = self.text(INSTALLATION + 'AppInstaller.swift')
        start = source.index('case .completed(let result):')
        branch = source[start:source.index('_progressTask?.cancel()', start)]
        self.assertIn('!(_probe is UnavailableInstallationProbe)', branch)
        self.assertIn('guard !_hasFinished else { return }', branch)
        self.assertIn('_armMonitoringBackstop()', branch)
        self.assertIn('_startProgressPolling()', branch)

    def test_installer_receives_the_actual_watcher_reading_before_finishing(self):
        source = self.text(INSTALLATION + 'AppInstaller.swift')
        body = source.split('private func _startProgressPolling()', 1)[1].split('private func _armVerificationDeadline()', 1)[0]
        self.assertIn('let observation = await InstallWatcher.watchObservation(', body)
        self.assertIn('installer?._confirmedApplication = observation.confirmedApplication', body)
        self.assertLess(body.index('_confirmedApplication ='), body.index('_finishConfirmed(observation.verdict)'))
        self.assertNotIn('InstalledApplicationEvidence(', body)
        self.assertNotIn('InstalledApp(bundleIdentifier:', body)

    def test_all_watcher_exit_paths_preserve_the_engine_observation(self):
        source = self.text(INSTALLATION + 'InstallConfirmation.swift')
        body = source.split('static func watchObservation(', 1)[1].split('static func confirm(', 1)[0]
        self.assertNotIn('return verdict', body)
        self.assertNotIn('return await confirm(', body)
        self.assertEqual(body.count('return Observation(confirmation: confirmation)'), 5)
        self.assertIn('verdict.provesInstalled ? confirmation.confirmedApplication : nil', source)

    def test_bound_before_state_cannot_be_borrowed_from_another_device(self):
        source = self.text(INSTALLATION + 'InstallConfirmation.swift')
        body = source.split('if let binding = expectation.deviceBinding {', 1)[1].split('if !baseline.isInstalled', 1)[0]
        for guard in ('baseline.isInstalled, !baseline.isPlaceholder', 'evidence.isWellFormed',
                      'evidence.deviceBinding == binding', 'evidence.observedAt <= cutoff',
                      'evidence.version == baseline.version', 'evidence.build == baseline.build',
                      'current.evidence?.confirms('):
            self.assertIn(guard, body)

    def test_retry_is_checked_before_the_failed_attempt_is_torn_down(self):
        source = self.text(INSTALLATION + 'InstallQueueCore.swift')
        body = source[source.index('func retryCurrent('):]
        self.assertLess(body.index('InstallRetryPolicy.refusal('), body.index('_teardownInstaller()'))

    def test_monitoring_regressions_are_registered_in_local_and_ci_gates(self):
        command = 'Tools/Validation/security-validation/test_install_monitoring_policy.py'
        self.assertIn(command, self.text('Makefile'))
        self.assertIn(command, self.text('.github/workflows/ci.yml'))


if __name__ == '__main__':
    unittest.main()
