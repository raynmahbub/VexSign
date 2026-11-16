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
        let root = holdingRoot(fileManager: fileManager)
        if !fileManager.fileExists(atPath: root.path) {
            do { try fileManager.createDirectory(at: root, withIntermediateDirectories: false) }
            catch {
                guard fileManager.fileExists(atPath: root.path) else { throw error }
                // Another valid run may have created the shared Undo root concurrently; the
                // safety check immediately below still rejects a symlink or non-directory.
            }
        }
        guard CleanupRemovalPolicy.isSafeDirectory(root, beneath: fileManager.temporaryDirectory) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        guard CleanupRemovalPolicy.isSafeDirectory(folder, beneath: root) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
		let held = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fileManager.moveItem(at: url, to: held)
        } catch {
            do { _ = try CleanupRemovalPolicy.remove(folder, beneath: root) }
            catch let cleanupError { FileLogger.error("Could not remove empty Undo staging folder: \(cleanupError.localizedDescription)", category: "files") }
            throw error
        }
		return Token(original: url, held: held)
	}

	/// Moves the file back. Refuses to overwrite something that has since taken its place.
	static func restore(_ token: Token, fileManager: FileManager = .default) throws {
        guard CleanupRemovalPolicy.isSafeTarget(token.held, beneath: holdingRoot(fileManager: fileManager)) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
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
		do {
            _ = try CleanupRemovalPolicy.remove(root, beneath: fileManager.temporaryDirectory)
		} catch {
			FileLogger.error("Could not clear removed items: \(error.localizedDescription)", category: "files")
		}
	}

	/// Deletes the held copy for good. A copy that is already gone is not an error.
	static func discard(_ token: Token, fileManager: FileManager = .default) {
		let folder = token.held.deletingLastPathComponent()
		do {
            _ = try CleanupRemovalPolicy.remove(folder, beneath: holdingRoot(fileManager: fileManager))
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
