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


if __name__ == '__main__':
    unittest.main()
