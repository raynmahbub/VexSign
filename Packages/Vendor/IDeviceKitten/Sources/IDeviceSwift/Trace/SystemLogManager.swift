// SystemLogManager.swift — IDeviceKit (MIT), VexSign local lifecycle repair.
import Foundation
import IDevice

public final class SystemLogManager: NSObject {
    static let shared = SystemLogManager()
    private let stateLock = NSLock()
    private var stream: Progress?
    public weak var delegate: SystemLogManagerDelegate?

    public var isStreaming: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stream.map { !$0.isCancelled } ?? false
    }

    private func beginStream() throws -> Progress {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream == nil else { throw DeviceTransportError.serviceUnavailable("another active device log stream") }
        let token = Progress(totalUnitCount: 1)
        stream = token
        return token
    }

    private func endStream() {
        stateLock.lock()
        stream = nil
        stateLock.unlock()
        notify(false)
    }

    private func notify(_ value: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .isStreamingDidChange, object: value)
        }
    }

    public func syslog_relay() async throws {
        let token = try beginStream()
        defer { endStream() }
        try await HeartbeatManager.shared.withDeviceSession { session, cancellation in
            var client: OpaquePointer?
            defer { if let client { syslog_relay_client_free(client) } }
            try session.checked(syslog_relay_connect_rsd(session.adapter, session.handshake, &client), stage: .discoveringServices)
            guard let client else { throw DeviceTransportError.serviceUnavailable("Syslog Relay") }
            self.notify(true)
            while !token.isCancelled {
                try DeviceServiceSession.check(cancellation)
                var line: UnsafeMutablePointer<CChar>?
                let error = syslog_relay_next(client, &line)
                defer { if let line { idevice_string_free(line) } }
                try session.checked(error, stage: .discoveringServices)
                guard let line, let text = String(validatingUTF8: line) else {
                    throw DeviceTransportError.invalidDeviceResponse
                }
                self.delegate?.activityStream(didRecieveString: text)
            }
        }
    }

    public func os_trace_relay() async throws {
        let token = try beginStream()
        defer { endStream() }
        try await HeartbeatManager.shared.withDeviceSession { session, cancellation in
            var client: OpaquePointer?
            var receiver: OpaquePointer?
            defer {
                if let receiver { os_trace_relay_receiver_free(receiver) }
                else if let client { os_trace_relay_free(client) }
            }
            try session.checked(os_trace_relay_connect_rsd(session.adapter, session.handshake, &client), stage: .discoveringServices)
            guard let ownedClient = client else { throw DeviceTransportError.serviceUnavailable("OS Trace Relay") }
            // With valid out-arguments, start_trace consumes the client on BOTH
            // success and service failure (Box::from_raw before awaiting).
            let startError = os_trace_relay_start_trace(ownedClient, &receiver, nil)
            client = nil
            try session.checked(startError, stage: .discoveringServices)
            guard let receiver else { throw DeviceTransportError.invalidDeviceResponse }
            self.notify(true)
            while !token.isCancelled {
                try DeviceServiceSession.check(cancellation)
                var entry: UnsafeMutablePointer<OsTraceLog>?
                let error = os_trace_relay_next(receiver, &entry)
                defer { if let entry { os_trace_relay_free_log(entry) } }
                try session.checked(error, stage: .discoveringServices)
                guard let entry else { throw DeviceTransportError.invalidDeviceResponse }
                self.delegate?.activityStream(didRecieveEntry: LogEntry(entry.pointee))
            }
        }
    }

    /// Does not free a handle from under a blocking native read. The worker keeps
    /// its serial slot until that call retires; hard native deadlines need an FFI update.
    public func stop() {
        stateLock.lock()
        let token = stream
        stateLock.unlock()
        token?.cancel()
    }

    deinit { stop() }
}
