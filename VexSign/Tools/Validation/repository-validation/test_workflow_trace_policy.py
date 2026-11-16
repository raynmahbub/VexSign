"""Portable wiring checks. Behavior is covered by WorkflowTraceTests on Apple CI."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


class WorkflowTracePolicyTests(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text()

    def test_distributable_and_ci_stamp_actual_checkout(self):
        self.assertIn('VEXSIGN_SOURCE_COMMIT="$(shell git rev-parse HEAD)"', self.text('Makefile'))
        ci = self.text('.github/workflows/ci.yml')
        self.assertEqual(ci.count('VEXSIGN_SOURCE_COMMIT="$(git rev-parse HEAD)"'), 2)
        self.assertIn('$(VEXSIGN_SOURCE_COMMIT)', self.text('VexSign/Configuration/Build/iOS/Info.plist'))

    def test_private_pairing_consumers_use_shared_path(self):
        consumers = {
            'VexSign/App/iOS/Infrastructure/Identity/CertificateManagementService.swift': 'HeartbeatManager.shared.importPairingRecord(from: url, replacing: expectedSHA256)',
            'VexSign/App/iOS/Infrastructure/Devices/Transport/PairingBridge.swift': 'HeartbeatManager.pairingFile()',
            'VexSign/App/iOS/Infrastructure/Devices/Transport/LockdownClient.swift': 'HeartbeatManager.pairingFile()',
        }
        for path, shared_entrypoint in consumers.items():
            source = self.text(path)
            self.assertIn(shared_entrypoint, source)
            self.assertNotIn('appendingPathComponent("pairingFile.plist")', source)
        owner = self.text('VexSign/Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat.swift')
        importer = owner.split('func importPairingRecord(', 1)[1].split('func deletePairingRecord(', 1)[0]
        self.assertIn('try await serialized', importer)
        self.assertIn('URL(fileURLWithPath: Self.pairingFile())', importer)

    def test_reports_never_export_raw_error_or_artifact_identifiers(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Tasks/TaskReceipt.swift')
        for forbidden in ['task.errorText', 'task.subjectID', 'context?.artifactID', 'task.subtitle']:
            self.assertNotIn(forbidden, source)
        self.assertIn('entry.phase.title', source)
        self.assertIn('validatedCommit', source)

    def test_failed_install_does_not_invoke_signing(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/InstallQueueCore.swift')
        self.assertNotIn('signPackage(', source)
        self.assertNotIn('PackageSigningCoordinator', source)
        self.assertNotIn('SigningService', source)
        self.assertIn('self.current?.id == failedEntryID', source)

    def test_install_baseline_probe_does_not_block_the_main_actor(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/AppInstaller.swift')
        start = source.split('func start(completion:', 1)[1].split('/// Capture the pre-install state', 1)[0]
        capture = source.split('private func _captureInstallBaseline(', 1)[1].split('/// Stops without reporting an outcome', 1)[0]
        self.assertIn('_captureInstallBaseline(identifier)', start)
        self.assertNotIn('_probe.installedApp(for: identifier)', start)
        self.assertIn('Task.detached(priority: .utility)', capture)
        self.assertIn('_installBaseline = .init(app: nil)', capture)
        self.assertIn('guard !Task.isCancelled', capture)

    def test_private_install_probes_are_bounded_off_main_and_single_flight(self):
        probe = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/InstalledAppProbe.swift')
        watcher = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/InstallConfirmation.swift')
        library = self.text('VexSign/App/iOS/Infrastructure/Persistence/Repositories/LibraryStatusStore.swift')
        self.assertIn('installedAppWithTimeout(', probe)
        self.assertIn('Thread.isMainThread', probe)
        self.assertIn('DispatchSemaphore(value: 1)', probe)
        self.assertIn('wait(timeout: .now())', probe)
        self.assertNotIn('probe.installedApp(for:', watcher)
        self.assertIn('await probe.installedAppWithTimeout', watcher)
        self.assertIn('await probe.installedAppWithTimeout', library)

    def test_native_acknowledgement_never_substitutes_for_exact_device_readback(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/AppInstaller.swift')
        native = source.split('private func _confirmIdeviceInstall()', 1)[1].split('extension AppInstaller.Outcome', 1)[0]
        self.assertIn('InstallWatcher.confirm(&confirmation', native)
        self.assertIn('PairedDeviceInstallationProbe(request: request)', native)
        self.assertIn('evidenceNotBefore: submission.acknowledgedAt', native)
        self.assertIn('_confirmedApplication = confirmation.confirmedApplication', native)
        self.assertNotIn('_probe.installedApp', native)
        self.assertNotIn('_finishConfirmed(.installed', native)
        self.assertIn('_finishConfirmed(.timedOutVerifying', native)
        self.assertIn('paired-installed-version-not-verified', native)
        self.assertIn('guard InstallationAppProxy.hasAcceptedInventoryBridge', source)
        wrapper = self.text('VexSign/Packages/Vendor/IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift')
        self.assertLess(wrapper.index('guard InstallationAppProxy.hasAcceptedInventoryBridge'),
                        wrapper.index('withDeviceSession'))

    def test_ota_observation_failure_does_not_trigger_reinstall(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/AppInstaller.swift')
        failure = source.split('case .notInstalled, .timedOutWaiting, .timedOutVerifying:', 1)[1].split('private func _confirmIdeviceInstall', 1)[0]
        self.assertIn('_finish(.failure(error))', failure)
        self.assertNotIn('viewModel.status = .broken', failure)

    def test_certificate_cards_follow_refreshed_profiles_and_case_insensitive_file_extensions(self):
        cell = self.text('VexSign/App/iOS/Presentation/Features/Certificates/Views/CertificatesCellView.swift')
        self.assertIn('private var data: Certificate? { cert.profile }', cell)
        self.assertNotIn('@State var data: Certificate?', cell)
        self.assertNotIn('data = cert.profile', cell)
        file_manager = self.text('VexSign/Packages/NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift')
        self.assertIn('pathExtension.caseInsensitiveCompare(pathExtension)', file_manager)

    def test_certificate_import_requires_a_matched_p12_leaf_and_authenticated_profile(self):
        service = self.text('VexSign/App/iOS/Infrastructure/Identity/CertificateManagementService.swift')
        self.assertIn('validateSigningPair(for: stagedKey', service)
        self.assertIn('handler.stage(keyData: p12Data, provisionData: profileData)', service)
        self.assertIn('SigningIdentityStore.inspect(data, password: password)', service)
        self.assertIn('return profileAuthorizes(proof.identity, profile: profile)', service)
        self.assertIn('SigningIdentity.fingerprint(of: $0) == identity.fingerprint', service)
        handler = self.text('VexSign/App/iOS/Infrastructure/Identity/CertificateFileHandler.swift')
        stage = handler.split('func stage(', 1)[1].split('@MainActor', 1)[0]
        self.assertLess(stage.index('ProtectedCertificateFiles.applyProtectionAttributes'), stage.index('keyData.write'))
        self.assertIn('CertificateReader(profileURL).decoded', stage)
        for path in [
            'VexSign/App/iOS/Infrastructure/Identity/CertificateAutoImporter.swift',
            'VexSign/App/iOS/Infrastructure/Identity/NexCerts.swift',
            'VexSign/App/iOS/Infrastructure/Networking/WebManager/WebManagerServer+HTTP.swift',
        ]:
            self.assertIn('CertificateManagementService.validateSigningPair', self.text(path))

    def test_unconfirmed_install_retry_requires_a_separate_device_check(self):
        policy = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/InstallEvidenceSummary.swift')
        self.assertIn('if outcomeUnknown && !afterManualDeviceCheck { return .checkDeviceFirst }', policy)

        queue = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/InstallQueueCore.swift')
        retry = queue.split('func retryCurrent(', 1)[1].split('/// Marks the failed app as pending again', 1)[0]
        self.assertIn('outcomeUnknown: outcomeUnknown', retry)
        self.assertIn('afterManualDeviceCheck: afterManualDeviceCheck', retry)
        self.assertIn('case .checkDeviceFirst:', retry)
        self.assertIn('requiresDeviceCheckBeforeRetry: kind.requiresDeviceCheckBeforeRetry', queue)

        view = self.text('VexSign/App/iOS/Presentation/Features/Library/Views/Install/InstallQueueWindow.swift')
        failure_view = view.split('private struct InstallQueueFailureView:', 1)[1].split('// MARK: - View: Paused queue', 1)[0]
        self.assertIn('failure.requiresDeviceCheckBeforeRetry', failure_view)
        self.assertIn('confirmationDialog', failure_view)
        self.assertIn('afterManualDeviceCheck: true', failure_view)
        self.assertIn('I Checked — Install Again', failure_view)
        for path in [
            'VexSign/App/iOS/Presentation/Features/Installation/ViewModels/InstallationQueueModel.swift',
            'VexSign/App/iOS/Application/Installation/ObserveInstallationQueueUseCase.swift',
            'VexSign/App/iOS/Infrastructure/Devices/Installation/InstallationQueueAdapter.swift',
        ]:
            self.assertIn('afterManualDeviceCheck', self.text(path))

        task_center = self.text('VexSign/App/iOS/Presentation/Features/Tasks/Views/TaskCenterView.swift')
        self.assertIn('task.outcomeUnknown', task_center)
        self.assertIn('allowingUnconfirmedInstall: true', task_center)
        self.assertIn('I Checked — Install Again', task_center)

    def test_resource_ownership_is_wired_to_managed_operations(self):
        for path in ['VexSign/App/iOS/Infrastructure/Signing/Execution/SigningService.swift',
                     'VexSign/App/iOS/Infrastructure/Devices/Installation/AppInstaller.swift',
                     'VexSign/App/iOS/Infrastructure/Archives/IPA/AppCloner.swift',
                     'VexSign/App/iOS/Infrastructure/Persistence/Database/Storage+Shared.swift']:
            self.assertIn('AppOperationRegistry', self.text(path))

    def test_signing_stage_is_reported_before_identity_and_profile_checks(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Signing/Execution/SigningHandler.swift')
        modify = source.split('func modify() async throws {', 1)[1].split('func move() async throws {', 1)[0]
        self.assertEqual(modify.count('onStage?(.signing)'), 1)
        # Customization ends with the disinjection; a refusal after it belongs to Sign.
        self.assertLess(modify.index('try await handler.disinject()'), modify.index('onStage?(.signing)'))
        self.assertLess(modify.index('onStage?(.signing)'), modify.index('try await handler.sign()'))
        self.assertLess(modify.index('onStage?(.signing)'), modify.index('throw SigningFileHandlerError.missingCertifcate'))
        handler = self.text('VexSign/App/iOS/Infrastructure/Signing/Execution/ZsignHandler.swift')
        sign = handler.split('func sign() async throws {', 1)[1].split('func adhocSign()', 1)[0]
        # Component/profile checks moved into the shared execution gate, not out
        # of signing. Both preparation and final revalidation precede execution.
        self.assertLess(sign.index('SigningResolutionSession.prepare('), sign.index('try self.run(prepared.request)'))
        self.assertLess(sign.index('SigningIdentityStore.requireCurrent('), sign.index('try self.run(prepared.request)'))

    def test_one_shot_tweak_files_are_copied_for_a_run_and_never_replayed(self):
        handler = self.text('VexSign/App/iOS/Infrastructure/Signing/Transformation/TweakHandler.swift')
        self.assertIn('OneShotTweakFiles.stage(oneShotFiles, into: baseTmpDir', handler)
        store = self.text('VexSign/App/iOS/Infrastructure/Signing/Execution/SigningProfileStore.swift')
        self.assertIn('all[bundleID]?.replayable()', store)
        self.assertIn('store[profile.bundleID] = profile.replayable()', store)
        presets = self.text('VexSign/App/iOS/Infrastructure/Signing/Execution/NamedSigningProfileStore.swift')
        self.assertGreaterEqual(presets.count('withoutOneShotFiles()'), 4)

    def test_reviewed_repeat_signing_forwards_the_accepted_override(self):
        manager = self.text('VexSign/App/iOS/Infrastructure/Signing/Execution/AutoSignManager.swift')
        self.assertIn('overridesBlockingPreflightIssues: overridingBlockingIssues', manager)
        details = self.text('VexSign/App/iOS/Presentation/Features/Library/Views/Info/LibraryInfoView.swift')
        self.assertIn('let overridesBlockingIssues = checks.canSignAnyway', details)
        self.assertIn('services.signing.signAgain(app, overridingBlockingIssues: overridesBlockingIssues)', details)
        adapter = self.text('VexSign/App/iOS/Infrastructure/Signing/Execution/LibrarySigningAdapter.swift')
        self.assertIn('AutoSignManager.shared.sign(row, overridingBlockingIssues: overridingBlockingIssues)', adapter)

    def test_library_details_describe_the_copy_not_the_last_run_started_from_it(self):
        details = self.text('VexSign/App/iOS/Presentation/Features/Library/Views/Info/LibraryInfoView.swift')
        self.assertIn('signingRecords(forCopy: app.uuid)', details)
        self.assertNotIn('latestSigningTask(subjectID:', details)
        self.assertNotIn('signingTrace(subjectID:', details)

    def test_declined_install_closes_its_own_task_record(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/InstallQueueCore.swift')
        declined = source.split('\t\tcase .success(.cancelled):\n', 1)[1].split('case .success(.guestImportPrepared):', 1)[0]
        self.assertIn('_finishUnifiedTask(cancelled: true)', declined)
        self.assertLess(declined.index('_finishUnifiedTask(cancelled: true)'), declined.index('_abandon()'))

    def test_install_monitoring_is_bounded_outside_the_watcher(self):
        source = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/AppInstaller.swift')
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
        self.assertIn('"installation-monitoring-deadline"', self.text('VexSign/App/iOS/Infrastructure/Tasks/TaskReceipt.swift'))

    # What a finished signing run may delete. The rule itself is covered by PostSignArtifactsTests;
    # these pin that every flow that signs goes through it and deletes nothing on its own.

    def test_every_signing_flow_settles_its_copies_through_the_one_rule(self):
        # The whole call, per flow: which copy is the source, which is the output, the flow's
        # origin, its own "Delete After Signing" where it has one, and whether it sweeps.
        flows = {
            'VexSign/App/iOS/Infrastructure/Signing/Execution/AutoSignManager.swift':
                'source: app, output: signed, origin: .savedSettings',
            'VexSign/App/iOS/Infrastructure/Signing/Execution/LibrarySigningAdapter.swift':
                'source: source, output: signed, origin: .sheet, runDeletesSource: deletesSource',
            'VexSign/App/iOS/Infrastructure/Tasks/BatchJobRunner.swift':
                'source: app, output: signed, origin: .batch, '
                'runDeletesSource: options.post_deleteAppAfterSigned, sweepsStorage: false',
            'VexSign/App/iOS/Infrastructure/Updates/UpdateAllManager.swift':
                'source: app, output: signed, origin: .update',
            'VexSign/App/iOS/Infrastructure/Archives/IPA/IPAWorkspace.swift':
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
        batch = self.text('VexSign/App/iOS/Infrastructure/Tasks/BatchJobRunner.swift')
        sign_all = batch.split('private func _signAll() async {', 1)[1].split('private func _installAll() async {', 1)[0]
        self.assertLess(sign_all.index('CleanupManager.shared.finishSign('),
                        sign_all.index('CleanupManager.shared.sweepAfterSigning()'))
        # After the loop over the batch, not inside it.
        self.assertIn('\n\t\tCleanupManager.shared.sweepAfterSigning()\n\t}\n', sign_all)
        # The flows above are every flow that signs a library app. A file that starts naming the
        # signer has to be added to one of the two lists, which is the moment to decide how the
        # new flow settles its copies.
        #   SelfUpdateManager is gated before certificate access. It neither signs scratch
        #   copies nor uploads signing material to a remote updater.
        #   PackageSigningCoordinator declares the function. FeatureStatusRegistry names it in a description.
        elsewhere = {
            'VexSign/App/iOS/Infrastructure/Signing/Execution/PackageSigningCoordinator.swift',
            'VexSign/App/iOS/Infrastructure/Diagnostics/FeatureStatusRegistry.swift',
            'VexSign/App/iOS/Presentation/Features/Signing/Views/SigningView.swift',
            'VexSign/App/iOS/Presentation/Features/Signing/ViewModels/SigningWorkspaceModel.swift',
        }
        sheet = self.text('VexSign/App/iOS/Presentation/Features/Signing/Views/SigningView.swift')
        self.assertIn('source: app, output: signed, options: runOptions, certificate: runCertificate', sheet)
        self.assertIn('deletesSource: runOptions.post_deleteAppAfterSigned', sheet)
        self.assertNotIn('CleanupManager.shared', sheet)
        application = self.text('VexSign/App/iOS/Application/Signing/SigningWorkspaceUseCase.swift')
        self.assertIn('try provider.finishSuccessfulRun(run.request, output: run.output, deletesSource: deletesSource)', application)
        self.assertIn('try LibraryAppReference(app: output) == run.output', application)
        self.assertIn('deletesSource == run.request.options.post_deleteAppAfterSigned', application)
        self.assertIn('run.settled = true', application)
        self.assertIn('for: app, requestID: requestID', sheet)
        self.assertIn('deletesSource: runOptions.post_deleteAppAfterSigned, requestID: requestID', sheet)
        named, started = set(), set()
        for path in sorted((ROOT / 'VexSign/App/iOS').rglob('*.swift')):
            source = path.read_text()
            if 'signPackage(' in source:
                named.add(path.relative_to(ROOT).as_posix())
            if 'SigningService.shared.sign(' in source:
                started.add(path.relative_to(ROOT).as_posix())
        self.assertEqual(named, set(flows) | elsewhere)
        self.assertEqual(started, {'VexSign/App/iOS/Infrastructure/Signing/Execution/PackageSigningCoordinator.swift'})

    def test_no_flow_can_ask_for_the_signed_copy_to_be_dropped(self):
        # The entry points that took the signed copy together with a "keep it?" flag are gone.
        for path in sorted((ROOT / 'VexSign/App/iOS').rglob('*.swift')):
            source = path.read_text()
            for gone in ['runAfterSign', 'keepsSignedApp', 'deletesSourceAfterSign']:
                self.assertNotIn(gone, source, f'{path.relative_to(ROOT)}: {gone}')
        manager = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/CleanupManager.swift')
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
        rule = self.text('VexSign/App/iOS/Infrastructure/Signing/Execution/PostSignArtifacts.swift')
        decision = rule.split('enum Decision: Equatable {', 1)[1].split('}', 1)[0]
        self.assertEqual(re.findall(r'case (\w+)', decision), ['keepSource', 'removeSource'])

    def test_cleanup_switches_reach_the_rule_as_stored(self):
        manager = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/CleanupManager.swift')
        stored = manager.split('extension PostSignArtifacts.Settings {', 1)[1]
        self.assertIn('autoCleanup: defaults.bool(forKey: CleanupManager.Key.enabled)', stored)
        self.assertIn('deleteUnsignedSource: defaults.bool(forKey: CleanupManager.Key.deleteSourceAfterSign)', stored)
        self.assertIn('deleteSignedSource: defaults.bool(forKey: CleanupManager.Key.deleteSignedAfterSign)', stored)
        finish = manager.split('func finishSign(', 1)[1].split('func sweepAfterSigning()', 1)[0]
        self.assertIn('settings: .stored(in: _defaults)', finish)
        self.assertIn('sourceIsSigned: source.isSigned', finish)
        self.assertIn('runDeletesSource: runDeletesSource', finish)

    def test_a_removal_that_was_refused_is_not_reported(self):
        manager = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/CleanupManager.swift')
        self.assertIn('guard Storage.shared.deleteApps(targets) else { return CleanupSummary() }', manager)
        finish = manager.split('func finishSign(', 1)[1].split('func sweepAfterSigning()', 1)[0]
        self.assertIn('guard !removed.removedApps.isEmpty else { return false }', finish)
        rules = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/CleanupHistory.swift')
        prune = rules.split('static func pruneDuplicateSignedApps()', 1)[1]
        self.assertIn('guard Storage.shared.deleteApps(targets) else { return ([], 0) }', prune)

    def test_post_sign_reporting_and_sweep_follow_the_caller(self):
        manager = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/CleanupManager.swift')
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
        rules = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/CleanupHistory.swift')
        prune = rules.split('static func pruneDuplicateSignedApps()', 1)[1]
        self.assertIn('SignedCopyRetention.surplus(among: copies)', prune)
        self.assertIn('for app in Storage.shared.getAllApps() where app.isSigned {', prune)
        self.assertIn('date: app.date', prune)
        self.assertNotIn('.sorted', prune)
        self.assertIn('!AppOperationRegistry.shared.isBusy(AppOperationRegistry.key($0))', prune)

    def test_a_copy_being_produced_is_announced_before_its_folder_exists(self):
        for path, claim in [('VexSign/App/iOS/Infrastructure/Signing/Execution/SigningHandler.swift', '_outputClaim'),
                            ('VexSign/App/iOS/Infrastructure/Archives/IPA/AppFileHandler.swift', '_importClaim')]:
            source = self.text(path)
            initializer = source.split('\tinit(', 1)[1].split('super.init()', 1)[0]
            self.assertIn(f'self.{claim} = AppOperationRegistry.shared.claimProduction(of: _uuid)', initializer, path)
            register = source.split('func addToDatabase()', 1)[1].split('func clean()', 1)[0]
            self.assertLess(register.index('_didAddToDatabase = true'),
                            register.index('AppOperationRegistry.shared.confirmProduction(of: _uuid)'), path)
        storage = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/StorageManager.swift')
        snapshot = storage.split('private func _librarySnapshot()', 1)[1].split('// MARK: - Manager extension: purging', 1)[0]
        self.assertIn('productions: .shared', snapshot)
        owns = storage.split('func owns(_ uuid: String, signed: Bool) -> Bool {', 1)[1].split('func ownsCertificate(', 1)[0]
        self.assertIn('productions?.knowsProduction(of: uuid) == true', owns)

    def test_every_cleanup_pass_defers_what_a_running_operation_uses(self):
        manager = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/CleanupManager.swift')
        clean_now = manager.split('func cleanNow() -> CleanupSummary {', 1)[1].split('// MARK: - Internals', 1)[0]
        self.assertIn('purgeWhatMayBeCleared(of: categories)', clean_now)
        guarded = manager.split('private func purgeWhatMayBeCleared(of', 1)[1].split('private func report(', 1)[0]
        self.assertIn('AppOperationRegistry.shared.acquireCleanup()', guarded)
        self.assertIn('withExtendedLifetime(lease)', guarded)
        self.assertIn('CleanupPassPolicy.plan(categories, operationsActive: lease == nil)', guarded)
        self.assertIn('summary.deferred = plan.deferred', guarded)
        self.assertIn('for category in plan.clear', guarded)
        self.assertIn('cleanupLease: lease', guarded)
        self.assertIn('purgeWhatMayBeCleared(of: enabledCategories)', manager)

    def test_temporary_cleanup_guards_handed_off_server_files(self):
        api = self.text('VexSign/App/iOS/Infrastructure/Networking/WebManager/WebManagerServer+API.swift')
        route = api.split('app.on(.POST, "api", "sign", body: .stream)', 1)[1].split('// MARK: Signing', 1)[0]
        self.assertLess(route.index('acquireTemporaryWork()'), route.index('streamToFile('))
        self.assertIn('staging: staging, workLease: workLease', route)
        package = api.split('private func _signAndPackage(', 1)[1].split('// MARK: Helpers', 1)[0]
        self.assertIn('asyncStreamFile(at: output.path)', package)
        self.assertIn('withExtendedLifetime(workLease)', package.split('asyncStreamFile(at: output.path)', 1)[1])
        http = self.text('VexSign/App/iOS/Infrastructure/Networking/WebManager/WebManagerServer+HTTP.swift')
        self.assertIn('downloadTemporary(req, file: zipURL', http)
        self.assertIn('downloadTemporary(req, file: ipaURL', http)
        stream = http.split('private static func downloadTemporary(', 1)[1].split('private static func dateString(', 1)[0]
        self.assertIn('asyncStreamFile(at: file.path)', stream)
        self.assertIn('withExtendedLifetime(lease)', stream.split('asyncStreamFile(at: file.path)', 1)[1])
        sweeper = self.text('VexSign/App/iOS/Security/Validation/TempStorageSweeper.swift')
        self.assertIn('registry.acquireCleanup()', sweeper)
        self.assertIn('TemporaryCleanupPolicy.isRetained(', sweeper)

    def test_install_archive_and_web_inbox_are_not_cleanup_scratch(self):
        archive = self.text('VexSign/App/iOS/Infrastructure/Devices/Installation/InstallationArchive.swift')
        self.assertIn('cleanupLease = try registry.acquireTemporaryWork()', archive)
        storage = self.text('VexSign/App/iOS/Infrastructure/Persistence/Cache/StorageManager.swift')
        leftovers = storage.split('static func leftovers(_ library:', 1)[1].split('// MARK: Measuring', 1)[0]
        self.assertNotIn('contents(of: fm.webManagerInbox)', leftovers)
        server = self.text('VexSign/App/iOS/Infrastructure/Networking/WebManager/WebManagerServer.swift')
        self.assertNotIn('Self.stagedCopy(of: url) ?? url', server)
        self.assertIn('WebManagerUploadFile(destination: destination)', server)
        self.assertIn('try upload.commit()', server)
        self.assertIn('WebManagerRouter.route(staged, lease:', server)
        dav = self.text('VexSign/App/iOS/Infrastructure/Networking/WebManager/WebManagerServer+WebDAV.swift')
        self.assertIn('if response.status == .created', dav)

    def test_repeat_signing_review_is_worded_by_the_rule_the_run_follows(self):
        details = self.text('VexSign/App/iOS/Presentation/Features/Library/Views/Info/LibraryInfoView.swift')
        self.assertIn('PostSignArtifacts.repeatSigningNotice(settings: .stored())', details)
        self.assertNotIn('repeat signing replaces this source copy', details)

    def test_source_journal_and_build_sidecars_are_wired(self):
        # History load/save and the restore path live with the task center's state,
        # which is what the journal writes into; the task model carries the default
        # progress the journal restores into.
        center = self.text('VexSign/App/iOS/Infrastructure/Tasks/UnifiedTaskCenter.swift')
        self.assertIn('progress: Double = 0', center)
        self.assertIn('(tasks + history).map', center)
        self.assertIn('task.recoverAfterRestart()', center)
        release = self.text('.github/workflows/release.yml')
        for required in ['write-build-provenance.py --directory upload', 'upload/BUILD.json', 'upload/SHA256SUMS']:
            self.assertIn(required, release)


if __name__ == '__main__':
    unittest.main()
