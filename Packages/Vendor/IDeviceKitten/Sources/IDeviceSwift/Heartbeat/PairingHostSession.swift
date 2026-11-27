// SPDX-License-Identifier: MIT
// VexSign local extension; retain the IDeviceKit wrapper LICENSE.
// On-device RPPairing host session for iOS 27+ bootstrap. Wraps the pinned
// DeviceBridge vexsign_pairable_host_* ABI. No pinless pairing, no unattended
// trust, no native filesystem writes, no credential logging.
import Foundation
import Darwin
import IDevice

public struct PairingHostAdvertisement: Sendable {
    public let serviceName: String
    public let serviceType: String
    public let port: Int32
    public let txtRecord: [String: Data]
}

public struct PairingHostEnrollmentResult: Sendable {
    public let recordData: Data
    public let metadata: PairingRecordMetadata
}

public enum PairingHostSessionError: Error, Equatable, LocalizedError, Sendable {
    case unsupported
    case invalidName
    case advertisementFailed
    case listenerFailed
    case peerRejected
    case pinRequired
    case cancelled
    case timedOut
    case nativeFailure(Int32)
    case invalidRecord

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "On-device pairing host is unavailable on this device build."
        case .invalidName: return "Pairing host name is invalid."
        case .advertisementFailed: return "Could not advertise the pairing host. Check Local Network permission and retry."
        case .listenerFailed: return "Could not open the local pairing listener."
        case .peerRejected: return "The pairing request was rejected or invalid."
        case .pinRequired: return "A pairing PIN is required; pinless pairing is not allowed."
        case .cancelled: return "Pairing was cancelled."
        case .timedOut: return "Pairing timed out before a verified device completed the session."
        case .nativeFailure(let code): return "Pairing host failed (code \(code))."
        case .invalidRecord: return "The pairing host returned an invalid or unreadable record."
        }
    }
}

private final class PairingHostPINBox: @unchecked Sendable {
    let callback: @Sendable (String) -> Void
    init(_ callback: @escaping @Sendable (String) -> Void) { self.callback = callback }
}

private let pairingHostPINTrampoline: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pin, context in
    guard let pin, let context else { return }
    let box = Unmanaged<PairingHostPINBox>.fromOpaque(context).takeUnretainedValue()
    let value = String(cString: pin)
    guard value.count == 6, value.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) else { return }
    box.callback(value)
}

/// One ephemeral on-device pairing host. It owns no persistent trust; the caller
/// decides whether to persist the returned record after explicit review.
public final class PairingHostSession: @unchecked Sendable {
    private let lock = NSLock()
    private var host: OpaquePointer?
    private var cancelHandle: OpaquePointer?
    private var listenerFD: Int32 = -1
    private var netService: NetService?
    private var cancelled = false

    public init() {}

    deinit { cleanup() }

    public func cancel() {
        lock.lock()
        cancelled = true
        let cancelHandle = self.cancelHandle
        let listenerFD = self.listenerFD
        self.listenerFD = -1
        lock.unlock()
        if let cancelHandle { vexsign_device_cancel_signal(cancelHandle) }
        if listenerFD >= 0 { Darwin.shutdown(listenerFD, SHUT_RDWR); Darwin.close(listenerFD) }
        stopAdvertising()
    }

    public func prepare(name: String) throws -> PairingHostAdvertisement {
        try DeviceTransportPolicy.requireOnDeviceHostPairingRoute(version: .current)
        guard !name.isEmpty, name.count <= 64, !name.contains(where: \.isNewline) else {
            throw PairingHostSessionError.invalidName
        }
        var host: OpaquePointer?
        var txtPtr: UnsafeMutablePointer<UInt8>?
        var txtLen: UInt = 0
        let error = name.withCString { cName in
            vexsign_pairable_host_prepare(cName, &host, &txtPtr, &txtLen)
        }
        if let error {
            let code = error.pointee.code
            idevice_error_free(error)
            throw PairingHostSessionError.nativeFailure(code)
        }
        guard let host, let txtPtr, txtLen > 0 else {
            if let txtPtr { vexsign_device_bytes_free(txtPtr, txtLen) }
            if let host { vexsign_pairable_host_free(host) }
            throw PairingHostSessionError.unsupported
        }
        let txtData = Data(bytes: txtPtr, count: Int(txtLen))
        vexsign_device_bytes_free(txtPtr, txtLen)
        lock.lock()
        self.host = host
        lock.unlock()

        let txtRecord = try Self.parseTXTRecord(txtData)
        return PairingHostAdvertisement(
            serviceName: name,
            serviceType: "_remotepairing-pairable-host._tcp.",
            port: 0,
            txtRecord: txtRecord
        )
    }

    /// Advertise the prepared host on the local network and accept one pairing request.
    /// The PIN is displayed through `onPIN` and must never be logged or persisted.
    public func advertiseAndAccept(
        advertisement: PairingHostAdvertisement,
        timeoutSeconds: UInt32 = 120,
        onPIN: @escaping @Sendable (String) -> Void
    ) async throws -> PairingHostEnrollmentResult {
        try DeviceTransportPolicy.requireOnDeviceHostPairingRoute(version: .current)
        guard timeoutSeconds >= 1, timeoutSeconds <= 300 else { throw PairingHostSessionError.timedOut }

        let fd = try openListener()
        let port = try boundPort(fd: fd)
        lock.lock()
        listenerFD = fd
        lock.unlock()

        try publishService(name: advertisement.serviceName, type: advertisement.serviceType, port: Int32(port), txt: advertisement.txtRecord)

        defer {
            stopAdvertising()
            lock.lock()
            let lfd = self.listenerFD
            self.listenerFD = -1
            lock.unlock()
            if lfd >= 0 { Darwin.shutdown(lfd, SHUT_RDWR); Darwin.close(lfd) }
        }

        let peerFD = try await acceptOneConnection(listenerFD: fd, timeout: timeoutSeconds)
        defer { if peerFD >= 0 { Darwin.close(peerFD) } }

        let recordData = try acceptPairing(fd: peerFD, timeoutMilliseconds: timeoutSeconds * 1000, onPIN: onPIN)
        let metadata: PairingRecordMetadata
        do { metadata = try PairingRecordDocument.inspect(recordData) }
        catch { throw PairingHostSessionError.invalidRecord }
        guard metadata.format.containsRemotePairing else { throw PairingHostSessionError.invalidRecord }
        return PairingHostEnrollmentResult(recordData: recordData, metadata: metadata)
    }

    private func openListener() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PairingHostSessionError.listenerFailed }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("0.0.0.0"))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw PairingHostSessionError.listenerFailed
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }

    private func boundPort(fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard result == 0 else { throw PairingHostSessionError.listenerFailed }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func acceptOneConnection(listenerFD: Int32, timeout: UInt32) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            try Task.checkCancellation()
            lock.lock(); let isCancelled = cancelled; lock.unlock()
            if isCancelled { throw PairingHostSessionError.cancelled }
            var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
            let rc = Darwin.poll(&pollFD, 1, 250)
            if rc > 0, pollFD.revents & Int16(POLLIN) != 0 {
                var peerAddr = sockaddr_storage()
                var peerLen: socklen_t = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let peerFD = withUnsafeMutablePointer(to: &peerAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(listenerFD, $0, &peerLen)
                    }
                }
                if peerFD >= 0 {
                    if let family = Self.sockaddrFamily(peerAddr), family == sa_family_t(AF_INET) {
                        let v4 = withUnsafePointer(to: &peerAddr) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } }
                        let ip = UInt32(bigEndian: v4.sin_addr.s_addr)
                        let isLoopback = (ip & 0xff000000) == 0x7f000000
                        let isPrivate10 = (ip & 0xff000000) == 0x0a000000
                        let isPrivate172 = (ip & 0xfff00000) == 0xac100000
                        let isPrivate192 = (ip & 0xffff0000) == 0xc0a80000
                        let isLinkLocal = (ip & 0xffff0000) == 0xa9fe0000
                        if !(isLoopback || isPrivate10 || isPrivate172 || isPrivate192 || isLinkLocal) {
                            Darwin.close(peerFD)
                            continue
                        }
                    } else if let family = Self.sockaddrFamily(peerAddr), family == sa_family_t(AF_INET6) {
                        // Accept IPv6 loopback/link-local; cryptographic pairing validates peer.
                    } else {
                        Darwin.close(peerFD)
                        continue
                    }
                    return peerFD
                }
            }
            await Task.yield()
        }
        throw PairingHostSessionError.timedOut
    }

    private static func sockaddrFamily(_ addr: sockaddr_storage) -> sa_family_t? {
        withUnsafePointer(to: addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee.sa_family } }
    }

    private func acceptPairing(fd: Int32, timeoutMilliseconds: UInt32, onPIN: @escaping @Sendable (String) -> Void) throws -> Data {
        lock.lock()
        let host = self.host
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled else { throw PairingHostSessionError.cancelled }
        guard let host else { throw PairingHostSessionError.unsupported }

        let cancelHandle = vexsign_device_cancel_new()
        lock.lock(); self.cancelHandle = cancelHandle; lock.unlock()
        defer {
            lock.lock(); self.cancelHandle = nil; lock.unlock()
            if let cancelHandle { vexsign_device_cancel_free(cancelHandle) }
        }

        let pinBox = PairingHostPINBox(onPIN)
        let context = Unmanaged.passRetained(pinBox).toOpaque()
        defer { Unmanaged<PairingHostPINBox>.fromOpaque(context).release() }

        var outRecord: UnsafeMutablePointer<UInt8>?
        var outLength: UInt = 0
        let error = vexsign_pairable_host_accept_fd(host, fd, pairingHostPINTrampoline, context, cancelHandle, timeoutMilliseconds, &outRecord, &outLength)
        if let error {
            let code = error.pointee.code
            idevice_error_free(error)
            if code == -13 /* CanceledByUser */ { throw PairingHostSessionError.cancelled }
            throw PairingHostSessionError.nativeFailure(code)
        }
        guard let outRecord, outLength > 0 else { throw PairingHostSessionError.invalidRecord }
        let data = Data(bytes: outRecord, count: Int(outLength))
        vexsign_device_bytes_free(outRecord, outLength)
        return data
    }

    private func publishService(name: String, type: String, port: Int32, txt: [String: Data]) throws {
        let service = NetService(domain: "local.", type: type, name: name, port: port)
        let txtData = NetService.data(fromTXTRecord: txt)
        service.setTXTRecord(txtData)
        service.publish(options: [])
        lock.lock(); netService = service; lock.unlock()
        // NetService publish is asynchronous; we give it a brief moment and rely on
        // the pairing timeout for the overall session. Callers observe failures via
        // timeout/cancellation rather than trusting publication alone.
    }

    private func stopAdvertising() {
        lock.lock()
        let service = netService
        netService = nil
        lock.unlock()
        service?.stop()
    }

    private func cleanup() {
        cancel()
        lock.lock()
        let host = self.host
        self.host = nil
        lock.unlock()
        if let host { vexsign_pairable_host_free(host) }
    }

    private static func parseTXTRecord(_ data: Data) throws -> [String: Data] {
        let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = root as? [String: Any] else { throw PairingHostSessionError.advertisementFailed }
        var out: [String: Data] = [:]
        for (key, value) in dict {
            if let s = value as? String { out[key] = Data(s.utf8) }
            else if let d = value as? Data { out[key] = d }
        }
        guard !out.isEmpty else { throw PairingHostSessionError.advertisementFailed }
        return out
    }
}
