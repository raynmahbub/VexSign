//
//  LibraryCellView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct LibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	@ObservedObject private var skippedUpdates = SkippedUpdatesManager.shared
	@ObservedObject private var appStoreTracker = AppStoreUpdateTracker.shared
	@ObservedObject private var updateChecker = AppUpdateChecker.shared
	@ObservedObject private var lockManager = AppLockManager.shared
	@ObservedObject private var _status = LibraryStatusStore.shared

	/// The expiry the pill counts down.
	///
	/// The certificate row on the `Signed` entity records what the user signed *with*, not what
	/// the stored bundle *carries* — they can differ after a re-sign or an import. When the
	/// bundle answers, its own certificate wins; when it cannot, the row is still better than
	/// nothing.
	var certInfo: Date.ExpirationInfo? {
		let status = _status.status(for: app)
		return (status.expiresAt ?? Storage.shared.getCertificate(from: app)?.expiration)?.expirationInfo()
	}
	
	var certRevoked: Bool {
		Storage.shared.getCertificate(from: app)?.revoked == true
	}
	
	var app: AppInfoPresentable
	/// Presented from the context menu; kept local so every cell owns its own explorer.
	@State private var _explorerApp: AnyApp?
	/// Clone sheet target, so "Clone…" can ask for a name and bundle ID.
	@State private var _cloneApp: AnyApp?
	/// LiveContainer / AppNest customization sheet
	@State private var _customizingApp: AnyApp?
    @State private var _companionApp: AnyApp?

	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>
	var isHighlighted: Bool = false
	var onSelectMore: (() -> Void)?
    var isIconTile = false
    var isGridLayout = false
    @State private var confirmDelete = false
    @State private var _isReSigning = false
	
	// MARK: Selections
	private var _isSelected: Bool {
		guard let uuid = app.uuid else { return false }
		return selectedAppUUIDs.contains(uuid)
	}
	
	private func _toggleSelection() {
		guard let uuid = app.uuid else { return }
		NBHaptic.selection()
		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}
	
	// MARK: Body
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active
		
        Group {
            if isIconTile {
                iconTile
            } else {
		HStack(spacing: NBSpacing.row) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(_isSelected ? .accentColor : .secondary)
						.font(.title2)
				}
				.buttonStyle(.borderless)
			}
			
			FRAppIconView(app: app, size: 48)
			
			NBTitleWithSubtitleView(
				title: app.name ?? .localized("Unknown"),
				subtitle: _desc,
				linelimit: 2
			)
			
			if !isEditing {
				_appStoreBadge

				_buttonActions(for: app)
			}
		}
            }
        }
		.padding(isIconTile ? 0 : (isRegular ? NBSpacing.cellPadding : 0))
		.background(_cellBackground(isRegular: isRegular, isEditing: isEditing))
        .confirmationDialog(.localized("Delete app?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(.localized("Delete"), role: .destructive) {
                // A failed delete used to look like a tap that did nothing: the row stayed and
                // nothing was said. Say it instead.
                let uuid = app.uuid
                if Storage.shared.deleteApp(for: app) {
                    if let uuid { selectedAppUUIDs.remove(uuid) }
                } else {
                    Toast.error(
                        .localized("Couldn't delete the app. The stored copy is still in the Library; try again."),
                        duration: .sticky
                    )
                }
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("This removes the stored copy from your Library, not the installed app on your device."))
        }
        .overlay {
            if isIconTile {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
		.contentShape(Rectangle())
		.onAppear { _status.request(app) }
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			} else if let uuid = app.uuid, lockManager.isAppLocked(uuid), !lockManager.isSessionUnlocked(uuid) {
				lockManager.authenticateForApp(uuid: uuid, name: app.name ?? .localized("Application")) { success in
					if success {
						selectedInfoAppPresenting = AnyApp(base: app)
					}
				}
			} else {
				selectedInfoAppPresenting = AnyApp(base: app)
			}
		}
		.modifier(LibraryGridSwipeDelete(enabled: isGridLayout && !isEditing) {
			confirmDelete = true
		})
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			if !isEditing {
				_actions(for: app)
				if let update = updateChecker.hasUpdate(for: app), let url = update.downloadURL {
					Button {
						_ = DownloadManager.shared.startDownload(
							from: url,
							id: update.app.currentUniqueId,
							appName: update.displayName,
							appDescription: update.app.localizedDescription
						)
						Toast.info(.localized("Downloading update..."), systemImage: "arrow.down.circle")
					} label: {
						Label(.localized("Update"), systemImage: "arrow.triangle.2.circlepath")
					}
					.tint(Color.userTint)
				}
				if SigningProfileStore.shared.profile(forBundleID: app.identifier) != nil {
					Button {
						_resignLastOrPresent()
					} label: {
						Label(.localized("Re-sign Last"), systemImage: "signature")
					}
					.tint(.accentColor)
				}
			}
		}
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isEditing {
                ForEach(LibraryAppWorkflowAction.actions(isSigned: app.isSigned), id: \.self) { action in
                    Button {
                        _performWorkflow(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .tint(Color.accentColor)
                }
            }
        }

		.sheet(item: $_explorerApp) { app in
			IPALibraryExplorerView(app: app.base)
		}
		.sheet(item: $_cloneApp) { target in
			AppCloneSheet(app: target.base)
		}
		.sheet(item: $_customizingApp) { item in
			AppCustomizationSheet(app: item.base)
		}
        .sheet(item: $_companionApp) { target in
            NavigationStack {
                CompanionSigningWorkflowView(libraryApp: target)
            }
        }
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)
				Divider()
				Button {
					_customizingApp = AnyApp(base: app)
				} label: {
					Label(.localized("Customize App..."), systemImage: "slider.horizontal.2.square")
				}
				Divider()
				_contextActionsExtra(for: app)
				Divider()
				if let uuid = app.uuid {
					Button {
						lockManager.toggleAppLock(uuid)
					} label: {
						Label(
							lockManager.isAppLocked(uuid) ? .localized("Unlock App") : .localized("Lock with Face ID"),
							systemImage: lockManager.isAppLocked(uuid) ? "lock.open" : "lock"
						)
					}
					Button {
						lockManager.toggleHideApp(uuid)
					} label: {
						Label(
							lockManager.isAppHidden(uuid) ? .localized("Unhide App") : .localized("Hide App"),
							systemImage: lockManager.isAppHidden(uuid) ? "eye" : "eye.slash"
						)
					}
					Divider()
				}
				if let onSelectMore {
					Button(.localized("Select"), systemImage: "checkmark.circle") {
						onSelectMore()
					}
				}
				_actions(for: app)
			}
		}
	}

    private var iconTile: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            FRAppIconView(app: app, size: 64)
            Text(app.name ?? .localized("Application"))
                .font(.headline).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(_desc).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) { _appStoreBadge }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(.localized("Open app details. More actions are available in the context menu.")))
    }

	// Single row background so highlight and card share one shape/radius.
	@ViewBuilder
	private func _cellBackground(isRegular: Bool, isEditing: Bool) -> some View {
        let radius = isIconTile ? Theme.Radius.card : (isRegular ? NBRadius.card : NBRadius.medium)
		let fill: Color = {
			if isHighlighted { return Color.accentColor.opacity(0.3) }
			if _isSelected && isEditing { return Color.accentColor.opacity(0.1) }
            if isIconTile { return Theme.card }
			return isRegular ? Color(.quaternarySystemFill) : .clear
		}()

		RoundedRectangle(cornerRadius: radius, style: .continuous)
			.fill(fill)
			.animation(.easeInOut(duration: 0.3), value: isHighlighted)
	}
	
	/// What the device reports, when it reports anything.
	///
	/// Silent for `.unknown` *and* for a probe that could not answer, on purpose: the library
	/// used to infer "installed" from `canOpenURL`, which said no for every app without a URL
	/// scheme. A badge that can be wrong is worse than no badge.
	@ViewBuilder
	private var _installBadge: some View {
		if case .imported = _status.status(for: app).guest {
			Label(.localized("Imported guest"), systemImage: "shippingbox")
				.font(.caption2.weight(.bold))
				.padding(.horizontal, 7)
				.padding(.vertical, 3)
				.background(Color.accentColor.opacity(0.16), in: Capsule())
				.foregroundStyle(Color.accentColor)
				.accessibilityHint(Text(.localized("Present in the embedded container. Signing and launch have not been verified; this is not a device installation.")))
				.accessibilityIdentifier(A11y.Library.guestBadge)
		}
		let status = _status.status(for: app)
		let badge = InstalledBadge(status)
		HStack(spacing: 3) {
			Image(systemName: badge.systemImage)
				.font(.system(size: 8, weight: .bold))

			if let title = badge.title {
				Text(title)
					.font(.caption2.weight(.bold))
			}
		}
		.padding(.horizontal, badge.title == nil ? 4 : 7)
		.padding(.vertical, 3)
		.background(_badgeTint(badge.tone).opacity(0.16), in: Capsule())
		.foregroundStyle(_badgeTint(badge.tone))
		.accessibilityLabel(Text(badge.accessibilityLabel))
		.accessibilityIdentifier(A11y.Library.installedBadge)
	}

	private func _badgeTint(_ tone: InstalledBadge.Tone) -> Color {
		switch tone {
		case .positive: .green
		case .warning: .orange
		case .neutral: .secondary
		case .active: Color.userTint
		}
	}

	/// Pill when an update is available (from AltSource repositories or App Store).
	@ViewBuilder
	private var _appStoreBadge: some View {
		_installBadge

		if let uuid = app.uuid, lockManager.isAppLocked(uuid) {
			Image(systemName: "lock.fill")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(.secondary)
				.padding(4)
				.background(Color.secondary.opacity(0.12), in: Circle())
				.accessibilityLabel(.localized("Locked"))
				.accessibilityIdentifier(A11y.Library.lockBadge)
		}

		if let update = updateChecker.hasUpdate(for: app) {
			HStack(spacing: 3) {
				Image(systemName: "arrow.triangle.2.circlepath")
					.font(.system(size: 8, weight: .bold))
				Text(String.localized("v%@", arguments: update.sourceVersion ?? ""))
					.font(.caption2.weight(.bold))
			}
			.padding(.horizontal, 7)
			.padding(.vertical, 3)
			.background(Color.userTint.opacity(0.18), in: Capsule())
			.foregroundStyle(Color.userTint)
			.accessibilityIdentifier(A11y.Library.updateBadge)
		} else if
			let info = appStoreTracker.info(for: app.identifier),
			appStoreTracker.hasNewerVersion(than: app) {
			Text(String.localized("v%@", arguments: info.version))
				.font(.caption2.weight(.semibold))
				.padding(.horizontal, 6)
				.padding(.vertical, 3)
				.background(Color.orange.opacity(0.15), in: Capsule())
				.foregroundStyle(.orange)
		}
	}

	private var _desc: String {
        let version = app.version ?? .localized("Unknown version")
        let state: String = app.isSigned ? .localized("Signed copy") : .localized("Imported copy")
        return version + " · " + state
    }
}

// MARK: - Extension: View
extension LibraryCellView {
    // KSign-style install/re-sign/sign-and-install actions, routed through
    // VexSign's checked signing and evidence-based installation pipeline.
    private func _performWorkflow(_ action: LibraryAppWorkflowAction) {
        _withAppAccess {
            switch action {
            case .install: InstallQueue.shared.enqueue(app)
            case .resign:
                Presentation.afterDismiss { selectedSigningAppPresenting = AnyApp(base: app) }
            case .signAndInstall:
                Presentation.afterDismiss { selectedSigningAppPresenting = AnyApp(base: app, installAfterSigning: true) }
            }
        }
    }

    /// Keep every row-level action behind the same app-lock gate as opening its details.
    private func _withAppAccess(_ action: @escaping () -> Void) {
        guard let uuid = app.uuid, lockManager.isAppLocked(uuid), !lockManager.isSessionUnlocked(uuid) else {
            action()
            return
        }
        lockManager.authenticateForApp(uuid: uuid, name: app.name ?? .localized("Application")) { success in
            if success { action() }
        }
    }

    private func _resignLastOrPresent() {
        _withAppAccess {
            guard SigningProfileStore.shared.profile(forBundleID: app.identifier) != nil else {
                Presentation.afterDismiss { selectedSigningAppPresenting = AnyApp(base: app) }
                return
            }
            guard !_isReSigning else { return }
            _isReSigning = true
            Task {
                defer { _isReSigning = false }
                switch await AutoSignManager.shared.sign(app) {
                case .success:
                    Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")
                case .failure(let error):
                    Toast.error(LogRedaction.redact(error.localizedDescription), duration: .sticky)
                }
            }
        }
    }

	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
        Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
            confirmDelete = true
        }
	}
	
	@ViewBuilder
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			Presentation.afterDismiss { selectedInfoAppPresenting = AnyApp(base: app) }
		}

		if let bundleId = app.originalIdentifier ?? app.identifier {
			Button(.localized("View on App Store"), systemImage: "bag") {
				AppStoreHelper.openAppStore(for: bundleId) { result in
					switch result {
					case .success:
						break
					case .failure(let error):
						let alert = UIAlertController(
							title: "App Store Error",
							message: error.localizedDescription,
							preferredStyle: .alert
						)
						alert.addAction(UIAlertAction(title: "OK", style: .default))

						if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
						   let viewController = windowScene.windows.first?.rootViewController {
							viewController.present(alert, animated: true)
						}
					}
				}
			}
		}

		if let bundleId = app.originalIdentifier ?? app.identifier, !bundleId.isEmpty {
			let isIgnored = skippedUpdates.isIgnored(bundleId)
			Button(
				.localized(isIgnored ? "Resume Updates" : "Ignore Updates"),
				systemImage: isIgnored ? "bell" : "bell.slash"
			) {
				SkippedUpdatesManager.shared.toggle(bundleId)
			}
		}
	}
	
	@ViewBuilder
	private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
        Button(.localized("SideStore & LiveContainer"), systemImage: "arrow.triangle.branch") {
            let present = {
                Presentation.afterDismiss { _companionApp = AnyApp(base: app) }
            }
            if let uuid = app.uuid, lockManager.isAppLocked(uuid), !lockManager.isSessionUnlocked(uuid) {
                lockManager.authenticateForApp(uuid: uuid, name: app.name ?? .localized("Application")) { success in
                    if success { present() }
                }
            } else {
                present()
            }
        }

		Button(.localized("Browse Files"), systemImage: "doc.text.magnifyingglass") {
			Presentation.afterDismiss { _explorerApp = AnyApp(base: app) }
		}

		Button(.localized("Duplicate"), systemImage: "plus.square.on.square") {
			Task {
				do {
					_ = try await AppCloner.shared.clone(app: app)
					Toast.success(.localized("App duplicated"), systemImage: "plus.square.on.square")
				} catch {
					Toast.error(error.localizedDescription)
				}
			}
		}

		Button(.localized("Clone…"), systemImage: "doc.on.doc") {
			Presentation.afterDismiss { _cloneApp = AnyApp(base: app) }
		}

		if app.isSigned {
			// "Open" on an app the device says is gone is a dead button; on an app it cannot
			// speak for, it is still the only way in. While an install is being monitored it can
			// only fail, so it waits for the attempt to end.
			let deviceState = _status.status(for: app).installed
			if let id = app.identifier, deviceState != .notInstalled, !deviceState.isTransient {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") {
					AppLauncher.open(id)
				}
			}
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				InstallQueue.shared.enqueue(app)
			}
			Button(.localized("Re-sign"), systemImage: "signature") {
				Presentation.afterDismiss { selectedSigningAppPresenting = AnyApp(base: app) }
			}
			if SigningProfileStore.shared.profile(forBundleID: app.identifier) != nil {
				Button(.localized("Re-sign with Last Settings"), systemImage: "clock.arrow.circlepath") {
					// The same path as the swipe action. This used to discard the result, so a
					// re-sign that failed from this menu said nothing at all.
					_resignLastOrPresent()
				}
			}
			Button(.localized("Export"), systemImage: "square.and.arrow.up") {
				InstallQueue.shared.enqueue(app, exporting: true)
			}
		} else {
            Button(.localized("Sign & Install"), systemImage: "signature") {
                _performWorkflow(.signAndInstall)
            }
			Button(.localized("Sign"), systemImage: "signature") {
				Presentation.afterDismiss { selectedSigningAppPresenting = AnyApp(base: app) }
			}
			Button(.localized("Install Without Signing"), systemImage: "bolt.badge.checkmark") {
				_installWithoutSigning(app)
			}
		}
	}
	
	/// Installs a bundle that is already signed, after verifying it actually is.
	private func _installWithoutSigning(_ app: AppInfoPresentable) {
		do {
			try DirectInstaller.shared.install(app)
		} catch DirectInstaller.DirectInstallError.verificationFailed(let issues) {
			_confirmInstallAnyway(app, issues: issues)
		} catch {
			Toast.error(error.localizedDescription, duration: .sticky)
		}
	}

	/// The only way past a failed signature check: the user is shown the checks that failed,
	/// by name, and decides. Never offered for a bundle with no signature at all.
	private func _confirmInstallAnyway(_ app: AppInfoPresentable, issues: [String]) {
		UIAlertController.showAlertWithCancel(
			title: .localized("Install Anyway?"),
			message: issues.joined(separator: "\n"),
			actions: [
				UIAlertAction(title: .localized("Install Anyway"), style: .destructive) { _ in
					do {
						try DirectInstaller.shared.install(app, allowingIssues: true)
					} catch {
						Toast.error(error.localizedDescription, duration: .sticky)
					}
				}
			]
		)
	}

	@ViewBuilder
	private func _buttonActions(for app: AppInfoPresentable) -> some View {
		// Wrapped in a Group so the trailing modifier applies to both branches.
		Group {
			if app.isSigned {
				HStack(spacing: 6) {
					Button {
						NBHaptic.tap()
						_performWorkflow(.install)
					} label: {
						FRExpirationPillView(
							title: .localized("Install"),
							revoked: certRevoked,
							expiration: certInfo
						)
						.accessibilityIdentifier(A11y.Install.start)
					}
					.accessibilityLabel(Text(.localized("Install")))

					_quickAction(.localized("Re-sign"), systemImage: "arrow.triangle.2.circlepath", identifier: A11y.Library.resign) {
						NBHaptic.tap()
						_resignLastOrPresent()
					}
					.disabled(_isReSigning)

					_quickAction(.localized("Export"), systemImage: "square.and.arrow.up", identifier: A11y.Library.export) {
						NBHaptic.tap()
						_withAppAccess { InstallQueue.shared.enqueue(app, exporting: true) }
					}
				}
			} else {
				Button {
					NBHaptic.tap()
					_performWorkflow(.resign)
				} label: {
					FRExpirationPillView(
						title: .localized("Sign"),
						revoked: false,
						expiration: nil
					)
				}
				.accessibilityLabel(Text(.localized("Sign")))
			}
		}
		.buttonStyle(.borderless)
	}

	private func _quickAction(
		_ title: String,
		systemImage: String,
		identifier: String,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: 15, weight: .semibold))
				.frame(width: 36, height: 36)
		}
		.buttonStyle(.bordered)
		.tint(Color.accentColor)
		.accessibilityLabel(Text(title))
		.accessibilityIdentifier(identifier)
	}
}
