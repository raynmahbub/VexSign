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
//  Both are relatively expensive (private LaunchServices lookups per identifier, a mapped read
//  of an executable per bundle), so reads are coalesced, throttled per app, and published through
//  one observable dictionary the list can diff against. A read that cannot answer leaves
//  `.unknown`; the Library says "Unknown" rather than guessing installed or not installed.
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
    /// A projection of the currently registered task, not an inventory verdict.
    var installationTaskPhase: UnifiedTaskPhase?
	/// Independent host inventory, never substituted for the device probe.
	var guest: ContainerGuestState = .unavailable
	/// nil until the stored bundle's signature has been read; not needed for unsigned apps.
	var signature: BundleSignature.State?
	var updatedAt: Date = .distantPast

	/// The expiry to show instead of the certificate row's date, when the bundle answered.
	var expiresAt: Date? { signature?.expiresAt }

	var isKnown: Bool { updatedAt != .distantPast }

    var installationTitle: String {
        guard installed == .installing else { return installed.title }
        switch installationTaskPhase {
        case .preparingInstallation: return .localized("Preparing installation")
        case .waitingForIOS: return .localized("Waiting for iOS confirmation")
        case .verifying: return .localized("Verifying installation")
        default: return installed.title
        }
    }
}

// MARK: - Installation lifecycle

/// One installation attempt that is currently being monitored.
///
/// Registered by `InstallQueue` when it actually starts an installer — not when an install is
/// requested, and not by a signing success — and cleared when that attempt reaches a terminal
/// outcome. While it is registered, every library record carrying the identifier publishes
/// `.installing`, and no device reading may replace that.
///
/// Keyed by identifier *and* attempt, so a completion belonging to an abandoned attempt can
/// neither clear nor rewrite the state of the attempt now in flight.
struct InstallationAttempt: Equatable, Sendable {
	/// The exact bundle identifier being installed.
	let identifier: String
	/// Unique per start. The queue builds it from its run generation and task record.
	let attemptID: String
	/// The unified-task record monitoring this attempt, when the queue created one.
	let taskID: String?
	let startedAt: Date
    var taskPhase: UnifiedTaskPhase?
}

// MARK: - Badge

/// The row badge for an install state. `nil` when there is nothing worth saying.
struct InstalledBadge: Equatable {
	enum Tone: Equatable {
		case positive
		case warning
		case neutral
		/// Work in flight. Not a verdict, so it is neither green nor a caution.
		case active
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
		case .installing:
			// An attempt is being monitored. Says so instead of the negative a mid-install
			// probe reading produces, and instead of claiming it worked.
			title = .localized("Installing")
			systemImage = "arrow.triangle.2.circlepath"
			tone = .active
		case .unknown:
			// Callers without a read lifecycle keep the old nil-on-unknown behavior.
			return nil
		}
	}

	/// Displays an explicit checking/unknown state in the Library without turning
	/// an unavailable device probe into a false installed/not-installed claim.
	init(_ status: LibraryAppStatus) {
        if status.installed == .installing, status.installationTaskPhase != nil {
            title = status.installationTitle
            switch status.installationTaskPhase {
            case .waitingForIOS: systemImage = "clock"
            case .verifying: systemImage = "magnifyingglass"
            default: systemImage = "arrow.triangle.2.circlepath"
            }
            tone = .active
            return
        }
		if let known = InstalledBadge(status.installed) {
			self = known
		} else {
			title = status.isKnown ? .localized("Unknown") : .localized("Checking…")
			systemImage = status.isKnown ? "questionmark.circle" : "hourglass"
			tone = .neutral
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
		var rows: [(title: String, value: String)] = [(.localized("On this device"), installationTitle)]

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
    // A just-confirmed install is stronger evidence than an immediately stale or
    // restricted inventory lookup. Keep this handoff short-lived, never persistent.
    private var confirmations: [String: (app: InstalledApp, date: Date)] = [:]
	/// Bumped by every new read, so a read already running when the device's answer
	/// changed cannot publish the answer it was about to.
	private var epoch: [String: Int] = [:]
	/// Installation attempts being monitored, by bundle identifier. One attempt per identifier:
	/// the queue runs one installer at a time, and a second start for the same bundle replaces
	/// the first rather than racing it.
	private var attempts: [String: InstallationAttempt] = [:]

	/// How long a read is trusted before the same app is read again.
	/// How long a cached answer stays good. `nonisolated` because it is a constant:
	/// two methods that read it carry it as a default argument, which is evaluated
	/// outside the actor.
	nonisolated static let defaultMaxAge: TimeInterval = 30

	/// How long an installation attempt is believed before it is treated as abandoned.
	///
	/// Every real path ends the attempt explicitly — success, failure, cancellation, skip, queue
	/// reset — and `InstallConfirmation` bounds the monitoring itself to a couple of minutes.
	/// This backstop only stops a registration whose owner died from pinning a row on
	/// "Installing" forever, so it is deliberately far longer than any real attempt.
	nonisolated static let attemptTimeout: TimeInterval = 900

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
        var seeded = applyingConfirmation(to: statuses[request.uuid] ?? LibraryAppStatus(), request: request)
        let stored = statuses[request.uuid]
        seeded = applyingActiveInstallation(to: seeded, request: request)
        if seeded.installed != .unknown {
            statuses[request.uuid] = seeded
        } else if stored?.installed.isTransient == true {
            // An attempt that expired with nobody left to end it: drop the transient state it
            // published rather than leave a row claiming "Installing" forever.
            statuses[request.uuid] = seeded
        }
		// An attempt in flight is the authoritative answer for this identifier, and a forced
		// refresh — including the one that runs when the user returns from iOS's install prompt —
		// must not replace it with a device reading taken mid-install. The read this skips is
		// requested again by `endInstallation`, so nothing is left unread.
		guard !isInstalling(request.bundleIdentifier) else { return }
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

    func recordConfirmedInstallation(bundleIdentifier: String, version: String?, now: Date = Date()) {
        guard !bundleIdentifier.isEmpty else { return }
        confirmations = confirmations.filter { now.timeIntervalSince($0.value.date) >= 0 && now.timeIntervalSince($0.value.date) <= Self.defaultMaxAge }
        confirmations[bundleIdentifier] = (InstalledApp(bundleIdentifier: bundleIdentifier, isInstalled: true, version: version), now)
        for request in Array(knownRequests.values) where request.bundleIdentifier == bundleIdentifier {
            var status = statuses[request.uuid] ?? LibraryAppStatus()
            status.bundleIdentifier = bundleIdentifier
            status.installed = .unknown
            status = applyingConfirmation(to: status, request: request, now: now)
            // The receipt is stored either way, but publishing it is the attempt's call. A
            // confirmation is normally recorded microseconds before the queue ends the attempt it
            // belongs to, so this only changes what a *stale* installer can do: one that finishes
            // late cannot rewrite the row of the attempt now in flight. `endInstallation` applies
            // the receipt the moment monitoring stops, so nothing is delayed for the user.
            statuses[request.uuid] = applyingActiveInstallation(to: status, request: request, now: now)
            self.request(request, force: true)
        }
    }

    private func applyingConfirmation(to status: LibraryAppStatus, request: Request, now: Date = Date()) -> LibraryAppStatus {
        guard status.installed == .unknown, let identifier = request.bundleIdentifier,
              let receipt = confirmations[identifier],
              now.timeIntervalSince(receipt.date) >= 0,
              now.timeIntervalSince(receipt.date) <= Self.defaultMaxAge else { return status }
        var updated = status
        updated.bundleIdentifier = identifier
        updated.installed = InstalledState.derive(from: receipt.app, expecting: request.expectedVersion)
        updated.updatedAt = now
        return updated
    }

    /// Refresh rows that remain mounted when returning from the iOS install prompt.
    func refreshKnown() {
        for request in Array(knownRequests.values) { self.request(request, force: true) }
    }

    // MARK: Installation lifecycle

    /// Registers an in-flight installation and publishes `Installing` to every library record
    /// carrying this identifier, including several rows that share one bundle identifier.
    ///
    /// Called by `InstallQueue` when it starts an installer. Registering an attempt says an
    /// install is being monitored — it never says the app is installed.
    @discardableResult
    func beginInstallation(
        identifier: String,
        attemptID: String,
        taskID: String? = nil,
        initialPhase: UnifiedTaskPhase? = nil,
        now: Date = Date()
    ) -> InstallationAttempt? {
        guard !identifier.isEmpty, !attemptID.isEmpty else { return nil }
        let attempt = InstallationAttempt(
            identifier: identifier, attemptID: attemptID, taskID: taskID, startedAt: now,
            taskPhase: initialPhase
        )
        attempts[identifier] = attempt
        for request in Array(knownRequests.values) where request.bundleIdentifier == identifier {
            let status = statuses[request.uuid] ?? LibraryAppStatus()
            statuses[request.uuid] = applyingActiveInstallation(to: status, request: request, now: now)
        }
        return attempt
    }

    /// Publish the current task projection only to the attempt that owns this identifier.
    func updateInstallationPhase(identifier: String, attemptID: String, phase: UnifiedTaskPhase) {
        guard var attempt = attempts[identifier], attempt.attemptID == attemptID else { return }
        attempt.taskPhase = phase
        attempts[identifier] = attempt
        for request in Array(knownRequests.values) where request.bundleIdentifier == identifier {
            let status = statuses[request.uuid] ?? LibraryAppStatus()
            statuses[request.uuid] = applyingActiveInstallation(to: status, request: request)
        }
    }

    /// Ends an attempt and lets the real evidence decide what the row shows next.
    ///
    /// A completion whose attempt ID is no longer the registered one is ignored, so an abandoned
    /// attempt cannot clear — or rewrite the state of — the attempt now in flight. Returns false
    /// for that stale call.
    @discardableResult
    func endInstallation(identifier: String, attemptID: String, now: Date = Date()) -> Bool {
        guard let active = attempts[identifier], active.attemptID == attemptID else { return false }
        attempts.removeValue(forKey: identifier)
        for request in Array(knownRequests.values) where request.bundleIdentifier == identifier {
            var status = statuses[request.uuid] ?? LibraryAppStatus()
            // Drop the transient state only. A confirmation receipt recorded by the installer
            // becomes the answer if the device proved the install; otherwise the row goes back
            // to being read, and reads `Unknown` rather than a guessed negative until it is.
            if status.installed.isTransient { status.installed = .unknown }
            status.installationTaskPhase = nil
            status = applyingConfirmation(to: status, request: request, now: now)
            statuses[request.uuid] = status
            self.request(request, force: true)
        }
        return true
    }

    /// Forgets every registered attempt — a queue reset, or a full store reset.
    func resetInstallations() {
        attempts.removeAll()
    }

    /// The attempt being monitored for this identifier, pruning one that outlived its bound.
    /// `now` is threaded through every hop, including the default.
    ///
    /// `isInstalling` used to call `activeInstallation(identifier:)` and fall back to this
    /// method's `Date()` default, silently ignoring the caller's clock. That made the pair
    /// inconsistent: a caller reasoning about a specific instant got the same answer as one asking
    /// about the present, so `activeInstallation(…, now: startedAt + attemptTimeout)` could return
    /// an attempt while `isInstalling` — asked about the same instant — said no. The regression
    /// test `testAnAttemptIsBelievedForExactlyItsBound` fails on the real clock for exactly that
    /// reason: the attempt is anchored at epoch 2,000,000, which is decades stale.
    func activeInstallation(identifier: String, now: Date = Date()) -> InstallationAttempt? {
        guard let attempt = attempts[identifier] else { return nil }
        guard now.timeIntervalSince(attempt.startedAt) <= Self.attemptTimeout else {
            attempts.removeValue(forKey: identifier)
            return nil
        }
        return attempt
    }

    /// Whether an installation attempt is in flight for this identifier.
    ///
    /// Also what gates actions that make no sense mid-install, and what keeps a forced refresh
    /// from publishing a device reading taken while iOS is still writing the bundle.
    ///
    /// `now` is forwarded rather than dropped. Without it this method answered a different
    /// question from the `activeInstallation(identifier:now:)` it delegates to: a caller passing a
    /// synthetic clock — every test that time-travels — got the real-time answer here and the
    /// synthetic one there, so the two accessors could disagree about the same instant. The
    /// regression test `testAnAttemptIsBelievedForExactlyItsBound` is the case that exposed it.
    func isInstalling(_ identifier: String?, now: Date = Date()) -> Bool {
        guard let identifier, !identifier.isEmpty else { return false }
        return activeInstallation(identifier: identifier, now: now) != nil
    }

    /// Overlays the transient state onto a status. The last word before publishing, so a probe
    /// result that arrives mid-install cannot replace `Installing` with a negative — and so a
    /// transient state whose attempt has expired does not outlive it.
    private func applyingActiveInstallation(
        to status: LibraryAppStatus,
        request: Request,
        now: Date = Date()
    ) -> LibraryAppStatus {
        guard let identifier = request.bundleIdentifier else { return status }
        guard let attempt = activeInstallation(identifier: identifier, now: now) else {
            guard status.installed.isTransient else { return status }
            var cleared = status
            cleared.installed = .unknown
            cleared.installationTaskPhase = nil
            return cleared
        }
        var updated = status
        updated.bundleIdentifier = identifier
        updated.installed = .installing
        updated.installationTaskPhase = attempt.taskPhase
        // Keep `isKnown` honest without claiming a device read happened.
        updated.updatedAt = max(updated.updatedAt, attempt.startedAt)
        return updated
    }

	func invalidateAll() {
		// Prevent a pre-reset read from repopulating the store or clearing a newer read.
		generation += 1
        // Forgetting everything the library knows includes the transient installation state;
        // a queue reset ends its attempts through `resetInstallations()` as well.
        attempts.removeAll()
        confirmations.removeAll()
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
                let candidate: InstalledApp?
                if let identifier = request.bundleIdentifier, !identifier.isEmpty {
                    candidate = await probe.installedAppWithTimeout(for: identifier)
                } else {
                    candidate = nil
                }
				collected.append((request.uuid, Self.resolve(request, installedApp: candidate,
                    readSignature: read, readGuest: readGuest)))
			}
			let results = collected

			await MainActor.run {
				guard let store, store.generation == generation else { return }
				for (uuid, status) in results {
					// An install finished while this read was running: its answer is the newer
					// one, so drop this.
					guard (store.epoch[uuid] ?? 0) == (epochs[uuid] ?? 0) else { continue }
					store.inflight.remove(uuid)
                    guard let request = store.knownRequests[uuid] else { continue }
					// Last writer wins, and the last writer is the installation lifecycle: an
					// install can have started while this read was in flight, and its answer is
					// the one that must not be overwritten by a mid-install device reading.
					store.statuses[uuid] = store.applyingActiveInstallation(
						to: store.applyingConfirmation(to: status, request: request),
						request: request
					)
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
        let candidate: InstalledApp?
        if let identifier = request.bundleIdentifier, !identifier.isEmpty {
            candidate = probe.installedApp(for: identifier)
        } else {
            candidate = nil
        }
        return resolve(request, installedApp: candidate, readSignature: readSignature, readGuest: readGuest)
    }

    nonisolated static func resolve(
        _ request: Request,
        installedApp candidate: InstalledApp?,
        readSignature: @Sendable (URL) -> BundleSignature.State,
        readGuest: @Sendable (String) -> ContainerGuestState = { _ in .unavailable }
    ) -> LibraryAppStatus {
        var status = LibraryAppStatus()
        status.bundleIdentifier = request.bundleIdentifier

        if let identifier = request.bundleIdentifier, !identifier.isEmpty {
            status.guest = readGuest(identifier)
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
