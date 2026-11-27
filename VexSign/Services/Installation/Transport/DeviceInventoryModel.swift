//
//  DeviceInventoryModel.swift
//  VexSign
//
//  Library-app-scoped device inventory over the existing pairing session.
//  This is a presentation/owner model, not a second transport: every native
//  call goes through PairingBridge, and every result must carry the frozen
//  device/record binding from that session.
//

import Foundation
import Combine
import IDeviceSwift
import NimbleExtensions

/// Bounded query port so deterministic tests can supply protocol-level readings
/// without a physical device. Production uses the paired service.
protocol DeviceInstalledAppQuerying: Sendable {
    func application(
        for identifier: String,
        request: DeviceConnectionRequest,
        reporting: @escaping @Sendable (DeviceConnectionStage) -> Void
    ) async throws -> DeviceInstalledApplication?
}

struct PairedDeviceInventoryQuery: DeviceInstalledAppQuerying {
    func application(
        for identifier: String,
        request: DeviceConnectionRequest,
        reporting: @escaping @Sendable (DeviceConnectionStage) -> Void
    ) async throws -> DeviceInstalledApplication? {
        try await MainActor.run {
            try await PairingBridge.queryInstalledApplication(
                identifier,
                expectedDevice: request.expectedDeviceIdentifier,
                fingerprint: request.expectedPairingSHA256,
                reporting: reporting
            )
        }
    }
}

@MainActor
final class DeviceInventoryModel: ObservableObject {
    static let taskSubject = "device-library-inventory"

    @Published private(set) var rows: [DeviceInstalledAppRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var stageTitle: String?
    @Published private(set) var message: String?

    private let query: any DeviceInstalledAppQuerying
    private let requestProvider: @MainActor () async throws -> DeviceConnectionRequest
    private var operation: Task<Void, Never>?
    private var taskRecord: UnifiedTask?

    init(
        query: any DeviceInstalledAppQuerying = PairedDeviceInventoryQuery(),
        requestProvider: @escaping @MainActor () async throws -> DeviceConnectionRequest = {
            try await PairingBridge.installationRequest()
        }
    ) {
        self.query = query
        self.requestProvider = requestProvider
    }

    /// Reads the selected device once per library app, in order. The native
    /// executor permits only one device operation at a time; this loop never
    /// overlaps its own queries and stops between apps on cancellation.
    func refresh(apps: [LibraryAppRecord]) {
        guard !isRefreshing else { return }
        let eligible = DeviceInstalledAppAssessment.eligible(apps)
        guard !eligible.isEmpty else {
            message = .localized("The library has no app with a valid bundle identifier to query on the selected device.")
            return
        }
        let center = UnifiedTaskCenter.shared
        guard TaskSubmissionPolicy.inFlight(
            kind: .deviceSetup, subjectID: Self.taskSubject, in: center.tasks
        ) == nil else { return }

        isRefreshing = true
        stageTitle = UnifiedTaskPhase.inspectingPairing.title
        message = nil
        let record = center.begin(
            kind: .deviceSetup,
            title: .localized("Read installed-app inventory"),
            progress: 0,
            subjectID: Self.taskSubject
        )
        taskRecord = record

        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.operation = nil
                self.isRefreshing = false
                self.stageTitle = nil
                self.taskRecord = nil
            }
            do {
                try Task.checkCancellation()
                let request = try await self.requestProvider()
                guard let binding = request.binding else {
                    throw DeviceTransportError.expectedDeviceRequired
                }
                try Task.checkCancellation()
                LibraryStatusStore.shared.selectDevice(binding: binding)

                var readings: [DeviceInstalledAppRow] = []
                readings.reserveCapacity(eligible.count)
                for (index, app) in eligible.enumerated() {
                    try Task.checkCancellation()
                    let observed = try await self.query.application(
                        for: app.identifier ?? "",
                        request: request,
                        reporting: { stage in
                            Task { @MainActor [weak self] in self?.stageTitle = stage.rawValue }
                        }
                    )
                    try Task.checkCancellation()
                    if let observed {
                        // Only a positive, same-device reading may refresh the
                        // library badge. The store repeats all evidence checks.
                        LibraryStatusStore.shared.recordInstalledApplicationObservation(
                            InstalledApp(application: observed)
                        )
                    }
                    let build = app.bundleURL
                        .flatMap { SignatureVerifier.readInfo(at: $0)?["CFBundleVersion"] as? String }
                        .flatMap { TaskContext.versionToken($0) }
                    readings.append(DeviceInstalledAppAssessment.make(
                        for: app, expectedBuild: build, observed: observed, binding: binding
                    ))
                    center.transition(
                        record, to: .inspectingPairing,
                        progress: Double(index + 1) / Double(eligible.count)
                    )
                }
                guard !Task.isCancelled else { throw CancellationError() }
                self.rows = readings
                self.refreshedAt = Date()
                record.context?.confirmationReason = "device-library-inventory-read"
                center.transition(record, to: .completed)
                self.message = .localized("The selected device was queried for each library bundle identifier. A missing report means comparable metadata was unavailable, not that the app is absent.")
            } catch {
                record.context?.recordFailure(error)
                if error is CancellationError || error as? DeviceTransportError == .operationCancelled {
                    center.transition(record, to: .cancelled)
                    self.message = .localized("Inventory refresh was cancelled. Partial readings were not published.")
                } else {
                    center.transition(record, to: .failed, error: error.localizedDescription)
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        operation?.cancel()
    }

    func clear() {
        cancel()
        rows = []
        refreshedAt = nil
        message = nil
    }
}
