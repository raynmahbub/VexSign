import Foundation
import NimbleExtensions

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
