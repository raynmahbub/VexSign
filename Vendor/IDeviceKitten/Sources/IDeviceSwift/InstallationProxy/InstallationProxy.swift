//
//  ConduitInstaller.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import Foundation
import SwiftUI
import IDevice
import UIKit.UIApplication

public class InstallationProxy: Identifiable, ObservableObject {
	private let _heartbeat = HeartbeatManager.shared
	private let _uuid = UUID().uuidString
	
	typealias AfcClientHandle = OpaquePointer
	typealias AfcFileHandle = OpaquePointer
	typealias InstallationProxyClientHandle = OpaquePointer
	
	@ObservedObject
	public var viewModel: InstallerStatusViewModel
	
	public init(viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
	}
	
	public func install(at url: URL, suspend: Bool = false) async throws {
		var afcClient: AfcClientHandle?
		var fileHandle: AfcFileHandle?
		var installproxy: InstallationProxyClientHandle?
		
        let uploadTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
			guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
				throw IDeviceSwiftError(message: "Missing Pairing")
			}
			
			if await self._heartbeat.isRsd {
				guard await self._heartbeat.ensureRSDTunnel() else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
			} else {
				guard await self._heartbeat.checkSocketConnection().isConnected else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
			}
			
            defer {
                if let handle = fileHandle { _ = afc_file_close(handle) }
                afc_client_free(afcClient)
				installation_proxy_client_free(installproxy)
			}
			
			let heartbeat = await self._heartbeat
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}
	
				guard afc_client_connect_rsd(adapter, handshake, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				
				guard afc_client_connect(provider, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			}
			
			let stagingDir = "PublicStaging"
			
			let afc_make_directory_result =  afc_make_directory(afcClient, stagingDir)
			guard afc_make_directory_result == nil else {
				throw IDeviceSwiftError(afc_make_directory_result)
			}
			
			print("1")
			
			let remoteDir = "/\(stagingDir)/\(self._uuid).ipa"
			
			let afc_file_open_result = afc_file_open(afcClient, remoteDir, AfcWrOnly, &fileHandle)
			guard afc_file_open_result == nil else {
				throw IDeviceSwiftError(afc_file_open_result)
			}
			
			print("2")
			
			try await self._updateStatus(with: .sendingPayload)
			
            guard let remoteHandle = fileHandle else {
                throw IDeviceSwiftError(message: "Missing File Handle")
            }

            // VexSign local patch: bounded reads; the FFI pointer never escapes Data's scope.
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() } // try? ok: preserve any original transport failure
            let totalSize = try input.seekToEnd()
            guard totalSize > 0 else { throw IDeviceSwiftError(message: "Empty installation payload") }
            try input.seek(toOffset: 0)
            let chunkSize = 1024 * 1024
            var sent: UInt64 = 0
            var lastProgress = 0.0
            while sent < totalSize {
                try Task.checkCancellation()
                let requested = Int(min(UInt64(chunkSize), totalSize - sent))
                guard let data = try input.read(upToCount: requested), !data.isEmpty else {
                    throw IDeviceSwiftError(message: "Installation payload ended before upload completed")
                }
                try data.withUnsafeBytes { buffer in
                    guard let pointer = buffer.bindMemory(to: UInt8.self).baseAddress else {
                        throw IDeviceSwiftError(message: "Cannot read installation payload bytes")
                    }
                    if let error = afc_file_write(remoteHandle, pointer, data.count) {
                        throw IDeviceSwiftError(error)
                    }
                }
                sent += UInt64(data.count)
                let progress = Double(sent) / Double(totalSize)
                if progress - lastProgress >= 0.01 || sent == totalSize {
                    lastProgress = progress
                    try await self._updateUploadProgress(with: progress)
                }
            }
            try Task.checkCancellation()
            let closeError = afc_file_close(remoteHandle)
            fileHandle = nil // The close consumes the handle; never close it a second time.
            if let closeError { throw IDeviceSwiftError(closeError) }

			try await self._updateStatus(with: .installing)
			
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}
				
				print(3)
				
				let installation_proxy_connect_rsd_result = installation_proxy_connect_rsd(adapter, handshake, &installproxy)
				guard installation_proxy_connect_rsd_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_rsd_result)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				let installation_proxy_connect_result = installation_proxy_connect(provider, &installproxy)
				guard installation_proxy_connect_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_result)
				}
			}
			
			print(4)
			
            try Task.checkCancellation()
            let installError: UnsafeMutablePointer<IdeviceFfiError>? = remoteDir.withCString { cString in
				let context = Unmanaged.passUnretained(self).toOpaque()
				
				if suspend {
					DispatchQueue.main.async {
						UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
					}
				}
				
				return installation_proxy_install_with_callback(
					installproxy,
					cString,
					nil, // options
					Self._installationProgressCallback,
					context
				)
			}
			
			guard installError == nil else {
				throw IDeviceSwiftError(installError)
			}
			
			try await Task.sleep(nanoseconds: 350_000_000)
			try await self._updateStatus(with: .completed(.success(())))
        }
        try await withTaskCancellationHandler(operation: {
            try await uploadTask.value
        }, onCancel: {
            uploadTask.cancel()
        })
    }

    private func _updateStatus(with status: InstallerStatusViewModel.InstallerStatus) async throws {
		await MainActor.run {
			self.viewModel.status = status
		}
	}
	
	private func _updateUploadProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.uploadProgress = status
		}
	}
	
	nonisolated static private let _installationProgressCallback: @convention(c) (
		UInt64,
		UnsafeMutableRawPointer?
	) -> Void = { progress, context in
		guard let context = context else { return }
		let installer = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
		Task {
			try? await installer._updateInstallProgress(with: Double(progress) / 100.0)
		}
	}
	
	private func _updateInstallProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.installProgress = status
		}
	}
}
