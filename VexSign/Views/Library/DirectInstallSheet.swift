//
//  DirectInstallSheet.swift
//  VexSign
//
//  One-tap download, auto-signing, and direct installation from URL.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct DirectInstallSheet: View {
	@Environment(\.dismiss) private var dismiss

	enum InstallMode: String, CaseIterable, Identifiable {
		case signAndInstall
		case installWithoutSigning

		var id: String { rawValue }
		var title: String {
			switch self {
			case .signAndInstall: .localized("Sign & Install")
			case .installWithoutSigning: .localized("Install Without Signing")
			}
		}
	}

	@State var urlString: String = ""
	@State var selectedMode: InstallMode = .signAndInstall
	@State private var isProcessing = false
	@State private var statusMessage = ""

	var body: some View {
		NBNavigationView(.localized("Direct Install"), displayMode: .inline) {
			Form {
				Section {
					TextField(.localized("https://example.com/app.ipa"), text: $urlString)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.disabled(isProcessing)

					Picker(.localized("Installation Mode"), selection: $selectedMode) {
						ForEach(InstallMode.allCases) { mode in
							Text(mode.title).tag(mode)
						}
					}
					.disabled(isProcessing)
				} header: {
					Text(.localized("Package URL"))
				} footer: {
					Text(.localized("Directly download, prepare, and install the package on your device in one step."))
				}

				if isProcessing {
					Section {
						HStack {
							ProgressView()
								.padding(.trailing, 6)
							Text(statusMessage)
								.font(.subheadline)
								.foregroundColor(.secondary)
						}
					}
				} else {
					Section {
						Button {
							_startDirectInstall()
						} label: {
							HStack {
								Spacer()
								Label(.localized("Start Direct Install"), systemImage: "arrow.down.app.fill")
									.bold()
								Spacer()
							}
						}
						.disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
			}
		}
	}

	private func _startDirectInstall() {
		let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let targetURL = URL(string: trimmed), targetURL.scheme != nil else {
			Toast.error(.localized("Please enter a valid URL."))
			return
		}

        let preparesGuest: Bool
        do {
            preparesGuest = try SigningModeManager.shared.pipeline() == .containerized
        } catch {
            Toast.error(error.localizedDescription, duration: .sticky)
            return
        }

		guard selectedMode == .installWithoutSigning || preparesGuest else {
			// Normal path: the download manager imports it and AutoSign signs + queues it.
			_ = DownloadManager.shared.startDownload(
				from: targetURL,
				appName: targetURL.deletingPathExtension().lastPathComponent
			)
			Toast.success(.localized("Download queued for signing & installation"), systemImage: "arrow.down.app")
			dismiss()
			return
		}

		// Fetch and import as-is. Direct installs preserve an existing identity; container guests
        // are signed by the host during its confirmed import flow. Zsign is not invoked here.
		isProcessing = true
		statusMessage = .localized("Downloading…")

		Task { await _downloadAndInstall(from: targetURL) }
	}

	@MainActor
	private func _downloadAndInstall(from targetURL: URL) async {
		defer { isProcessing = false }

        let workLease: AppOperationRegistry.Lease
        do { workLease = try AppOperationRegistry.shared.acquireTemporaryWork() }
        catch {
            Toast.error(error.localizedDescription, duration: .sticky)
            return
        }
        defer { withExtendedLifetime(workLease) {} }
		let downloaded: URL
		do {
			let (tempURL, _) = try await URLSession.shared.download(from: targetURL)

			// The importer reads the name and type from the file, so keep the extension.
			let destination = FileManager.default
				.uniqueTemporaryDirectory("DirectInstall")
				.appendingPathComponent(targetURL.lastPathComponent.isEmpty ? "package.ipa" : targetURL.lastPathComponent)
			try FileManager.default.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
			try FileManager.default.moveItem(at: tempURL, to: destination)
			downloaded = destination
		} catch {
			Toast.error(error.localizedDescription, duration: .sticky)
			return
		}

		statusMessage = .localized("Importing…")

		let outcome: (app: AppInfoPresentable?, error: Error?) = await withCheckedContinuation { continuation in
			FR.handlePackageFile(downloaded) { result in
				switch result {
				case .success(let app): continuation.resume(returning: (app, nil))
				case .failure(let error): continuation.resume(returning: (nil, error))
				}
			}
		}

		guard let imported = outcome.app else {
			Toast.error(
				outcome.error?.localizedDescription ?? .localized("Could not import that package."),
				duration: .sticky
			)
			return
		}

        let preparesGuest: Bool
        do { preparesGuest = try SigningModeManager.shared.pipeline(for: imported) == .containerized }
        catch { preparesGuest = false } // DirectInstaller immediately presents the same route error.
        statusMessage = preparesGuest ? .localized("Preparing guest import…") : .localized("Verifying signature…")

		do {
			try DirectInstaller.shared.install(imported)
            Toast.success(
                preparesGuest ? .localized("Guest import queued…") : .localized("Installing without signing…"),
                systemImage: preparesGuest ? "shippingbox" : "bolt.badge.checkmark"
            )
			dismiss()
		} catch DirectInstaller.DirectInstallError.verificationFailed(let issues) {
			// Same rule as the library: name the failed checks and let the user decide.
			UIAlertController.showAlertWithCancel(
				title: .localized("Install Anyway?"),
				message: issues.joined(separator: "\n"),
				actions: [
					UIAlertAction(title: .localized("Install Anyway"), style: .destructive) { _ in
						do {
							try DirectInstaller.shared.install(imported, allowingIssues: true)
							Toast.success(.localized("Installing without signing…"), systemImage: "bolt.badge.checkmark")
							dismiss()
						} catch {
							Toast.error(error.localizedDescription, duration: .sticky)
						}
					}
				]
			)
		} catch {
			Toast.error(error.localizedDescription, duration: .sticky)
		}
	}
}
