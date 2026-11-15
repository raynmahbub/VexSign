//
//  InstallationProxy.swift — Feather / IDeviceKit (MIT).
//  VexSign local maintenance: serialize complete native operations and retain
//  bounded streaming. Native completion is a request acknowledgement, NOT an
//  installed-app/version receipt. AppInstaller owns final confirmation.
//
import Foundation
import Combine
import CryptoKit
import Darwin
import IDevice

public final class InstallationProxy: Identifiable, ObservableObject {
    @Published public var viewModel: InstallerStatusViewModel
    public init(viewModel: InstallerStatusViewModel) { self.viewModel = viewModel }

    @available(iOS 16.0, macOS 13.0, *)
    @discardableResult
    public func install(at url: URL, suspend: Bool = false,
                        request: DeviceConnectionRequest? = nil, target: DeviceInstallationTarget? = nil,
                        control: DeviceInstallationControl = DeviceInstallationControl(),
                        onSubmission: @escaping @Sendable (Date) -> Void = { _ in }) async throws -> DeviceInstallationSubmission {
        // No staging/upload/command until the implementation's binary/physical
        // acceptance gates pass. App preflight cannot override this lower gate.
        guard InstallationAppProxy.hasAcceptedInventoryBridge else { throw DeviceTransportError.inventoryBridgeUnavailable }
        // No undocumented UIApplication/NSXPCConnection suspend selector.
        guard !suspend else { throw DeviceTransportError.serviceUnavailable("self-update; use an eligible external installer") }
        guard let request, let binding = request.binding, let target else {
            throw DeviceTransportError.serviceUnavailable("reviewed device, record and exact installation target")
        }
        return try await HeartbeatManager.shared.withDeviceSession(request: request, waiterTimeout: 300) { session, cancellation in
            var afc: OpaquePointer?
            var file: OpaquePointer?
            var installation: OpaquePointer?
            var ownedStagingDirectory: String?
            var commandStarted = false
            var commandFinished = false
            defer {
                if let file, let error = afc_file_close(file) { idevice_error_free(error) }
                // Close the attempt's file BEFORE removing its directory. Never
                // delete PublicStaging or another installer's attempt directory.
                // After a command transport failure, installd may still consume
                // this IPA. Retain that one attempt directory rather than deleting
                // a package from under a potentially accepted install. A later
                // reviewed/user-initiated recovery may reclaim it; no broad sweep.
                if !commandStarted || commandFinished, let afc, let path = ownedStagingDirectory,
                   let error = afc_remove_path_and_contents(afc, path) { idevice_error_free(error) }
                if let installation { installation_proxy_client_free(installation) }
                if let afc { afc_client_free(afc) }
            }
            try session.checked(afc_client_connect_rsd(session.adapter, session.handshake, &afc), stage: .discoveringServices)
            guard let afc else { throw DeviceTransportError.serviceUnavailable("AFC") }
            let stagingDirectory = "/PublicStaging/VexSign-" + UUID().uuidString
            // AFC may return ObjectExists for the common root. Accept only a
            // subsequent positive directory/non-link reading, never any error code
            // treated as success or a guessed allocator for file-info strings.
            if let error = afc_make_directory(afc, "PublicStaging") { idevice_error_free(error) }
            try Self.requireDirectory("PublicStaging", afc: afc, session: session)
            try session.checked(afc_make_directory(afc, stagingDirectory), stage: .discoveringServices)
            ownedStagingDirectory = stagingDirectory
            try Self.requireDirectory(stagingDirectory, afc: afc, session: session)
            let remotePath = stagingDirectory + "/payload.ipa"
            try session.checked(afc_file_open(afc, remotePath, AfcWrOnly, &file), stage: .discoveringServices)
            guard let remoteHandle = file else { throw DeviceTransportError.serviceUnavailable("AFC file") }
            guard url.isFileURL else { throw DeviceTransportError.invalidDeviceResponse }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw DeviceTransportError.serviceUnavailable("readable regular installation archive") }
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? input.close() } // try? ok: preserve the original transfer failure
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size > 0, before.st_size <= 16 * 1024 * 1024 * 1024 else {
                throw DeviceTransportError.serviceUnavailable("nonempty regular archive within the 16 GiB transfer limit")
            }
            let totalSize = UInt64(before.st_size)
            self.status(.sendingPayload)
            var sent: UInt64 = 0
            var hasher = SHA256()
            var lastProgress = 0.0
            while sent < totalSize {
                try DeviceServiceSession.check(cancellation)
                let requested = Int(min(UInt64(1024 * 1024), totalSize - sent))
                let count: Int = try autoreleasepool {
                    guard let data = try input.read(upToCount: requested), data.count == requested else {
                        throw DeviceTransportError.serviceUnavailable("complete installation payload")
                    }
                    try data.withUnsafeBytes { buffer in
                        guard let pointer = buffer.bindMemory(to: UInt8.self).baseAddress else {
                            throw DeviceTransportError.serviceUnavailable("installation payload bytes")
                        }
                        try session.checked(afc_file_write(remoteHandle, pointer, data.count), stage: .discoveringServices)
                    }
                    hasher.update(data: data)
                    return data.count
                }
                sent += UInt64(count)
                let progress = Double(sent) / Double(totalSize)
                if progress - lastProgress >= 0.01 || sent == totalSize {
                    lastProgress = progress
                    DispatchQueue.main.async { self.viewModel.uploadProgress = progress }
                }
            }
            try DeviceServiceSession.check(cancellation)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            var after = stat()
            guard digest == target.packageSHA256, (try input.read(upToCount: 1) ?? Data()).isEmpty,
                  fstat(descriptor, &after) == 0, Self.sameArchive(before, after) else {
                throw DeviceTransportError.serviceUnavailable("unchanged verified installation archive")
            }
            let closeError = afc_file_close(remoteHandle)
            file = nil // Native close consumes the handle, including on error.
            try session.checked(closeError, stage: .discoveringServices)
            try session.checked(installation_proxy_connect_rsd(session.adapter, session.handshake, &installation), stage: .discoveringServices)
            guard let installation else { throw DeviceTransportError.serviceUnavailable("Installation Proxy") }
            try DeviceServiceSession.check(cancellation)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let submittedAt = Date()
            guard let snapshot = session.snapshot,
                  target.permitsSubmission(deviceOS: snapshot.productVersion, at: submittedAt) else {
                throw DeviceTransportError.serviceUnavailable("unexpired authorization on the verified device OS; prepare the app again")
            }
            // Linearize against UI Stop before announcing handoff. No cancellable
            // step separates this point from calling installd. Stop that wins this
            // lock prevents the command; Stop after it is monitoring-only.
            try control.beginSubmission(at: submittedAt, cancellation: cancellation)
            commandStarted = true
            onSubmission(submittedAt)
            self.status(.installing)
            try session.checked(installation_proxy_install_with_callback(installation, remotePath, nil,
                Self.installationProgress, context), stage: .discoveringServices)
            commandFinished = true
            let acknowledgedAt = Date()
            try DeviceServiceSession.check(cancellation)
            // Returning acknowledges this command only. Do NOT publish a
            // Completed status: AppInstaller owns exact-version corroboration.
            return DeviceInstallationSubmission(target: target, binding: binding,
                submittedAt: submittedAt, acknowledgedAt: acknowledgedAt)
        }
    }

    private static func requireDirectory(_ path: String, afc: OpaquePointer, session: DeviceServiceSession) throws {
        var info = AfcFileInfo()
        defer { afc_file_info_free(&info) }
        try session.checked(afc_get_file_info(afc, path, &info), stage: .discoveringServices)
        guard let kind = info.st_ifmt, strnlen(kind, 16) == 7,
              String(cString: kind) == "S_IFDIR", info.st_link_target == nil else {
            throw DeviceTransportError.serviceUnavailable("non-link AFC staging directory")
        }
    }

    private static func sameArchive(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func status(_ status: InstallerStatusViewModel.InstallerStatus) {
        DispatchQueue.main.async { self.viewModel.status = status }
    }

    private static let installationProgress: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { value, context in
        guard let context else { return }
        let owner = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
        let progress = min(0.99, Double(value) / 100)
        DispatchQueue.main.async { owner.viewModel.installProgress = progress }
    }
}
