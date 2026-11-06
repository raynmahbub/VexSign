//
//  LibraryStatusStore.swift
//  VexSign
//
//  What the library is allowed to claim about an app.
//
//  Two facts per library entry, both of which used to be guesses:
//
//    * whether the app is on the device, and in which version — from `InstalledAppProbe`, the
//      same evidence uses to confirm an install, never from `canOpenURL(`scheme://`)`
//      (which answers "no" for every app without a URL scheme, and "yes" long after the app
//      was deleted);
//    * which certificate the stored bundle carries, and when it expires — from the bundle's own
//      CMS signature, not from the `CertificatePair` row it happens to point at.
//
//  Both are relatively expensive (a private ObjC lookup per identifier, a mapped read of an
//  executable per bundle), so reads are coalesced, throttled per app, and published through one
//  observable dictionary the list can diff against. A read that cannot answer leaves `.unknown`
//  and the UI says nothing: a probe that cannot see must not be allowed to claim.
//

import Foundation
import SwiftUI
import NimbleExtensions

// MARK: - Status

/// Everything the library knows about one stored app.
struct LibraryAppStatus: Equatable, Sendable {
	/// The identifier the probe answered for — what invalidation matches on.
	var bundleIdentifier: String?
	var installed: InstalledState = .unknown
	/// Independent host inventory, never substituted for the device probe.
	var guest: ContainerGuestState = .unavailable
	/// nil until the stored bundle's signature has been read; not needed for unsigned apps.
	var signature: BundleSignature.State?
	var updatedAt: Date = .distantPast

	/// The expiry to show instead of the certificate row's date, when the bundle answered.
	var expiresAt: Date? { signature?.expiresAt }

	var isKnown: Bool { updatedAt != .distantPast }
}

// MARK: - Badge

/// The row badge for an install state. `nil` when there is nothing worth saying.
struct InstalledBadge: Equatable {
	enum Tone: Equatable {
		case positive
		case warning
		case neutral
	}

	let title: String?
	let systemImage: String
	let tone: Tone

	init?(_ state: InstalledState) {
		switch state {
		case .installed:
			title = .localized("Installed")
			systemImage = "checkmark.circle.fill"
			tone = .positive
		case .installedOtherVersion(let version):
			title = version.map { String.localized("v%@", arguments: $0) } ?? .localized("Other version")
			systemImage = "iphone"
			tone = .warning
		case .notInstalled:
			title = .localized("Not installed")
			systemImage = "iphone.slash"
			tone = .neutral
		case .unknown:
			// The probe could not answer. Saying anything here would be the guess removes.
			return nil
		}
	}

	var accessibilityLabel: String {
		guard let title else { return .localized("Installed on this device") }
		return title
	}
}

// MARK: - Rows

extension LibraryAppStatus {
	/// The info sheet's installation and signature rows.
	///
	/// Pure, so the wording can be tested without a device: this is where "unknown" has to stay
	/// `Unknown` instead of quietly becoming "not installed".
	func signatureRows(certificateRow: String? = nil) -> [(title: String, value: String)] {
		var rows: [(title: String, value: String)] = [(.localized("On this device"), installed.title)]

		switch signature {
		case .none:
			break
		case .noCodeSignature:
			rows.append((.localized("Signature"), .localized("Not signed.")))
		case .noCertificates:
			rows.append((.localized("Signature"), .localized("Ad-hoc signed — the signature carries no certificate.")))
		case .unreadable(let reason):
			rows.append((.localized("Signature"), reason))
		case .certificates:
			if let signer = signature?.signer {
				rows.append((.localized("Signed by"), signer.displayName))
				if let serial = signer.serial {
					rows.append((.localized("Serial"), serial))
				}
				rows.append((.localized("Fingerprint"), signer.shortFingerprint))
			}
			if let expiresAt = expiresAt {
				rows.append((.localized("Expires"), expiresAt.expirationInfo().formatted))
			}
		}

		if let certificateRow {
			rows.append((.localized("Certificate"), certificateRow))
		}

		return rows
	}
}

// MARK: - Store

@MainActor
final class LibraryStatusStore: ObservableObject {
	static let shared = LibraryStatusStore()

	/// A snapshot of what a background read needs, taken on the main actor so no Core Data
	/// object ever leaves it.
	struct Request: Equatable, Sendable {
		let uuid: String
		let bundleIdentifier: String?
		let expectedVersion: String?
		let bundleURL: URL?
		let isSigned: Bool
	}

	@Published private(set) var statuses: [String: LibraryAppStatus] = [:]

	private let probe: InstalledAppProbing
	private let readGuest: @Sendable (String) -> ContainerGuestState
	private let readSignature: @Sendable (URL) -> BundleSignature.State
	private var lastAttempt: [String: Date] = [:]
	private var inflight: Set<String> = []
	private var pending: [Request] = []
	/// Keep snapshots (never managed objects) so invalidation can re-read visible rows.
	private var knownRequests: [String: Request] = [:]
	private var generation = 0
	/// Bumped by every new read, so a read already running when the device's answer
	/// changed cannot publish the answer it was about to.
	private var epoch: [String: Int] = [:]

	/// How long a read is trusted before the same app is read again.
	/// How long a cached answer stays good. `nonisolated` because it is a constant:
	/// two methods that read it carry it as a default argument, which is evaluated
	/// outside the actor.
	nonisolated static let defaultMaxAge: TimeInterval = 30

	init(
		probe: InstalledAppProbing = InstalledAppProbe(),
		readGuest: @escaping @Sendable (String) -> ContainerGuestState = { EmbeddedContainerRuntime.guestState(for: $0) },
		readSignature: @escaping @Sendable (URL) -> BundleSignature.State = { BundleSignature.read(bundleAt: $0) }
	) {
		self.probe = probe
		self.readGuest = readGuest
		self.readSignature = readSignature
	}

	// MARK: Reading

	func status(for app: AppInfoPresentable) -> LibraryAppStatus {
		guard let uuid = app.uuid else { return LibraryAppStatus() }
		return statuses[uuid] ?? LibraryAppStatus()
	}

	/// Requests a read for one app, unless one is already in flight or the cached answer is
	/// younger than `maxAge`. Cheap enough to call from every row's `onAppear`.
	func request(_ app: AppInfoPresentable, maxAge: TimeInterval = defaultMaxAge, force: Bool = false) {
		guard let request = self.request(for: app) else { return }
		self.request(request, maxAge: maxAge, force: force)
	}

	/// Snapshot entry point also lets tests exercise refreshes without a persistent store.
	func request(_ request: Request, maxAge: TimeInterval = defaultMaxAge, force: Bool = false) {
		let changed = knownRequests[request.uuid] != request
		knownRequests[request.uuid] = request
		guard force || changed || _needsRead(request.uuid, maxAge: maxAge) else { return }

		// A forced refresh may supersede an in-flight read. Only the newest read owns
		// the right to publish a status or clear the in-flight marker.
		epoch[request.uuid, default: 0] += 1
		lastAttempt[request.uuid] = Date()
		inflight.insert(request.uuid)
		pending.append(request)
		_flush()
	}

	func refresh(_ apps: [AppInfoPresentable], force: Bool = false, maxAge: TimeInterval = defaultMaxAge) {
		for app in apps {
			request(app, maxAge: maxAge, force: force)
		}
	}

	/// Forgets what was known about every library app carrying this identifier.
	///
	/// Called when an install finishes: the probe's answer just changed, and a cached answer is
	/// the one thing that would make the library claim the wrong version.
	func invalidate(bundleIdentifier: String) {
		let affected = knownRequests.values.filter { $0.bundleIdentifier == bundleIdentifier }
		for request in affected {
			statuses.removeValue(forKey: request.uuid)
			lastAttempt.removeValue(forKey: request.uuid)
			// Do not wait for onAppear: the row may remain on screen after installation.
			self.request(request, force: true)
		}
	}

	func invalidateAll() {
		// Prevent a pre-reset read from repopulating the store or clearing a newer read.
		generation += 1
		lastAttempt.removeAll()
		statuses.removeAll()
		knownRequests.removeAll()
		inflight.removeAll()
		pending.removeAll()
		epoch.removeAll()
	}

	// MARK: Snapshot

	private func request(for app: AppInfoPresentable) -> Request? {
		guard let uuid = app.uuid else { return nil }
		return Request(
			uuid: uuid,
			bundleIdentifier: app.identifier,
			expectedVersion: app.version,
			bundleURL: app.isSigned ? Storage.shared.getAppDirectory(for: app) : nil,
			isSigned: app.isSigned
		)
	}

	private func _needsRead(_ uuid: String, maxAge: TimeInterval) -> Bool {
		guard !inflight.contains(uuid) else { return false }
		guard let last = lastAttempt[uuid] else { return true }
		return Date().timeIntervalSince(last) >= maxAge
	}

	private func _flush() {
		guard !pending.isEmpty else { return }
		let batch = pending
		pending.removeAll()

		let probe = self.probe
		let generation = self.generation
		let read = self.readSignature
		let readGuest = self.readGuest
		let epochs = batch.reduce(into: [String: Int]()) { $0[$1.uuid] = epoch[$1.uuid] ?? 0 }

		Task.detached(priority: .utility) { [weak self] in
			let store = self
			var collected: [(String, LibraryAppStatus)] = []
			collected.reserveCapacity(batch.count)

			for request in batch {
				collected.append((request.uuid, Self.resolve(request, probe: probe, readSignature: read, readGuest: readGuest)))
			}
			let results = collected

			await MainActor.run {
				guard let store, store.generation == generation else { return }
				for (uuid, status) in results {
					// An install finished while this read was running: its answer is the newer
					// one, so drop this.
					guard (store.epoch[uuid] ?? 0) == (epochs[uuid] ?? 0) else { continue }
					store.inflight.remove(uuid)
					store.statuses[uuid] = status
				}
			}
		}
	}

	// MARK: Resolve

	/// The whole read, as a pure function of the request — which is what the tests exercise.
	nonisolated static func resolve(
		_ request: Request,
		probe: InstalledAppProbing,
		readSignature: @Sendable (URL) -> BundleSignature.State,
		readGuest: @Sendable (String) -> ContainerGuestState = { _ in .unavailable }
	) -> LibraryAppStatus {
		var status = LibraryAppStatus()
		status.bundleIdentifier = request.bundleIdentifier

		if let identifier = request.bundleIdentifier, !identifier.isEmpty {
			status.guest = readGuest(identifier)
			let candidate = probe.installedApp(for: identifier)
			status.installed = InstalledState.derive(
				from: candidate?.bundleIdentifier == identifier ? candidate : nil,
				expecting: request.expectedVersion
			)
		}

		if request.isSigned, let url = request.bundleURL {
			status.signature = readSignature(url)
		}

		status.updatedAt = Date()
		return status
	}
}
