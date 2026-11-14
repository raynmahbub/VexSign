//
//  UndoableRemoval.swift
//  VexSign
//
//  One way to offer "Undo" after a swipe removal.
//
//  A removal that can be put back announces itself; whichever screen is showing an
//  `undoableRemovalBanner()` offers Undo for a few seconds. When the time runs out the
//  removal is made permanent. Nothing here decides *whether* a removal is undoable — a
//  caller only announces one when it holds everything needed to restore it.
//

import SwiftUI
import Combine
import OSLog
import NimbleExtensions

struct UndoableRemoval: Identifiable {
	let id = UUID()
	/// What was removed, as the row named it.
	let title: String
	/// Puts the item back. Returns false when it could not be restored.
	let restore: () -> Bool
	/// Makes the removal permanent. Must be safe to call more than once.
	let discard: () -> Void

	static let announced = Notification.Name("vexsign.removal.announced")
	static let resolved = Notification.Name("vexsign.removal.resolved")
	/// How long Undo stays on offer.
	static let window: Duration = .seconds(6)

	/// Removals that were undone, so their timer does not make them permanent afterwards.
	/// Read and written on the main thread only.
	private static var _undone: Set<UUID> = []

	/// Offers Undo for a removal that has already happened.
	///
	/// The countdown belongs to the removal, not to a screen: when it ends the removal is
	/// made permanent whether or not any banner is still showing, so held files (a
	/// certificate's private key among them) never outlive the offer because the user
	/// navigated away. Call on the main thread.
	static func announce(_ removal: UndoableRemoval) {
		NotificationCenter.default.post(name: announced, object: nil, userInfo: ["removal": removal])
		Task { @MainActor in
			do {
				try await Task.sleep(for: window)
			} catch {
				// Never cancelled in practice; if it is, ending the offer early is the safe side.
			}
			if _undone.remove(removal.id) == nil {
				removal.discard()
			}
			NotificationCenter.default.post(name: resolved, object: nil, userInfo: ["id": removal.id])
		}
	}

	/// Undoes a removal. Returns false when it could not be restored; the offer then stays
	/// open until its time runs out.
	static func undo(_ removal: UndoableRemoval) -> Bool {
		guard removal.restore() else { return false }
		_undone.insert(removal.id)
		NotificationCenter.default.post(name: resolved, object: nil, userInfo: ["id": removal.id])
		return true
	}
}

// MARK: - Files

/// Removes a file by moving it aside, so it can be moved back.
enum RecoverableFileRemoval {
	struct Token: Equatable {
		let original: URL
		let held: URL
	}

	static func holdingRoot(fileManager: FileManager = .default) -> URL {
		fileManager.temporaryDirectory.appendingPathComponent("RemovedItems", isDirectory: true)
	}

	static func remove(_ url: URL, fileManager: FileManager = .default) throws -> Token {
		let folder = holdingRoot(fileManager: fileManager).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
		let held = folder.appendingPathComponent(url.lastPathComponent)
		try fileManager.moveItem(at: url, to: held)
		return Token(original: url, held: held)
	}

	/// Moves the file back. Refuses to overwrite something that has since taken its place.
	static func restore(_ token: Token, fileManager: FileManager = .default) throws {
		guard !fileManager.fileExists(atPath: token.original.path) else {
			throw CocoaError(.fileWriteFileExists)
		}
		try fileManager.createDirectory(at: token.original.deletingLastPathComponent(), withIntermediateDirectories: true)
		try fileManager.moveItem(at: token.held, to: token.original)
		discard(token, fileManager: fileManager)
	}

	/// Deletes everything still held from an earlier session. Called once at launch: an
	/// offer does not survive the process, so whatever is left was never undone.
	static func sweep(fileManager: FileManager = .default) {
		let root = holdingRoot(fileManager: fileManager)
		guard fileManager.fileExists(atPath: root.path) else { return }
		do {
			try fileManager.removeItem(at: root)
		} catch {
			FileLogger.error("Could not clear removed items: \(error.localizedDescription)", category: "files")
		}
	}

	/// Deletes the held copy for good. A copy that is already gone is not an error.
	static func discard(_ token: Token, fileManager: FileManager = .default) {
		let folder = token.held.deletingLastPathComponent()
		guard fileManager.fileExists(atPath: folder.path) else { return }
		do {
			try fileManager.removeItem(at: folder)
		} catch {
			FileLogger.error("Could not discard removed item: \(error.localizedDescription)", category: "files")
		}
	}

	/// Removes a file and offers Undo. Returns false (after a toast) when it could not be removed.
	@discardableResult
	static func removeOfferingUndo(_ url: URL, onChange: @escaping () -> Void) -> Bool {
		let token: Token
		do {
			token = try remove(url)
		} catch {
			Toast.error(error.localizedDescription)
			return false
		}
		UndoableRemoval.announce(UndoableRemoval(
			title: url.lastPathComponent,
			restore: {
				do {
					try restore(token)
					onChange()
					return true
				} catch {
					Toast.error(error.localizedDescription)
					return false
				}
			},
			discard: { discard(token) }
		))
		onChange()
		return true
	}
}

// MARK: - Sources

/// Removes a repository while keeping what is needed to add it back.
enum SourceRemoval {
	struct Snapshot: Equatable {
		let url: URL
		let name: String?
		let identifier: String
		let iconURL: URL?
		let date: Date?
	}

	static func snapshot(of source: AltSource) -> Snapshot? {
		guard let url = source.sourceURL, let identifier = source.identifier else { return nil }
		return Snapshot(url: url, name: source.name, identifier: identifier, iconURL: source.iconURL, date: source.date)
	}

	/// Deletes sources and offers Undo for those that can be restored exactly. Premium
	/// sources are deleted without Undo: removing one also unregisters it, which adding the
	/// row back would not reverse.
	static func delete(_ sources: [AltSource]) {
		var snapshots: [Snapshot] = []
		for source in sources {
			if let snapshot = snapshot(of: source), !VexSignAPI.isPremiumSource(snapshot.url) {
				snapshots.append(snapshot)
			}
			Storage.shared.deleteSource(for: source)
		}
		guard let first = snapshots.first else { return }

		let title = snapshots.count == 1
			? (first.name ?? first.url.host ?? first.url.absoluteString)
			: String.localized("%lld sources", arguments: snapshots.count)
		UndoableRemoval.announce(UndoableRemoval(
			title: title,
			restore: {
				for snapshot in snapshots { _restore(snapshot) }
				return true
			},
			discard: {}
		))
	}

	private static func _restore(_ snapshot: Snapshot) {
		// The user's own previously saved configuration: the transport policy was applied
		// when it was first added, as with a backup restore.
		Storage.shared.addSource(
			snapshot.url,
			name: snapshot.name,
			identifier: snapshot.identifier,
			iconURL: snapshot.iconURL,
			enforceTransportPolicy: false
		) { error in
			if let error { Toast.error(error.localizedDescription) }
		}
		// Keep the row where it was in date-ordered lists.
		if let date = snapshot.date,
		   let restored = Storage.shared.getSources().first(where: { $0.identifier == snapshot.identifier }) {
			restored.date = date
			Storage.shared.saveContext()
		}
	}
}

// MARK: - Certificates

/// Deletes a certificate while keeping what is needed to put it back for a few seconds.
///
/// The certificate really is deleted — row, Keychain password, revocation snapshot — so
/// nothing can sign with it during the offer. Its folder (the .p12 and profiles) is moved
/// aside rather than erased, and the password is kept in memory only. When the offer ends
/// the folder is erased; if the app is closed first, the launch sweep erases it.
enum CertificateRemoval {
	struct Snapshot {
		let uuid: String
		let nickname: String?
		let ppq: Bool
		let expiration: Date
		let isDefault: Bool
		let revoked: Bool
		let date: Date?
		let password: String
		let signedAppURIs: [URL]
	}

	static func delete(_ cert: CertificatePair) {
		let offer = _prepareUndo(for: cert)
		Storage.shared.deleteCertificate(for: cert)
		guard let (snapshot, token) = offer else { return }

		UndoableRemoval.announce(UndoableRemoval(
			title: snapshot.nickname ?? .localized("Certificate"),
			// Undo is tapped on the main thread; the banner is the only caller.
			restore: { MainActor.assumeIsolated { _restore(snapshot, token: token) } },
			discard: { if let token { RecoverableFileRemoval.discard(token) } }
		))
	}

	/// Nil when the certificate cannot be restored exactly; it is then deleted without Undo.
	private static func _prepareUndo(for cert: CertificatePair) -> (Snapshot, RecoverableFileRemoval.Token?)? {
		guard let uuid = cert.uuid, let expiration = cert.expiration else { return nil }

		let password: String
		do {
			password = try cert.requireSigningPassword()
		} catch {
			Logger.misc.info("Certificate password unavailable; deleting without Undo.")
			return nil
		}

		var token: RecoverableFileRemoval.Token?
		if let folder = Storage.shared.getUuidDirectory(for: cert), FileManager.default.fileExists(atPath: folder.path) {
			do {
				token = try RecoverableFileRemoval.remove(folder)
			} catch {
				Logger.misc.error("Certificate files could not be set aside; deleting without Undo.")
				return nil
			}
		}

		let signed = (cert.signedApps as? Set<Signed>) ?? []
		return (
			Snapshot(
				uuid: uuid,
				nickname: cert.nickname,
				ppq: cert.ppQCheck,
				expiration: expiration,
				isDefault: cert.isDefault,
				revoked: cert.revoked,
				date: cert.date,
				password: password,
				signedAppURIs: signed.map { $0.objectID.uriRepresentation() }
			),
			token
		)
	}

	@MainActor
	private static func _restore(_ snapshot: Snapshot, token: RecoverableFileRemoval.Token?) -> Bool {
		// Files first: a row without its .p12 is a certificate that cannot sign.
		if let token {
			do {
				try RecoverableFileRemoval.restore(token)
			} catch {
				Toast.error(error.localizedDescription)
				return false
			}
		}

		var failure: Error?
		Storage.shared.addCertificate(
			uuid: snapshot.uuid,
			password: snapshot.password,
			nickname: snapshot.nickname,
			ppq: snapshot.ppq,
			expiration: snapshot.expiration,
			isDefault: snapshot.isDefault
		) { failure = $0 }

		let restored = Storage.shared.getAllCertificates().first { $0.uuid == snapshot.uuid }
		guard failure == nil, let restored else {
			// Put the files back in holding so the key is still erased when the offer ends.
			if let token {
				do {
					try FileManager.default.createDirectory(at: token.held.deletingLastPathComponent(), withIntermediateDirectories: true)
					try FileManager.default.moveItem(at: token.original, to: token.held)
				} catch {
					Logger.misc.error("Certificate files could not be set aside again after a failed restore.")
				}
			}
			Toast.error(failure?.localizedDescription ?? .localized("The certificate could not be restored."))
			return false
		}

		// Same place in the list (the selected certificate is stored as a position), same
		// revocation state, and the signed apps point at it again.
		restored.date = snapshot.date
		restored.revoked = snapshot.revoked
		Storage.shared.relinkSignedApps(objectURIs: snapshot.signedAppURIs, to: restored)
		return true
	}
}

// MARK: - Banner

private struct UndoableRemovalBanner: ViewModifier {
	@State private var _current: UndoableRemoval?

	func body(content: Content) -> some View {
		content
			.safeAreaInset(edge: .bottom) {
				if let removal = _current {
					HStack {
						Text(String.localized("Removed %@", arguments: removal.title))
							.font(.subheadline)
							.lineLimit(1)
						Spacer()
						Button(.localized("Undo")) {
							if UndoableRemoval.undo(removal) { _current = nil }
						}
						.fontWeight(.semibold)
					}
					.padding(.horizontal, 16)
					.padding(.vertical, 12)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
					.padding(.horizontal, 16)
					.padding(.bottom, 8)
					.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.animation(.snappy, value: _current?.id)
			.onReceive(NotificationCenter.default.publisher(for: UndoableRemoval.announced)) { note in
				guard let removal = note.userInfo?["removal"] as? UndoableRemoval else { return }
				// A newer removal replaces the offer on screen; the older one keeps its own
				// countdown and becomes permanent when that ends.
				_current = removal
			}
			.onReceive(NotificationCenter.default.publisher(for: UndoableRemoval.resolved)) { note in
				guard let id = note.userInfo?["id"] as? UUID, _current?.id == id else { return }
				_current = nil
			}
	}
}

extension View {
	/// Shows "Removed … Undo" at the bottom of this screen after an undoable removal.
	func undoableRemovalBanner() -> some View {
		modifier(UndoableRemovalBanner())
	}
}
