//
//  DeviceAppRemoval.swift
//  VexSign
//
//  Removing an app from the paired device, as a checked sequence rather than a call:
//
//      refuse what must not be removed → ask the device → read the device back
//
//  The result says what is known. A device that accepted the request and can no longer
//  be read is "requested", not "removed": the same rule the install path follows.
//
//  The transport is injected, so everything here except the one line that reaches the
//  device is tested without one.
//

import Foundation
import IDeviceSwift
import NimbleExtensions

// MARK: - Transport

protocol DeviceAppUninstalling: Sendable {
	/// Asks the paired device to remove one app. Throws when the device refuses or the
	/// session cannot be opened.
	func uninstall(bundleIdentifier: String) async throws
}

/// The installation service of the pairing session.
struct PairedDeviceUninstaller: DeviceAppUninstalling {
	func uninstall(bundleIdentifier: String) async throws {
		try await InstallationAppProxy.deleteApp(for: bundleIdentifier)
	}
}

// MARK: - Rules

enum DeviceAppRemoval {
	/// Why a removal is not attempted.
	enum Refusal: LocalizedError, Equatable {
		/// Empty, or not shaped like a bundle identifier.
		case invalidIdentifier
		/// VexSign itself. Removing the app that holds the session ends the session mid-request.
		case ownApp
		/// An Apple system app.
		case systemApp

		var errorDescription: String? {
			switch self {
			case .invalidIdentifier:
				String.localized("This app has no usable bundle identifier, so the device cannot be asked to remove it.")
			case .ownApp:
				String.localized("VexSign cannot remove itself. Delete it from the Home Screen instead.")
			case .systemApp:
				String.localized("VexSign does not remove Apple system apps.")
			}
		}
	}

	/// What happened, on evidence.
	enum Outcome: Equatable {
		/// The device accepted the request and afterwards reports the app as absent.
		case removed
		/// The device accepted the request, and its state could not be read back.
		case requested
		/// The device accepted the request and still reports the app as installed.
		case stillInstalled
		/// The device refused, or the session could not be opened. Nothing was removed.
		case failed(String)
		case refused(Refusal)

		var title: String {
			switch self {
			case .removed: .localized("Removed from the device")
			case .requested: .localized("Removal requested")
			case .stillInstalled: .localized("Still installed")
			case .failed: .localized("Removal failed")
			case .refused: .localized("Not removed")
			}
		}

		var message: String {
			switch self {
			case .removed:
				.localized("The device no longer reports this app. The copy in your Library is untouched.")
			case .requested:
				.localized("The device accepted the request, but VexSign could not read back whether the app is gone. Check the Home Screen.")
			case .stillInstalled:
				.localized("The device accepted the request but still reports the app as installed. Check the Home Screen, or try again.")
			case .failed(let reason):
				.localized("The device did not remove the app: %@", arguments: reason)
			case .refused(let refusal):
				refusal.errorDescription ?? ""
			}
		}
	}

	/// Whether `bundleIdentifier` may be removed at all.
	static func refusal(for bundleIdentifier: String, ownBundleIdentifier: String?) -> Refusal? {
		let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
		// ASCII letters, digits, dot, hyphen and underscore: what a bundle identifier is made of.
		let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
		guard !identifier.isEmpty, identifier.count <= 255, identifier.contains("."),
		      identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
			return .invalidIdentifier
		}
		if let own = ownBundleIdentifier, identifier.caseInsensitiveCompare(own) == .orderedSame {
			return .ownApp
		}
		if identifier.lowercased().hasPrefix("com.apple.") { return .systemApp }
		return nil
	}

	/// Reads the device's answer after an accepted request.
	///
	/// - Parameter after: the probe's reading; `nil` when the device could not be read. A
	///   placeholder is not a reading either way.
	static func outcome(after: InstalledApp?) -> Outcome {
		guard let after, !after.isPlaceholder else { return .requested }
		return after.isInstalled ? .stillInstalled : .removed
	}

	/// The whole sequence.
	///
	/// - Parameters:
	///   - probe: reads the device back. Called off the main thread, after `settle`.
	///   - settle: how long to give the device before reading it back.
	static func remove(
		bundleIdentifier: String,
		ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
		uninstaller: DeviceAppUninstalling = PairedDeviceUninstaller(),
		probe: InstalledAppProbing = InstalledAppProbe(),
		settle: Duration = .seconds(2)
	) async -> Outcome {
		if let refusal = refusal(for: bundleIdentifier, ownBundleIdentifier: ownBundleIdentifier) {
			return .refused(refusal)
		}
		let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

		do {
			try await uninstaller.uninstall(bundleIdentifier: identifier)
		} catch {
			FileLogger.error("Device removal failed for \(identifier): \(error.localizedDescription)", category: "install")
			return .failed(error.localizedDescription)
		}

		do {
			try await Task.sleep(for: settle)
		} catch {
			// Cancelled while waiting: the request was already accepted, so say exactly that.
			return .requested
		}
		let reading = await Task.detached(priority: .utility) {
			probe.installedApp(for: identifier)
		}.value
		let result = outcome(after: reading)
		FileLogger.log("Device removal for \(identifier): \(result.title)", category: "install")
		return result
	}
}
