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

    def test_install_baseline_probe_does_not_block_the_main_actor(self):
        source = self.text('VexSign/Backend/Observable/AppInstaller.swift')
        start = source.split('func start(completion:', 1)[1].split('/// Capture the pre-install state', 1)[0]
        capture = source.split('private func _captureInstallBaseline(', 1)[1].split('/// Stops without reporting an outcome', 1)[0]
        self.assertIn('_captureInstallBaseline(identifier)', start)
        self.assertNotIn('_probe.installedApp(for: identifier)', start)
        self.assertIn('Task.detached(priority: .utility)', capture)
        self.assertIn('_installBaseline = .init(app: nil)', capture)
        self.assertIn('guard !Task.isCancelled', capture)

    def test_private_install_probes_are_bounded_off_main_and_single_flight(self):
        probe = self.text('VexSign/Utilities/Installing/InstalledAppProbe.swift')
        watcher = self.text('VexSign/Utilities/Installing/InstallConfirmation.swift')
        library = self.text('VexSign/Backend/Observable/LibraryStatusStore.swift')
        self.assertIn('installedAppWithTimeout(', probe)
        self.assertIn('Thread.isMainThread', probe)
        self.assertIn('DispatchSemaphore(value: 1)', probe)
        self.assertIn('wait(timeout: .now())', probe)
        self.assertNotIn('probe.installedApp(for:', watcher)
        self.assertIn('await probe.installedAppWithTimeout', watcher)
        self.assertIn('await probe.installedAppWithTimeout', library)

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

    def test_signing_stage_is_reported_before_identity_and_profile_checks(self):
        source = self.text('VexSign/Utilities/Handlers/SigningHandler.swift')
        modify = source.split('func modify() async throws {', 1)[1].split('func move() async throws {', 1)[0]
        self.assertEqual(modify.count('onStage?(.signing)'), 1)
        # Customization ends with the disinjection; a refusal after it belongs to Sign.
        self.assertLess(modify.index('try await handler.disinject()'), modify.index('onStage?(.signing)'))
        self.assertLess(modify.index('onStage?(.signing)'), modify.index('try _auditNestedBundles('))
        self.assertLess(modify.index('onStage?(.signing)'), modify.index('throw SigningFileHandlerError.missingCertifcate'))

    def test_one_shot_tweak_files_are_copied_for_a_run_and_never_replayed(self):
        handler = self.text('VexSign/Utilities/Handlers/TweakHandler.swift')
        self.assertIn('OneShotTweakFiles.stage(oneShotFiles, into: baseTmpDir', handler)
        store = self.text('VexSign/Backend/Observable/SigningProfileStore.swift')
        self.assertIn('all[bundleID]?.replayable()', store)
        self.assertIn('store[profile.bundleID] = profile.replayable()', store)
        presets = self.text('VexSign/Backend/Observable/NamedSigningProfileStore.swift')
        self.assertGreaterEqual(presets.count('withoutOneShotFiles()'), 4)

    def test_reviewed_repeat_signing_forwards_the_accepted_override(self):
        manager = self.text('VexSign/Backend/Observable/AutoSignManager.swift')
        self.assertIn('overridesBlockingPreflightIssues: overridingBlockingIssues', manager)
        details = self.text('VexSign/Views/Library/Info/LibraryInfoView.swift')
        self.assertIn('let overridesBlockingIssues = checks.hasBlocking', details)
        self.assertIn('AutoSignManager.shared.sign(app, overridingBlockingIssues: overridesBlockingIssues)', details)

    def test_library_details_describe_the_copy_not_the_last_run_started_from_it(self):
        details = self.text('VexSign/Views/Library/Info/LibraryInfoView.swift')
        self.assertIn('signingRecords(forCopy: app.uuid)', details)
        self.assertNotIn('latestSigningTask(subjectID:', details)
        self.assertNotIn('signingTrace(subjectID:', details)

    def test_declined_install_closes_its_own_task_record(self):
        source = self.text('VexSign/Backend/Observable/InstallQueue.swift')
        declined = source.split('\t\tcase .success(.cancelled):\n', 1)[1].split('case .success(.guestImportPrepared):', 1)[0]
        self.assertIn('_finishUnifiedTask(cancelled: true)', declined)
        self.assertLess(declined.index('_finishUnifiedTask(cancelled: true)'), declined.index('_abandon()'))

    def test_install_monitoring_is_bounded_outside_the_watcher(self):
        source = self.text('VexSign/Backend/Observable/AppInstaller.swift')
        self.assertNotIn('Task.detached(priority: .background)', source)
        polling = source.split('private func _startProgressPolling()', 1)[1].split('private func _armVerificationDeadline()', 1)[0]
        self.assertIn('_progressTask = Task.detached(priority: .utility)', polling)
        self.assertIn('onVerificationAttempt:', polling)
        served = source.split('_hasServedPayload = true', 1)[1]
        self.assertIn('_armMonitoringBackstop()', served)
        self.assertLess(served.index('_armMonitoringBackstop()'), served.index('_startProgressPolling()'))
        deadlines = source.split('private func _armVerificationDeadline()', 1)[1].split('private func _handleVerificationAttempt(', 1)[0]
        self.assertEqual(deadlines.count('await InstallDeadlineBudget.wait(seconds: seconds)'), 2)
        self.assertEqual(deadlines.count('self._progressTask?.cancel()'), 2)
        self.assertNotIn('Task.sleep', deadlines)
        self.assertIn('"installation-monitoring-deadline"', deadlines)
        self.assertIn('"installation-monitoring-deadline"', self.text('VexSign/Backend/Services/TaskReceipt.swift'))

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
