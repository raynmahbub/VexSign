// SPDX-License-Identifier: MIT
// VexSign local extension; retain the IDeviceKit wrapper LICENSE.
// VexSign local extension. All native handles are confined to HeartbeatManager's
// serial device executor and released before it admits the next operation.
import Foundation
import Darwin
import IDevice

final class DeviceServiceSession {
    private var pairing: OpaquePointer?
    private var provider: OpaquePointer?
    private(set) var adapter: OpaquePointer?
    private(set) var handshake: OpaquePointer?
    private var lockdown: OpaquePointer?
    private(set) var snapshot: AuthorizedDeviceSnapshot?

    func open(_ request: DeviceConnectionRequest, recordBytes: Data, metadata: PairingRecordMetadata,
              cancellation: Progress, reporting: (DeviceConnectionStage) -> Void) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard request.protocolConsent else { throw DeviceTransportError.consentRequired }
        #if targetEnvironment(simulator)
        throw DeviceTransportError.simulator
        #else
        let route = DevicePairingRoute.resolve(.current)
        if route == .onDeviceHostPairing {
            try openOnDeviceHostPairing(request, recordBytes: recordBytes, metadata: metadata, cancellation: cancellation, reporting: reporting)
            return
        }
        try DeviceTransportPolicy.requireClassicRoute(format: metadata.format, version: .current)
        guard PairingRecordDocument.isDeviceIdentifier(request.expectedDeviceIdentifier) else {
            throw DeviceTransportError.expectedDeviceRequired
        }
        if let recordDevice = metadata.deviceIdentifier, recordDevice != request.expectedDeviceIdentifier {
            throw DeviceTransportError.wrongDevice
        }
        try Self.check(cancellation)
        reporting(.checkingTransport)
        try Self.probePeer(request.peerAddress, timeout: 2)
        try Self.check(cancellation)
        reporting(.openingTunnel)
        // Parse the exact bounded, inspected bytes. A path re-open would permit
        // a symlink/size/ABA race against a document-provider or external writer.
        try recordBytes.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { throw PairingRecordError.malformed }
            try checked(idevice_pairing_file_from_bytes(base, UInt(bytes.count), &pairing), stage: .inspectingRecord)
        }
        guard pairing != nil else { throw DeviceTransportError.invalidDeviceResponse }
        var address = try Self.peer(request.peerAddress, port: 62078)
        let providerError = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, pairing, "VexSign", &provider)
            }
        }
        // v0.1.57 provider_new consumes the pairing handle on SUCCESS. The
        // provider now owns it; a second pairing_file_free would double-free it.
        if providerError == nil { pairing = nil }
        try checked(providerError, stage: .openingTunnel)
        guard provider != nil else { throw DeviceTransportError.invalidDeviceResponse }
        try Self.check(cancellation)
        // Despite its name this FFI takes any IdeviceProvider, including the TCP
        // provider above. It opens CoreDeviceProxy and performs the RSD handshake.
        try checked(tunnel_create_usb(provider, &adapter, &handshake), stage: .discoveringServices)
        guard adapter != nil, handshake != nil else { throw DeviceTransportError.invalidDeviceResponse }
        try Self.check(cancellation)
        reporting(.discoveringServices)
        try checked(lockdownd_connect_rsd(adapter, handshake, &lockdown), stage: .discoveringServices)
        guard lockdown != nil else { throw DeviceTransportError.serviceUnavailable("Lockdown") }
        reporting(.queryingDevice)
        let identifier = PairingRecordDocument.normalizeDeviceIdentifier(try readString("UniqueDeviceID"))
        guard PairingRecordDocument.isDeviceIdentifier(identifier), identifier == request.expectedDeviceIdentifier else {
            throw DeviceTransportError.wrongDevice
        }
        let version = try readString("ProductVersion")
        guard let deviceOS = DeviceOSVersion.parse(version) else { throw DeviceTransportError.invalidDeviceResponse }
        try DeviceTransportPolicy.requireClassicRoute(format: metadata.format, version: deviceOS)
        let name = try readString("DeviceName")
        let product = try readString("ProductType")
        let build = try readString("BuildVersion")
        try Self.check(cancellation)
        // Identity authorization and operation capability are separate. Opening
        // Installation Proxy/AFC here made a read-only identity/inventory check
        // depend on services it never uses. Each operation opens/checks its own
        // required clients on this already identity-checked tunnel instead.
        snapshot = AuthorizedDeviceSnapshot(deviceIdentifier: identifier, name: name,
            productType: product, productVersion: version, buildVersion: build,
            services: ["Lockdown", "RSD"], observedAt: Date(), pairingSHA256: metadata.sha256)
        reporting(.authorized)
        #endif
    }

    private func openOnDeviceHostPairing(_ request: DeviceConnectionRequest, recordBytes: Data, metadata: PairingRecordMetadata,
                                         cancellation: Progress, reporting: (DeviceConnectionStage) -> Void) throws {
        try DeviceTransportPolicy.requireOnDeviceHostPairingRoute(version: .current)
        guard metadata.format.containsRemotePairing else { throw DeviceTransportError.remoteRecordRequired }
        guard PairingRecordDocument.isDeviceIdentifier(request.expectedDeviceIdentifier) else {
            throw DeviceTransportError.expectedDeviceRequired
        }
        if let recordDevice = metadata.deviceIdentifier, recordDevice != request.expectedDeviceIdentifier {
            throw DeviceTransportError.wrongDevice
        }
        try Self.check(cancellation)
        reporting(.checkingTransport)
        try Self.probePeer(request.peerAddress, timeout: 2)
        try Self.check(cancellation)
        reporting(.openingTunnel)
        let cancelHandle = vexsign_device_cancel_new()
        let cancelWatcher = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        cancelWatcher.schedule(deadline: .now(), repeating: .milliseconds(100))
        cancelWatcher.setEventHandler { [weak cancellation] in
            if cancellation?.isCancelled == true { vexsign_device_cancel_signal(cancelHandle) }
        }
        cancelWatcher.resume()
        defer {
            cancelWatcher.cancel()
            if let cancelHandle { vexsign_device_cancel_free(cancelHandle) }
        }
        let peer = try Self.validatedPeerHost(request.peerAddress)
        var outAdapter: OpaquePointer?
        var outHandshake: OpaquePointer?
        let error = recordBytes.withUnsafeBytes { bytes -> UnsafeMutablePointer<IdeviceFfiError>? in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return peer.withCString { cPeer in
                vexsign_tunnel_rppairing_verified(base, bytes.count, cPeer, 62078, cancelHandle, 30_000, &outAdapter, &outHandshake)
            }
        }
        if let error {
            if let outAdapter { adapter_free(outAdapter) }
            if let outHandshake { rsd_handshake_free(outHandshake) }
            try checked(error, stage: .openingTunnel)
        }
        guard let outAdapter, let outHandshake else { throw DeviceTransportError.invalidDeviceResponse }
        adapter = outAdapter
        handshake = outHandshake
        try Self.check(cancellation)
        reporting(.discoveringServices)
        try checked(lockdownd_connect_rsd(adapter, handshake, &lockdown), stage: .discoveringServices)
        guard lockdown != nil else { throw DeviceTransportError.serviceUnavailable("Lockdown") }
        reporting(.queryingDevice)
        let identifier = PairingRecordDocument.normalizeDeviceIdentifier(try readString("UniqueDeviceID"))
        guard PairingRecordDocument.isDeviceIdentifier(identifier), identifier == request.expectedDeviceIdentifier else {
            throw DeviceTransportError.wrongDevice
        }
        let version = try readString("ProductVersion")
        guard DeviceOSVersion.parse(version) != nil else { throw DeviceTransportError.invalidDeviceResponse }
        let name = try readString("DeviceName")
        let product = try readString("ProductType")
        let build = try readString("BuildVersion")
        try Self.check(cancellation)
        snapshot = AuthorizedDeviceSnapshot(deviceIdentifier: identifier, name: name,
            productType: product, productVersion: version, buildVersion: build,
            services: ["Lockdown", "RSD"], observedAt: Date(), pairingSHA256: metadata.sha256)
        reporting(.authorized)
    }

    func close() {
        snapshot = nil
        if let lockdown { lockdownd_client_free(lockdown) }
        lockdown = nil
        if let handshake { rsd_handshake_free(handshake) }
        handshake = nil
        if let adapter { adapter_free(adapter) }
        adapter = nil
        if let provider { idevice_provider_free(provider) }
        provider = nil
        if let pairing { idevice_pairing_file_free(pairing) }
        pairing = nil
    }

    func checked(_ error: UnsafeMutablePointer<IdeviceFfiError>?, stage: DeviceConnectionStage) throws {
        guard let error else { return }
        let code = error.pointee.code
        idevice_error_free(error)
        throw DeviceTransportError.nativeFailure(stage: stage, code: code)
    }

    static func check(_ cancellation: Progress) throws {
        guard !cancellation.isCancelled else { throw DeviceTransportError.operationCancelled }
    }

    private func readString(_ key: String) throws -> String {
        var value: UnsafeMutableRawPointer?
        try checked(lockdownd_get_value(lockdown, key, nil, &value), stage: .queryingDevice)
        guard let value else { throw DeviceTransportError.invalidDeviceResponse }
        defer { plist_free(value) }
        var xml: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        let result = plist_to_xml(value, &xml, &length)
        defer { if let xml { plist_mem_free(xml) } }
        guard result == PLIST_ERR_SUCCESS, let xml, length > 0, length <= 64 * 1024,
              let string = (try? PropertyListSerialization.propertyList(
                from: Data(bytes: xml, count: Int(length)), options: [], format: nil)) as? String,
              !string.isEmpty, string.utf8.count <= 256,
              !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DeviceTransportError.invalidDeviceResponse
        }
        return string
    }

    static func validatedPeerHost(_ raw: String) throws -> String {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && parts[1] == "32") else { throw DeviceTransportError.invalidPeer }
        let host = String(parts[0])
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) && Int($0).map({ (0...255).contains($0) }) == true }),
              let first = Int(octets[0]), let second = Int(octets[1]),
              first == 10 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168) || (first == 169 && second == 254),
              host != "10.7.1.1" else { throw DeviceTransportError.invalidPeer }
        var probe = sockaddr_in()
        probe.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        probe.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &probe.sin_addr) == 1 else { throw DeviceTransportError.invalidPeer }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw DeviceTransportError.transportUnavailable }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let current = cursor {
            if let candidate = current.pointee.ifa_addr, candidate.pointee.sa_family == sa_family_t(AF_INET) {
                let own = UnsafeRawPointer(candidate).assumingMemoryBound(to: sockaddr_in.self).pointee
                if own.sin_addr.s_addr == probe.sin_addr.s_addr { throw DeviceTransportError.invalidPeer }
            }
            cursor = current.pointee.ifa_next
        }
        return host
    }

    static func peer(_ raw: String, port: UInt16) throws -> sockaddr_in {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && parts[1] == "32") else {
            throw DeviceTransportError.invalidPeer
        }
        let host = String(parts[0])
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) })
                  && Int($0).map({ (0...255).contains($0) }) == true }),
              let first = Int(octets[0]), let second = Int(octets[1]),
              first == 10 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168)
                  || (first == 169 && second == 254),
              host != "10.7.1.1" else { throw DeviceTransportError.invalidPeer }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = CFSwapInt16HostToBig(port)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw DeviceTransportError.invalidPeer }
        // Reject every address owned by this device, not just a hardcoded VPN
        // interface address. Interface presence alone is not proof of a VPN route.
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw DeviceTransportError.transportUnavailable }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let current = cursor {
            if let candidate = current.pointee.ifa_addr, candidate.pointee.sa_family == sa_family_t(AF_INET) {
                let own = UnsafeRawPointer(candidate).assumingMemoryBound(to: sockaddr_in.self).pointee
                if own.sin_addr.s_addr == address.sin_addr.s_addr { throw DeviceTransportError.invalidPeer }
            }
            cursor = current.pointee.ifa_next
        }
        return address
    }

    /// A bounded endpoint probe, NOT evidence of VPN ownership, device trust or RSD.
    static func probePeer(_ raw: String, timeout: TimeInterval) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var address = try peer(raw, port: 62078)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DeviceTransportError.transportUnavailable }
        defer { Darwin.close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw DeviceTransportError.transportUnavailable
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw socketError(errno) }
        var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let wait = poll(&event, 1, Int32(max(0.1, min(timeout, 5)) * 1000))
        guard wait > 0 else {
            throw wait == 0 ? DeviceTransportError.transportTimeout : DeviceTransportError.transportUnavailable
        }
        var socketStatus: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketStatus, &length) == 0 else {
            throw DeviceTransportError.transportUnavailable
        }
        guard socketStatus == 0 else { throw socketError(socketStatus) }
        guard event.revents & Int16(POLLOUT) != 0,
              event.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
            throw DeviceTransportError.transportUnavailable
        }
    }

    private static func socketError(_ code: Int32) -> DeviceTransportError {
        switch code {
        case EACCES, EPERM: return .permissionDenied
        case ECONNREFUSED: return .connectionRefused
        case ETIMEDOUT: return .transportTimeout
        default: return .transportUnavailable
        }
    }
}
