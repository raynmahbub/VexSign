"""Portable wiring checks. Behavior is covered by WorkflowTraceTests on Apple CI."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class WorkflowTracePolicyTests(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text()

    def test_distributable_and_ci_stamp_actual_checkout(self):
        self.assertIn('VEXSIGN_SOURCE_COMMIT="$(shell git rev-parse HEAD)"', self.text('Makefile'))
        ci = self.text('.github/workflows/ci.yml')
        self.assertEqual(ci.count('VEXSIGN_SOURCE_COMMIT="$(git rev-parse HEAD)"'), 2)
        self.assertIn('$(VEXSIGN_SOURCE_COMMIT)', self.text('VexSign/Resources/Info.plist'))

    def test_private_pairing_consumers_use_shared_path(self):
        for path in ['VexSign/Utilities/FR.swift', 'VexSign/Views/Settings/DevicePickerView.swift',
                     'VexSign/Utilities/IDevice/LockdownClient.swift']:
            source = self.text(path)
            self.assertIn('HeartbeatManager.pairingFile()', source)
            self.assertNotIn('appendingPathComponent("pairingFile.plist")', source)

    def test_reports_never_export_raw_error_or_artifact_identifiers(self):
        source = self.text('VexSign/Backend/Services/TaskReceipt.swift')
        for forbidden in ['task.errorText', 'task.subjectID', 'context?.artifactID', 'task.subtitle']:
            self.assertNotIn(forbidden, source)
        self.assertIn('entry.phase.title', source)
        self.assertIn('validatedCommit', source)

    def test_failed_install_does_not_invoke_signing(self):
        source = self.text('VexSign/Backend/Observable/InstallQueue.swift')
        self.assertNotIn('signPackageFile', source)
        self.assertNotIn('SigningService', source)
        self.assertIn('self.current?.id == failedEntryID', source)

    def test_native_acknowledgement_does_not_wait_on_private_probe(self):
        source = self.text('VexSign/Backend/Observable/AppInstaller.swift')
        native = source.split('private func _confirmIdeviceInstall()', 1)[1].split('extension AppInstaller.Outcome', 1)[0]
        self.assertNotIn('InstallWatcher.confirm', native)
        self.assertNotIn('_probe.installedApp', native)
        self.assertIn('native-installation-completed', native)

    def test_ota_observation_failure_does_not_trigger_reinstall(self):
        source = self.text('VexSign/Backend/Observable/AppInstaller.swift')
        failure = source.split('case .notInstalled, .timedOutWaiting, .timedOutVerifying:', 1)[1].split('private func _confirmIdeviceInstall', 1)[0]
        self.assertIn('_finish(.failure(error))', failure)
        self.assertNotIn('viewModel.status = .broken', failure)

    def test_resource_ownership_is_wired_to_managed_operations(self):
        for path in ['VexSign/Utilities/Signing/SigningService.swift',
                     'VexSign/Backend/Observable/AppInstaller.swift',
                     'VexSign/Utilities/Handlers/AppCloner.swift',
                     'VexSign/Backend/Storage/Storage+Shared.swift']:
            self.assertIn('AppOperationRegistry', self.text(path))

    def test_source_journal_and_build_sidecars_are_wired(self):
        center = self.text('VexSign/Backend/Observable/UnifiedTaskCenter.swift')
        self.assertIn('(tasks + history).map', center)
        self.assertIn('task.recoverAfterRestart()', center)
        self.assertIn('progress: Double = 0', center)
        release = self.text('.github/workflows/release.yml')
        for required in ['write-build-provenance.py --directory upload', 'upload/BUILD.json', 'upload/SHA256SUMS']:
            self.assertIn(required, release)


if __name__ == '__main__':
    unittest.main()
