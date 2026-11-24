//
//  NetworkReachabilityMonitor.swift
//  VexSign
//
//  General reachability monitoring for callers that need to know whether the
//  device is online, on an expensive path, or constrained. Download admission
//  keeps its own monitor in DownloadPreferences; this is the injectable
//  primitive for everything else. The caller owns the monitor and must call
//  `stop()` when it is done.

import Foundation
import Network

final class NetworkReachabilityMonitor {
    enum Status: Equatable, Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "VexSign.Networking.Monitoring")
    private let lock = NSLock()
    private var _status: Status = .requiresConnection
    private var _isExpensive = true
    private var _isConstrained = false

    /// Called on the monitor queue whenever the path changes.
    var onChange: ((Status, Bool, Bool) -> Void)?

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isExpensive
    }

    var isConstrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConstrained
    }

    var isSatisfied: Bool { status == .satisfied }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status: Status
            switch path.status {
            case .satisfied: status = .satisfied
            case .unsatisfied: status = .unsatisfied
            case .requiresConnection: status = .requiresConnection
            @unknown default: status = .unsatisfied
            }
            self.lock.lock()
            self._status = status
            self._isExpensive = path.isExpensive
            self._isConstrained = path.isConstrained
            self.lock.unlock()
            self.onChange?(status, path.isExpensive, path.isConstrained)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
