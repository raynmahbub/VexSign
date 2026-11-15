// SPDX-License-Identifier: MIT
// VexSign local extension; retain the IDeviceKit wrapper LICENSE.
import Foundation
import Darwin

/// Sole pairing-file storage owner. Production lifecycle operations use the
/// device executor; this lock also excludes recovery/export-dismissal cleanup.
/// No credentials belong in Documents, preferences, backups or diagnostics.
public enum PairingFileStorage {
    private static let lock = NSLock()
    private static var recoveredTemporaryFiles = false
    private static var containerRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
    }
    private static var exportRoot: URL {
        #if os(iOS)
        // tmp is app-owned too: resolving it could silently redirect credentials
        // into file-shared Documents. Only canonicalize the container prefix.
        let temporary = containerRoot.appendingPathComponent("tmp", isDirectory: true)
        #else
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        #endif
        return temporary.appendingPathComponent("pairing-exports", isDirectory: true)
    }
    private static var legacyURL: URL {
        containerRoot.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("pairingFile.plist")
    }
    private static var currentURL: URL { privateURL(in: containerRoot) }

    /// Canonicalize the OS/container prefix only, never app-owned Library,
    /// Application Support or Private. Mutation guards must see and reject a
    /// substituted ancestor link, including one that points into Documents.
    /// Internal root injection keeps that same production calculation testable.
    static func privateURL(in container: URL) -> URL {
        container.resolvingSymlinksInPath().appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Private", isDirectory: true).appendingPathComponent("pairingFile.plist")
    }

    /// Pure lookup. In particular it does not migrate on the main actor or fall
    /// back to file-shared Documents when protected storage is unavailable.
    public static func path() -> String { currentURL.path }

    /// Called only by the existing device executor, before local/native work.
    static func prepare() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock()
        defer { lock.unlock() }
        do {
            if !recoveredTemporaryFiles {
                try discardAbandoned(in: exportRoot, prefix: nil)
                try discardAbandoned(in: currentURL.deletingLastPathComponent(), prefix: ".pairing-")
                recoveredTemporaryFiles = true
            }
            try migrateUnlocked(legacy: legacyURL, destination: currentURL, beforeMove: { _, _ in })
        } catch let error as PairingRecordError { throw error }
        catch { throw PairingRecordError.unreadable }
    }

    /// O_NOFOLLOW/nonblocking + fstat + maximum+1 read: never follow a final
    /// symlink, block opening a FIFO, or trust a separate file-size lookup.
    /// An atomic rename can leave us with the old complete snapshot; callers
    /// binding a mutation/session to a review also recheck its digest.
    public static func read(from url: URL) throws -> Data {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw PairingRecordError.unsafeFile }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw PairingRecordError.missing }
            if errno == ELOOP || errno == ENOTDIR { throw PairingRecordError.unsafeFile }
            throw PairingRecordError.unreadable
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() } // try? ok: preserve the original read/validation error
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw PairingRecordError.unreadable }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw PairingRecordError.unsafeFile }
        guard before.st_size >= 0, before.st_size <= PairingRecordDocument.maximumSize else {
            throw PairingRecordError.oversized
        }
        let data: Data
        do { data = try file.read(upToCount: PairingRecordDocument.maximumSize + 1) ?? Data() }
        catch { throw PairingRecordError.unreadable }
        guard data.count <= PairingRecordDocument.maximumSize else { throw PairingRecordError.oversized }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameFile(before, after),
              data.count == after.st_size else { throw PairingRecordError.unreadable }
        return data
    }

    /// nil imports into an empty slot ONLY. Replacement/deletion needs the
    /// digest from the user's review, including for malformed bounded old data.
    /// The hook exercises pre-commit failure/change races in production-source
    /// host tests; production uses the empty default, never an external callback.
    @discardableResult
    static func install(_ data: Data, at destination: URL, replacing expectedSHA256: String?,
                        beforeCommit: () throws -> Void = {}) throws -> PairingRecordMetadata {
        lock.lock()
        defer { lock.unlock() }
        let metadata = try PairingRecordDocument.inspect(data)
        let directory = destination.deletingLastPathComponent()
        try requireUnlinkedPath(directory)
        try requireCurrent(destination, expectedSHA256: expectedSHA256)
        try protectDirectory(directory, complete: false)
        let staging = directory.appendingPathComponent(".pairing-" + UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) } // try? ok: rename/link consumes the protected staging file
        try data.write(to: staging, options: writeOptions(complete: false))
        try protectFile(staging, complete: false)
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PairingRecordError.unreadable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try file.synchronize(); try file.close() }
        catch { try? file.close(); throw PairingRecordError.unreadable } // try? ok: preserve synchronization failure
        try beforeCommit()
        try requireUnlinkedPath(directory)
        try requireCurrent(destination, expectedSHA256: expectedSHA256)
        if expectedSHA256 == nil {
            // Unlike rename(), link() cannot clobber a file created after the
            // last empty-slot check. Both names briefly refer to our protected
            // inode; deferred removal drops only the staging name.
            guard Darwin.link(staging.path, destination.path) == 0 else {
                throw errno == EEXIST ? PairingRecordError.changedRecord : .unreadable
            }
        } else {
            // The private directory has one app writer, excluded by this lock
            // and the executor. A reviewed replacement is one atomic rename.
            guard Darwin.rename(staging.path, destination.path) == 0 else { throw PairingRecordError.unreadable }
        }
        // No throwing chmod/backup write after commit: cancellation or an I/O
        // error must not claim the previous file survived an actual replacement.
        return metadata
    }

    static func remove(at url: URL, expectedSHA256: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireUnlinkedPath(url.deletingLastPathComponent())
        try requireCurrent(url, expectedSHA256: expectedSHA256)
        guard Darwin.unlink(url.path) == 0 else { throw PairingRecordError.unreadable }
    }

    private static func requireCurrent(_ url: URL, expectedSHA256: String?) throws {
        do {
            guard try regularInfo(url) != nil else {
                guard expectedSHA256 == nil else { throw PairingRecordError.changedRecord }
                return
            }
            guard PairingRecordDocument.fingerprint(try read(from: url)) == expectedSHA256 else {
                throw PairingRecordError.changedRecord
            }
        } catch PairingRecordError.missing {
            // A previously present file disappearing is a changed review, not
            // permission to overwrite whatever appears next.
            throw PairingRecordError.changedRecord
        }
    }

    /// Exact bytes, explicit temporary destination, no companion-receipt claim.
    /// The root override is internal for isolated tests, not an app API.
    static func export(from source: URL, expectedSHA256: String, root: URL? = nil) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let data = try read(from: source)
        guard try PairingRecordDocument.inspect(data).sha256 == expectedSHA256 else { throw PairingRecordError.changedRecord }
        let root = root ?? exportRoot
        try protectDirectory(root, complete: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try protectDirectory(directory, complete: true)
        let destination = directory.appendingPathComponent("VexSign-Pairing.plist")
        do {
            try data.write(to: destination, options: writeOptions(complete: true))
            try protectFile(destination, complete: true)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory) // try? ok: keep original failure; protected cleanup retries at launch
            throw PairingRecordError.unreadable
        }
    }

    public static func discardExport(at url: URL) { discardExport(at: url, root: exportRoot) }

    static func discardExport(at url: URL, root: URL) {
        lock.lock()
        defer { lock.unlock() }
        let directory = url.standardizedFileURL.deletingLastPathComponent()
        guard url.isFileURL, url.lastPathComponent == "VexSign-Pairing.plist",
              directory.deletingLastPathComponent() == root.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil,
              (try? requireUnlinkedPath(root)) != nil else { return }
        try? FileManager.default.removeItem(at: directory) // try? ok: protected, bounded recovery retries on launch
    }

    /// Same cleanup as launch, using isolated roots for interruption tests.
    static func recoverTemporaryFiles(privateDirectory: URL, exports: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try discardAbandoned(in: exports, prefix: nil)
        try discardAbandoned(in: privateDirectory, prefix: ".pairing-")
    }

    private static func discardAbandoned(in root: URL, prefix: String?) throws {
        try requireUnlinkedPath(root)
        var status = stat()
        if lstat(root.path, &status) != 0 {
            guard errno == ENOENT else { throw PairingRecordError.unreadable }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else { throw PairingRecordError.unsafeFile }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]) else { throw PairingRecordError.unreadable }
        var inspected = 0
        for case let file as URL in files {
            inspected += 1
            if inspected > 128 { break } // Never sweep an unbounded shared directory.
            let name = file.lastPathComponent
            if let prefix {
                guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            } else { guard UUID(uuidString: name) != nil else { continue } }
            try? FileManager.default.removeItem(at: file) // try? ok: leave protected leftovers for a later recovery
        }
    }

    @discardableResult
    public static func migrate(legacy: URL, destination: URL,
                               beforeMove: (URL, URL) throws -> Void = { _, _ in }) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try migrateUnlocked(legacy: legacy, destination: destination, beforeMove: beforeMove)
    }

    private static func migrateUnlocked(legacy: URL, destination: URL,
                                        beforeMove: (URL, URL) throws -> Void) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try protectDirectory(directory, complete: false)
        let destinationInfo = try regularInfo(destination)
        if try regularInfo(legacy) != nil {
            try protectFile(legacy, complete: false)
            guard let protected = try regularInfo(legacy) else { throw PairingRecordError.changedRecord }
            let target = destinationInfo == nil ? destination : directory.appendingPathComponent("legacy-\(UUID().uuidString).plist")
            try beforeMove(legacy, target)
            try requireUnlinkedPath(directory)
            // A hook/concurrent writer cannot substitute a symlink or a new file
            // between inspection and the move. FileManager's move refuses overwrite.
            guard let current = try regularInfo(legacy), sameFile(current, protected),
                  try regularInfo(target) == nil else {
                throw PairingRecordError.changedRecord
            }
            try FileManager.default.moveItem(at: legacy, to: target)
        }
        if try regularInfo(destination) != nil { try protectFile(destination, complete: false) }
        return destination
    }

    private static func regularInfo(_ url: URL) throws -> stat? {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw PairingRecordError.unsafeFile }
        try requireUnlinkedPath(url.deletingLastPathComponent())
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw PairingRecordError.unreadable }
            return nil
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else { throw PairingRecordError.unsafeFile }
        return status
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Private roots are built from canonical system/container prefixes. Reject
    /// app-owned ancestor links too, not only a symlink in the final component.
    /// Other sandbox processes cannot write these 0700 app-private directories;
    /// hostile same-process arbitrary filesystem access is not a supported threat boundary.
    private static func requireUnlinkedPath(_ url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0),
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw PairingRecordError.unsafeFile
        }
    }

    private static func protectDirectory(_ url: URL, complete: Bool) throws {
        try requireUnlinkedPath(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: attributes(mode: 0o700, complete: complete))
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw PairingRecordError.unsafeFile }
        try FileManager.default.setAttributes(attributes(mode: 0o700, complete: complete), ofItemAtPath: url.path)
        var excluded = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
    }

    private static func protectFile(_ url: URL, complete: Bool) throws {
        guard try regularInfo(url) != nil else { throw PairingRecordError.missing }
        try FileManager.default.setAttributes(attributes(mode: 0o600, complete: complete), ofItemAtPath: url.path)
        var excluded = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
    }

    private static func attributes(mode: Int, complete: Bool) -> [FileAttributeKey: Any] {
        var result: [FileAttributeKey: Any] = [.posixPermissions: mode]
        // macOS/simulator fixtures cannot prove iOS Data Protection. Physical iOS
        // has no unsupported-protection fallback: failure blocks the operation.
        #if os(iOS) && !targetEnvironment(simulator)
        result[.protectionKey] = complete ? FileProtectionType.complete : .completeUntilFirstUserAuthentication
        #endif
        return result
    }

    private static func writeOptions(complete: Bool) -> Data.WritingOptions {
        #if os(iOS) && !targetEnvironment(simulator)
        return complete ? [.withoutOverwriting, .completeFileProtection]
            : [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.withoutOverwriting]
        #endif
    }
}
