"""Portable wiring checks. Behavior is covered by WorkflowTraceTests on Apple CI."""
import pathlib
import re
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

    # What a finished signing run may delete. The rule itself is covered by PostSignArtifactsTests;
    # these pin that every flow that signs goes through it and deletes nothing on its own.

    def test_every_signing_flow_settles_its_copies_through_the_one_rule(self):
        # The whole call, per flow: which copy is the source, which is the output, the flow's
        # origin, its own "Delete After Signing" where it has one, and whether it sweeps.
        flows = {
            'VexSign/Backend/Observable/AutoSignManager.swift':
                'source: app, output: signed, origin: .savedSettings',
            'VexSign/Views/Signing/SigningView.swift':
                'source: app, output: signed, origin: .sheet, '
                'runDeletesSource: _temporaryOptions.post_deleteAppAfterSigned',
            'VexSign/Backend/Observable/BatchJobRunner.swift':
                'source: app, output: signed, origin: .batch, '
                'runDeletesSource: options.post_deleteAppAfterSigned, sweepsStorage: false',
            'VexSign/Backend/Observable/UpdateAllManager.swift':
                'source: app, output: signed, origin: .update',
            'VexSign/Utilities/IPAExplorer/IPAWorkspace.swift':
                'source: target, output: signed, origin: .explorer, sweepsStorage: false',
        }
        for path, arguments in flows.items():
            source = self.text(path)
            self.assertEqual(source.count('CleanupManager.shared.finishSign('), 1, path)
            call = source.split('CleanupManager.shared.finishSign(', 1)[1].split(')\n', 1)[0]
            self.assertEqual(' '.join(call.split()), arguments, path)
            self.assertNotIn('deleteApps(', source, path)
            if path.endswith('IPAWorkspace.swift'):
                # The explorer may still drop the import it made itself when the run never
                # produced anything. Nothing else.
                self.assertEqual(source.count('Storage.shared.deleteApp('),
                                 source.count('if temporary { Storage.shared.deleteApp(for: target) }'), path)
            else:
                self.assertNotIn('Storage.shared.deleteApp(', source, path)
            # A batch settles each app without sweeping and sweeps once when it is through.
            sweeps = source.count('CleanupManager.shared.sweepAfterSigning()')
            self.assertEqual(sweeps, 1 if path.endswith('BatchJobRunner.swift') else 0, path)
        batch = self.text('VexSign/Backend/Observable/BatchJobRunner.swift')
        sign_all = batch.split('private func _signAll() async {', 1)[1].split('private func _installAll() async {', 1)[0]
        self.assertLess(sign_all.index('CleanupManager.shared.finishSign('),
                        sign_all.index('CleanupManager.shared.sweepAfterSigning()'))
        # After the loop over the batch, not inside it.
        self.assertIn('\n\t\tCleanupManager.shared.sweepAfterSigning()\n\t}\n', sign_all)
        # The flows above are every flow that signs a library app. A file that starts naming the
        # signer has to be added to one of the two lists, which is the moment to decide how the
        # new flow settles its copies.
        #   SelfUpdateManager signs a scratch import of VexSign itself and deletes both scratch
        #   entries once the update is packaged: neither was ever meant to stay in the library.
        #   FR declares the function. FeatureStatusRegistry names it in a description.
        elsewhere = {
            'VexSign/Backend/Observable/SelfUpdateManager.swift',
            'VexSign/Utilities/FR.swift',
            'VexSign/Backend/Observable/FeatureStatusRegistry.swift',
        }
        named, started = set(), set()
        for path in sorted((ROOT / 'VexSign').rglob('*.swift')):
            source = path.read_text()
            if 'signPackageFile(' in source:
                named.add(path.relative_to(ROOT).as_posix())
            if 'SigningService.shared.sign(' in source:
                started.add(path.relative_to(ROOT).as_posix())
        self.assertEqual(named, set(flows) | elsewhere)
        self.assertEqual(started, {'VexSign/Utilities/FR.swift'})

    def test_no_flow_can_ask_for_the_signed_copy_to_be_dropped(self):
        # The entry points that took the signed copy together with a "keep it?" flag are gone.
        for path in sorted((ROOT / 'VexSign').rglob('*.swift')):
            source = path.read_text()
            for gone in ['runAfterSign', 'keepsSignedApp', 'deletesSourceAfterSign']:
                self.assertNotIn(gone, source, f'{path.relative_to(ROOT)}: {gone}')
        manager = self.text('VexSign/Backend/Observable/CleanupManager.swift')
        finish = manager.split('func finishSign(', 1)[1].split('func sweepAfterSigning()', 1)[0]
        # The signed copy is only looked up. The one deletion is bound to the source.
        self.assertIn('outputIsInLibrary: { _holdsSignedCopy($0) }', finish)
        self.assertEqual(re.findall(r'(?<![A-Za-z_.])delete\(([^)]*)\)', finish), ['[source]'])
        self.assertNotIn('deleteApp', finish)
        # Confirmed means a signed row with that identifier whose bundle is on disk.
        holds = manager.split('private func _holdsSignedCopy(_ uuid: String) -> Bool {', 1)[1].split('// MARK: - Downloads', 1)[0]
        self.assertIn('first(where: { $0.isSigned && $0.uuid == uuid })', holds)
        self.assertIn('return Storage.shared.getAppDirectory(for: row) != nil', holds)
        self.assertEqual(holds.count('return '), 2)
        rule = self.text('VexSign/Backend/Services/PostSignArtifacts.swift')
        decision = rule.split('enum Decision: Equatable {', 1)[1].split('}', 1)[0]
        self.assertEqual(re.findall(r'case (\w+)', decision), ['keepSource', 'removeSource'])

    def test_cleanup_switches_reach_the_rule_as_stored(self):
        manager = self.text('VexSign/Backend/Observable/CleanupManager.swift')
        stored = manager.split('extension PostSignArtifacts.Settings {', 1)[1]
        self.assertIn('autoCleanup: defaults.bool(forKey: CleanupManager.Key.enabled)', stored)
        self.assertIn('deleteUnsignedSource: defaults.bool(forKey: CleanupManager.Key.deleteSourceAfterSign)', stored)
        self.assertIn('deleteSignedSource: defaults.bool(forKey: CleanupManager.Key.deleteSignedAfterSign)', stored)
        finish = manager.split('func finishSign(', 1)[1].split('func sweepAfterSigning()', 1)[0]
        self.assertIn('settings: .stored(in: _defaults)', finish)
        self.assertIn('sourceIsSigned: source.isSigned', finish)
        self.assertIn('runDeletesSource: runDeletesSource', finish)

    def test_a_removal_that_was_refused_is_not_reported(self):
        manager = self.text('VexSign/Backend/Observable/CleanupManager.swift')
        self.assertIn('guard Storage.shared.deleteApps(targets) else { return CleanupSummary() }', manager)
        finish = manager.split('func finishSign(', 1)[1].split('func sweepAfterSigning()', 1)[0]
        self.assertIn('guard !removed.removedApps.isEmpty else { return false }', finish)
        rules = self.text('VexSign/Backend/Observable/CleanupHistory.swift')
        prune = rules.split('static func pruneDuplicateSignedApps()', 1)[1]
        self.assertIn('guard Storage.shared.deleteApps(targets) else { return ([], 0) }', prune)

    def test_post_sign_reporting_and_sweep_follow_the_caller(self):
        manager = self.text('VexSign/Backend/Observable/CleanupManager.swift')
        finish = manager.split('func finishSign(', 1)[1].split('func sweepAfterSigning()', 1)[0]
        # A flow using up its own import, or a run's own option, is not announced as a cleanup.
        self.assertIn('if cause == .cleanupSetting { summary.absorb(removed) }', finish)
        self.assertEqual(finish.count('summary.absorb('), 2)
        # No sweep for a caller that did not ask for one, and none with Auto Cleanup off. What a
        # cleanup switch removed is still recorded then, without a toast.
        quiet = finish.split('guard sweepsStorage, isEnabled else {', 1)[1].split('\n\t\t}\n', 1)[0]
        self.assertIn('report(summary, trigger: .sign, silent: true)', quiet)
        self.assertIn('return outcome', quiet)
        self.assertNotIn('purge', quiet)
        swept = finish.split('guard sweepsStorage, isEnabled else {', 1)[1].split('\n\t\t}\n', 1)[1]
        self.assertIn('summary.absorb(purgeEnabledCategories())', swept)
        self.assertIn('report(summary, trigger: .sign, silent: false)', swept)
        sweep = manager.split('func sweepAfterSigning() {', 1)[1].split('private func _holdsSignedCopy(', 1)[0]
        self.assertIn('guard isEnabled else { return }', sweep)

    def test_duplicate_pruning_uses_the_retention_rule(self):
        rules = self.text('VexSign/Backend/Observable/CleanupHistory.swift')
        prune = rules.split('static func pruneDuplicateSignedApps()', 1)[1]
        self.assertIn('SignedCopyRetention.surplus(among: copies)', prune)
        self.assertIn('for app in Storage.shared.getAllApps() where app.isSigned {', prune)
        self.assertIn('date: app.date', prune)
        self.assertNotIn('.sorted', prune)
        self.assertIn('!AppOperationRegistry.shared.isBusy(AppOperationRegistry.key($0))', prune)

    def test_a_copy_being_produced_is_announced_before_its_folder_exists(self):
        for path, claim in [('VexSign/Utilities/Handlers/SigningHandler.swift', '_outputClaim'),
                            ('VexSign/Utilities/Handlers/AppFileHandler.swift', '_importClaim')]:
            source = self.text(path)
            initializer = source.split('\tinit(', 1)[1].split('super.init()', 1)[0]
            self.assertIn(f'self.{claim} = AppOperationRegistry.shared.claimProduction(of: _uuid)', initializer, path)
            register = source.split('func addToDatabase()', 1)[1].split('func clean()', 1)[0]
            self.assertLess(register.index('_didAddToDatabase = true'),
                            register.index('AppOperationRegistry.shared.confirmProduction(of: _uuid)'), path)
        storage = self.text('VexSign/Backend/Observable/StorageManager.swift')
        snapshot = storage.split('private func _librarySnapshot()', 1)[1].split('// MARK: - Manager extension: purging', 1)[0]
        self.assertIn('productions: .shared', snapshot)
        owns = storage.split('func owns(_ uuid: String, signed: Bool) -> Bool {', 1)[1].split('func ownsCertificate(', 1)[0]
        self.assertIn('productions?.knowsProduction(of: uuid) == true', owns)

    def test_every_cleanup_pass_defers_what_a_running_operation_uses(self):
        manager = self.text('VexSign/Backend/Observable/CleanupManager.swift')
        clean_now = manager.split('func cleanNow() -> CleanupSummary {', 1)[1].split('// MARK: - Internals', 1)[0]
        self.assertIn('purgeWhatMayBeCleared(of: categories)', clean_now)
        guarded = manager.split('private func purgeWhatMayBeCleared(of', 1)[1].split('private func purge(_', 1)[0]
        self.assertIn('CleanupPassPolicy.plan(', guarded)
        self.assertIn('operationsActive: AppOperationRegistry.shared.hasActiveOperations', guarded)
        self.assertIn('summary.deferred = plan.deferred', guarded)
        self.assertIn('purgeWhatMayBeCleared(of: enabledCategories)', manager)
        # Nothing reaches the unguarded purge except the guard itself.
        self.assertEqual(re.findall(r'(?<![A-Za-z_.])purge\(([^)]*)\)', manager),
                         ['plan.clear', '_ categories: [StorageCategory]'])

    def test_repeat_signing_review_is_worded_by_the_rule_the_run_follows(self):
        details = self.text('VexSign/Views/Library/Info/LibraryInfoView.swift')
        self.assertIn('PostSignArtifacts.repeatSigningNotice(settings: .stored())', details)
        self.assertNotIn('repeat signing replaces this source copy', details)

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
